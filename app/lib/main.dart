// Last modified: 2026-07-25--2115
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'artwork/artwork_backfill.dart';
import 'artwork/artwork_resolver.dart';
import 'artwork/artwork_store.dart';
import 'model/app_config.dart';
import 'model/library_model.dart';
import 'model/library_roots_prefs.dart';
import 'model/playlist_store.dart';
import 'platform_paths.dart';
import 'player/player_service.dart';
import 'ui/adaptive.dart';
import 'ui/app_theme.dart';
import 'ui/home_screen.dart';
import 'ui/layout_prefs.dart';
import 'ui/phone/browse_views.dart';
import 'ui/phone/mini_player.dart';
import 'ui/phone/phone_settings_view.dart';
import 'ui/phone/phone_shell.dart';
import 'ui/phone/track_context_sheet.dart';

/// How often [LibraryModel.rescan] runs on its own, in addition to the
/// launch-time and Refresh-button triggers -- see main() below.
const _rescanInterval = Duration(minutes: 5);

File _configFile(Directory dataDir) =>
    File(p.join(dataDir.path, 'config.json'));

/// Reads the whole config.json as a map (empty map if missing; see
/// [readConfigFile] for the corrupt-file handling). Every key this app
/// doesn't otherwise interpret is preserved so it round-trips through
/// [_writeConfig] untouched.
Map<String, dynamic> _loadConfig(Directory dataDir) =>
    readConfigFile(_configFile(dataDir));

void _writeConfig(Map<String, dynamic> config, Directory dataDir) =>
    writeConfigFile(_configFile(dataDir), config);

/// Flushes any debounced [LayoutPrefs] write and cancels the periodic
/// library-rescan [Timer] on app shutdown, so a drag-a-divider-then-close
/// sequence isn't silently lost and the app doesn't keep a dangling timer
/// (and the isolates/IO it would eventually trigger) alive past exit.
///
/// Two hooks are wired for reliability, since desktop shutdown paths vary
/// by platform/embedder version:
///
/// - [AppLifecycleListener.onExitRequested] is the modern, awaitable
///   exit-request flow -- on Windows the engine's WindowsLifecycleManager
///   intercepts WM_CLOSE on the last window, asks the framework via this
///   callback whether it's OK to exit, and only re-dispatches the real
///   close (and lets the process actually terminate) after the returned
///   future completes. This reliably runs our flush *before* the process
///   goes away, which is exactly the guarantee needed here.
/// - [WidgetsBindingObserver.didChangeAppLifecycleState]'s
///   [AppLifecycleState.detached] transition is wired too, as a
///   defense-in-depth fallback for any shutdown path that bypasses the
///   exit-request flow (e.g. a future/alternate embedder, or a runner
///   without the WM_CLOSE-interception plumbing).
class _LifecycleFlusher with WidgetsBindingObserver {
  final LayoutPrefs layoutPrefs;
  final Timer? rescanTimer;

  /// Cancelled on shutdown too: the background artwork pass must not keep
  /// issuing provider requests (or writing sidecars) while the process is
  /// tearing down. [ArtworkBackfill.cancel] is synchronous and never waits
  /// on in-flight I/O, so this can't delay exit.
  final ArtworkBackfill? artworkBackfill;

