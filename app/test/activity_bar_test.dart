// The persistent background-activity bar.
//
// It exists because long work used to announce itself with a three-second
// toast and then go silent -- "still working" and "finished twenty minutes
// ago" looked identical, and a greyed-out button was the only clue. So the
// tests that matter are: it stays for the whole job, it says what the job is,
// and it disappears when nothing is running.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/ui/activity_bar.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

Future<void> _pump(
  WidgetTester tester,
  ActivityModel activity, {
  LibraryModel? library,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: ActivityBar(activity: activity, library: library ?? LibraryModel()),
    ),
  ),
);

void main() {
  group('ActivityModel', () {
    test('start / progress / finish', () {
      final a = ActivityModel();
      expect(a.isBusy, isFalse);

      a.start('x', 'Reading tags');
      expect(a.isBusy, isTrue);
      expect(a.active.single.label, 'Reading tags');
      expect(
        a.active.single.hasProgress,
        isFalse,
        reason: 'unknown totals get an indeterminate bar, not a fake number',
      );

      a.progress('x', 'Reading tags', 250, 1000);
      expect(a.active.single.fraction, 0.25);
      expect(a.active.single.text, 'Reading tags — 250 / 1,000');

      a.finish('x');
      expect(a.isBusy, isFalse);
    });

    test('finishing twice is not an error', () {
      final a = ActivityModel()..start('x', 'Work');
      a.finish('x');
      expect(() => a.finish('x'), returnsNormally);
    });

    test('several jobs coexist, each keyed independently', () {
      final a = ActivityModel()
        ..start('lib', 'Reading tags')
        ..progress('art', 'Embedding artwork', 3, 9);
      expect(a.active, hasLength(2));
      a.finish('lib');
      expect(a.active.single.label, 'Embedding artwork');
    });

    test('a repeated identical update does not notify', () {
      final a = ActivityModel();
      var notifications = 0;
      a.addListener(() => notifications++);
      a.progress('x', 'Work', 5, 10);
      a.progress('x', 'Work', 5, 10);
      expect(notifications, 1, reason: 'no churn when nothing visibly changed');
    });

    test('thousands separators, because 5470 reads worse than 5,470', () {
      final a = ActivityModel()..progress('x', 'Reading tags', 1204, 5470);
      expect(a.active.single.text, 'Reading tags — 1,204 / 5,470');
    });
  });

  group('ActivityBar', () {
    testWidgets('is permanent, showing the track count even when idle', (
      tester,
    ) async {
      final library = LibraryModel()
        ..allTracks = [
          for (var i = 0; i < 1204; i++)
            Track(
              contentId: '\$i',
              relPath: '\$i.mp3',
              rootPath: r'L:\M',
              dateAdded: DateTime.utc(2026),
              title: 'T\$i',
              artist: 'A',
              album: 'B',
            ),
        ];
      await _pump(tester, ActivityModel(), library: library);

      // The footer stays put: a strip that came and went under the
      // now-playing bar would jump the layout on every background job.
      expect(find.byKey(const Key('activity-bar')), findsOneWidget);
      expect(find.text('1,204 tracks'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('appears with the label, and a determinate bar once counted', (
      tester,
    ) async {
      final activity = ActivityModel()..start('lib', 'Reading tags');
      await _pump(tester, activity);

      expect(find.byKey(const Key('activity-bar')), findsOneWidget);
      expect(find.text('Reading tags'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'no progress known yet',
      );

      activity.progress('lib', 'Reading tags', 1204, 5470);
      await tester.pump();

      expect(find.text('Reading tags — 1,204 / 5,470'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(1204 / 5470, 0.0001));
    });

    testWidgets('one row per job, and vanishes when the last one finishes', (
      tester,
    ) async {
      final activity = ActivityModel()
        ..start('lib', 'Reading tags')
        ..start('art', 'Embedding artwork into files');
      await _pump(tester, activity);

      expect(find.byKey(const Key('activity-lib')), findsOneWidget);
      expect(find.byKey(const Key('activity-art')), findsOneWidget);

      activity.finish('lib');
      await tester.pump();
      expect(find.byKey(const Key('activity-lib')), findsNothing);
      expect(find.byKey(const Key('activity-art')), findsOneWidget);

      activity.finish('art');
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'no jobs left -- but the footer itself stays',
      );
      expect(find.byKey(const Key('footer-track-count')), findsOneWidget);
    });
  });

  group('the footer carries the transport while the strip is collapsed', () {
    // Collapsing the now-playing strip used to be a one-way door: nothing
    // showed what was playing and nothing brought the controls back short of
    // restarting the app.
    PlayerService playing({
      String title = 'Like It Or Not',
      String artist = 'Bob Moses',
      Duration pos = const Duration(seconds: 64),
      Duration? total = const Duration(minutes: 6, seconds: 20),
    }) {
      final p = PlayerService();
      p.queueController.setQueue([
        Track(
          contentId: 'a',
          relPath: 'a.mp3',
          dateAdded: DateTime.utc(2024),
          title: title,
          artist: artist,
        ),
      ], 0);
      p.position = pos;
      p.duration = total;
      return p;
    }

    Future<void> pump(
      WidgetTester tester, {
      required bool hidden,
      PlayerService? player,
      ActivityModel? activity,
      VoidCallback? onExpand,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ActivityBar(
            activity: activity ?? ActivityModel(),
            library: LibraryModel(),
            player: player,
            nowPlayingHidden: hidden,
            onExpand: onExpand,
          ),
        ),
      ),
    );

    testWidgets('shows title, artist and a text clock -- no progress bar', (
      tester,
    ) async {
      await pump(tester, hidden: true, player: playing());

      expect(find.text('Like It Or Not — Bob Moses'), findsOneWidget);
      expect(find.text('1:04 / 6:20'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'a bar here is just a smaller copy of what was collapsed',
      );
    });

    testWidgets('says nothing while the strip is up', (tester) async {
      await pump(tester, hidden: false, player: playing());
      expect(find.byKey(const Key('footer-now-playing')), findsNothing);
      expect(find.byKey(const Key('footer-track-count')), findsOneWidget);
    });

    testWidgets('clicking the bar brings the player back', (tester) async {
      var expanded = 0;
      await pump(
        tester,
        hidden: true,
        player: playing(),
        onExpand: () => expanded++,
      );

      await tester.tap(find.byKey(const Key('footer-expand')));
      await tester.pumpAndSettle();

      expect(expanded, 1);
    });

    testWidgets('background work still takes the line while it runs', (
      tester,
    ) async {
      await pump(
        tester,
        hidden: true,
        player: playing(),
        activity: ActivityModel()..start('lib', 'Reading tags'),
      );

      expect(find.text('Reading tags'), findsOneWidget);
      expect(
        find.byKey(const Key('footer-now-playing')),
        findsNothing,
        reason: 'transient work is worth interrupting the track line for',
      );
    });

    testWidgets('an unknown duration shows the elapsed time alone', (
      tester,
    ) async {
      await pump(tester, hidden: true, player: playing(total: null));
      expect(find.text('1:04'), findsOneWidget);
    });

    testWidgets('nothing loaded means nothing to say', (tester) async {
      await pump(tester, hidden: true, player: PlayerService());
      expect(find.byKey(const Key('footer-now-playing')), findsNothing);
    });
  });
}
