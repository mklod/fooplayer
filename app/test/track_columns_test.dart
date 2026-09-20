// The library list's Path column, hiding columns from the header's
// context menu, and dragging column widths (asked for 2026-09-18).
//
// Three rejected cuts are pinned here as behaviour:
//   - the menu must DISMISS on a click away. The MenuAnchor version did
//     not, which left hiding the clicked column as the only way out.
//   - it must not animate in.
//   - a drag must move ONE column's edge. The flex-weight version had
//     the columns share the leftover space, so dragging Artist quietly
//     resized Title and Path as well.
//
// Last modified: 2026-09-18--1945
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

const _folder = r'L:\Music\albums\Muse\Absolution';
const _file = r'L:\Music\albums\Muse\Absolution\01 Apocalypse Please.mp3';

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
      durationMs: 230000,
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
  // A desktop-sized window: the columns are fixed widths now, and the
  // 800x600 test default would clip the right-hand ones out of reach.
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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

/// Scoped to the list: the Album/Artist FILTER panes show the same
/// values, so an unscoped text matcher finds those too.
Finder inList(String text) =>
    find.descendant(of: find.byType(TrackListView), matching: find.text(text));

Future<void> rightClick(WidgetTester tester, Finder target) async {
  await tester.tapAt(tester.getCenter(target), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the Path column shows the FOLDER, not the file', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());

    expect(headerLabel('PATH'), findsOneWidget);
    expect(inList(_folder), findsOneWidget);
    expect(
      inList(_file),
      findsNothing,
      reason: 'the row already names the track twice over',
    );
  });

  testWidgets('the Path cell reads left to right', (tester) async {
    await pump(tester, fixtureLibrary());
    expect(
      tester.widget<Text>(inList(_folder)).textDirection,
      isNot(TextDirection.rtl),
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
    final prefs = await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('ALBUM'));
    expect(find.byKey(const Key('column-toggle-album')), findsOneWidget);

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

  testWidgets('dragging a divider resizes ONLY that column', (tester) async {
    final prefs = await pump(tester, fixtureLibrary());
    final before = {
      for (final c in TrackColumn.values) c: prefs.columnSize(c),
    };

    await tester.drag(
      find.byKey(const Key('column-resize-artist')),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();

    expect(
      prefs.columnSize(TrackColumn.artist),
      closeTo(before[TrackColumn.artist]! - 60, 0.01),
    );
    for (final c in TrackColumn.values) {
      if (c == TrackColumn.artist) continue;
      expect(
        prefs.columnSize(c),
        before[c],
        reason: 'dragging Artist must not touch ${c.label}',
      );
    }
  });

  testWidgets('a drag actually moves the column on screen', (tester) async {
    final prefs = await pump(tester, fixtureLibrary());
    final beforeX = tester.getTopLeft(headerLabel('ALBUM')).dx;
    final beforeW = prefs.columnSize(TrackColumn.title);
    final albumW = tester.getSize(headerLabel('ALBUM')).width;

    await tester.drag(
      find.byKey(const Key('column-resize-title')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    // However the test framework splits the gesture, the screen must
    // agree with the stored width: Title grew by exactly that much, and
    // everything after it slid along by the same amount, unresized.
    final grew = prefs.columnSize(TrackColumn.title) - beforeW;
    expect(grew, greaterThan(0));
    expect(
      tester.getTopLeft(headerLabel('ALBUM')).dx,
      closeTo(beforeX + grew, 1),
      reason: 'a wider Title pushes what follows along',
    );
    expect(
      tester.getSize(headerLabel('ALBUM')).width,
      albumW,
      reason: '...without resizing it',
    );
  });

  testWidgets('the tick columns have no grab handle', (tester) async {
    await pump(tester, fixtureLibrary());
    expect(find.byKey(const Key('column-resize-art')), findsNothing);
    expect(find.byKey(const Key('column-resize-emb')), findsNothing);
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

  testWidgets('a hidden column is remembered across a restart', (
    tester,
  ) async {
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
    expect(LayoutPrefs.fromConfig(null).columnSizes, isEmpty);
  });

  testWidgets('clicking the Path header sorts by path', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    await tester.tap(headerLabel('PATH'));
    await tester.pumpAndSettle();

    expect(lib.sortColumn, SortColumn.path);
  });

  testWidgets('a config from the flex-weight build does not collapse the '
      'columns', (tester) async {
    // Reported live: after the +34 upgrade Title and Artist were
    // invisible. Their stored numbers were +33 flex WEIGHTS (1.64) in
    // the field that now means pixels, so they laid out 1.6px wide --
    // present, ticked in the menu, and impossible to see or grab.
    final prefs = LayoutPrefs.fromConfig({
      'columnSizes': {'title': 1.6438, 'artist': 1.6412, 'time': 177.0},
    });

    expect(prefs.columnSize(TrackColumn.title), TrackColumn.title.width);
    expect(prefs.columnSize(TrackColumn.artist), TrackColumn.artist.width);
    expect(
      prefs.columnSize(TrackColumn.time),
      177.0,
      reason: 'a real dragged width still survives',
    );
    expect(
      prefs.toJson()['columnSizes'],
      {'time': 177.0},
      reason: 'and the nonsense is not written back out',
    );

    await pump(tester, fixtureLibrary(), prefs: prefs);
    expect(headerLabel('TITLE'), findsOneWidget);
    expect(
      tester.getSize(headerLabel('TITLE')).width,
      greaterThan(kMinColumnWidth),
    );
    expect(
      tester.getSize(headerLabel('ARTIST')).width,
      greaterThan(kMinColumnWidth),
    );
  });

  testWidgets('Time, Date and Path start at the minimum width', (
    tester,
  ) async {
    // Asked for 2026-09-19: these three start as narrow as a column can
    // be, and are widened by hand (or by double-clicking to fit).
    final prefs = await pump(tester, fixtureLibrary());
    for (final c in [TrackColumn.time, TrackColumn.date, TrackColumn.path]) {
      expect(prefs.columnSize(c), kMinColumnWidth, reason: c.label);
    }
    expect(
      prefs.columnSize(TrackColumn.title),
      greaterThan(kMinColumnWidth),
      reason: 'the text columns keep a readable default',
    );
  });

  testWidgets('every column is right-aligned except Time', (tester) async {
    await pump(tester, fixtureLibrary());

    for (final c in TrackColumn.values) {
      expect(
        c.alignEnd,
        c != TrackColumn.time,
        reason: '${c.label} alignment',
      );
    }
    expect(
      tester.widget<Text>(inList('Apocalypse Please')).textAlign,
      TextAlign.right,
    );
    expect(tester.widget<Text>(inList('3:50')).textAlign, TextAlign.left);
  });

  testWidgets('hiding a column never stretches another', (tester) async {
    await pump(tester, fixtureLibrary());
    final embBefore = tester.getSize(headerLabel('EMB')).width;

    await rightClick(tester, headerLabel('PATH'));
    await tester.tap(find.byKey(const Key('column-toggle-path')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(headerLabel('EMB')).width,
      embBefore,
      reason: 'columns keep their widths; the space just goes unused',
    );
  });

  testWidgets('every column boundary carries a divider you can see', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());

    // One per visible column (the gap after each, the last included).
    final dividers = find.descendant(
      of: find.byKey(const Key('track-list-header')),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 1,
      ),
    );
    expect(dividers, findsNWidgets(TrackColumn.values.length));
  });

  testWidgets('the Album divider is grabbable and resizes Album', (
    tester,
  ) async {
    // Reported: "I am unable to grab the right hand side of the album
    // column". The gap was 8px between two clickable header labels --
    // aim slightly off and you sorted instead of resizing.
    final prefs = await pump(tester, fixtureLibrary());
    final before = prefs.columnSize(TrackColumn.album);

    final handle = find.byKey(const Key('column-resize-album'));
    expect(tester.getSize(handle).width, greaterThanOrEqualTo(12));

    await tester.drag(handle, const Offset(50, 0));
    await tester.pumpAndSettle();

    expect(prefs.columnSize(TrackColumn.album), closeTo(before + 50, 0.01));
    expect(
      prefs.columnSize(TrackColumn.title),
      TrackColumn.title.width,
      reason: 'and only Album',
    );
  });

  testWidgets('double-clicking a divider fits the column to its contents', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final prefs = await pump(tester, lib);

    // Start far too wide, then fit: "Absolution" and the ALBUM header
    // are both short, so the column must come in a long way.
    await tester.drag(
      find.byKey(const Key('column-resize-album')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    final wide = prefs.columnSize(TrackColumn.album);

    await tester.tap(find.byKey(const Key('column-resize-album')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const Key('column-resize-album')));
    await tester.pumpAndSettle();

    final fitted = prefs.columnSize(TrackColumn.album);
    expect(fitted, lessThan(wide));
    expect(
      fitted,
      greaterThan(kMinColumnWidth),
      reason: 'fit means fits -- the widest value must still show',
    );
    // Wide enough for "Absolution" at 13px, which is about 65px.
    expect(fitted, greaterThan(60));
  });
}
