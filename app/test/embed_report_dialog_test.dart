// The end-of-pass report.
//
// It was a six-second SnackBar closing a job that runs for a quarter of an
// hour, so unless you happened to be looking at the window at that moment,
// the entire outcome was gone. What follows is the account of the pass, so
// the tests are about it surviving long enough to be read and being specific
// about why files were left alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_embed_pass.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/embed_report_dialog.dart';

Future<void> _pump(WidgetTester tester, EmbedPassReport report) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: EmbedReportDialog(report: report)),
      ),
    );

void main() {
  testWidgets('states the tallies and stays until dismissed', (tester) async {
    await _pump(
      tester,
      const EmbedPassReport(embedded: 1091, skipped: 2289, failed: 0),
    );

    expect(find.byKey(const Key('embed-report')), findsOneWidget);
    expect(find.text('1091'), findsOneWidget);
    expect(find.text('2289'), findsOneWidget);
    expect(find.text('3380 files considered.'), findsOneWidget);

    // The old SnackBar disappeared on a timer; this must not.
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const Key('embed-report')), findsOneWidget);
    expect(find.byKey(const Key('embed-report-close')), findsOneWidget);
  });

  testWidgets('names the reasons, biggest first', (tester) async {
    await _pump(
      tester,
      const EmbedPassReport(
        embedded: 12,
        skipped: 2100,
        reasons: {
          'format cannot carry embedded art': 13,
          'no artwork chosen for this album': 2087,
        },
      ),
    );

    expect(find.text('no artwork chosen for this album'), findsOneWidget);
    expect(find.text('2087'), findsOneWidget);

    // The reason accounting for most of the skips has to lead -- it is the
    // answer to "why didn't it do more than that?".
    final big = tester.getTopLeft(find.text('no artwork chosen for this album'));
    final small = tester.getTopLeft(
      find.text('format cannot carry embedded art'),
    );
    expect(big.dy, lessThan(small.dy));
  });

  testWidgets('a disturbed date is called out and the files named', (
    tester,
  ) async {
    await _pump(
      tester,
      const EmbedPassReport(
        embedded: 5,
        datesDisturbed: 2,
        disturbedPaths: [r'L:\music\a.mp3', r'L:\music\b.mp3'],
      ),
    );

    expect(find.byKey(const Key('embed-report-dates')), findsOneWidget);
    expect(find.textContaining('2 files came back'), findsOneWidget);
    expect(find.text(r'L:\music\a.mp3'), findsOneWidget);
    expect(find.text(r'L:\music\b.mp3'), findsOneWidget);
  });

  testWidgets('a clean pass shows no date warning at all', (tester) async {
    await _pump(tester, const EmbedPassReport(embedded: 5, skipped: 1));
    expect(find.byKey(const Key('embed-report-dates')), findsNothing);
  });
}
