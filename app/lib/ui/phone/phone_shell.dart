// Last modified: 2026-08-04--1654
import 'dart:async';

import 'package:flutter/material.dart';
import '../../artwork/artwork_resolver.dart';
import '../../artwork/picker_seams.dart' show ArtworkServices;
import '../../model/activity_model.dart';
import '../../model/library_model.dart';
import '../../model/playlist_store.dart';
import '../../model/track.dart';
import '../../player/player_service.dart';
import 'app_background.dart';
import '../queue_view.dart';
import 'now_playing_page.dart';
import 'phone_activity_strip.dart';
import 'phone_feed.dart';
import 'phone_search_page.dart';

/// The phone shell's body views, one per Drawer entry. [library] is the
/// feed (home, built in); production (main.dart) supplies every other
/// view's body via [PhoneShell.viewBuilders] -- the P3 browse views plus
/// the Settings page (`phone_settings_view.dart`).
enum PhoneView { library, queue, folders, artists, albums, playlists, settings }

/// App-global "switch the shell to this view" request bus. The full-screen
/// player's bottom shortcut bar (now_playing_page.dart's `_navBar`) lives on
/// a pushed ROUTE above the shell, with no constructor path back to the
/// shell's private view state -- so it pops itself and posts the target view
/// here, and the live shell listens and switches. Nulled by the handler, so
/// the same view can be requested again later.
final ValueNotifier<PhoneView?> phoneShellNavRequest =
    ValueNotifier<PhoneView?>(null);

extension PhoneViewInfo on PhoneView {
  /// Drawer entry text AND the AppBar title while the view is active.
  String get label => switch (this) {
    PhoneView.library => 'Library',
    PhoneView.queue => 'Queue',
    PhoneView.folders => 'Folders',
    PhoneView.artists => 'Artists',
    PhoneView.albums => 'Albums',
    PhoneView.playlists => 'Playlists',
    PhoneView.settings => 'Settings',
  };

