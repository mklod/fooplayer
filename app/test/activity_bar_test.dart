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
import 'package:fooplayer_app/ui/activity_bar.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

Future<void> _pump(WidgetTester tester, ActivityModel activity) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ActivityBar(activity: activity)),
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
      expect(a.active.single.hasProgress, isFalse,
          reason: 'unknown totals get an indeterminate bar, not a fake number');

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
    testWidgets('shows nothing at all when idle', (tester) async {
      await _pump(tester, ActivityModel());
      expect(find.byKey(const Key('activity-bar')), findsNothing);
    });

    testWidgets('appears with the label, and a determinate bar once counted',
        (tester) async {
      final activity = ActivityModel()..start('lib', 'Reading tags');
      await _pump(tester, activity);

      expect(find.byKey(const Key('activity-bar')), findsOneWidget);
      expect(find.text('Reading tags'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing,
          reason: 'no progress known yet');

      activity.progress('lib', 'Reading tags', 1204, 5470);
      await tester.pump();

      expect(find.text('Reading tags — 1,204 / 5,470'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(1204 / 5470, 0.0001));
    });

    testWidgets('one row per job, and vanishes when the last one finishes',
        (tester) async {
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
      expect(find.byKey(const Key('activity-bar')), findsNothing);
    });
  });
}
