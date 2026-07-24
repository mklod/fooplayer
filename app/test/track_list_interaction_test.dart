// Click-to-select / double-click-to-play / right-click "View in folder"
// interaction model (see ui/track_list.dart's _TrackRow doc). Playback and
// the explorer launch are both injected via TrackListView's onPlayTrack /
// launchExplorer callbacks so these tests never touch real media_kit
// natives or actually shell out -- see PlayerService.playFrom's doc for why
// the real Player must never be constructed in a widget test.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'sub/Banana.mp3',
      rootPath: r'C:\Music',
      dateAdded: DateTime.utc(2024, 1, 1),
      title: 'Banana',
      artist: 'Muse',
      album: 'X',
    ),
    Track(
      contentId: 'b',
      relPath: 'Apple.mp3',
      rootPath: r'C:\Music',
      dateAdded: DateTime.utc(2024, 1, 2),
      title: 'Apple',
      artist: 'Feed Me',
      album: 'Y',
    ),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpTrackList(
  WidgetTester tester,
  LibraryModel lib,
  PlayerService player, {
  void Function(List<Track>, int)? onPlayTrack,
  void Function(Track)? launchExplorer,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: TrackListView(
        library: lib,
        player: player,
        onPlayTrack: onPlayTrack,
        launchExplorer: launchExplorer ?? (_) {},
      ),
    ),
  ),
);

/// Simulates a real double-click: two taps close enough together (but not
/// so close as to violate [kDoubleTapMinTime]) that Flutter's gesture arena
/// resolves them as one [GestureDetector.onDoubleTap], not two
/// [GestureDetector.onTap]s. The trailing pump flushes the recognizer's own
/// internal `kDoubleTapMinTime` bookkeeping timer (armed on the second tap
/// to guard against a stray third tap) so it doesn't outlive the test.
Future<void> doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
}

void main() {
  testWidgets('single click selects the row and does not start playback', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    var playCalls = 0;
    await pumpTrackList(
      tester,
      lib,
      player,
      onPlayTrack: (_, _) => playCalls++,
    );

    expect(lib.selectedTrackId, isNull);

    await tester.tap(find.text('Banana'));
    // onTap is only resolved once the double-tap disambiguation window
    // elapses (InkWell has both onTap and onDoubleTap registered) -- pump
    // past it before asserting.
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));

    expect(lib.selectedTrackId, 'a');
    expect(playCalls, 0);
    expect(player.current, isNull);
  });

  testWidgets('clicking a different row moves the selection', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await pumpTrackList(tester, lib, player, onPlayTrack: (_, _) {});

    await tester.tap(find.text('Banana'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    expect(lib.selectedTrackId, 'a');

    await tester.tap(find.text('Apple'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    expect(lib.selectedTrackId, 'b');
  });

  testWidgets(
    'double click plays the track (via the injected spy) and selects it',
    (tester) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      final playedTracks = <Track>[];
      var playedIndex = -1;
      await pumpTrackList(
        tester,
        lib,
        player,
        onPlayTrack: (tracks, index) {
          playedTracks.addAll(tracks);
          playedIndex = index;
        },
      );

      await doubleTap(tester, find.text('Apple'));

      // Default sort is dateAdded descending (newest first): 'Apple' (added
      // 2024-01-02) sorts ahead of 'Banana' (2024-01-01), so it's index 0 in
      // the visible list handed to onPlayTrack.
      expect(playedIndex, 0);
      expect(playedTracks.length, 2);
      expect(playedTracks[playedIndex].contentId, 'b');
      expect(lib.selectedTrackId, 'b');
      // The real player must never be touched by this spy-based flow.
      expect(player.current, isNull);
    },
  );

  testWidgets('right click shows a context menu with "View in folder"', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await pumpTrackList(tester, lib, player);

    expect(find.text('View in folder'), findsNothing);

    await tester.tap(find.text('Banana'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('View in folder'), findsOneWidget);
  });

  testWidgets(
    'tapping "View in folder" invokes the launcher with the right track and closes the menu',
    (tester) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      final launched = <Track>[];
      await pumpTrackList(
        tester,
        lib,
        player,
        launchExplorer: (t) => launched.add(t),
      );

      await tester.tap(find.text('Banana'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('View in folder'));
      await tester.pumpAndSettle();

      expect(launched, hasLength(1));
      expect(launched.single.contentId, 'a');
      expect(find.text('View in folder'), findsNothing); // menu closed
    },
  );

  testWidgets('right-click also opens the menu on the row currently playing', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await pumpTrackList(tester, lib, player);

    // Simulate a queue without touching media_kit natives (same technique
    // as ui_shell_test.dart / track_list_header_test.dart): setVolume
    // triggers notifyListeners without ever constructing the real Player.
    player.queueController.setQueue(lib.allTracks, 0); // 'Banana' playing
    await player.setVolume(1.0);
    await tester.pump();

    await tester.tap(find.text('Banana'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('View in folder'), findsOneWidget);
  });

  testWidgets(
    'playing and selected highlights are independent: playing keeps the accent title, selected gets the fill',
    (tester) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      await pumpTrackList(tester, lib, player, onPlayTrack: (_, _) {});

      player.queueController.setQueue(lib.allTracks, 0); // 'Banana' playing
      await player.setVolume(1.0);
      lib.selectTrack('b'); // 'Apple' selected -- different row than playing
      await tester.pump();

      final bananaTitle = tester.widget<Text>(find.text('Banana'));
      expect(bananaTitle.style?.color, AppColors.accent); // playing

      // The selection fill lives on the row's AnimatedContainer (not the
      // Material, which stays transparent so the snappy fill fade below it
      // is the only selection animation).
      expect(_rowFillColor(tester, 'Apple'), AppColors.selectionFill);
      expect(_rowFillColor(tester, 'Banana'), isNot(AppColors.selectionFill));
    },
  );

  testWidgets(
    'selection highlight is snappy: ~80ms fill fade, no slow ink splash/highlight',
    (tester) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      await pumpTrackList(tester, lib, player, onPlayTrack: (_, _) {});

      final container = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('Banana'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      // Perceived selection response must stay ~80ms -- anything much longer
      // reads as sluggish on single click.
      expect(container.duration.inMilliseconds, lessThanOrEqualTo(100));
      expect(
        container.duration.inMilliseconds,
        greaterThan(0),
      ); // still animated

      final inkWell = tester.widget<InkWell>(
        find
            .ancestor(of: find.text('Banana'), matching: find.byType(InkWell))
            .first,
      );
      // The stock splash + pressed highlight take hundreds of ms; both must
      // stay suppressed so the fill fade alone carries the feedback.
      expect(inkWell.splashFactory, NoSplash.splashFactory);
      expect(inkWell.highlightColor, Colors.transparent);
    },
  );
}

/// The effective selection-fill color of the row containing [title]: the
/// row's AnimatedContainer decoration color.
Color? _rowFillColor(WidgetTester tester, String title) {
  final container = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.text(title),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}
