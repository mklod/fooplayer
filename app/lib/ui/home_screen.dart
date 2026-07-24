import 'package:flutter/material.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';
import 'app_theme.dart';
import 'drag_divider.dart';
import 'filter_panel.dart';
import 'layout_prefs.dart';
import 'now_playing_bar.dart';
import 'track_list.dart';

class HomeScreen extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  final LayoutPrefs layoutPrefs;
  const HomeScreen({
    super.key,
    required this.library,
    required this.player,
    required this.layoutPrefs,
  });

  @override
  Widget build(BuildContext context) {
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
                      child: _Sidebar(library: library),
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
                          child: _SearchField(library: library),
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
                        ),
                        HorizontalDragDivider(
                          key: const Key('filter-divider'),
                          onDragDelta: (dy) => layoutPrefs
                              .setFilterHeight(layoutPrefs.filterHeight + dy),
                        ),
                        Expanded(
                            child:
                                TrackListView(library: library, player: player)),
                        _StatusBar(library: library),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          NowPlayingBar(player: player, libraryRoot: player.libraryRoot),
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
