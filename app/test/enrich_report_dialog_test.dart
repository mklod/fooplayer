// The end-of-enrichment report.
//
// "Can you tell me did the enrichment complete, there's no confirmation on
// it" -- a fair question, because the answer was a SnackBar on a pass that
// runs for many minutes throttled to about a request a second. Two of them,
// in fact: one when the local harvest finished and another much later, so the
// middle of the job looked like the end of it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/local_art_harvest.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/enrich_report_dialog.dart';

Future<void> _pump(
  WidgetTester tester, {
  HarvestReport? harvest,
  int found = 0,
  int albumsChecked = 0,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: EnrichReportDialog(
        harvest: harvest,
        found: found,
        albumsChecked: albumsChecked,
      ),
    ),
  ),
);

void main() {
  testWidgets('states both passes and stays until dismissed', (tester) async {
    await _pump(
      tester,
      harvest: const HarvestReport(adopted: 718, albumsConsidered: 811),
      found: 40,
      albumsChecked: 1526,
    );

    expect(find.byKey(const Key('enrich-report')), findsOneWidget);
    expect(find.text('718'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('1526 albums checked.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const Key('enrich-report')), findsOneWidget);
    expect(find.byKey(const Key('enrich-report-close')), findsOneWidget);
  });

  testWidgets('finding nothing reads as an answer, not a failure', (
    tester,
  ) async {
    await _pump(tester, found: 0, albumsChecked: 119);
    expect(find.textContaining('Nothing found online is a real answer'),
        findsOneWidget);
  });

  testWidgets('a pass that found something does not editorialise', (
    tester,
  ) async {
    await _pump(tester, found: 3, albumsChecked: 119);
    expect(find.textContaining('Nothing found online'), findsNothing);
  });

  testWidgets('local reasons are listed, biggest first', (tester) async {
    await _pump(
      tester,
      harvest: const HarvestReport(
        adopted: 12,
        albumsConsidered: 130,
        skippedNoImage: 93,
        skippedTooSmall: 4,
      ),
      albumsChecked: 130,
    );

    final big = tester.getTopLeft(
      find.text('no image file in the album folder'),
    );
    final small = tester.getTopLeft(
      find.text('only a thumbnail, too small to use'),
    );
    expect(big.dy, lessThan(small.dy));
  });

  testWidgets('with no sidecar wired, only the online half is shown', (
    tester,
  ) async {
    await _pump(tester, harvest: null, found: 2, albumsChecked: 9);
    expect(find.text('Covers adopted from your folders'), findsNothing);
    expect(find.text('Covers found online'), findsOneWidget);
  });
}
