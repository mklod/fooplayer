// The Queue is a sidebar destination now, not a popup dialog -- and it only
// appears once there IS one.
//
// Requested: "it's not a modal; it displays like a playlist and is listed
// under playlists just below the 'Library' header in side panel." Before
// this, "Queue" sat at the bottom of the sidebar (grouped with Rescan/
// Enrich/Embed/Settings) and opened a fixed-size Dialog over everything
// else. It is a real navigation entry now -- right under Library, above the
// saved playlists -- and clicking it swaps the main content area (search
// field, Folder/Artist/Album filters, track list) for the queue itself,
// exactly the way clicking a playlist swaps it for that playlist's tracks.
//
// The other half of the same request: a normal play's own continuation (the
// "faux queue" -- see QueueController's doc) is just whatever the library
// view already shows, so the tile stays hidden for it -- "no need for a
// side panel there". It appears only once a real, explicit queue exists,
// born from the first "Play next" / "Add to queue".
//
// Last modified: 2026-07-30--0130
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      rootPath: r'L:\Music',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Now Playing',
      artist: 'Muse',
      album: 'X',
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      rootPath: r'L:\Music',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Up Next',
      artist: 'Feed Me',
      album: 'Y',
    ),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['a', 'b'])];
  m.status = 'ready';
  return m;
}

Future<PlayerService> pumpHome(
  WidgetTester tester,
  LibraryModel lib, {
  PlayerService? player,
}) async {
  final p = player ?? PlayerService();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
        library: lib,
        player: p,
        layoutPrefs: LayoutPrefs(),
        libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
      ),
    ),
  );
  return p;
}

/// Starts [tracks[0]] "playing" the way a normal double-click would --
/// straight on the controller, never through PlayerService.playFrom, which
/// would try to construct a real (native-backed) media_kit Player. Widget
/// tests must never do that.
///
/// Seeds the WHOLE list, not just the first track: a real double-click
/// hands the faux queue the entire filtered/sorted library view, so
/// `upcoming` is non-empty from the start. A single-track seed would let
/// a gate that checks only `upcoming.isNotEmpty` (forgetting
/// `hasExplicitQueue`) pass by accident -- exactly the bug this file
/// exists to catch.
void seedNowPlaying(PlayerService player, List<Track> tracks) {
  player.queueController.setQueue(tracks, 0);
}

