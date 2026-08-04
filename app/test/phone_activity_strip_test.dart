// PhoneActivityStrip: hidden entirely when idle (no permanent footer here,
// unlike the desktop ActivityBar -- see the widget's class doc for why),
// visible with a label once a job starts, and a determinate progress bar
// once its extent is known.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/phone_activity_strip.dart';

Future<void> _pump(WidgetTester tester, ActivityModel activity) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: PhoneActivityStrip(activity: activity)),
      ),
    );

void main() {
  testWidgets('nothing running -> nothing shown', (tester) async {
    await _pump(tester, ActivityModel());
    expect(find.byKey(const Key('phone-activity-strip')), findsNothing);
  });

  testWidgets('a job appearing shows its label, indeterminate until counted', (
    tester,
  ) async {
    final activity = ActivityModel()..start('sync', 'Syncing with NAS');
    await _pump(tester, activity);

    expect(find.byKey(const Key('phone-activity-strip')), findsOneWidget);
    expect(find.byKey(const Key('phone-activity-sync')), findsOneWidget);
    expect(find.text('Syncing with NAS'), findsOneWidget);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'no extent known yet',
    );
  });

  testWidgets('progress known -> a determinate bar under the row', (
    tester,
  ) async {
    final activity = ActivityModel()..start('sync', 'Syncing with NAS');
    await _pump(tester, activity);

    activity.progress('sync', 'Syncing with NAS', 3, 10);
    await tester.pump();

    expect(find.text('Syncing with NAS — 3 / 10'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.3, 0.0001));
  });

  testWidgets('one row per job, and the strip vanishes when the last one '
      'finishes', (tester) async {
    final activity = ActivityModel()
      ..start('sync', 'Syncing with NAS')
      ..start('lib', 'Reading tags');
    await _pump(tester, activity);

    expect(find.byKey(const Key('phone-activity-sync')), findsOneWidget);
    expect(find.byKey(const Key('phone-activity-lib')), findsOneWidget);

    activity.finish('sync');
    await tester.pump();
    expect(find.byKey(const Key('phone-activity-sync')), findsNothing);
    expect(find.byKey(const Key('phone-activity-lib')), findsOneWidget);

    activity.finish('lib');
    await tester.pump();
    expect(find.byKey(const Key('phone-activity-strip')), findsNothing);
  });
}
