// Widget tests for SyncView + SyncReportDialog (Plan 3 Task 11): the sync
// settings fields round-trip through the injected `onSave` seam, the
// connection check renders both outcomes, discovered roots render as
// checkboxes that persist their toggle, "Sync now" disables itself while a
// run is in flight, and the finishing report dialog shows per-root counts
// and failures and stays up until explicitly dismissed. Every seam here is
// a fake -- no real SmbTransport, no platform channel, anywhere in this
// file.
//
// Last modified: 2026-07-31--2123
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/sync/sync_engine.dart';
import 'package:fooplayer_app/sync/sync_settings.dart';
import 'package:fooplayer_app/ui/sync_view.dart';

SyncSettings _fixtureSettings({Map<String, bool>? roots}) => SyncSettings(
  host: 'oldhost',
  share: 'oldshare',
  basePath: 'oldbase',
  roots: roots ?? {},
);

Future<void> _pumpSyncView(
  WidgetTester tester, {
  required SyncSettings settings,
  required void Function(SyncSettings) onSave,
  Future<SyncReport> Function()? runSync,
  Future<bool> Function()? probe,
  Future<List<String>> Function()? discoverRoots,
  Future<void> Function()? cancelSync,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncView(
            settings: settings,
            onSave: onSave,
            runSync: runSync ?? () async => _emptyReport(),
            probe: probe ?? () async => true,
            discoverRoots: discoverRoots ?? () async => const [],
            cancelSync: cancelSync ?? () async {},
          ),
        ),
      ),
    ),
  );
}

SyncReport _emptyReport() => SyncReport(
  playlistNotes: const [],
  roots: const [],
  finishedAt: DateTime(2026, 7, 31),
);

