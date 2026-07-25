// Last modified: 2026-07-24--1837
import 'package:flutter/material.dart';
import '../../model/library_model.dart';
import '../../player/player_service.dart';
import 'phone_feed.dart';
import 'phone_search_page.dart';

/// The phone shell's body views, one per Drawer entry. [library] is the
/// feed (home); the browse views default to placeholders until the P3
/// branch's real pages are wired in via [PhoneShell.viewBuilders] (see its
/// doc), and Settings likewise awaits its page.
enum PhoneView { library, folders, artists, albums, playlists, settings }

extension PhoneViewInfo on PhoneView {
  /// Drawer entry text AND the AppBar title while the view is active.
  String get label => switch (this) {
        PhoneView.library => 'Library',
        PhoneView.folders => 'Folders',
        PhoneView.artists => 'Artists',
        PhoneView.albums => 'Albums',
        PhoneView.playlists => 'Playlists',
        PhoneView.settings => 'Settings',
      };

  IconData get icon => switch (this) {
        PhoneView.library => Icons.library_music_outlined,
        PhoneView.folders => Icons.folder_outlined,
        PhoneView.artists => Icons.person_outline,
        PhoneView.albums => Icons.album_outlined,
        PhoneView.playlists => Icons.queue_music_outlined,
        PhoneView.settings => Icons.settings_outlined,
      };
}

/// The Android phone chrome (Plan 2b): Scaffold + AppBar (hamburger /
/// current-view title / search icon), a navigation Drawer that switches the
/// body between [PhoneView]s, the feed as the home view, and a
/// bottom-of-screen mini-player slot. Reuses the desktop's
/// [LibraryModel]/[PlayerService] unchanged.
///
/// Two injectable builder slots exist so the parallel branches can fill
/// them at merge without this file changing shape:
///
/// - [miniPlayerBuilder]: rendered as the Scaffold's bottomNavigationBar.
///   Defaults to nothing ([SizedBox.shrink]); the P2 branch's MiniPlayer
///   (which itself renders empty until a track is loaded, like the desktop
///   NowPlayingBar) drops straight in.
/// - [viewBuilders]: per-[PhoneView] body overrides. Any view without an
///   entry uses the built-in body -- the live feed for [PhoneView.library],
///   a "coming soon" placeholder for everything else. The P3 branch's
///   Folders/Artists/Albums/Playlists pages (and a future Settings page)
///   drop in as map entries.
class PhoneShell extends StatefulWidget {
  final LibraryModel library;
  final PlayerService player;

  /// Feed/search row tap handler; defaults to [PlayerService.playFrom]
  /// (tap = play, the phone idiom). Injectable so widget tests can spy
  /// without constructing a real media_kit Player.
  final PlayTrackCallback? onPlayTrack;

  /// Feed/search row long-press handler; defaults to the placeholder
  /// context sheet ([showTrackContextSheet]) until P3's real one lands.
  final TrackLongPressCallback onTrackLongPress;

  /// Mini-player slot -- see the class doc.
  final WidgetBuilder? miniPlayerBuilder;

  /// Per-view body overrides -- see the class doc.
  final Map<PhoneView, WidgetBuilder> viewBuilders;

  const PhoneShell({
    super.key,
    required this.library,
    required this.player,
    this.onPlayTrack,
    this.onTrackLongPress = showTrackContextSheet,
    this.miniPlayerBuilder,
    this.viewBuilders = const {},
  });

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  PhoneView _view = PhoneView.library;

  PlayTrackCallback get _onPlay => widget.onPlayTrack ?? widget.player.playFrom;

  Widget _body(BuildContext context) {
    final override = widget.viewBuilders[_view];
    if (override != null) return override(context);
    if (_view == PhoneView.library) {
      return PhoneFeedView(
        library: widget.library,
        onPlay: _onPlay,
        onLongPress: widget.onTrackLongPress,
      );
    }
    return const Center(child: Text('coming soon'));
  }

  Widget _drawerTile(BuildContext context, PhoneView view) {
    return ListTile(
      key: Key('phone-drawer-${view.name}'),
      leading: Icon(view.icon, size: 20),
      title: Text(view.label),
      // Active entry highlight: `selected` paints the app theme's
      // selectedTileColor (AppColors.selectionFill) with ink text, same
      // treatment as the desktop sidebar's active playlist row.
      selected: view == _view,
      onTap: () {
        setState(() => _view = view);
        Navigator.of(context).pop(); // close the drawer
      },
    );
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhoneSearchPage(
        library: widget.library,
        onPlayTrack: _onPlay,
        onTrackLongPress: widget.onTrackLongPress,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_view.label),
        actions: [
          IconButton(
            key: const Key('phone-search'),
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => _openSearch(context),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              for (final v in const [
                PhoneView.library,
                PhoneView.folders,
                PhoneView.artists,
                PhoneView.albums,
                PhoneView.playlists,
              ])
                _drawerTile(context, v),
              const Divider(height: 1),
              _drawerTile(context, PhoneView.settings),
            ],
          ),
        ),
      ),
      body: _body(context),
      bottomNavigationBar:
          widget.miniPlayerBuilder?.call(context) ?? const SizedBox.shrink(),
    );
  }
}
