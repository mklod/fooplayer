// The library list's Path column, and hiding columns by right-clicking
// the one you mean (asked for 2026-09-18).
//
// The first cut put every column in one popup menu off the whole header.
// Rejected: the menu you get should be about the column under the cursor,
// with no animation and no list to read. So a right-click on ARTIST says
// "Hide Artist" and nothing else -- except the way back, which has to
// live somewhere, so any header also offers "Show <column>" for whatever
// is currently hidden.
//
// Last modified: 2026-09-18--1630
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

  testWidgets('right-clicking a column offers that column ALONE', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('ALBUM'));

    expect(find.byKey(const Key('column-hide-album')), findsOneWidget);
    expect(
      find.byKey(const Key('column-hide-artist')),
      findsNothing,
      reason: 'the menu is about the column under the cursor, not a list',
    );
    expect(find.byKey(const Key('column-hide-path')), findsNothing);
  });

  testWidgets('hiding takes the header and the cells with it', (tester) async {
    await pump(tester, fixtureLibrary());
    expect(inList('Absolution'), findsOneWidget);

    await rightClick(tester, headerLabel('ALBUM'));
    await tester.tap(find.byKey(const Key('column-hide-album')));
    await tester.pumpAndSettle();

    expect(headerLabel('ALBUM'), findsNothing);
    expect(inList('Absolution'), findsNothing);
    expect(inList('Apocalypse Please'), findsOneWidget, reason: 'rest intact');
  });

  testWidgets('a hidden column comes back from any header\'s menu', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('ALBUM'));
    await tester.tap(find.byKey(const Key('column-hide-album')));
    await tester.pumpAndSettle();
    expect(headerLabel('ALBUM'), findsNothing);

    // The hidden column has no header left to right-click, so the way
    // back has to live on the ones still showing.
    await rightClick(tester, headerLabel('ARTIST'));
    expect(find.byKey(const Key('column-hide-artist')), findsOneWidget);
    await tester.tap(find.byKey(const Key('column-show-album')));
    await tester.pumpAndSettle();

    expect(headerLabel('ALBUM'), findsOneWidget);
  });

  testWidgets('nothing hidden means no restore entries', (tester) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabelLoose('DATE'));

    expect(find.byKey(const Key('column-hide-date')), findsOneWidget);
    for (final c in TrackColumn.values) {
      expect(find.byKey(Key('column-show-${c.id}')), findsNothing);
    }
  });

  testWidgets('Title is not hideable', (tester) async {
    await pump(tester, fixtureLibrary());
    await rightClick(tester, headerLabel('TITLE'));

    expect(find.byKey(const Key('column-hide-title')), findsNothing);
  });

  testWidgets('the choice is remembered across a restart', (tester) async {
    final prefs = LayoutPrefs(writer: (_) {}, debounce: Duration.zero);
    await pump(tester, fixtureLibrary(), prefs: prefs);

    await rightClick(tester, headerLabel('PATH'));
    await tester.tap(find.byKey(const Key('column-hide-path')));
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
