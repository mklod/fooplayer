// AppVersionFooter: the settings surfaces' "which build am I running?"
// line -- reported live that there was no way to tell on the phone. Reads
// the real package at runtime; these tests drive the override seam because
// PackageInfo's platform channel is unavailable under `flutter test`.
//
// Last modified: 2026-09-10--1830
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

Future<void> pumpFooter(WidgetTester tester, Future<String> version) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: AppVersionFooter(versionOverride: version)),
      ),
    );

void main() {
  testWidgets('renders "fooplayer <version>+<build>" once resolved', (
    tester,
  ) async {
    await pumpFooter(tester, Future.value('1.0.0+23'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-version-footer')), findsOneWidget);
    expect(find.text('fooplayer 1.0.0+23'), findsOneWidget);
  });

  testWidgets('shows nothing until the lookup lands', (tester) async {
    final gate = Completer<String>();
    await pumpFooter(tester, gate.future);
    await tester.pump();

    expect(find.byKey(const Key('app-version-footer')), findsNothing);

    gate.complete('1.0.0+23');
    await tester.pumpAndSettle();
    expect(find.text('fooplayer 1.0.0+23'), findsOneWidget);
  });

  testWidgets('a failed lookup degrades to nothing, not an error', (
    tester,
  ) async {
    // Completed AFTER the pump so the widget's handler is already
    // attached -- an eagerly-errored future would be reported as
    // unhandled by the test zone before initState ever ran, which is a
    // harness artifact rather than the behaviour under test.
    final gate = Completer<String>();
    await pumpFooter(tester, gate.future);
    gate.completeError(StateError('no channel'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-version-footer')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
