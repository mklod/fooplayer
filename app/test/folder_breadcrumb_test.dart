// The Folder pane's step-wise breadcrumb navigation (TODO #28): the pinned
// header's breadcrumb is no longer one inert string -- each ancestor
// segment is an individually clickable link that pops the drill-down back
// to that level (LibraryModel.popFolderTo), a leading 'All' segment equals
// the full reset, and the last segment (the level currently shown) stays
// plain and non-clickable. The pinned X keeps its full-reset behavior.
//
// Covers both layers: FilterPanel's headerSegments/onHeaderSegmentTap
// rendering contract in isolation, and the HomeScreen wiring end-to-end
// (click a mid-breadcrumb segment -> pane entries return to that level
// while the shallower folderPath selection persists).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/filter_panel.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

const monthlyRoot = r'L:\Music\monthly';
const albumsRoot = r'L:\Music\albums';

Track tr(String id, String relPath, String title,
        {String rootPath = monthlyRoot}) =>
    Track(
      contentId: id,
      relPath: relPath,
      rootPath: rootPath,
      dateAdded: DateTime.utc(2024, 1, 1),
      title: title,
      artist: 'Artist $id',
      album: 'Album $id',
    );

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    tr('a1', '2007-08/t1.mp3', 'Aug Song'),
    tr('b1', '2007-09/sub/t2.mp3', 'Sub Song'),
    tr('x1', 'loose.mp3', 'Other Song', rootPath: albumsRoot),
  ];
  m.status = 'ready';
  return m;
}

void main() {
  group('FilterPanel.headerSegments (widget contract)', () {
    Future<void> pumpPanel(WidgetTester tester,
        {required List<String> segments,
        required ValueChanged<int> onTap}) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: FilterPanel(
            title: 'Folder',
            values: const ['child-a', 'child-b'],
            selected: const {},
            onSelect: (_) {},
            headerSegments: segments,
            onHeaderSegmentTap: onTap,
          ),
        ),
      ));
    }

    testWidgets('renders every segment; ancestors are links reporting their '
        'index, the last segment is plain and non-clickable', (tester) async {
      final taps = <int>[];
      await pumpPanel(tester,
          segments: const ['All', 'monthly', '2007-08'], onTap: taps.add);

      expect(find.text('All'), findsOneWidget); // distinct from 'All (2)' row
      expect(find.text('monthly'), findsOneWidget);
      expect(find.text('2007-08'), findsOneWidget);

      await tester.tap(find.byKey(const Key('breadcrumb-seg-0')));
      await tester.tap(find.byKey(const Key('breadcrumb-seg-1')));
      expect(taps, [0, 1]);

      // Last segment: plain text, no InkWell wrapping it -- a tap on it
      // must not report anything.
      expect(
        find.ancestor(
            of: find.byKey(const Key('breadcrumb-seg-2')),
            matching: find.byType(InkWell)),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('breadcrumb-seg-2')),
          warnIfMissed: false);
      expect(taps, [0, 1]);
    });

    testWidgets('pinned header (with its clear X) shows for segments even '
        'while selected is empty', (tester) async {
      await pumpPanel(tester, segments: const ['All', 'monthly'], onTap: (_) {});
      expect(find.byKey(const Key('filter-clear')), findsOneWidget);
    });
  });

  group('HomeScreen wiring (end-to-end)', () {
    Future<LibraryModel> pumpHome(WidgetTester tester) async {
      final lib = fixtureLibrary();
      await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: HomeScreen(
              library: lib,
              player: PlayerService(),
              layoutPrefs: LayoutPrefs(),
              libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
      return lib;
    }

    Future<void> drillTo(WidgetTester tester, List<String> entries) async {
      for (final e in entries) {
        await tester.tap(find.text(e));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('clicking a mid-breadcrumb segment pops back to that level: '
        'its subfolders are listed again and the shallower selection '
        'persists', (tester) async {
      final lib = await pumpHome(tester);
      await drillTo(tester, ['monthly', '2007-09', 'sub']);
      expect(lib.folderPath, [monthlyRoot, '2007-09', 'sub']);

      // Breadcrumb: All / monthly / 2007-09 / sub -- click 'monthly'.
      await tester.tap(find.byKey(const Key('breadcrumb-seg-1')));
      await tester.pumpAndSettle();

      expect(lib.folderPath, [monthlyRoot]); // shallower selection kept
      // The pane lists monthly's subfolders again...
      expect(find.text('2007-08'), findsOneWidget);
      expect(find.text('2007-09'), findsOneWidget);
      // ...the folder filter still applies (other root's track hidden)...
      expect(find.text('Aug Song'), findsOneWidget);
      expect(find.text('Sub Song'), findsOneWidget);
      expect(find.text('Other Song'), findsNothing);
      // ...and 'monthly' is now the (plain) last breadcrumb segment.
      expect(find.byKey(const Key('breadcrumb-seg-1')), findsOneWidget);
      expect(find.byKey(const Key('breadcrumb-seg-2')), findsNothing);
    });

    testWidgets("the leading 'All' segment fully resets, same as the X",
        (tester) async {
      final lib = await pumpHome(tester);
      await drillTo(tester, ['monthly', '2007-09']);

      await tester.tap(find.byKey(const Key('breadcrumb-seg-0'))); // 'All'
      await tester.pumpAndSettle();

      expect(lib.folderPath, isEmpty);
      expect(lib.folderSiblings, isEmpty);
      // Root list is back, all tracks visible again.
      expect(find.text('monthly'), findsOneWidget);
      expect(find.text('albums'), findsOneWidget);
      expect(find.text('Other Song'), findsOneWidget);
    });

    testWidgets('the pinned X still fully resets from any depth',
        (tester) async {
      final lib = await pumpHome(tester);
      await drillTo(tester, ['monthly', '2007-09', 'sub']);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(lib.folderPath, isEmpty);
      expect(lib.folderSiblings, isEmpty);
      expect(find.text('Other Song'), findsOneWidget);
    });
  });
}