  _LifecycleFlusher(this.layoutPrefs, {this.rescanTimer, this.artworkBackfill}) {
    WidgetsBinding.instance.addObserver(this);
    AppLifecycleListener(
      onExitRequested: () async {
        layoutPrefs.flush();
        rescanTimer?.cancel();
        artworkBackfill?.cancel();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      layoutPrefs.flush();
      rescanTimer?.cancel();
      artworkBackfill?.cancel();
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final dataDir = await appDataDir();
  final defaultRoot = (await defaultLibraryRoots()).first;
  final rawConfig = _loadConfig(dataDir);
  final appConfig = migrateConfig(rawConfig, defaultRoot: defaultRoot);
  // `config` (appConfig.raw) is the single mutable map every writer below
  // reads from and persists via _writeConfig -- it already carries the
  // migrated `libraryRoots` plus every other preserved key (e.g. `"ui"`).
  final config = appConfig.raw;
  if (needsMigrationWrite(rawConfig)) {
    _writeConfig(config, dataDir);
  }

  final library = LibraryModel();
  final player = PlayerService();
  // On-play duration backfill: when the engine reports a real duration for
  // a track whose library metadata has none (its cache entry was persisted
  // with durationMs: null because the tag parser couldn't derive one --
  // e.g. an APEv2-tagged MP3; see PlayerService.onObservedDuration), fold
  // it back into the library + tag cache so the track permanently gains
  // its Time value from having been played once.
  player.onObservedDuration = (contentId, duration) =>
      library.updateDuration(contentId, duration.inMilliseconds);

  final layoutPrefs = LayoutPrefs.fromConfig(
    config['ui'] as Map<String, dynamic>?,
    writer: (ui) {
      config['ui'] = ui;
      _writeConfig(config, dataDir);
    },
  );

  // ---- Artwork (Plan 4) ---------------------------------------------------
  // One store per library root (sidecar `.artwork.json` + `.artwork/` image
  // cache inside the root; app-data fallback when the root is read-only),
  // one resolver shared by every art surface, and the throttled background
  // best-guess pass.
  final artworkStores = ArtworkStoreRegistry(appDataDir: dataDir);
  final artworkResolver = ArtworkResolver(stores: artworkStores);
  final artworkBackfill = ArtworkBackfill(
    resolver: artworkResolver,
    // MERGE POINT (task A1 -- providers + scoring). `enabled: false` keeps
    // the automatic pass switched OFF until the three seams below are real:
    // with stub providers every album would come back "no confident match"
    // and earn a 14-day negative-cache record, poisoning the sidecar before
    // the real providers ever ran. It also means this build issues no
    // network request whatsoever. Wiring is three one-liners plus flipping
    // `enabled` to true:
    //   search:     (q) => searchAll(ArtQuery(artist: q.artist, album: q.album))
    //   autoPick:   (c, q) { final b = bestGuess(c.cast<ArtCandidate>());
    //                        return b == null ? null
    //                          : ArtworkPick(url: b.url, source: b.source); }
    //   downloader: (url) => httpGetBytes(url)
    enabled: false,
    search: (_) async => const <dynamic>[],
    autoPick: (_, _) => null,
    downloader: (_) async => null,
  );

  final cacheFile = File(p.join(dataDir.path, 'meta_cache.json'));
  final libraryRootsPrefs = LibraryRootsPrefs(
    roots: appConfig.libraryRoots,
    writer: (roots) {
      config['libraryRoots'] = roots;
      _writeConfig(config, dataDir);
    },
  );
  // [triggerLaunchRescan] is true only for the very first load (app
  // launch): that's the one load() call main.dart wires an automatic
  // rescan onto. The rescan is fired only *after* load() itself has fully
  // settled (feed rendered AND tag enrichment finished) -- not a delay
  // anyone can see, since the instant feed already rendered minutes/seconds
  // earlier via load()'s own internal notifyListeners() calls; awaiting
  // load() here only postpones *starting the rescan*, never the feed. This
  // sequencing -- await load(), then call rescan() -- is deliberately the
  // "simplest, honest" wiring: rescan() itself refuses to run while
  // LibraryModel.busy is still held (see its guard), and load() holds that
  // flag for its own entire duration (feed + enrichment), so firing rescan
  // from *inside* load() (as an early "first feed rendered" hook used to)
  // would always find the flag still held and silently no-op every time.
  // Reloads triggered by a settings-dialog root add/remove don't also kick
  // off a rescan here -- the periodic timer and Refresh button already
  // cover ongoing discovery of new files.
  Future<void> reloadLibrary({bool triggerLaunchRescan = false}) async {
    // Supersede any pass still sweeping the previous root set. cancel() is
    // synchronous and run() serializes behind it, so this can't delay the
    // reload or double up on provider traffic.
    artworkBackfill.cancel();
    await library.load(
      libraryRoots: libraryRootsPrefs.roots.map(Directory.new).toList(),
      cacheFile: cacheFile,
    );
    if (triggerLaunchRescan) {
      library.rescan();
    }
    // Background best-guess pass, queued once load() has fully settled
    // (feed rendered AND tag enrichment finished -- artist/album tags are
    // what the album key is built from, so running earlier would key off
    // filename guesses). Fire-and-forget: never awaited on any UI path, and
    // it never writes LibraryModel.status.
    unawaited(
      artworkBackfill.run(artworkBackfillRequests(library.allTracks)),
    );
  }

  // Settings-dialog add/remove calls writer() above then notifies -- react
  // by reloading so the merged feed/playlists reflect the new root set.
  libraryRootsPrefs.addListener(reloadLibrary);

  // Periodic background rescan (Task 5's third trigger, alongside launch
  // and the Refresh button): LibraryModel.rescan() is itself a no-op
  // whenever a load()/rescan() is already in flight, so an overlap here --
  // e.g. a slow SMB rescan still running when the next 5-minute tick fires
  // -- just skips that tick rather than piling up concurrent scans.
  final rescanTimer = Timer.periodic(_rescanInterval, (_) => library.rescan());

  _LifecycleFlusher(
    layoutPrefs,
    rescanTimer: rescanTimer,
    artworkBackfill: artworkBackfill,
  );
  WidgetsBinding.instance
      .addPostFrameCallback((_) => reloadLibrary(triggerLaunchRescan: true));
  runApp(FooPlayerApp(
    library: library,
    player: player,
    layoutPrefs: layoutPrefs,
    libraryRootsPrefs: libraryRootsPrefs,
    artworkResolver: artworkResolver,
  ));
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  final LibraryRootsPrefs libraryRootsPrefs;

  /// Shared artwork resolution chain (Plan 4) -- handed to every art
  /// surface so desktop bar, phone mini-player and phone Now Playing all
  /// read from one cache and refresh together when a pick changes.
  final ArtworkResolver? artworkResolver;

  const FooPlayerApp({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
    required this.libraryRootsPrefs,
    this.artworkResolver,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fooplayer',
      theme: buildAppTheme(),
      // Adaptive form-factor switch (Plan 2b): Android (or a future
      // phone-sized mobile target) gets the PhoneShell; desktop keeps the
      // panel layout untouched -- see usePhoneShell's doc for the exact
      // rule (a desktop OS never satisfies it). The Builder exists so the
      // check runs under MaterialApp's MediaQuery.
      home: Builder(
        builder: (context) {
          if (!usePhoneShell(context)) {
            return HomeScreen(
              library: library,
              player: player,
              layoutPrefs: layoutPrefs,
              libraryRootsPrefs: libraryRootsPrefs,
              artworkResolver: artworkResolver,
            );
          }
          // Phone integration wiring (Plan 2b merge): P2's MiniPlayer fills
          // the mini-player slot (it self-hides when no track is loaded),
          // P3's browse views plus the Settings page fill the viewBuilders
          // map (every drawer destination has a real body -- no
          // placeholders), and P3's real track context sheet (Add to
          // playlist / View details) handles feed and search long-presses.
          // Same PlaylistStore-per-build pattern as HomeScreen (the store
          // is a stateless facade over the library).
          final store = PlaylistStore(library: library);
          return PhoneShell(
            library: library,
            player: player,
            onTrackLongPress: (sheetContext, track) => showTrackContextSheet(
              sheetContext,
              track: track,
              library: library,
              store: store,
            ),
            miniPlayerBuilder: (_) =>
                MiniPlayer(player: player, artworkResolver: artworkResolver),
            viewBuilders: {
              PhoneView.folders: (_) => FoldersView(
                    library: library,
                    store: store,
                    onPlayTrack: player.playFrom,
                  ),
              PhoneView.artists: (_) => ArtistsView(
                    library: library,
                    store: store,
                    onPlayTrack: player.playFrom,
                  ),
              PhoneView.albums: (_) => AlbumsView(
                    library: library,
                    store: store,
                    onPlayTrack: player.playFrom,
                  ),
              PhoneView.playlists: (_) => PlaylistsView(
                    library: library,
                    store: store,
                    onPlayTrack: player.playFrom,
                  ),
              // Settings as a page (plan: "reuses existing SettingsDialog
              // content"): same roots editor + prefs the desktop dialog
              // uses, so add/remove triggers the same config write +
              // library reload via libraryRootsPrefs' listener above.
              PhoneView.settings: (_) => PhoneSettingsView(
                    library: library,
                    libraryRootsPrefs: libraryRootsPrefs,
                  ),
            },
          );
        },
      ),
    );
  }
}
