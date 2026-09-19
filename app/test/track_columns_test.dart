// The library list's Path column, hiding columns from the header's
// context menu, and dragging column widths (asked for 2026-09-18).
//
// Two rejected cuts are pinned here as behaviour:
//   - the menu must DISMISS on a click away. The MenuAnchor version did
//     not, which left hiding the clicked column as the only way out.
//   - it must not animate in.
// The menu is the full list of columns with a tick against the ones
// showing; clicking a ticked row hides that column.
//
// Last modified: 2026-09-18--1715
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';
import 'package:fooplayer_app/ui/track_columns.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'Muse/Absolution/01 Apocalypse Please.mp3',
      rootPath: r'L:\Music\albums',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Apocalypse Please',
      artist: 'Muse',
      album: 'Absolution',
    ),
  ];
  m.status = 'ready';
  return m;
}

Future<LayoutPrefs> pump(
  WidgetTester tester,
  LibraryModel lib, {
  LayoutPrefs? prefs,
}) async {
  final layout = prefs ?? LayoutPrefs();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
        library: lib,
        player: PlayerService(),
        layoutPrefs: layout,
        libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
        playlistStore: PlaylistStore(library: lib, device: 'test'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return layout;
}

/// Header labels render upper-cased (see _HeaderCell).
Finder headerLabel(String text) => find.descendant(
  of: find.byKey(const Key('track-list-header')),
  matching: find.text(text),
);

/// The ACTIVE sort column's label carries its arrow in the same span
/// ("DATE ▼"), so an exact match misses it.
Finder headerLabelLoose(String text) => find.descendant(
  of: find.byKey(const Key('track-list-header')),
  matching: find.textContaining(text),
);

/// Scoped to the list: the Album/Artist FILTER panes show the same values,
/// so an unscoped text matcher finds those too.
Finder inList(String text) =>
    find.descendant(of: find.byType(TrackListView), matching: find.text(text));

Future<void> rightClick(WidgetTester tester, Finder target) async {
  await tester.tapAt(tester.getCenter(target), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the Path column shows the track\'s file path', (tester) async {
    await pump(tester, fixtureLibrary());

    expect(headerLabel('PATH'), findsOneWidget);
    expect(
      inList(r'L:\Music\albums\Muse\Absolution\01 Apocalypse Please.mp3'),
      findsOneWidget,
    );
  });

  testWidgets('Path is the LAST column', (tester) async {
    await pump(tester, fixtureLibrary());

    final path = tester.getTopLeft(headerLabel('PATH')).dx;
    for (final other in ['TITLE', 'ARTIST', 'ALBUM', 'TIME', 'EMB']) {
      expect(
        tester.getTopLeft(headerLabel(other)).dx,
        lessThan(path),
        reason: '$other must sit left of PATH',
      );
    }
    // DATE is the active sort column, so its label carries the arrow.
    expect(tester.getTopLeft(headerLabelLoose('DATE')).dx, lessThan(path));
  });

  testWidgets('the header menu lists every hideable column, ticked', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('ALBUM'));

    for (final c in TrackColumn.hideableColumns) {
      expect(
        find.byKey(Key('column-toggle-${c.id}')),
        findsOneWidget,
        reason: '${c.label} must be listed',
      );
      expect(
        find.descendant(
          of: find.byKey(Key('column-toggle-${c.id}')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
        reason: '${c.label} is showing, so it is ticked',
      );
    }
    // Title is not hideable: a row with no title is not a row.
    expect(find.byKey(const Key('column-toggle-title')), findsNothing);
  });

  testWidgets('clicking away dismisses the menu and changes nothing', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final prefs = await pump(tester, lib);
    await rightClick(tester, headerLabel('ALBUM'));
    expect(find.byKey(const Key('column-toggle-album')), findsOneWidget);

    // Anywhere off the menu -- here, the top-left corner of the window.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('column-toggle-album')), findsNothing);
    expect(
      prefs.hiddenColumns,
      isEmpty,
      reason: 'dismissing must not hide the column you right-clicked',
    );
    expect(headerLabel('ALBUM'), findsOneWidget);
  });

  testWidgets('clicking a ticked row hides that column, and closes', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    expect(inList('Absolution'), findsOneWidget);

    await rightClick(tester, headerLabel('ALBUM'));
    await tester.tap(find.byKey(const Key('column-toggle-album')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('column-toggle-album')), findsNothing);
    expect(headerLabel('ALBUM'), findsNothing);
    expect(inList('Absolution'), findsNothing);
    expect(inList('Apocalypse Please'), findsOneWidget, reason: 'rest intact');
  });

  testWidgets('an unticked row brings the column back', (tester) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('ALBUM'));
    await tester.tap(find.byKey(const Key('column-toggle-album')));
    await tester.pumpAndSettle();
    expect(headerLabel('ALBUM'), findsNothing);

    await rightClick(tester, headerLabel('ARTIST'));
    expect(
      find.descendant(
        of: find.byKey(const Key('column-toggle-album')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
      reason: 'hidden columns are listed unticked',
    );
    await tester.tap(find.byKey(const Key('column-toggle-album')));
    await tester.pumpAndSettle();

    expect(headerLabel('ALBUM'), findsOneWidget);
  });

  testWidgets('dragging a divider widens the column to its left', (
    tester,
  ) async {
    final prefs = await pump(tester, fixtureLibrary());
    final before = tester.getSize(headerLabel('TITLE')).width;

    await tester.drag(
      find.byKey(const Key('column-resize-title')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(headerLabel('TITLE')).width, greaterThan(before));
    expect(prefs.columnSizes[TrackColumn.title], isNotNull);
  });

  testWidgets('a fixed-width column takes the pixels it was dragged', (
    tester,
  ) async {
    final prefs = await pump(tester, fixtureLibrary());
    final before = prefs.columnSize(TrackColumn.date);

    await tester.drag(
      find.byKey(const Key('column-resize-date')),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();

    expect(prefs.columnSize(TrackColumn.date), closeTo(before + 40, 0.01));
  });

  testWidgets('a dragged width survives a restart', (tester) async {
    final prefs = LayoutPrefs(writer: (_) {}, debounce: Duration.zero);
    await pump(tester, fixtureLibrary(), prefs: prefs);

    await tester.drag(
      find.byKey(const Key('column-resize-date')),
      const Offset(25, 0),
    );
    await tester.pumpAndSettle();

    final reopened = LayoutPrefs.fromConfig(prefs.toJson());
    expect(
      reopened.columnSize(TrackColumn.date),
      closeTo(prefs.columnSize(TrackColumn.date), 0.01),
    );
  });

  testWidgets('a column cannot be dragged away to nothing', (tester) async {
    final prefs = await pump(tester, fixtureLibrary());

    await tester.drag(
      find.byKey(const Key('column-resize-date')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(prefs.columnSize(TrackColumn.date), kMinColumnWidth);
  });

  testWidgets('the choice is remembered across a restart', (tester) async {
    final prefs = LayoutPrefs(writer: (_) {}, debounce: Duration.zero);
    await pump(tester, fixtureLibrary(), prefs: prefs);

    await rightClick(tester, headerLabel('PATH'));
    await tester.tap(find.byKey(const Key('column-toggle-path')));
    await tester.pumpAndSettle();

    expect(prefs.hiddenColumns, contains(TrackColumn.path));
    final reopened = LayoutPrefs.fromConfig(prefs.toJson());
    expect(reopened.hiddenColumns, contains(TrackColumn.path));
    expect(reopened.hiddenColumns, isNot(contains(TrackColumn.album)));
  });

  testWidgets('every column is visible in a fresh config', (tester) async {
    expect(LayoutPrefs.fromConfig(null).hiddenColumns, isEmpty);
  });

  testWidgets('clicking the Path header sorts by path', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    await tester.tap(headerLabel('PATH'));
    await tester.pumpAndSettle();

    expect(lib.sortColumn, SortColumn.path);
  });
}
