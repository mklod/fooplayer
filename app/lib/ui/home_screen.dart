import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../artwork/artwork_backfill.dart';
import '../artwork/artwork_resolver.dart';
import '../artwork/picker_seams.dart';
import '../model/library_model.dart';
import '../model/library_roots_prefs.dart';
import '../model/manifest_io.dart';
import '../model/playlist_store.dart';
import '../player/player_service.dart';
import 'app_theme.dart';
import 'drag_divider.dart';
import 'filter_panel.dart';
import 'layout_prefs.dart';
import 'now_playing_bar.dart';
import 'playlist_dialogs.dart';
import 'settings_dialog.dart';
import 'track_list.dart';

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

  /// Background best-guess artwork pass -- the Refresh button below queues a
  /// pass over any newly-discovered tracks once its manual rescan settles
  /// (mirroring what main.dart's periodic timer and launch-time rescan
  /// already do; see [rescanThenBackfill]). Null falls back to a plain
  /// `library.rescan()` with no backfill queued, which is what widget tests
  /// building this screen without the artwork feature wired rely on.
  final ArtworkBackfill? artworkBackfill;

  const HomeScreen({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
    required this.libraryRootsPrefs,
    this.playlistStore,
    this.artworkResolver,
    this.artworkServices,
    this.artworkBackfill,
  });

  @override
  Widget build(BuildContext context) {
    final store = playlistStore ?? PlaylistStore(library: library);
    return Scaffold(
      body: Column(
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
                          library: library,
                          libraryRootsPrefs: libraryRootsPrefs,
                          playlistStore: store),
                    ),
                  ),
                  VerticalDragDivider(
                    key: const Key('sidebar-divider'),
                    onDragDelta: (dx) => layoutPrefs
                        .setSidebarWidth(layoutPrefs.sidebarWidth + dx),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              Expanded(child: _SearchField(library: library)),
                              const SizedBox(width: 4),
                              _RefreshButton(
                                library: library,
                                artworkBackfill: artworkBackfill,
                              ),
                            ],
                          ),
                        ),
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
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: FilterPanel(
                                      key: const Key('folder-filter-panel'),
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
                                      values: library.folderEntries,
                                      selected: library.folderSiblings,
                                      onSelect: library.setFolderSiblings,
                                      onDrill: library.drillIntoFolder,
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
                                      headerSegments:
                                          library.folderBreadcrumbs.isEmpty
                                              ? null
                                              : [
                                                  'All',
                                                  ...library.folderBreadcrumbs,
                                                ],
                                      onHeaderSegmentTap: library.popFolderTo,
                                      onClearHeader:
                                          library.clearFolderSelection,
                                      displayName: library.folderPath.isEmpty
                                          ? p.basename
                                          : null,
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(
                                    child: FilterPanel(
                                      key: const Key('artist-filter-panel'),
                                      title: 'Artist',
                                      values: library.artists,
                                      selected: library.artistFilters,
                                      onSelect: library.setArtists,
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(
                                    child: FilterPanel(
                                      key: const Key('album-filter-panel'),
                                      title: 'Album',
                                      values: library.albums,
                                      selected: library.albumFilters,
                                      onSelect: library.setAlbums,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        HorizontalDragDivider(
                          key: const Key('filter-divider'),
                          onDragDelta: (dy) => layoutPrefs
                              .setFilterHeight(layoutPrefs.filterHeight + dy),
                        ),
                        Expanded(
                            child: TrackListView(
                                library: library,
                                player: player,
                                playlistStore: store,
                                artwork: artworkServices)),
                        _StatusBar(library: library),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          NowPlayingBar(player: player, artworkResolver: artworkResolver),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final LibraryModel library;
  final LibraryRootsPrefs libraryRootsPrefs;
  final PlaylistStore playlistStore;
  const _Sidebar({
    required this.library,
    required this.libraryRootsPrefs,
    required this.playlistStore,
  });

  Future<void> _createPlaylist(BuildContext context) async {
    final name = await showPlaylistNameDialog(context, store: playlistStore);
    if (name == null || !context.mounted) return;
    try {
      await playlistStore.createPlaylist(name);
    } on PlaylistStoreException catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                ListTile(
                  title: const Text('Library'),
                  selected: library.activePlaylist == null,
                  // Clears any active playlist (setPlaylist(null) also
                  // resets folder/artist/album/search state) -- the
                  // "clicking Library must clear" path of the #30
                  // selection-clear trio, alongside the toggle-off tap and
                  // the ✕ on the active playlist row below.
                  onTap: () => library.setPlaylist(null),
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
          // above) so it's always reachable regardless of playlist count.
          ListTile(
            key: const Key('settings-gear'),
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => _openSettings(context),
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
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
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
    if (!confirmed || !context.mounted) return;
    try {
      await store.deletePlaylist(playlist.name);
    } on PlaylistStoreException catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = library.activePlaylist == playlist.name;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: ListTile(
        title: Text(playlist.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: active,
        // Toggle: a tap on the already-active playlist clears back to the
        // Library view instead of being a dead click.
        onTap: () => library.setPlaylist(active ? null : playlist.name),
        trailing: active
            ? IconButton(
                key: Key('clear-playlist-${playlist.name}'),
                icon: const Icon(Icons.close,
                    size: 14, color: AppColors.inkSecondary),
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
  void dispose() {
    _controller.dispose();
    super.dispose();
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
                  icon: const Icon(Icons.close,
                      size: 16, color: AppColors.inkSecondary),
                  tooltip: 'Clear search',
                  onPressed: _clear,
                ),
        ),
        onChanged: widget.library.setSearch,
      ),
    );
  }
}

/// Manual trigger for [LibraryModel.rescan] (the other two triggers --
/// launch and the 5-minute periodic timer -- are wired in main.dart).
/// Disabled (and grayed out, standard [IconButton] behavior for a `null`
/// `onPressed`) while [LibraryModel.busy] so a tap can't queue up a second
/// overlapping rescan; [LibraryModel.rescan] itself would just no-op it
/// anyway, but disabling communicates that visually instead of silently
/// swallowing the tap.
///
/// When [artworkBackfill] is supplied, the rescan is chained through
/// [rescanThenBackfill] so any newly-discovered tracks get an automatic
/// artwork pass queued once the rescan settles -- without this, a manual
/// refresh (like the periodic timer) never triggered a backfill at all, so
/// an album added after launch showed no art until the app was restarted.
class _RefreshButton extends StatelessWidget {
  final LibraryModel library;
  final ArtworkBackfill? artworkBackfill;
  const _RefreshButton({required this.library, this.artworkBackfill});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => IconButton(
        key: const Key('refresh-library'),
        icon: const Icon(Icons.refresh),
        tooltip: 'Rescan library folders',
        onPressed: library.busy
            ? null
            : () {
                final backfill = artworkBackfill;
                if (backfill == null) {
                  library.rescan();
                } else {
                  unawaited(rescanThenBackfill(
                    rescan: library.rescan,
                    backfill: backfill,
                    tracks: () => library.allTracks,
                  ));
                }
              },
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final LibraryModel library;
  const _StatusBar({required this.library});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '${library.status} — ${library.visibleTracks.length} tracks',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