void main() {
  testWidgets('host/share/base fields round-trip through onSave on commit', (
    tester,
  ) async {
    final saved = <SyncSettings>[];
    await _pumpSyncView(
      tester,
      settings: _fixtureSettings(),
      onSave: saved.add,
    );

    await tester.enterText(find.byKey(const Key('sync-host')), 'newhost');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.enterText(find.byKey(const Key('sync-share')), 'newshare');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.enterText(find.byKey(const Key('sync-base')), 'newbase');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(saved, isNotEmpty);
    final last = saved.last;
    expect(last.host, 'newhost');
    expect(last.share, 'newshare');
    expect(last.basePath, 'newbase');
  });

  testWidgets('probe result line renders the reachable outcome', (
    tester,
  ) async {
    await _pumpSyncView(
      tester,
      settings: _fixtureSettings(),
      onSave: (_) {},
      probe: () async => true,
    );

    expect(find.byKey(const Key('sync-probe-result')), findsNothing);
    await tester.tap(find.byKey(const Key('sync-check-connection')));
    await tester.pumpAndSettle();

    final resultText = tester.widget<Text>(
      find.byKey(const Key('sync-probe-result')),
    );
    expect(resultText.data, contains('Connected'));
  });

  testWidgets('probe result line renders the unreachable outcome', (
    tester,
  ) async {
    await _pumpSyncView(
      tester,
      settings: _fixtureSettings(),
      onSave: (_) {},
      probe: () async => false,
    );

    await tester.tap(find.byKey(const Key('sync-check-connection')));
    await tester.pumpAndSettle();

    final resultText = tester.widget<Text>(
      find.byKey(const Key('sync-probe-result')),
    );
    expect(resultText.data, contains('Could not reach'));
  });

  testWidgets(
    'discovered roots render as checkboxes and a toggle persists via onSave',
    (tester) async {
      final saved = <SyncSettings>[];
      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: saved.add,
        discoverRoots: () async => ['monthly', 'archive'],
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-root-monthly')), findsOneWidget);
      expect(find.byKey(const Key('sync-root-archive')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sync-root-monthly')));
      await tester.pump();

      expect(saved, isNotEmpty);
      expect(saved.last.roots['monthly'], isTrue);
    },
  );

  testWidgets('Sync now is disabled while a slow runSync is in flight', (
    tester,
  ) async {
    final completer = Completer<SyncReport>();
    await _pumpSyncView(
      tester,
      settings: _fixtureSettings(),
      onSave: (_) {},
      runSync: () => completer.future,
    );

    FilledButton syncButton() =>
        tester.widget<FilledButton>(find.byKey(const Key('sync-now')));

    expect(syncButton().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump();

    expect(syncButton().onPressed, isNull);

    completer.complete(_emptyReport());
    await tester.pumpAndSettle();

    expect(syncButton().onPressed, isNotNull);
  });

  testWidgets(
    'Cancel button is absent while idle, appears while syncing, and tapping '
    'it invokes the cancelSync seam',
    (tester) async {
      final completer = Completer<SyncReport>();
      var cancelCalls = 0;
      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: (_) {},
        runSync: () => completer.future,
        cancelSync: () async {
          cancelCalls++;
        },
      );

      // Idle: no Cancel button at all.
      expect(find.byKey(const Key('sync-cancel')), findsNothing);

      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pump();

      // Syncing: Cancel button appears.
      expect(find.byKey(const Key('sync-cancel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sync-cancel')));
      await tester.pump();
      expect(cancelCalls, 1);

      // The run still completes normally through the engine (no special
      // cancelled-UI path) -- finishing it clears the Cancel button again
      // and opens the report dialog exactly as any other completed run
      // would.
      completer.complete(_emptyReport());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-cancel')), findsNothing);
      expect(find.byKey(const Key('sync-report-dialog')), findsOneWidget);
    },
  );

  testWidgets(
    'a throwing runSync re-enables the button and shows a visible inline '
    'error, with no report dialog',
    (tester) async {
      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: (_) {},
        runSync: () async => throw Exception('NAS session dropped'),
      );

      expect(find.byKey(const Key('sync-error-line')), findsNothing);

      FilledButton syncButton() =>
          tester.widget<FilledButton>(find.byKey(const Key('sync-now')));

      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();

      // Re-enabled, not left permanently disabled by the failure.
      expect(syncButton().onPressed, isNotNull);
      // The error is visible, not an invisible unhandled-Future error --
      // this app has no runZonedGuarded/FlutterError.onError above this
      // widget, so without this catch a thrown runSync would otherwise look
      // exactly like "nothing happened".
      final errorText = tester.widget<Text>(
        find.byKey(const Key('sync-error-line')),
      );
      expect(errorText.data, contains('NAS session dropped'));
      // Never a report dialog for a run that never produced a report.
      expect(find.byKey(const Key('sync-report-dialog')), findsNothing);
    },
  );

  testWidgets(
    'a successful runSync after a failed one clears the error line and '
    'opens the report dialog',
    (tester) async {
      var shouldFail = true;
      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: (_) {},
        runSync: () async {
          if (shouldFail) throw Exception('NAS session dropped');
          return _emptyReport();
        },
      );

      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-error-line')), findsOneWidget);

      shouldFail = false;
      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-error-line')), findsNothing);
      expect(find.byKey(const Key('sync-report-dialog')), findsOneWidget);
    },
  );

  testWidgets(
    'report dialog shows per-root lines and failures, and requires an '
    'explicit dismissal',
    (tester) async {
      final report = SyncReport(
        playlistNotes: ['copied "road trip" NAS -> phone (newer)'],
        roots: [
          RootSyncResult(
            rootName: 'archive',
            copied: 1,
            copiedBytes: 1024,
            updated: 0,
            renamed: 0,
            deleted: 0,
            adopted: 5,
            unindexedLocal: const [],
            failures: const [],
            aborted: false,
          ),
          RootSyncResult(
            rootName: 'monthly',
            copied: 12,
            copiedBytes: 48 * 1024 * 1024,
            updated: 3,
            renamed: 1,
            deleted: 2,
            adopted: 465,
            unindexedLocal: const [],
            failures: [
              SyncFailure(relPath: 'bad.mp3', reason: 'content ID mismatch'),
            ],
            aborted: false,
          ),
        ],
        finishedAt: DateTime(2026, 7, 31),
      );

      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: (_) {},
        runSync: () async => report,
      );

      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-report-dialog')), findsOneWidget);
      // Biggest-first: "monthly" did far more work than "archive", so its
      // line must render before archive's -- checked by finding the higher
      // Y offset (rendered first) rather than by the more brittle
      // full-string-with-em-dash match.
      final monthlyLine = find.textContaining('monthly —');
      final archiveLine = find.textContaining('archive —');
      expect(monthlyLine, findsOneWidget);
      expect(archiveLine, findsOneWidget);
      expect(
        tester.getTopLeft(monthlyLine).dy,
        lessThan(tester.getTopLeft(archiveLine).dy),
      );

      // Wording contract from Task 9's review: "files", never "tracks", for
      // the copied count; adopted reads "already present"; a copied byte
      // figure only for the copied clause, not the updated one.
      final monthlyText = tester.widget<Text>(monthlyLine).data!;
      expect(monthlyText, contains('12 files copied'));
      expect(monthlyText, contains('48.0 MB new data'));
      expect(monthlyText, contains('3 files updated'));
      expect(monthlyText, contains('1 files renamed'));
      expect(monthlyText, contains('2 files deleted'));
      expect(monthlyText, isNot(contains('tracks')));
      expect(monthlyText, contains('465 files adopted (already present)'));

      expect(
        find.text('copied "road trip" NAS -> phone (newer)'),
        findsOneWidget,
      );
      expect(find.textContaining('bad.mp3'), findsOneWidget);
      expect(find.textContaining('content ID mismatch'), findsOneWidget);

      // Stays up until dismissed -- still there after settling, only gone
      // once the Close button is actually tapped.
      expect(find.byKey(const Key('sync-report-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-report-dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-report-dialog')), findsNothing);
    },
  );

  testWidgets(
    'a run that never reached the NAS renders the abort reason, not a '
    'per-root tally',
    (tester) async {
      final report = SyncReport(
        playlistNotes: const [],
        roots: [
          RootSyncResult(
            rootName: '',
            copied: 0,
            copiedBytes: 0,
            updated: 0,
            renamed: 0,
            deleted: 0,
            adopted: 0,
            unindexedLocal: const [],
            failures: const [],
            aborted: true,
            abortReason: 'NAS unreachable',
          ),
        ],
        finishedAt: DateTime(2026, 7, 31),
      );

      await _pumpSyncView(
        tester,
        settings: _fixtureSettings(),
        onSave: (_) {},
        runSync: () async => report,
      );

      await tester.tap(find.byKey(const Key('sync-now')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Sync did not run: NAS unreachable'),
        findsOneWidget,
      );
    },
  );
}
