// The library list's Path column, and hiding columns from the header's
// right-click menu (asked for 2026-09-18).
//
// Last modified: 2026-09-18--1610
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

Finder headerLabel(String text) => find.descendant(
  of: find.byKey(const Key('track-list-header')),
  matching: find.text(text),
);

/// Scoped to the list: the Album/Artist FILTER panes show the same values,
/// so an unscoped text matcher finds those too.
Finder inList(String text) =>
    find.descendant(of: find.byType(TrackListView), matching: find.text(text));

void main() {
  testWidgets('the Path column shows the track\'s file path', (tester) async {
    await pump(tester, fixtureLibrary());

    expect(headerLabel('PATH'), findsOneWidget);
    expect(
      find.text(r'L:\Music\albums\Muse\Absolution\01 Apocalypse Please.mp3'),
      findsOneWidget,
    );
  });

  testWidgets('right-clicking the header offers every hideable column', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());

    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('track-list-header'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    for (final c in TrackColumn.values) {
      expect(
        find.byKey(Key('column-toggle-${c.id}')),
        findsOneWidget,
        reason: '${c.label} must be offered',
      );
    }
    // Title is not hideable: a row with no title is not a row.
    expect(find.byKey(const Key('column-toggle-title')), findsNothing);
  });

  testWidgets('unchecking a column hides its header and its cells', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);
    expect(headerLabel('ALBUM'), findsOneWidget);
    expect(inList('Absolution'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('track-list-header'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('column-toggle-album')));
    await tester.pumpAndSettle();

    expect(headerLabel('ALBUM'), findsNothing);
    expect(
      inList('Absolution'),
      findsNothing,
      reason: 'the cells go with the header, not just the label',
    );
    // The rest of the row is untouched.
    expect(inList('Apocalypse Please'), findsOneWidget);
  });

  testWidgets('the choice is remembered across a restart', (tester) async {
    final prefs = LayoutPrefs(writer: (_) {}, debounce: Duration.zero);
    await pump(tester, fixtureLibrary(), prefs: prefs);

    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('track-list-header'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
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
