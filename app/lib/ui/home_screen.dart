import 'package:flutter/material.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';
import 'filter_panel.dart';
import 'track_list.dart';

class HomeScreen extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const HomeScreen({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 200, child: _Sidebar(library: library)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: _SearchField(library: library),
                      ),
                      SizedBox(
                        height: 180,
                        child: ListenableBuilder(
                          listenable: library,
                          builder: (context, _) => Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: FilterPanel(
                                  title: 'Genre',
                                  values: library.genres,
                                  selected: library.genreFilter,
                                  onSelect: library.setGenre,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: FilterPanel(
                                  title: 'Artist',
                                  values: library.artists,
                                  selected: library.artistFilter,
                                  onSelect: library.setArtist,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: FilterPanel(
                                  title: 'Album',
                                  values: library.albums,
                                  selected: library.albumFilter,
                                  onSelect: library.setAlbum,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                          child: TrackListView(library: library, player: player)),
                      _StatusBar(library: library),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // NowPlayingBar inserted here in Task 8.
          const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final LibraryModel library;
  const _Sidebar({required this.library});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => ListView(
        children: [
          ListTile(
            title: const Text('Library'),
            selected: library.activePlaylist == null,
            onTap: () => library.setPlaylist(null),
          ),
          const Divider(),
          for (final pl in library.playlists)
            ListTile(
              title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: library.activePlaylist == pl.name,
              onTap: () => library.setPlaylist(pl.name),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final LibraryModel library;
  const _SearchField({required this.library});

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Search title, artist, album',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: library.setSearch,
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
