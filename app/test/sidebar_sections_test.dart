// The sidebar's two collapsible sections (asked for 2026-09-18).
//
// Playlists used to be a flat list that grew forever between "Library" and
// the pinned actions, and there was no way to jump to a source folder from
// the sidebar at all -- that lived only in the Folder filter pane. Both are
// now sections that fold away, and both start folded: the sidebar's job at
// rest is Library, not an inventory.
//
// Last modified: 2026-09-18--1640
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      rootPath: r'L:\Music\RockFolder',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Newest Song',
      artist: 'Muse',
      album: 'X',
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      rootPath: r'L:\Music\ElectroFolder',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Oldest Song',
      artist: 'Feed Me',
      album: 'Y',
    ),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['b'])];
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

void main() {
  testWidgets('both sections start collapsed', (tester) async {
    await pump(tester, fixtureLibrary());

    expect(find.byKey(const Key('playlists-section')), findsOneWidget);
    expect(find.byKey(const Key('folders-section')), findsOneWidget);

    expect(find.text('mix'), findsNothing, reason: 'playlists are folded');
    expect(find.byKey(const Key('new-playlist')), findsNothing);
    // By key, not by text: the Folder FILTER pane in the content area
    // lists the same root names, so a text matcher would find those.
    expect(find.byKey(const Key('folder-row-RockFolder')), findsNothing,
        reason: 'folders are folded');
  });

  testWidgets('tapping Playlists reveals the playlists and New playlist', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());

    await tester.tap(find.byKey(const Key('playlists-section')));
    await tester.pumpAndSettle();

    expect(find.text('mix'), findsOneWidget);
    expect(find.byKey(const Key('new-playlist')), findsOneWidget);

    // ...and folds away again.
    await tester.tap(find.byKey(const Key('playlists-section')));
    await tester.pumpAndSettle();
    expect(find.text('mix'), findsNothing);
  });

  testWidgets('tapping Folders lists the library roots by name', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());

    await tester.tap(find.byKey(const Key('folders-section')));
    await tester.pumpAndSettle();

    // Basenames -- a sidebar has no room for a full NAS path.
    expect(find.byKey(const Key('folder-row-ElectroFolder')), findsOneWidget);
    final row = find.byKey(const Key('folder-row-RockFolder'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('RockFolder')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a folder scopes the library to that root', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    await tester.tap(find.byKey(const Key('folders-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-row-RockFolder')));
    await tester.pumpAndSettle();

    expect(lib.folderPath, [r'L:\Music\RockFolder']);
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsNothing);
  });

  testWidgets('a folder tapped from inside a playlist leaves the playlist', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);
    lib.setPlaylist('mix');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('folders-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-row-RockFolder')));
    await tester.pumpAndSettle();

    expect(lib.activePlaylist, isNull);
    expect(lib.folderPath, [r'L:\Music\RockFolder']);
  });

  testWidgets('each section remembers being open', (tester) async {
    final saved = <Map<String, dynamic>>[];
    final prefs = LayoutPrefs(
      writer: saved.add,
      debounce: Duration.zero,
    );
    await pump(tester, fixtureLibrary(), prefs: prefs);

    await tester.tap(find.byKey(const Key('playlists-section')));
    await tester.pumpAndSettle();
    expect(prefs.playlistsExpanded, isTrue);

    await tester.tap(find.byKey(const Key('folders-section')));
    await tester.pumpAndSettle();
    expect(prefs.foldersExpanded, isTrue);

    // ...and survives a restart, which is what the config write is for.
    final reopened = LayoutPrefs.fromConfig(prefs.toJson());
    expect(reopened.playlistsExpanded, isTrue);
    expect(reopened.foldersExpanded, isTrue);
  });

  testWidgets('a fresh config folds both sections', (tester) async {
    final prefs = LayoutPrefs.fromConfig(null);
    expect(prefs.playlistsExpanded, isFalse);
    expect(prefs.foldersExpanded, isFalse);
  });

  testWidgets('New playlist sits at the TOP of the open section', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    await tester.tap(find.byKey(const Key('playlists-section')));
    await tester.pumpAndSettle();

    final header = tester.getTopLeft(find.byKey(const Key('playlists-section')));
    final newRow = tester.getTopLeft(find.byKey(const Key('new-playlist')));
    final mixRow = tester.getTopLeft(find.text('mix'));

    expect(newRow.dy, greaterThan(header.dy));
    expect(
      newRow.dy,
      lessThan(mixRow.dy),
      reason: 'creating a playlist is the action; the list is the inventory',
    );
  });

  testWidgets('playlist rows carry an icon and sit at the folder indent', (
    tester,
  ) async {
    await pump(tester, fixtureLibrary());
    await tester.tap(find.byKey(const Key('playlists-section')));
    await tester.tap(find.byKey(const Key('folders-section')));
    await tester.pumpAndSettle();

    final playlistRow = find.byKey(const Key('playlist-row-mix'));
    expect(playlistRow, findsOneWidget);
    expect(
      find.descendant(of: playlistRow, matching: find.byType(Icon)),
      findsWidgets,
      reason: 'a bare label read as a different kind of thing to a folder',
    );

    // Same left edge as a folder row -- the two sections are siblings and
    // a half-indent between them looks like a mistake.
    final label = tester.getTopLeft(
      find.descendant(of: playlistRow, matching: find.text('mix')),
    );
    final folderLabel = tester.getTopLeft(
      find.descendant(
        of: find.byKey(const Key('folder-row-RockFolder')),
        matching: find.text('RockFolder'),
      ),
    );
    expect(label.dx, folderLabel.dx);
  });
}
