// Last modified: 2026-08-04--0131
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import 'artwork/artwork_backfill.dart';
import 'artwork/artwork_resolver.dart';
import 'artwork/artwork_store.dart';
import 'artwork/artwork_wiring.dart';
import 'artwork/picker_seams.dart';
import 'model/app_config.dart';
import 'metadata/tag_providers.dart';
import 'model/activity_model.dart';
import 'model/library_home.dart';
import 'model/library_model.dart';
import 'model/library_roots_prefs.dart';
import 'model/playlist_migration.dart';
import 'model/playlist_store.dart';
import 'model/set_up_root.dart';
import 'platform_paths.dart';
import 'model/track.dart';
import 'player/audio_handler.dart';
import 'player/player_service.dart';
import 'sync/playlist_reconciler.dart';
import 'sync/smb_transport.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_foreground.dart';
import 'sync/sync_settings.dart';
import 'ui/adaptive.dart';
import 'ui/app_theme.dart';
import 'ui/home_screen.dart';
import 'ui/layout_prefs.dart';
import 'ui/phone/browse_views.dart';
import 'ui/phone/mini_player.dart';
import 'ui/phone/phone_settings_view.dart';
import 'ui/phone/phone_shell.dart';
import 'ui/phone/storage_access.dart';
import 'ui/phone/track_context_sheet.dart';
import 'ui/sync_view.dart';

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

  _LifecycleFlusher(
    this.layoutPrefs, {
    this.rescanTimer,
    this.artworkBackfill,
  }) {
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

/// One tick of the background rescan+artwork timer.
///
/// Extracted from the Timer so it can be tested. The bug that made this worth
/// doing: the model's `quiet` flag worked, and a model-level test proved it,
/// but main.dart's timer never passed it -- so the every-five-minutes scan
/// narrated its way through all five roots, and on this library that takes
/// long enough that "Scanning ..." was showing more or less permanently.
/// Nothing covered the wiring, which is where the mistake was.
///
/// Quiet because nobody asked for this scan. A user-initiated one (the
/// Refresh button) still announces itself, and a quiet pass that actually
/// FINDS something still reports "added N new tracks".
Future<void> periodicRescanTick(
  LibraryModel library,
  ArtworkBackfill backfill,
) => rescanThenBackfill(
  rescan: () => library.rescan(quiet: true),
  backfill: backfill,
  tracks: () => library.allTracks,
  // A tick must not cut short a pass that is already working -- see
  // rescanThenBackfill's note. Whatever this tick would have queued is in the
  // running pass's list already, or will be at the next tick.
  yieldToRunningPass: true,
);

/// A `file://` URI for [track]'s cover, for the lock screen to draw.
///
/// Android wants a URI, not bytes, so whatever the resolver produces --
/// embedded art, a sidecar choice, a folder image -- is cached to one file
/// per track and handed over by path. Returns null when there is no cover,
/// which shows Android's own placeholder rather than a stale one.
Future<Uri?> _lockScreenArt(
  Track track,
  ArtworkResolver resolver,
  Directory dataDir,
) async {
  try {
    final cacheDir = Directory(p.join(dataDir.path, 'lockscreen'));
    final file = File(p.join(cacheDir.path, '${track.contentId}.img'));
    if (file.existsSync() && file.lengthSync() > 0) return file.uri;
    final bytes = await resolver.resolve(ArtworkRequest.forTrack(track));
    if (bytes == null || bytes.isEmpty) return null;
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.uri;
  } catch (_) {
    // A cover is a nicety; never let one stop playback from starting.
    return null;
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

  // Ask for storage before the first load, on Android. Without it the app can
  // LIST a music folder and open nothing in it -- which presents as an empty
  // library rather than as a permission problem, and cost an evening on the
  // tablet before anyone thought to check.
  if (Platform.isAndroid && !await hasFullStorageAccess()) {
    await requestFullStorageAccess();
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
  // One wiring object joins the three halves of the feature: A1's keyless
  // providers + scorer, A2's per-root sidecar store / display resolution
  // chain / background pass, and A3's picker. Everything network-facing is
  // an injected seam inside [ArtworkWiring]; this is the only place the
  // production HTTP implementations are actually selected.
  //
  // The automatic best-guess pass is ON now that the providers behind it are
  // real: with the stub seams it shipped with, every album would have come
  // back "no confident match" and earned a 14-day negative-cache record.
  final activity = ActivityModel();
  final artwork = ArtworkWiring.production(appDataDir: dataDir);
  final artworkResolver = artwork.resolver;
  final artworkBackfill = artwork.backfill;
  final artworkServices = artwork.services;

  final cacheFile = File(p.join(dataDir.path, 'meta_cache.json'));
  final libraryRootsPrefs = LibraryRootsPrefs(
    roots: appConfig.libraryRoots,
    writer: (roots) {
      config['libraryRoots'] = roots;
      _writeConfig(config, dataDir);
    },
  );

  // Who signs `modified_by` on every playlist file this device writes (Plan
  // 3) -- config `deviceName` if set, else the OS hostname.
  final device = deviceLabel(config);

  // Where `.playlists/` lives: the deepest common parent of every
  // configured root, or the `libraryHome` config override verbatim.
  // Recomputed on every [reloadLibrary] (roots can change via Settings);
  // this first value is only for the one-time migration below.
  String? currentLibraryHome() => resolveLibraryHome(
    libraryRootsPrefs.roots,
    override: config['libraryHome'] as String?,
  );

  // ---- LAN sync (Plan 3 Tasks 9-11) --------------------------------------
  // Mutable holder for the persisted `"sync"` config block. `syncUi` below
  // hands the UI a GETTER (`() => syncSettings`), never this value directly,
  // so reopening the sync UI later in the same run sees whatever the
  // previous visit's edits already saved rather than the value at launch.
  var syncSettings = SyncSettings.fromConfig(config) ?? SyncSettings();
  void saveSyncSettings(SyncSettings s) {
    syncSettings = s;
    config['sync'] = s.toJson();
    _writeConfig(config, dataDir);
  }

  // Where a sync lands. Same resolution as the playlists home, but with a
  // concrete fallback for the one case that has neither a configured root
  // nor a `libraryHome` override yet: the very first sync ever run, before
  // this device has any music folder configured at all.
  String syncLocalHomePath() =>
      currentLibraryHome() ?? '/storage/emulated/0/Music';

  // Every SmbTransport/PlaylistReconciler/SyncEngine below is constructed
  // freshly INSIDE these closures and closed again before returning --
  // never held across calls. On a non-Android build these are simply never
  // invoked (see the `Platform.isAndroid` gates on `syncUi`/`syncScheduler`
  // below), so nothing here ever reaches for a platform channel that
  // doesn't exist there.
  Future<List<String>> discoverSyncRoots() async {
    final s = syncSettings;
    final transport = SmbTransport(
      host: s.host,
      share: s.share,
      basePath: s.basePath,
    );
    try {
      // One shallow SMB listing of the base -- the old listTree('') walked
      // the ENTIRE share (~15k files) just to derive five folder names,
      // which took minutes over real Wi-Fi and made the roots list look
      // permanently stuck (found live on the Tab S9+, 2026-08-02).
      final topLevel = await transport.listDirNames('');
      final withManifest = <String>[];
      for (final name in topLevel) {
        final bytes = await transport.readFile(
          '$name/${core.manifestFileName}',
        );
        if (bytes != null) withManifest.add(name);
      }
      withManifest.sort();
      return withManifest;
    } finally {
      // A thrown exception inside a `finally` REPLACES whatever the `try`
      // was about to return/throw -- so a close()-time failure here would
      // silently discard the discovered root list. close() failing is never
      // more important than the result it's cleaning up after; swallow it.
      try {
        await transport.close();
      } catch (_) {}
    }
  }

  Future<bool> probeSyncNow() async {
    final s = syncSettings;
    final transport = SmbTransport(
      host: s.host,
      share: s.share,
      basePath: s.basePath,
    );
    try {
      return await transport.probe();
    } finally {
      // See discoverSyncRoots' comment above -- same reasoning.
      try {
        await transport.close();
      } catch (_) {}
    }
  }

  // Holds whatever SyncEngine [runSyncNow] currently has in flight -- the
  // seam [cancelSync] below needs to reach it. Null whenever no sync is
  // running (including between the two: a stray cancelSync() call while
  // idle is simply a no-op, which is exactly right since SyncView only
  // ever surfaces its Cancel button while a run is actually in progress).
  SyncEngine? runningSyncEngine;

  Future<SyncReport> runSyncNow() async {
    final s = syncSettings;
    final localHomePath = syncLocalHomePath();
    final transport = SmbTransport(
      host: s.host,
      share: s.share,
      basePath: s.basePath,
    );
    try {
      final engine = SyncEngine(
        transport: transport,
        localHome: Directory(localHomePath),
        settings: s,
        library: library,
        activity: activity,
        freeSpace: SmbTransport.freeSpace,
        reconciler: PlaylistReconciler(
          localHome: Directory(localHomePath),
          transport: transport,
          localLabel: device,
        ),
        // Whole-branch review, Finding I-1: lets SyncEngine.cancel()
        // interrupt whatever chunk this transport is mid-download on RIGHT
        // NOW, instead of only stopping the loop between files.
        onCancelTransport: () => transport.cancelInFlight(),
      );
      runningSyncEngine = engine;
      final report = await engine.run();
      // A checked root's local folder is only worth adopting once a sync
      // that could have created it has actually run -- never for the bare
      // NAS-unreachable sentinel (RootSyncResult.rootName == '', see
      // SyncEngine.run's doc), which never attempted a single real root.
      if (report.roots.any((r) => r.rootName.isNotEmpty)) {
        for (final entry in s.roots.entries) {
          if (!entry.value) continue;
          final localRootPath = p.join(localHomePath, entry.key);
          if (libraryRootsPrefs.roots.contains(localRootPath)) continue;
          if (Directory(localRootPath).existsSync()) {
            libraryRootsPrefs.addRoot(localRootPath);
          }
        }
      }
      return report;
    } finally {
      // Cleared before close() below -- once this engine is done (success,
      // failure, or aborted), cancelSync() must go back to being a no-op
      // rather than reaching a finished engine's now-meaningless cancel().
      runningSyncEngine = null;
      // Most important of the four: this is the one whose `try` most often
      // completes with real, hard-won work (a computed SyncReport) to
      // return -- and a half-dead SMB session (e.g. exactly the kind that
      // just made a root abort with "connection lost") is also exactly the
      // kind most likely to throw on close(). Losing that report to a
      // close()-time PlatformException would make files that genuinely
      // copied look like nothing happened at all.
      try {
        await transport.close();
      } catch (_) {}
    }
  }

  // The Cancel button's seam (SyncView -> SyncUiSeams.cancelSync):
  // interrupts whatever [runSyncNow] currently has in flight. A no-op when
  // nothing is running -- see [runningSyncEngine]'s doc.
  Future<void> cancelSync() async {
    runningSyncEngine?.cancel();
  }

  // Standalone playlist reconcile, for the scheduler's own cadence (app
  // start / 5-minute tick / debounced-after-edit) -- deliberately NOT
  // routed through SyncEngine.run(), which would also attempt every checked
  // music-file root on each of those triggers. SyncEngine's own reconcile
  // phase reloads playlists internally when it produces notes (Task 9); this
  // standalone path has to do the same thing itself, since it never goes
  // through SyncEngine at all.
  Future<List<String>> runPlaylistReconcileOnly() async {
    final s = syncSettings;
    final localHomePath = syncLocalHomePath();
    final transport = SmbTransport(
      host: s.host,
      share: s.share,
      basePath: s.basePath,
    );
    try {
      final reconciler = PlaylistReconciler(
        localHome: Directory(localHomePath),
        transport: transport,
        localLabel: device,
      );
      final notes = await reconciler.run();
      if (notes.isNotEmpty) {
        library.reloadPlaylists();
      }
      return notes;
    } finally {
      // See discoverSyncRoots' comment above -- same reasoning.
      try {
        await transport.close();
      } catch (_) {}
    }
  }

  // The six SyncView seams, bundled for the UI to thread through (see
  // SyncUiSeams' doc) -- Android only, since there is no SMB bridge
  // implementation anywhere else. Null hides every sync entry point
  // (SettingsDialog's "Sync…" button, PhoneSettingsView's "Sync" tile)
  // regardless of screen size/layout.
  final syncUi = Platform.isAndroid
      ? SyncUiSeams(
          currentSettings: () => syncSettings,
          onSave: saveSyncSettings,
          runSync: runSyncNow,
          probe: probeSyncNow,
          discoverRoots: discoverSyncRoots,
          cancelSync: cancelSync,
        )
      : null;

  // Android-only playlist sync scheduler (Plan 3 Task 8) -- probe-gated,
  // debounced auto-cadence over [PlaylistReconciler]. Constructed eagerly
  // (unlike the transport/engine objects above, which are built fresh per
  // call) because its onAppStart/onPeriodicTick hooks need to be live from
  // the very first load -- null on every other platform, which is what
  // keeps PlaylistStore.onMutated, the periodic-rescan tick, and the
  // post-first-load app-start hook all inert there (every call is `?.`).
  final syncScheduler = Platform.isAndroid
      ? PlaylistSyncScheduler(
          probe: probeSyncNow,
          runReconcile: runPlaylistReconcileOnly,
        )
      : null;

  // Sync-survives-backgrounding: mirrors the [ActivityIds.sync] job onto
  // Android's SyncForegroundService (SmbBridge.kt's syncFg* methods) so a
  // sync keeps its network alive with the app backgrounded and shows a
  // system-wide progress notification for as long as it runs -- reported
  // live as "connection closed midstream" the moment the phone was
  // backgrounded, with no indicator anywhere that a sync was in flight.
  // Android-only for the same reason [syncUi]/[syncScheduler] are: there is
  // no SMB bridge (and so no `syncFgStart`/`syncFgUpdate`/`syncFgStop`
  // channel handler) on any other platform. Held (never disposed) for the
  // app's lifetime, same as every other top-level wiring object here.
  if (Platform.isAndroid) {
    SyncForegroundNotifier(
      activity,
      invoke: (method, [args]) => const MethodChannel(
        'dev.mklod.fooplayer/smb',
      ).invokeMethod(method, args),
    );
  }

  // One-time move of any playlists still sitting in a root's
  // `.library.json` into the shared sidecar (Plan 3 Task 4) -- must run
  // before the very first [reloadLibrary] so that load's playlist merge
  // already reads the sidecar, not a stale pre-migration manifest. A failed
  // migration must not block startup: playlists simply stay in their
  // manifests (still readable the old way, just not by [PlaylistStore]
  // anymore) until it succeeds on a later launch.
  //
  // Gated on `config['playlistsMigrated']`: once every configured root's
  // manifest has been confirmed to have no `playlists` left, this whole
  // pass -- which re-parses every root's `.library.json` (can be
  // megabytes, over SMB) just to find nothing left to do -- is skipped on
  // every subsequent cold start, on the pre-first-frame path. Left unset
  // (so the next launch retries) whenever the post-check can't confirm
  // every root is actually clean -- a root with no manifest yet, or one
  // that migrated cleanly, counts as clean; a root whose manifest fails to
  // parse does not, since that's exactly the kind of transient/corrupt
  // read that deserves another chance rather than being silently written
  // off as "done".
  if (config['playlistsMigrated'] != true) {
    final initialHome = currentLibraryHome();
    if (initialHome != null) {
      final roots = libraryRootsPrefs.roots.map(Directory.new).toList();
      try {
        await migratePlaylistsToSidecar(
          roots: roots,
          home: Directory(initialHome),
          device: device,
        );
        var allClean = true;
        for (final root in roots) {
          final manifestFile = File(p.join(root.path, core.manifestFileName));
          if (!manifestFile.existsSync()) continue; // nothing to migrate
          try {
            if (core.loadManifest(root).playlists.isNotEmpty) {
              allClean = false;
              break;
            }
          } catch (_) {
            allClean = false; // corrupt -- retry next launch
            break;
          }
        }
        if (allClean) {
          config['playlistsMigrated'] = true;
          _writeConfig(config, dataDir);
        }
      } catch (_) {
        // Logged nowhere yet (no crash-reporting wired) -- flag stays
        // unset, so the next launch retries the whole pass.
      }
    }
  }

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

    // Load every root's artwork sidecar. The library view's "Art" column asks
    // the store synchronously (`entryFor`), and a store that has never been
    // loaded answers "nothing recorded" -- so without this, an album whose
    // cover came from a sidecar (a harvested local file, or an online lookup
    // like Gorillaz "El Manana") showed a blank Art cell however much artwork
    // it had.
    //
    // Started BEFORE the load rather than after it: load() does not return
    // until background tag enrichment finishes, which is minutes on this
    // library -- the column would have stayed wrong for all of it.
    unawaited(() async {
      for (final root in libraryRootsPrefs.roots) {
        try {
          await artwork.stores.forRoot(root).ensureLoaded();
        } catch (_) {
          // An unreadable sidecar just means "no recorded picks" here.
        }
      }
      library.notifyDerivedChanged();
    }());

    await library.load(
      libraryRoots: libraryRootsPrefs.roots.map(Directory.new).toList(),
      cacheFile: cacheFile,
      libraryHome: currentLibraryHome(),
    );
    if (triggerLaunchRescan) {
      // Once the launch rescan itself settles, queue a FOLLOW-UP backfill
      // pass covering whatever it discovered -- see [rescanThenBackfill]'s
      // doc for why every rescan trigger (not just load()) needs this.
      unawaited(
        rescanThenBackfill(
          // Quiet: the timer must not narrate a scan nobody asked for.
          rescan: () => library.rescan(quiet: true),
          backfill: artworkBackfill,
          tracks: () => library.allTracks,
        ),
      );
      // First (and only) load of this app run has settled -- this is the
      // scheduler's "app start" trigger (a no-op while [syncScheduler] is
      // null, see its declaration above).
      syncScheduler?.onAppStart();
    }
    // Background best-guess pass, queued once load() has fully settled
    // (feed rendered AND tag enrichment finished -- artist/album tags are
    // what the album key is built from, so running earlier would key off
    // filename guesses). Fire-and-forget: never awaited on any UI path, and
    // it never writes LibraryModel.status.
    unawaited(artworkBackfill.run(artworkBackfillRequests(library.allTracks)));
  }

  // The Settings "Set up" action (permission request -> seed -> reload) --
  // see model/set_up_root.dart's doc for the silent-no-op bug this replaces
  // (every outcome of tapping "Set up" for a manifest-less root used to
  // look like nothing happened: a denied permission bailed silently, a
  // successful seed never refreshed rootsMissingManifest since that only
  // updates inside load(), and a seed failure was equally quiet). Built
  // once, here, so PhoneSettingsView and HomeScreen's Settings dialog share
  // one instance rather than each closing over the model separately.
  final setUpRoot = makeSetUpRootAction(
    requestAccess: requestFullStorageAccess,
    seed: (root) => library.seedRoot(Directory(root)),
    reloadLibrary: reloadLibrary,
    libraryStatus: () => library.status,
  );

  // Settings-dialog add/remove calls writer() above then notifies -- react
  // by reloading so the merged feed/playlists reflect the new root set.
  libraryRootsPrefs.addListener(reloadLibrary);

  // Periodic background rescan (Task 5's third trigger, alongside launch
  // and the Refresh button): LibraryModel.rescan() is itself a no-op
  // whenever a load()/rescan() is already in flight, so an overlap here --
  // e.g. a slow SMB rescan still running when the next 5-minute tick fires
  // -- just skips that tick rather than piling up concurrent scans.
  //
  // Chained through [rescanThenBackfill] (not a bare `library.rescan()`) so
  // albums this tick discovers get an automatic artwork pass too -- without
  // it, only the very first load() ever queued a backfill and everything
  // found afterward sat un-arted until the app restarted.
  final rescanTimer = Timer.periodic(_rescanInterval, (_) {
    unawaited(periodicRescanTick(library, artworkBackfill));
    // Same 5-minute tick doubles as the sync scheduler's periodic trigger
    // (a no-op while [syncScheduler] is null).
    syncScheduler?.onPeriodicTick();
  });

  _LifecycleFlusher(
    layoutPrefs,
    rescanTimer: rescanTimer,
    artworkBackfill: artworkBackfill,
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => reloadLibrary(triggerLaunchRescan: true),
  );
  // The library reports what it is doing through `status`; mirror that into
  // the activity bar so tag reading and scanning are as visible as the
  // artwork passes. Without this the bar would only ever show artwork work,
  // and "is anything happening?" would still be unanswerable during a scan.
  library.addListener(() {
    final status = library.status;
    if (!library.busy) {
      activity.finish(ActivityIds.library);
      return;
    }
    final m = RegExp(r'^reading tags (\d+)/(\d+)').firstMatch(status);
    if (m != null) {
      activity.progress(
        ActivityIds.library,
        'Reading tags',
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
      );
    } else if (status.startsWith('scanning')) {
      activity.start(
        ActivityIds.library,
        // "scanning alternative times…" -> "Scanning alternative times…"
        'Scanning ${status.substring('scanning '.length)}',
      );
    } else if (status.startsWith('ready (reading tags')) {
      activity.start(ActivityIds.library, 'Reading tags');
    } else if (status.startsWith('loading')) {
      activity.start(ActivityIds.library, 'Loading library');
    }
  });

  // ---- Background audio (Plan 2c) ----------------------------------------
  // Android only. Registers a media session so playback keeps going with the
  // screen off and the lock screen / notification / headset buttons drive it.
  // Returns null on Windows, where audio_service has no implementation and
  // the app already has a window to control playback from.
  unawaited(
    maybeStartAudioService(
      player: player,
      artUriFor: (track) => _lockScreenArt(track, artworkResolver, dataDir),
    ),
  );

  runApp(
    FooPlayerApp(
      library: library,
      player: player,
      layoutPrefs: layoutPrefs,
      libraryRootsPrefs: libraryRootsPrefs,
      device: device,
      artworkResolver: artworkResolver,
      artworkServices: artworkServices,
      artworkStores: artwork.stores,
      artworkBackfill: artworkBackfill,
      activity: activity,
      syncScheduler: syncScheduler,
      syncUi: syncUi,
      onSetUpRootAction: setUpRoot,
    ),
  );
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  final LibraryRootsPrefs libraryRootsPrefs;

  /// Who signs `modified_by` on every playlist file this device's
  /// [PlaylistStore] writes (Plan 3) -- see `library_home.dart`'s
  /// `deviceLabel`, computed once in `main()`.
  final String device;

  /// Shared artwork resolution chain (Plan 4) -- handed to every art
  /// surface so desktop bar, phone mini-player and phone Now Playing all
  /// read from one cache and refresh together when a pick changes.
  final ArtworkResolver? artworkResolver;

  /// Per-root artwork sidecars -- backs the sidebar's "Embed art in files"
  /// action, which copies each album's chosen cover into the tracks' own
  /// tags so other players can see it.
  final ArtworkStoreRegistry? artworkStores;

  /// Background jobs, shown in the persistent activity bar.
  final ActivityModel? activity;

  /// Artwork picker services (Plan 4 A3) -- the desktop row context menu and
  /// the phone long-press sheet both hide their "Album artwork" item when
  /// this is null, so a build without artwork wiring simply has no picker.
  final ArtworkServices? artworkServices;

  /// Background best-guess artwork pass -- forwarded to [HomeScreen] so its
  /// Refresh button can queue a pass after a manual rescan (see
  /// [rescanThenBackfill]). Null keeps the pre-fix behavior (plain rescan,
  /// no backfill queued), which is what widget tests building this app
  /// without the artwork feature wired rely on.
  final ArtworkBackfill? artworkBackfill;

  /// The Plan 3 auto-sync cadence (Task 8) -- real (Android) or null (every
  /// other platform; there is no SMB bridge implementation there). See
  /// main()'s construction above. [PlaylistStore.onMutated] points at
  /// [PlaylistSyncScheduler.onPlaylistMutated] through this field, so it's
  /// inert (every call is `?.`) whenever it's null.
  final PlaylistSyncScheduler? syncScheduler;

  /// The [SyncView] seams (Plan 3 Task 11) -- real (Android) or null (every
  /// other platform), forwarded to [HomeScreen] (the tablet path, via
  /// SettingsDialog's "Sync…" button) and [PhoneSettingsView] (the phone
  /// path, via its "Sync" tile). Both also gate on [isAndroidPlatform]
  /// themselves, so a null here is belt-and-suspenders, not the only guard.
  final SyncUiSeams? syncUi;

  /// The Set-up action (permission request -> seed -> reload), built once in
  /// main() by `makeSetUpRootAction` and forwarded to both shells' Settings
  /// surfaces (HomeScreen's dialog, PhoneSettingsView's page). Null keeps
  /// the "Set up" affordance hidden -- see `PhoneSettingsView
  /// .onSetUpRootAction`'s doc; production always supplies a real one.
  final SetUpRootAction? onSetUpRootAction;

  const FooPlayerApp({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
    required this.libraryRootsPrefs,
    required this.device,
    this.artworkResolver,
    this.artworkServices,
    this.artworkStores,
    this.artworkBackfill,
    this.activity,
    this.syncScheduler,
    this.syncUi,
    this.onSetUpRootAction,
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
          // Shared by both branches below -- a stateless facade over
          // [library], so one instance per build is as good as one per
          // branch. `onMutated` points at the sync scheduler's "something
          // changed" hook -- inert (a no-op `?.call()`) while
          // [syncScheduler] is null, i.e. until Task 9/11 construct a real
          // one.
          final store = PlaylistStore(
            library: library,
            device: device,
            onMutated: () => syncScheduler?.onPlaylistMutated(),
          );
          if (!usePhoneShell(context)) {
            return HomeScreen(
              library: library,
              player: player,
              layoutPrefs: layoutPrefs,
              libraryRootsPrefs: libraryRootsPrefs,
              playlistStore: store,
              artworkResolver: artworkResolver,
              artworkServices: artworkServices,
              artworkStores: artworkStores,
              activity: activity,
              artworkBackfill: artworkBackfill,
              // Shares the artwork lookups' MusicBrainz rate limiter -- one
              // request a second is a condition of using the service, and two
              // independent limiters would quietly break it.
              tagSearch: searchMusicBrainzRecordings,
              syncUi: syncUi,
              onSetUpRootAction: onSetUpRootAction,
            );
          }
          // Phone integration wiring (Plan 2b merge): P2's MiniPlayer fills
          // the mini-player slot (it self-hides when no track is loaded),
          // P3's browse views plus the Settings page fill the viewBuilders
          // map (every drawer destination has a real body -- no
          // placeholders), and P3's real track context sheet (Add to
          // playlist / View details) handles feed and search long-presses.
          return PhoneShell(
            library: library,
            player: player,
            // The full-screen player this shell opens on a song tap needs the
            // same artwork chain the mini-player uses.
            artworkResolver: artworkResolver,
            // Renders PhoneActivityStrip above the mini-player -- see
            // SyncForegroundNotifier's wiring above for the other half of
            // sync-survives-backgrounding (the system notification).
            activity: activity,
            // Lets the full-screen player's overflow button reuse the same
            // track context sheet every other long-press opens.
            store: store,
            artwork: artworkServices,
            onTrackLongPress: (sheetContext, track) => showTrackContextSheet(
              sheetContext,
              track: track,
              library: library,
              store: store,
              artwork: artworkServices,
              // Enables "Play next" / "Add to queue" in the sheet.
              player: player,
            ),
            miniPlayerBuilder: (_) => MiniPlayer(
              player: player,
              artworkResolver: artworkResolver,
              library: library,
              store: store,
              artwork: artworkServices,
            ),
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
                syncUi: syncUi,
                onSetUpRootAction: onSetUpRootAction,
              ),
            },
          );
        },
      ),
    );
  }
}
