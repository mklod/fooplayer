// Last modified: 2026-07-24--1837
//
// Phone-shell browse views (Plan 2b, task P3): Folders / Artists / Albums /
// Playlists -- the drawer destinations other than the Library feed. Each is
// a STANDALONE widget taking exactly the models it needs (LibraryModel,
// PlaylistStore, and an injected play callback), so PhoneShell can mount
// them via its viewBuilders map at merge time without any coupling here.
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../model/filtering.dart';
import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
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

  const FoldersView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final atTop = library.folderPath.isEmpty;
        final entries = library.folderEntries;
        final tracks = atTop
            ? const <Track>[]
            : sortTracks(
                applyFilters(library.allTracks,
                    folders: library.folderScopes, search: library.search),
                library.sortColumn,
                library.sortAscending,
              );
        final crumbs = library.folderBreadcrumbs;
        final breadcrumbText =
            atTop ? 'All folders' : (['All', ...crumbs]).join(' › ');
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
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
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
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.inkSecondary),
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
                      title: Text(display,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// Artists view: alphabetical list from [LibraryModel.artists]; tapping an
/// artist pushes a [TrackListPage] filtered to that artist (newest first,
/// the library default).
class ArtistsView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  const ArtistsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final artists = library.artists;
        return ListView.builder(
          itemCount: artists.length,
          itemBuilder: (context, i) {
            final artist = artists[i];
            return ListTile(
              title:
                  Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
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
              )),
            );
          },
        );
      },
    );
  }
}

/// Albums view: alphabetical list from [LibraryModel.albums]; tapping an
/// album pushes a [TrackListPage] filtered to that album in trackNumber
/// order ascending -- the same album-view default the desktop's
/// [LibraryModel.setAlbums] applies, via the same [sortTracks] logic
/// (unknown track numbers sort last).
class AlbumsView extends StatelessWidget {
  final LibraryModel library;
  final PlaylistStore store;
  final PlayTrackCallback onPlayTrack;

  const AlbumsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final albums = library.albums;
        return ListView.builder(
          itemCount: albums.length,
          itemBuilder: (context, i) {
            final album = albums[i];
            return ListTile(
              title: Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
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
              )),
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

  const PlaylistsView({
    super.key,
    required this.library,
    required this.store,
    required this.onPlayTrack,
  });

  Future<void> _create(BuildContext context) async {
    final name = await showPlaylistNameDialog(context, store: store);
    if (name == null) return;
    try {
      await store.createPlaylist(name);
    } on PlaylistStoreException catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, String name) async {
    final confirmed = await confirmDeletePlaylist(context, name);
    if (!confirmed || !context.mounted) return;
    try {
      await store.deletePlaylist(name);
    } on PlaylistStoreException catch (e) {
      if (context.mounted) showPlaylistError(context, e);
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
        if (byId[id] != null) byId[id]!
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
              title:
                  Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('$count ${count == 1 ? 'track' : 'tracks'}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TrackListPage(
                  title: pl.name,
                  library: library,
                  store: store,
                  onPlayTrack: onPlayTrack,
                  tracksOf: (lib) => playlistTracks(lib, pl.name),
                ),
              )),
              onLongPress: () => _delete(context, pl.name),
            );
          },
        );
      },
    );
  }
}
