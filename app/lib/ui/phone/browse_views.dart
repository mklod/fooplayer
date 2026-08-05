// Last modified: 2026-08-05--0633
//
// Phone-shell browse views (Plan 2b, task P3): Folders / Artists / Albums /
// Playlists -- the drawer destinations other than the Library feed. Each is
// a STANDALONE widget taking exactly the models it needs (LibraryModel,
// PlaylistStore, and an injected play callback), so PhoneShell can mount
// them via its viewBuilders map at merge time without any coupling here.
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../artwork/picker_seams.dart' show ArtworkServices;
import '../../model/filtering.dart';
import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
import '../../player/player_service.dart';
import '../app_theme.dart';
import '../playlist_dialogs.dart';
import 'track_context_sheet.dart';
import 'track_list_page.dart';

/// Signature the phone views use to start playback: play [tracks] from
/// [index]. The shell wires `PlayerService.playFrom` here at merge; tests
/// inject a spy so no media_kit Player is ever constructed.
typedef PlayTrackCallback = void Function(List<Track> tracks, int index);

/// Folders drill-down view: lists [LibraryModel.folderEntries] (library
/// roots at the top level, subfolder names below), reusing the model's own
/// [LibraryModel.drillIntoFolder]/[LibraryModel.popFolderTo] navigation.
/// A breadcrumb text line sits under a back affordance that pops exactly
/// one level; once drilled in, the tracks under the current folder are
/// listed below its subfolders (feed-style rows, tap = play), sorted by
/// the model's current sort -- which the model itself switches to
/// trackNumber order when the drilled folder is a single album's (see
/// [LibraryModel.folderSelectionIsSingleAlbum]).
class FoldersView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  /// Forwarded into every long-press context sheet (and, for the
  /// drill-down views, into the TrackListPage they push) -- see
  /// TrackListPage.artwork's doc for the bug this closed.
  final ArtworkServices? artwork;
  final PlayerService? player;

  const FoldersView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
    this.artwork,
    this.player,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        // "At the top" is not always "listing roots": with a single library
        // root the pane opens inside it (see [LibraryModel.folderTopPath]),
        // so there is no level above and no back arrow -- but there ARE
        // tracks and subfolders to list.
        final atTop = library.folderAtTop;
        final listingRoots = library.folderPath.isEmpty;
        final entries = library.folderEntries;
        final tracks = listingRoots
            ? const <Track>[]
            : sortTracks(
                applyFilters(
                  library.allTracks,
                  folders: library.folderScopes,
                  search: library.search,
                ),
                library.sortColumn,
                library.sortAscending,
              );
        final crumbs = library.folderBreadcrumbs;
        // "All ›" is only worth showing when there is an All to go back to.
        final breadcrumbText = listingRoots
            ? 'All folders'
            : crumbs.isEmpty
            // The one implicit root's own top: no drilled path, no
            // sibling selection, so folderBreadcrumbs is empty (its own
            // name is never a segment -- see LibraryModel._rootIsImplicit).
            // Blank text would look broken with nothing to explain it, so
            // this is the one place its name still appears -- as plain
            // orientation text, not a segment anyone can tap.
            ? p.basename(library.folderPath.first)
            : ([
                if (library.folderTopPath.isEmpty) 'All',
                ...crumbs,
              ]).join(' › ');
        return Column(
          children: [
            Container(
              color: AppColors.panelBg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              height: 36,
              child: Row(
                children: [
                  if (!atTop)
                    IconButton(
                      key: const Key('folders-back'),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      padding: EdgeInsets.zero,
                      // Fits the 36px breadcrumb bar (the default 48px
                      // min-size would overflow it).
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      tooltip: 'Up one level',
                      onPressed: () =>
                          library.popFolderTo(library.folderPath.length - 1),
                    ),
                  Expanded(
                    child: Text(
                      breadcrumbText,
                      key: const Key('folders-breadcrumb'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.inkSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length + tracks.length,
                itemBuilder: (context, i) {
                  if (i < entries.length) {
                    final entry = entries[i];
                    // Top-level entries ARE root paths (see
                    // [LibraryModel.folderNames]) -- display by basename,
                    // pass back verbatim.
                    final display = atTop ? p.basename(entry) : entry;
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined, size: 18),
                      title: Text(
                        display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => library.drillIntoFolder(entry),
                    );
                  }
                  final ti = i - entries.length;
                  return PhoneTrackRow(
                    track: tracks[ti],
                    onTap: () => onPlayTrack(tracks, ti),
                    onLongPress: () => showTrackContextSheet(
                      context,
                      track: tracks[ti],
                      library: library,
                      store: store,
                      artwork: artwork,
                      player: player,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Artists view: alphabetical list of ALL artists in the library; tapping
/// an artist pushes a [TrackListPage] filtered to that artist (newest
/// first, the library default).
///
/// Deliberately derived from the UNSCOPED [LibraryModel.allTracks], not
/// [LibraryModel.artists]: that getter is scoped by the Folder pane's
/// cascade ([LibraryModel.folderScopes]), which is right for desktop --
/// where the panels sit side by side and the breadcrumb shows the scope --
/// but wrong for the phone drawer, where Artists is presented as an
/// independent top-level destination. Without this, drilling into a folder
/// in FoldersView would silently shrink the Artists list with zero UI
/// indication of why.
class ArtistsView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  /// Forwarded into every long-press context sheet (and, for the
  /// drill-down views, into the TrackListPage they push) -- see
  /// TrackListPage.artwork's doc for the bug this closed.
  final ArtworkServices? artwork;
  final PlayerService? player;

  const ArtistsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
    this.artwork,
    this.player,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final artists = distinctValues(library.allTracks, (t) => t.artist);
        return ListView.builder(
          itemCount: artists.length,
          itemBuilder: (context, i) {
            final artist = artists[i];
            return ListTile(
              title: Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TrackListPage(
                    title: artist,
                    library: library,
                    store: store,
                    onPlayTrack: onPlayTrack,
                    tracksOf: (lib) => sortTracks(
                      applyFilters(lib.allTracks, artist: {artist}),
                      SortColumn.dateAdded,
                      false,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Albums view: alphabetical list of ALL albums in the library; tapping an
/// album pushes a [TrackListPage] filtered to that album in trackNumber
/// order ascending -- the same album-view default the desktop's
/// [LibraryModel.setAlbums] applies, via the same [sortTracks] logic
/// (unknown track numbers sort last).
///
/// Like [ArtistsView], derived from the UNSCOPED [LibraryModel.allTracks]
/// rather than [LibraryModel.albums] (which the desktop Folder/Artist
/// cascade scopes) -- see ArtistsView's doc for why the phone drawer's
/// independent-destination model requires this.
class AlbumsView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  /// Forwarded into every long-press context sheet (and, for the
  /// drill-down views, into the TrackListPage they push) -- see
  /// TrackListPage.artwork's doc for the bug this closed.
  final ArtworkServices? artwork;
  final PlayerService? player;

  const AlbumsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
    this.artwork,
    this.player,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final albums = distinctValues(library.allTracks, (t) => t.album);
        return ListView.builder(
          itemCount: albums.length,
          itemBuilder: (context, i) {
            final album = albums[i];
            return ListTile(
              title: Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TrackListPage(
                    title: album,
                    library: library,
                    store: store,
                    onPlayTrack: onPlayTrack,
                    tracksOf: (lib) => sortTracks(
                      applyFilters(lib.allTracks, album: {album}),
                      SortColumn.trackNumber,
                      true,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Playlists view: merged playlist list (name + track count) with a
/// "New playlist…" entry on top (shared name dialog ->
/// [PlaylistStore.createPlaylist]) and long-press delete behind the shared
/// confirm dialog ([PlaylistStore.deletePlaylist]). Tapping a playlist
/// pushes a [TrackListPage] showing its tracks in playlist order (never
/// resorted -- same rule as [LibraryModel.visibleTracks]).
class PlaylistsView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  /// Forwarded into every long-press context sheet (and, for the
  /// drill-down views, into the TrackListPage they push) -- see
  /// TrackListPage.artwork's doc for the bug this closed.
  final ArtworkServices? artwork;
  final PlayerService? player;

  const PlaylistsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
    this.artwork,
    this.player,
  });

  Future<void> _create(BuildContext context) async {
    // Captured before the name dialog opens -- see showPlaylistError's doc.
    final messenger = ScaffoldMessenger.of(context);
    final name = await showPlaylistNameDialog(context, store: store);
    if (name == null) return;
    try {
      await store.createPlaylist(name);
    } on PlaylistStoreException catch (e) {
      showPlaylistError(messenger, e);
    }
  }

  Future<void> _delete(BuildContext context, String name) async {
    // Captured before the confirm dialog opens -- matters here specifically
    // because a SUCCESSFUL delete removes this very playlist row from the
    // list a rebuild produces, but a refused delete must still be able to
    // report through a messenger that doesn't depend on that row surviving.
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await confirmDeletePlaylist(context, name);
    if (!confirmed) return;
    try {
      await store.deletePlaylist(name);
    } on PlaylistStoreException catch (e) {
      showPlaylistError(messenger, e);
    }
  }

  /// The tracks of the merged playlist shown as [name], in playlist order,
  /// skipping ids not (or no longer) present in the library -- the same
  /// resolution [LibraryModel.visibleTracks] applies in playlist mode.
  static List<Track> playlistTracks(LibraryModel lib, String name) {
    final matches = lib.playlists.where((pl) => pl.name == name);
    if (matches.isEmpty) return const [];
    final byId = {for (final t in lib.allTracks) t.contentId: t};
    return [
      for (final id in matches.first.trackIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final playlists = library.playlists;
        return ListView.builder(
          itemCount: playlists.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return ListTile(
                key: const Key('playlist-create'),
                leading: const Icon(Icons.add),
                title: const Text('New playlist…'),
                onTap: () => _create(context),
              );
            }
            final pl = playlists[i - 1];
            final count = pl.trackIds.length;
            return ListTile(
              leading: const Icon(Icons.queue_music, size: 18),
              title: Text(
                pl.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('$count ${count == 1 ? 'track' : 'tracks'}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TrackListPage(
                    title: pl.name,
                    library: library,
                    store: store,
                    onPlayTrack: onPlayTrack,
                    tracksOf: (lib) => playlistTracks(lib, pl.name),
                  ),
                ),
              ),
              onLongPress: () => _delete(context, pl.name),
            );
          },
        );
      },
    );
  }
}