void main() {
  testWidgets('nothing playing: no Queue tile -- there is no queue yet', (
    tester,
  ) async {
    await pumpHome(tester, fixtureLibrary());
    expect(find.byKey(const Key('queue-open')), findsNothing);
  });

  testWidgets(
    'something playing but nothing explicitly queued: still no tile -- '
    'that is the faux queue, and it needs no panel of its own',
    (tester) async {
      final lib = fixtureLibrary();
      // Seeded BEFORE the first build (not via a post-build tester.pump()):
      // seedNowPlaying mutates the controller directly, without going
      // through PlayerService, so it never calls notifyListeners -- a
      // pump() after the fact would rebuild nothing and this assertion
      // would pass vacuously against the pre-seed (also tile-less) state.
      final player = PlayerService();
      seedNowPlaying(player, lib.allTracks);
      await pumpHome(tester, lib, player: player);

      expect(find.byKey(const Key('queue-open')), findsNothing);
    },
  );

  testWidgets(
    'the first "Add to queue" makes the tile appear, right under Library, '
    'above the playlists',
    (tester) async {
      final lib = fixtureLibrary();
      final player = await pumpHome(tester, lib);
      seedNowPlaying(player, lib.allTracks);
      await player.addToQueue([lib.allTracks[1]]);
      await tester.pump();

      final library = tester.getTopLeft(find.text('Library'));
      final queue = tester.getTopLeft(find.byKey(const Key('queue-open')));
      final playlist = tester.getTopLeft(find.text('mix'));
      expect(queue.dy, greaterThan(library.dy), reason: 'below Library');
      expect(
        playlist.dy,
        greaterThan(queue.dy),
        reason: 'above the saved playlists',
      );
    },
  );

  testWidgets('clicking Queue opens no dialog -- it replaces the content '
      'area, the way a playlist does', (tester) async {
    final lib = fixtureLibrary();
    final player = await pumpHome(tester, lib);
    seedNowPlaying(player, lib.allTracks);
    await player.addToQueue([lib.allTracks[1]]);
    await tester.pump();

    await tester.tap(find.byKey(const Key('queue-open')));
    await tester.pumpAndSettle();

    expect(
      find.byType(Dialog),
      findsNothing,
      reason: 'a popup was the exact thing reported as wrong',
    );
    expect(find.byKey(const Key('queue-list')), findsOneWidget);
    // The library-browsing chrome has nothing to do while showing the
    // queue -- there is nothing to search or filter in a flat queue list.
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('folder-filter-panel')), findsNothing);
  });

  testWidgets(
    'the queue shown is the real one -- current track then whatever was '
    'explicitly queued, nothing from the browsing context',
    (tester) async {
      final lib = fixtureLibrary();
      final player = await pumpHome(tester, lib);
      seedNowPlaying(player, lib.allTracks);
      await player.addToQueue([lib.allTracks[1]]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('queue-open')));
      await tester.pumpAndSettle();

      // Scoped to the queue list itself: the now-playing bar at the bottom
      // of the screen shows the current track's title too, so a bare
      // find.text would (correctly) find it twice.
      final queueList = find.byKey(const Key('queue-list'));
      expect(
        find.descendant(of: queueList, matching: find.text('Now Playing')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: queueList, matching: find.text('Up Next')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('queue-empty')), findsNothing);
    },
  );

  testWidgets('the Queue tile is selected while showing, Library is not', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final player = await pumpHome(tester, lib);
    seedNowPlaying(player, lib.allTracks);
    await player.addToQueue([lib.allTracks[1]]);
    await tester.pump();
    expect(lib.showingQueue, isFalse);

    await tester.tap(find.byKey(const Key('queue-open')));
    await tester.pumpAndSettle();
    expect(lib.showingQueue, isTrue);

    final queueTile = tester.widget<ListTile>(
      find.byKey(const Key('queue-open')),
    );
    expect(queueTile.selected, isTrue);
  });

  testWidgets(
    'clicking Library exits the Queue back to the normal view -- the '
    'queue itself is untouched, so more can be added and it is reachable '
    'again',
    (tester) async {
      final lib = fixtureLibrary();
      final player = await pumpHome(tester, lib);
      seedNowPlaying(player, lib.allTracks);
      await player.addToQueue([lib.allTracks[1]]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('queue-open')));
      await tester.pumpAndSettle();
      expect(lib.showingQueue, isTrue);

      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();

      expect(lib.showingQueue, isFalse);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const Key('folder-filter-panel')), findsOneWidget);
      // The tile is still there -- Library did not clear the queue, only
      // the view.
      expect(find.byKey(const Key('queue-open')), findsOneWidget);
    },
  );

  testWidgets('selecting a playlist also exits the Queue', (tester) async {
    final lib = fixtureLibrary();
    final player = await pumpHome(tester, lib);
    seedNowPlaying(player, lib.allTracks);
    await player.addToQueue([lib.allTracks[1]]);
    await tester.pump();

    await tester.tap(find.byKey(const Key('queue-open')));
    await tester.pumpAndSettle();
    expect(lib.showingQueue, isTrue);

    await tester.tap(find.text('mix'));
    await tester.pumpAndSettle();

    expect(
      lib.showingQueue,
      isFalse,
      reason: 'the content area cannot show a playlist and the queue at once',
    );
    expect(lib.activePlaylist, 'mix');
  });

  testWidgets(
    'removing the last queued track hides the tile again -- back to just '
    'the faux queue',
    (tester) async {
      final lib = fixtureLibrary();
      final player = await pumpHome(tester, lib);
      seedNowPlaying(player, lib.allTracks);
      await player.addToQueue([lib.allTracks[1]]);
      await tester.pump();
      expect(find.byKey(const Key('queue-open')), findsOneWidget);

      await tester.tap(find.byKey(const Key('queue-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('queue-remove-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('queue-open')),
        findsNothing,
        reason: 'nothing left beyond what is playing',
      );
    },
  );
}