  IconData get icon => switch (this) {
    PhoneView.library => Icons.library_music_outlined,
    PhoneView.queue => Icons.playlist_play,
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
/// Two injectable builder slots keep this file decoupled from the concrete
/// view/player widgets (main.dart owns the production wiring):
///
/// - [miniPlayerBuilder]: rendered as the bottom of the Scaffold's
///   bottomNavigationBar column. Defaults to nothing ([SizedBox.shrink]);
///   production passes the P2 MiniPlayer (which itself renders empty until
///   a track is loaded, like the desktop NowPlayingBar). [activity], when
///   supplied, renders [PhoneActivityStrip] just above it in that same
///   column -- the phone's answer to the desktop's persistent ActivityBar.
/// - [viewBuilders]: per-[PhoneView] body builders. Production fills EVERY
///   non-library entry (P3's Folders/Artists/Albums/Playlists views and
///   the Settings page); [PhoneView.library] always uses the built-in live
///   feed. A view left without an entry (only possible in tests that
///   construct a bare PhoneShell) falls back to a defensive placeholder.
class PhoneShell extends StatefulWidget {
  final LibraryModel library;
  final PlayerService player;

  /// Feed/search row tap handler; defaults to [PlayerService.playFrom]
  /// (tap = play, the phone idiom). Injectable so widget tests can spy
  /// without constructing a real media_kit Player.
  final PlayTrackCallback? onPlayTrack;

  /// Feed/search row long-press handler; production wires the real track
  /// context sheet (Add to playlist / View details -- see main.dart, which
  /// closes it over the library's PlaylistStore). Required: there is no
  /// meaningful default without a store to add to.
  final TrackLongPressCallback onTrackLongPress;

  /// Mini-player slot -- see the class doc.
  final WidgetBuilder? miniPlayerBuilder;

  /// Background jobs (sync, tag reading, artwork work), shown above the
  /// mini-player as [PhoneActivityStrip]. Null hides the strip entirely --
  /// matches the desktop's [ActivityBar], which is likewise optional in
  /// bare test builds that construct a shell without one.
  final ActivityModel? activity;

  /// Per-view body overrides -- see the class doc.
  final Map<PhoneView, WidgetBuilder> viewBuilders;

  /// Artwork chain, forwarded to the full-screen player this shell opens.
  final ArtworkResolver? artworkResolver;

  /// Forwarded to the full-screen player's overflow ("more") button, which
  /// reuses the existing track context sheet. Null keeps that button a
  /// harmless no-op, exactly like [NowPlayingPage]'s own default.
  final PlaylistStore? store;
  final ArtworkServices? artwork;

  /// Whether tapping a song opens the full-screen player on top of playing
  /// it. On by default; widget tests that only want to observe the play
  /// callback turn it off rather than dealing with a pushed route.
  final bool openNowPlayingOnPlay;

  const PhoneShell({
    super.key,
    required this.library,
    required this.player,
    this.onPlayTrack,
    required this.onTrackLongPress,
    this.miniPlayerBuilder,
    this.activity,
    this.viewBuilders = const {},
    this.artworkResolver,
    this.store,
    this.artwork,
    this.openNowPlayingOnPlay = true,
  });

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  PhoneView _view = PhoneView.library;

  /// Drawer views the user came through, oldest first, NOT including the
  /// current one.
  ///
  /// Switching drawer views changes state rather than pushing a route, so
  /// without this the system Back button found nothing to pop and closed the
  /// app -- from Albums, from Settings, from anywhere but the feed. Back has
  /// to unwind this the same way it unwinds a route stack.
  final List<PhoneView> _viewHistory = [];

  /// So Back can tell whether the drawer is open. The drawer is not a
  /// Navigator route, and this shell's PopScope sits above the Scaffold, so
  /// without this check Back would skip past an open drawer and change the
  /// view underneath it -- two levels for one press.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    phoneShellNavRequest.addListener(_onNavRequest);
  }

  @override
  void dispose() {
    phoneShellNavRequest.removeListener(_onNavRequest);
    super.dispose();
  }

  void _onNavRequest() {
    final v = phoneShellNavRequest.value;
    if (v == null) return;
    // Null it BEFORE acting: the write re-fires this listener (guarded by
    // the null check above), and leaves the bus clean for the next request.
    phoneShellNavRequest.value = null;
    _selectView(v);
  }

  PlayTrackCallback get _rawPlay =>
      widget.onPlayTrack ?? widget.player.playFrom;

  /// Tapping a song plays it AND opens the full-screen player.
  ///
  /// It used to only start playback and leave you looking at the list, with
  /// the now-playing screen reachable solely by then noticing the strip at
  /// the bottom and tapping that. Going into the song is what tapping a song
  /// means on a phone; the mini-player is for getting back to it later.
  void _playAndOpen(List<Track> tracks, int index) {
    _rawPlay(tracks, index);
    if (widget.openNowPlayingOnPlay) {
      Navigator.of(context).push(
        NowPlayingPage.route(
          player: widget.player,
          artworkResolver: widget.artworkResolver,
          library: widget.library,
          store: widget.store,
          artwork: widget.artwork,
        ),
      );
    }
  }

  PlayTrackCallback get _onPlay => _playAndOpen;

  void _selectView(PhoneView view) {
    if (view == _view) return;
    setState(() {
      _viewHistory.add(_view);
      _view = view;
    });
  }

  /// Back: exactly one level, and never out of the app.
  Future<void> _handleBack() async {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return;
    }
    if (_viewHistory.isNotEmpty) {
      setState(() => _view = _viewHistory.removeLast());
      return;
    }
    // At the root. Step aside rather than tearing the app down -- see
    // [moveAppToBackground] for why that distinction matters here.
    await moveAppToBackground();
  }

  Widget _body(BuildContext context) {
    final override = widget.viewBuilders[_view];
    if (override != null) return override(context);
    if (_view == PhoneView.queue) {
      return QueueView(
        player: widget.player,
        artworkResolver: widget.artworkResolver,
      );
    }
    if (_view == PhoneView.library) {
      return PhoneFeedView(
        library: widget.library,
        onPlay: _onPlay,
        onLongPress: widget.onTrackLongPress,
      );
    }
    // Defensive fallback only: production (main.dart) supplies a builder
    // for every non-library view, so this is reachable solely from tests
    // that construct a bare PhoneShell.
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
        _selectView(view);
        Navigator.of(context).pop(); // close the drawer
      },
    );
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhoneSearchPage(
          library: widget.library,
          onPlayTrack: _onPlay,
          onTrackLongPress: widget.onTrackLongPress,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Never pop automatically: at the root that would finish the activity,
      // and on a non-library view there is no route to pop anyway -- the
      // view is state, so Back has to be handled here or it closes the app.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        key: _scaffoldKey,
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
          // Wider than Material's 304 default -- reported live as "too
          // small" together with the rest of the phone chrome; the wider
          // panel also keeps the (now larger, see buildAppTheme's phone
          // ramp) entry text from feeling cramped against the edge.
          width: 340,
          child: SafeArea(
            child: ListView(
              children: [
                for (final v in const [
                  PhoneView.library,
                  PhoneView.queue,
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
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.activity != null)
              PhoneActivityStrip(activity: widget.activity!),
            widget.miniPlayerBuilder?.call(context) ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}
