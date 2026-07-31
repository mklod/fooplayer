import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../artwork/artwork_backfill.dart';
import '../artwork/artwork_store.dart';
import '../artwork/artwork_embed_pass.dart';
import '../artwork/local_art_harvest.dart';
import '../artwork/artwork_picker.dart';
import '../artwork/artwork_resolver.dart';
import '../artwork/picker_seams.dart';
import '../metadata/tag_providers.dart';
import '../model/activity_model.dart';
import 'activity_bar.dart';
import '../model/library_model.dart';
import '../model/library_roots_prefs.dart';
import '../model/manifest_io.dart';
import '../model/playlist_store.dart';
import '../player/player_service.dart';
import 'app_theme.dart';
import 'drag_divider.dart';
import 'embed_report_dialog.dart';
import 'enrich_report_dialog.dart';
import 'filter_panel.dart';
import 'layout_prefs.dart';
import 'now_playing_bar.dart';
import 'phone/storage_access.dart';
import 'playlist_dialogs.dart';
import 'queue_view.dart';
import 'settings_dialog.dart';
import 'track_list.dart';

/// Stand-in for widget tests that build a screen without wiring background
/// activity: nothing ever registers with it, so the bar stays hidden.
final ActivityModel _idleActivity = ActivityModel();

class HomeScreen extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  final LibraryRootsPrefs libraryRootsPrefs;

  /// Playlist CRUD service the sidebar and track-list context menus write
  /// through. Defaults to a real [PlaylistStore] over [library]; injectable
  /// so widget tests can substitute a spy that never touches disk.
  final PlaylistStore? playlistStore;

  /// Artwork resolution chain (Plan 4), forwarded to [NowPlayingBar]. Null
  /// keeps the pre-Plan-4 embedded-art-only behavior, which is what widget
  /// tests that build the screen without an app-level resolver rely on.
  final ArtworkResolver? artworkResolver;

  /// Artwork picker services (Plan 4 A3), forwarded to the track list so its
  /// row context menu can offer "Album artwork...". Null hides the item.
  final ArtworkServices? artworkServices;

  /// Per-root artwork sidecars. Backs the sidebar's "Embed art in files"
  /// action; null hides it (widget tests that build the screen without the
  /// artwork feature wired).
  final ArtworkStoreRegistry? artworkStores;

  /// Background best-guess artwork pass -- the Refresh button below queues a
  /// pass over any newly-discovered tracks once its manual rescan settles
  /// (mirroring what main.dart's periodic timer and launch-time rescan
  /// already do; see [rescanThenBackfill]). Null falls back to a plain
  /// `library.rescan()` with no backfill queued, which is what widget tests
  /// building this screen without the artwork feature wired rely on.
  final ArtworkBackfill? artworkBackfill;

  /// Backs the edit dialog's "Find correct tags..." button -- MusicBrainz in
  /// production, null in widget tests (which must never open a socket, and
  /// which the null also spares the button entirely).
  final TagSearch? tagSearch;

  /// Everything running in the background, shown in the persistent bar above
  /// the now-playing bar. Optional so widget tests need not thread one
  /// through; they get a throwaway that nothing renders.
  final ActivityModel? activity;

  const HomeScreen({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
    required this.libraryRootsPrefs,
    this.playlistStore,
    this.artworkResolver,
    this.artworkServices,
    this.artworkStores,
    this.artworkBackfill,
    this.activity,
    this.tagSearch,
  });

  @override
  Widget build(BuildContext context) {
    // main.dart always injects a real store (with the real device label);
    // this fallback only fires in widget tests that build the screen
    // without one.
    final store =
        playlistStore ?? PlaylistStore(library: library, device: 'test');
    return Scaffold(
      // The panel layout was written for a window with a title bar, so it
      // painted from pixel zero. On a tablet that put the Android status bar
      // over the sidebar and the search field, and the gesture pill over the
      // track count. SafeArea is a no-op on desktop, where these insets are
      // all zero.
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        // Dark status-bar icons: this UI is white, and Android's default for
        // a full-screen app is white-on-white.
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: AppColors.panelBg,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: layoutPrefs,
                  builder: (context, _) => Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        key: const Key('sidebar-panel'),
                        width: layoutPrefs.sidebarWidth,
                        // Material (not a plain Container/ColoredBox) so the
                        // sidebar ListTiles' selection fill and ink splashes --
                        // which paint on the nearest Material ancestor -- aren't
                        // hidden behind an opaque background layer.
                        child: Material(
                          color: AppColors.panelBg,
                          child: _Sidebar(
                            artworkBackfill: artworkBackfill,
                            artworkStores: artworkStores,
                            library: library,
                            libraryRootsPrefs: libraryRootsPrefs,
                            playlistStore: store,
                            player: player,
                            artworkResolver: artworkResolver,
                            artworkServices: artworkServices,
                            activity: activity ?? _idleActivity,
                            layoutPrefs: layoutPrefs,
                          ),
                        ),
                      ),
                      VerticalDragDivider(
                        key: const Key('sidebar-divider'),
                        onDragDelta: (dx) => layoutPrefs.setSidebarWidth(
                          layoutPrefs.sidebarWidth + dx,
                        ),
                      ),
                      Expanded(
                        // The Queue is not a filter over the library --
                        // there is nothing to search or drill into -- so it
                        // replaces the whole search/filters/list column
                        // rather than being another TrackListView mode.
                        // Its own ListenableBuilder (not folded into the
                        // layoutPrefs one above) so toggling it repaints
                        // immediately without widening what that one
                        // rebuilds on.
                        child: ListenableBuilder(
                          listenable: library,
                          builder: (context, _) => library.showingQueue
                              ? QueueView(
                                  player: player,
                                  showHeader: true,
                                  artworkResolver: artworkResolver,
                                )
                              : Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: _SearchField(
                                              library: library,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          // Collapse/expand the Folder/Artist/Album row.
                                          // The dragged height is remembered, so
                                          // expanding restores the same size.
                                          IconButton(
                                            key: const Key('filters-collapse'),
                                            tooltip:
                                                layoutPrefs.filtersCollapsed
                                                ? 'Show filters'
                                                : 'Hide filters',
                                            icon: Icon(
                                              layoutPrefs.filtersCollapsed
                                                  ? Icons.unfold_more
                                                  : Icons.unfold_less,
                                              size: 18,
                                              color: AppColors.inkSecondary,
                                            ),
                                            onPressed: layoutPrefs
                                                .toggleFiltersCollapsed,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!layoutPrefs.filtersCollapsed)
                                      SizedBox(
                                        key: const Key('filter-panel'),
                                        height: layoutPrefs.filterHeight,
                                        // Same reasoning as the sidebar: Material, not
                                        // Container, so the filter panels' ListTile
                                        // selection/ink still paints correctly.
                                        child: Material(
                                          color: AppColors.panelBg,
                                          child: ListenableBuilder(
                                            listenable: library,
                                            builder: (context, _) => Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Expanded(
                                                  child: FilterPanel(
                                                    key: const Key(
                                                      'folder-filter-panel',
                                                    ),
                                                    title: 'Folder',
                                                    // Drill-down navigator (see
                                                    // LibraryModel.folderEntries): plain
                                                    // click selects AND descends into a
                                                    // folder, Ctrl+click toggles siblings
                                                    // at the current level, the pinned ✕
                                                    // resets to the root list. Entries
                                                    // are full root paths only at the top
                                                    // level (shown by basename); below
                                                    // that they're already bare names.
                                                    values:
                                                        library.folderEntries,
                                                    selected:
                                                        library.folderSiblings,
                                                    onSelect: library
                                                        .setFolderSiblings,
                                                    onDrill:
                                                        library.drillIntoFolder,
                                                    // Step-wise breadcrumb: a leading
                                                    // 'All' segment (full reset) plus one
                                                    // segment per drill-down step, each
                                                    // ancestor clickable. The 'All'
                                                    // prepend keeps UI segment index ==
                                                    // popFolderTo depth (0 = roots); the
                                                    // trailing sibling/'N selected'
                                                    // segment, when present, is the
                                                    // non-clickable last one, so the
                                                    // deepest clickable index is at most
                                                    // folderPath.length -- which
                                                    // popFolderTo treats as "keep the
                                                    // path, drop the sibling selection".
                                                    // The leading 'All' is the root-list
                                                    // level, so it is only offered when
                                                    // there IS one -- with a single
                                                    // library root that level does not
                                                    // exist (see folderTopPath) and the
                                                    // segment would be a step to nowhere.
                                                    // Dropping it shifts every segment
                                                    // index down by the depth the pane
                                                    // now starts at, which is what the
                                                    // tap offset restores.
                                                    headerSegments:
                                                        library
                                                            .folderBreadcrumbs
                                                            .isEmpty
                                                        ? null
                                                        : [
                                                            if (library
                                                                .folderTopPath
                                                                .isEmpty)
                                                              'All',
                                                            ...library
                                                                .folderBreadcrumbs,
                                                          ],
                                                    onHeaderSegmentTap: (i) =>
                                                        library.popFolderTo(
                                                          library
                                                              .breadcrumbPopDepth(
                                                                i,
                                                              ),
                                                        ),
                                                    onClearHeader: library
                                                        .clearFolderSelection,
                                                    displayName:
                                                        library
                                                            .folderPath
                                                            .isEmpty
                                                        ? p.basename
                                                        : null,
                                                  ),
                                                ),
                                                const VerticalDivider(width: 1),
                                                Expanded(
                                                  child: FilterPanel(
                                                    key: const Key(
                                                      'artist-filter-panel',
                                                    ),
                                                    title: 'Artist',
                                                    values: library.artists,
                                                    selected:
                                                        library.artistFilters,
                                                    onSelect:
                                                        library.setArtists,
                                                  ),
                                                ),
                                                const VerticalDivider(width: 1),
                                                Expanded(
                                                  child: FilterPanel(
                                                    key: const Key(
                                                      'album-filter-panel',
                                                    ),
                                                    title: 'Album',
                                                    values: library.albums,
                                                    selected:
                                                        library.albumFilters,
                                                    onSelect: library.setAlbums,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (!layoutPrefs.filtersCollapsed)
                                      HorizontalDragDivider(
                                        key: const Key('filter-divider'),
                                        onDragDelta: (dy) =>
                                            layoutPrefs.setFilterHeight(
                                              layoutPrefs.filterHeight + dy,
                                            ),
                                      ),
                                    Expanded(
                                      child: TrackListView(
                                        library: library,
                                        player: player,
                                        playlistStore: store,
                                        artwork: artworkServices,
                                        tagSearch: tagSearch,
                                        activity: activity,
                                        // "Art" ticks when the app has a cover at all:
                                        // the file's own, or one recorded in the sidecar
                                        // (which, after a harvest, includes covers
                                        // adopted from loose files in the folder).
                                        hasArtwork: (t) =>
                                            t.hasEmbeddedArt ||
                                            (artworkStores
                                                    ?.forRoot(t.rootPath)
                                                    .entryFor(
                                                      albumKeyForTrack(t),
                                                    ) !=
                                                null),
                                        artworkResolver: artworkResolver,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _BottomBars(
                player: player,
                library: library,
                activity: activity ?? _idleActivity,
                layoutPrefs: layoutPrefs,
                artworkResolver: artworkResolver,
                artworkServices: artworkServices,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatefulWidget {
  /// Forwarded to the selected-track cover preview, which has to know
  /// whether the now-playing strip is up. See [_SelectedArtPreview].
  final LayoutPrefs layoutPrefs;

  final LibraryModel library;
  final LibraryRootsPrefs libraryRootsPrefs;
  final PlaylistStore playlistStore;

  /// Background best-guess artwork pass, driven by the "Enrich artwork"
  /// entry pinned at the sidebar bottom. Null hides that entry (widget
  /// tests that build the screen without the artwork feature wired).
  final ArtworkBackfill? artworkBackfill;

  /// Per-root artwork sidecars, read by "Embed art in files". Null hides it.
  final ArtworkStoreRegistry? artworkStores;

  /// Drives the selected-track artwork preview under the button stack: it
  /// only shows when nothing is playing (the now-playing bar owns the cover
  /// otherwise).
  final PlayerService player;
  final ArtworkResolver? artworkResolver;

  /// Picker services, so the selected-track preview can open the same dialog
  /// the now-playing cover and the row context menu use.
  final ArtworkServices? artworkServices;

  /// Where the sidebar's long-running actions report progress.
  final ActivityModel activity;

  const _Sidebar({
    required this.layoutPrefs,
    required this.library,
    required this.libraryRootsPrefs,
    required this.playlistStore,
    required this.player,
    this.artworkBackfill,
    this.artworkStores,
    this.artworkResolver,
    this.artworkServices,
    required this.activity,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  /// True while an embed pass runs, so it can't be started twice.
  ///
  /// Deliberately NOT gated on [LibraryModel.busy]: the pass writes tag
  /// blocks inside audio files and touches neither the manifests nor the tag
  /// cache, so it is safe alongside a scan -- and this library rescans on a
  /// timer, which would otherwise leave the entry greyed out most of the
  /// time.
  bool _embedding = false;

  LibraryModel get library => widget.library;
  LibraryRootsPrefs get libraryRootsPrefs => widget.libraryRootsPrefs;
  PlaylistStore get playlistStore => widget.playlistStore;
  ArtworkBackfill? get artworkBackfill => widget.artworkBackfill;
  ArtworkStoreRegistry? get artworkStores => widget.artworkStores;
  ArtworkServices? get artworkServices => widget.artworkServices;
  ActivityModel get activity => widget.activity;

  Future<void> _createPlaylist(BuildContext context) async {
    // Captured before the name dialog opens -- see showPlaylistError's doc.
    final messenger = ScaffoldMessenger.of(context);
    final name = await showPlaylistNameDialog(context, store: playlistStore);
    if (name == null) return;
    try {
      await playlistStore.createPlaylist(name);
    } on PlaylistStoreException catch (e) {
      showPlaylistError(messenger, e);
    }
  }

  /// Kicks the background best-guess pass over every album that still has
  /// no artwork. Safe to press repeatedly: the pass dedupes per album and
  /// skips albums that already resolved.
  /// Takes what is already on disk first, then goes to the network for
  /// whatever is left.
  ///
  /// The harvest is the cheap half and by far the bigger one: measured on
  /// this library, of 1,470 albums with no recorded cover, 659 already had
  /// embedded art, 718 had a loose image sitting in the folder, and only 93
  /// genuinely needed a provider request. Doing the local pass first turns
  /// "an evening of throttled lookups" into a file copy plus a short online
  /// tail -- and it means the online pass isn't asking about albums whose
  /// cover was on disk the whole time.
  Future<void> _enrichArtwork(BuildContext context) async {
    final backfill = artworkBackfill;
    if (backfill == null) return;
    final stores = artworkStores;
    HarvestReport? harvest;

    if (stores != null) {
      activity.start(
        ActivityIds.artworkHarvest,
        'Adopting artwork already in your folders',
      );
      try {
        // Held for the single report at the end rather than announced here:
        // two SnackBars, one at the start of a job and one many minutes
        // later, is how the middle of a pass came to look like the end of it.
        harvest = await harvestLocalArt(
          library.allTracks,
          stores,
          onProgress: (done, total) => activity.progress(
            ActivityIds.artworkHarvest,
            'Adopting artwork already in your folders',
            done,
            total,
          ),
        );
      } finally {
        activity.finish(ActivityIds.artworkHarvest);
      }
    }

    // The lookup reports no progress of its own, so poll its counters while
    // it runs: an indeterminate spinner for a pass that can take an hour is
    // barely better than the silence it replaced.
    activity.start(ActivityIds.artworkLookup, 'Looking up artwork online');
    final total = artworkBackfillRequests(library.allTracks).length;
    final ticker = Timer.periodic(const Duration(milliseconds: 700), (_) {
      activity.progress(
        ActivityIds.artworkLookup,
        'Looking up artwork online (${backfill.appliedCount} found)',
        backfill.consideredCount,
        total,
      );
    });
    try {
      await backfill.run(artworkBackfillRequests(library.allTracks));
    } finally {
      ticker.cancel();
      activity.finish(ActivityIds.artworkLookup);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: this.context,
      builder: (context) => EnrichReportDialog(
        harvest: harvest,
        found: backfill.appliedCount,
        albumsChecked: backfill.consideredCount,
      ),
    );
  }

  /// Writes the artwork fooplayer has chosen into the files themselves, so
  /// every other player can see it.
  ///
  /// Confirmed first, and the dialog states plainly what is and isn't
  /// touched: only tag blocks are rewritten, never audio, so no content ID
  /// moves -- and every file's dates are restored and re-read afterwards,
  /// which since 2026-07-28 ARE the library's "date downloaded". A write
  /// that failed to put a date back is surfaced in the result rather than
  /// counted as a success.
  Future<void> _embedArtwork(BuildContext context) async {
    final stores = artworkStores;
    if (stores == null) return;
    final tracks = library.allTracks
        .where(
          (t) => kEmbeddableExtensions.contains(
            p.extension(t.relPath).toLowerCase(),
          ),
        )
        .toList();

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('embed-artwork-confirm'),
        title: const Text('Embed art in files?'),
        content: Text(
          'Writes the cover fooplayer picked into the tags of each track, so '
          'foobar2000, Kodi, Explorer and your phone can see it.\n\n'
          '${tracks.length} eligible tracks (mp3 and FLAC).\n\n'
          'Audio is never rewritten, so nothing changes identity, and every '
          'file has its dates put back exactly as they were — the date '
          'downloaded is not touched. Anything that cannot be written safely '
          'is skipped and reported.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('embed-artwork-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Embed'),
          ),
        ],
      ),
    );
    if (go != true) return;

    setState(() => _embedding = true);
    activity.start(ActivityIds.artworkEmbed, 'Embedding artwork into files');

    EmbedPassReport report;
    try {
      report = await ArtworkEmbedPass(stores: stores).run(
        tracks,
        onProgress: (done, total) => activity.progress(
          ActivityIds.artworkEmbed,
          'Embedding artwork into files',
          done,
          total,
        ),
      );
    } finally {
      activity.finish(ActivityIds.artworkEmbed);
      if (mounted) setState(() => _embedding = false);
    }

    // The Emb column caches what the file looked like when its tags were
    // last read, so without this a finished pass still shows every file it
    // just wrote as bare -- which reads as "the pass did nothing".
    await library.markEmbeddedArt(report.embeddedIds);

    if (!mounted) return;
    await showDialog<void>(
      context: this.context,
      builder: (context) => EmbedReportDialog(report: report),
    );
  }

  /// Manual rescan of every library root, queueing an artwork pass for any
  /// newly-found tracks (same path as the periodic timer and launch scan).
  void _rescan() {
    final backfill = artworkBackfill;
    if (backfill == null) {
      unawaited(library.rescan());
      return;
    }
    unawaited(
      rescanThenBackfill(
        rescan: library.rescan,
        backfill: backfill,
        tracks: () => library.allTracks,
      ),
    );
  }

  void _openSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: Listenable.merge([libraryRootsPrefs, library]),
        builder: (context, _) => SettingsDialog(
          roots: libraryRootsPrefs.roots,
          rootsMissingManifest: library.rootsMissingManifest,
          rootsFailed: library.rootsFailed,
          onAddRoot: libraryRootsPrefs.addRoot,
          onRemoveRoot: libraryRootsPrefs.removeRoot,
          // Same as the phone page's: the panel layout runs on a tablet
          // now, where seeding cannot read a byte without all-files access
          // (the manifest is not a media file). No-op off Android.
          onSetUpRoot: (root) async {
            if (!await requestFullStorageAccess()) return;
            await library.seedRoot(Directory(root));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Also player: the Queue tile below appears and disappears with
      // player.queueController.upcoming, and only player -- never library --
      // notifies when that changes (Add to queue / Play next / removing the
      // last queued track).
      listenable: Listenable.merge([library, widget.player]),
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                ListTile(
                  title: const Text('Library'),
                  selected:
                      library.activePlaylist == null && !library.showingQueue,
                  // Clears any active playlist (setPlaylist(null) also
                  // resets folder/artist/album/search state) -- the
                  // "clicking Library must clear" path of the #30
                  // selection-clear trio, alongside the toggle-off tap and
                  // the ✕ on the active playlist row below.
                  onTap: () => library.setPlaylist(null),
                ),
                // Only once there IS a queue -- born the moment "Play next" /
                // "Add to queue" is used for the first time (see
                // QueueController.hasExplicitQueue). A normal play's own
                // continuation ("the faux queue") is just whatever the
                // library view currently shows; it needs no panel of its
                // own, and showing this entry for it would be exactly the
                // "queue full of the whole library" bug restated as a menu
                // item.
                if (widget.player.queueController.hasExplicitQueue &&
                    widget.player.queueController.upcoming.isNotEmpty)
                  ListTile(
                    key: const Key('queue-open'),
                    leading: const Icon(Icons.playlist_play, size: 18),
                    title: const Text('Queue'),
                    selected: library.showingQueue,
                    // A real destination now, not a popup: it sits right
                    // under Library because it is reached about as often,
                    // and renders in the same content area a playlist would
                    // -- see the ListenableBuilder around the search/filter/
                    // track-list column above. Switching to Library and back
                    // does not lose it -- it lives in the queue controller,
                    // not in what is on screen -- so it is there to add more
                    // to between browsing.
                    onTap: library.showQueue,
                  ),
                const Divider(),
                for (final pl in library.playlists)
                  _PlaylistTile(
                    library: library,
                    store: playlistStore,
                    playlist: pl,
                  ),
                ListTile(
                  key: const Key('new-playlist'),
                  leading: const Icon(Icons.add, size: 18),
                  title: const Text('New playlist'),
                  onTap: () => _createPlaylist(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Pinned at the sidebar bottom (outside the scrolling ListView
          // above) so these stay reachable regardless of playlist count:
          // the library status line, the manual artwork pass, then Settings.
          ListTile(
            key: const Key('rescan-library'),
            leading: const Icon(Icons.refresh, size: 18),
            title: const Text('Rescan library'),
            enabled: !library.busy,
            onTap: library.busy ? null : () => _rescan(),
          ),
          if (artworkBackfill != null)
            ListTile(
              key: const Key('enrich-artwork'),
              leading: const Icon(Icons.image_search_outlined, size: 18),
              title: const Text('Enrich artwork'),
              onTap: () => unawaited(_enrichArtwork(context)),
            ),
          if (artworkStores != null)
            ListTile(
              key: const Key('embed-artwork'),
              leading: const Icon(Icons.save_alt_outlined, size: 18),
              title: Text(_embedding ? 'Embedding art…' : 'Embed art in files'),
              enabled: !_embedding,
              onTap: _embedding ? null : () => _embedArtwork(context),
            ),
          ListTile(
            key: const Key('settings-gear'),
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => _openSettings(context),
          ),
          _SelectedArtPreview(
            library: library,
            layoutPrefs: widget.layoutPrefs,
            player: widget.player,
            resolver: widget.artworkResolver,
            artwork: widget.artworkServices,
          ),
        ],
      ),
    );
  }
}

/// One sidebar playlist row. Interaction model (#29/#30):
///
/// - Tap selects the playlist; tapping the ALREADY-ACTIVE row toggles it
///   back off (returns to the Library view) -- one of the three
///   selection-clear paths, alongside the row's ✕ and the Library row.
/// - The active row alone shows a small trailing ✕ doing the same clear.
/// - Right-click opens a context menu with "Delete playlist" (behind a
///   confirm dialog); a delete refused by the store -- e.g. the playlist
///   lives in another root's manifest -- surfaces its message in a
///   SnackBar rather than silently no-opping.
class _PlaylistTile extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final ManifestPlaylist playlist;
  const _PlaylistTile({
    required this.library,
    required this.store,
    required this.playlist,
  });

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    // Captured before the popup menu opens -- see showPlaylistError's doc.
    // Matters here specifically: a SUCCESSFUL delete removes this very tile
    // (LibraryModel.reloadPlaylists rebuilds the sidebar's playlist list
    // without it), but a refused delete must still be able to report
    // through a messenger that doesn't depend on this tile still existing.
    final messenger = ScaffoldMessenger.of(context);
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      // Same instant-open rule as the track list's row menus.
      popUpAnimationStyle: AnimationStyle.noAnimation,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlayBox.size,
      ),
      items: const [
        PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
      ],
    );
    if (action != 'delete' || !context.mounted) return;
    final confirmed = await confirmDeletePlaylist(context, playlist.name);
    if (!confirmed) return;
    try {
      await store.deletePlaylist(playlist.name);
    } on PlaylistStoreException catch (e) {
      showPlaylistError(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = library.activePlaylist == playlist.name;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: ListTile(
        title: Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        selected: active,
        // Toggle: a tap on the already-active playlist clears back to the
        // Library view instead of being a dead click.
        onTap: () => library.setPlaylist(active ? null : playlist.name),
        trailing: active
            ? IconButton(
                key: Key('clear-playlist-${playlist.name}'),
                icon: const Icon(
                  Icons.close,
                  size: 14,
                  color: AppColors.inkSecondary,
                ),
                tooltip: 'Back to Library',
                onPressed: () => library.setPlaylist(null),
              )
            : null,
      ),
    );
  }
}

/// Stateful so it owns a [TextEditingController]: the clear (X) affordance
/// only appears while the field has text, and pressing it must both empty
/// the visible field and reset the library's search filter in one tap.
class _SearchField extends StatefulWidget {
  final LibraryModel library;
  const _SearchField({required this.library});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_followModel);
  }

  @override
  void dispose() {
    widget.library.removeListener(_followModel);
    _controller.dispose();
    super.dispose();
  }

  /// Keeps the box showing what is actually being searched for.
  ///
  /// Several things reset the model's search without going through this
  /// field -- picking a playlist or clicking Library both call
  /// [LibraryModel.setPlaylist], which clears search along with the folder,
  /// artist and album filters. The box kept its old text through all of
  /// that, so you were left looking at a search term that was filtering
  /// nothing, with the full library listed underneath it.
  void _followModel() {
    if (!mounted) return;
    if (widget.library.search == _controller.text) return;
    _controller.value = TextEditingValue(
      text: widget.library.search,
      selection: TextSelection.collapsed(offset: widget.library.search.length),
    );
  }

  void _clear() {
    _controller.clear();
    widget.library.setSearch('');
  }

  @override
  Widget build(BuildContext context) {
    // ValueListenableBuilder (rather than setState in onChanged) so the
    // suffix icon also tracks programmatic controller changes like _clear.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        controller: _controller,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search title, artist, album',
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('search-clear'),
                  icon: const Icon(
                    Icons.close,
                    size: 16,
                    color: AppColors.inkSecondary,
                  ),
                  tooltip: 'Clear search',
                  onPressed: _clear,
                ),
        ),
        onChanged: widget.library.setSearch,
      ),
    );
  }
}

/// The cover of whatever is SELECTED, shown under the sidebar's button stack
/// when nothing is playing.
///
/// Deliberately conditional: while a track plays, the now-playing bar already
/// shows a large cover, and a second one in the corner is just clutter. This
/// fills that space the rest of the time -- clicking through the library then
/// shows you what each thing looks like.
class _SelectedArtPreview extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final ArtworkResolver? resolver;

  /// Lets the preview open the picker for the SELECTED track, the same way
  /// the now-playing cover does for the playing one. Null leaves it inert.
  final ArtworkServices? artwork;

  /// Consulted so the preview can come back when the now-playing strip is
  /// dismissed. Hiding that strip is done PRECISELY so the window can show
  /// the selected track's cover instead -- if this stayed keyed on "is
  /// anything loaded", dismissing it would hide both covers and the
  /// dismissal would achieve nothing.
  final LayoutPrefs layoutPrefs;

  const _SelectedArtPreview({
    required this.library,
    required this.layoutPrefs,
    required this.player,
    this.resolver,
    this.artwork,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // layoutPrefs too: dismissing the strip has to repaint this.
      listenable: Listenable.merge([library, player, layoutPrefs]),
      builder: (context, _) {
        // Show the selection's cover whenever the now-playing strip is not
        // up -- either nothing is loaded, or the strip has been dismissed.
        if (player.current != null && !layoutPrefs.nowPlayingHidden) {
          return const SizedBox.shrink();
        }
        final selected = library.selectedTrackIds;
        if (selected.isEmpty) return const SizedBox.shrink();
        // The most recently clicked row wins; with a wide multi-selection,
        // showing the first is as good an answer as any.
        final track = library.visibleTracks.firstWhere(
          (t) => selected.contains(t.contentId),
          orElse: () => library.allTracks.firstWhere(
            (t) => selected.contains(t.contentId),
            orElse: () => library.allTracks.first,
          ),
        );
        // Square, and as wide as the sidebar allows -- it is the one piece
        // of art on screen while nothing plays, so it gets the space.
        final services = artwork;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final art = AlbumArt(
                key: const Key('sidebar-art-preview'),
                contentId: track.contentId,
                file: File(p.join(track.rootPath, track.relPath)),
                size: constraints.maxWidth,
                resolver: resolver,
                track: track,
              );
              if (services == null) return art;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: const Key('sidebar-art-preview-tap'),
                  onTap: () => showArtworkPickerDialog(
                    context,
                    track: track,
                    services: services,
                    resolver: resolver,
                  ),
                  child: art,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The now-playing strip and the status footer, in that order.
///
/// Now playing sits ABOVE the footer and the footer is always the last thing
/// in the window. The other way round put the track strip below the status
/// line, which read as the window having two bottoms.
///
/// Stateful only to remember that the strip was dismissed -- see
/// [_dismissed]. Everything else here is pass-through.
class _BottomBars extends StatefulWidget {
  final PlayerService player;
  final LibraryModel library;
  final ActivityModel activity;
  final ArtworkResolver? artworkResolver;
  final ArtworkServices? artworkServices;
  final LayoutPrefs layoutPrefs;

  const _BottomBars({
    required this.player,
    required this.library,
    required this.activity,
    required this.layoutPrefs,
    this.artworkResolver,
    this.artworkServices,
  });

  @override
  State<_BottomBars> createState() => _BottomBarsState();
}

class _BottomBarsState extends State<_BottomBars> {
  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerChanged);
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  /// A different track brings the strip back -- see [LayoutPrefs].
  void _onPlayerChanged() {
    final prefs = widget.layoutPrefs;
    if (!prefs.nowPlayingHidden) return;
    final id = widget.player.current?.contentId;
    if (id != null && id != prefs.nowPlayingHiddenFor) prefs.showNowPlaying();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.layoutPrefs,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.layoutPrefs.nowPlayingHidden)
          NowPlayingBar(
            player: widget.player,
            artworkResolver: widget.artworkResolver,
            artwork: widget.artworkServices,
            onDismiss: () => widget.layoutPrefs.hideNowPlaying(
              widget.player.current?.contentId,
            ),
          ),
        ActivityBar(
          activity: widget.activity,
          library: widget.library,
          player: widget.player,
          nowPlayingHidden: widget.layoutPrefs.nowPlayingHidden,
          onExpand: widget.layoutPrefs.showNowPlaying,
        ),
      ],
    ),
  );
}
