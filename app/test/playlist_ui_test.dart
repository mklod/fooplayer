// Playlist management UI (TODO #29) + selection clear (TODO #30):
// - sidebar: tapping the already-active playlist deselects it (back to
//   Library), the active row's ✕ affordance does the same, and tapping
//   'Library' also clears;
// - '+ New playlist' opens the name dialog (unique-name validation incl.
//   the " (2)" merge-suffix convention);
// - playlist row right-click -> Delete behind a confirm dialog;
// - track row right-click -> 'Add to playlist' submenu (playlists + 'New
//   playlist...') and, in playlist view, 'Remove from playlist'.
// All store writes are spied (SpyPlaylistStore) so no test touches disk.
import 'package:flutter/gestures.dart';
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

class SpyPlaylistStore extends PlaylistStore {
  SpyPlaylistStore(LibraryModel library) : super(library: library);

  final created = <String>[];
  final deleted = <String>[];
  final added = <(String, String)>[];
  final removed = <(String, String)>[];

  @override
  Future<void> createPlaylist(String name) async => created.add(name.trim());
  @override
  Future<void> deletePlaylist(String name) async => deleted.add(name);
  @override
  Future<void> addTrack(String name, String contentId) async =>
      added.add((name, contentId));
  @override
  Future<void> removeTrack(String name, String contentId) async =>
      removed.add((name, contentId));
}

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
        album: 'X'),
    Track(
        contentId: 'b',
        relPath: 'b.mp3',
        rootPath: r'L:\Music\ElectroFolder',
        dateAdded: DateTime.utc(2020, 1, 1),
        title: 'Oldest Song',
        artist: 'Feed Me',
        album: 'Y'),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['b'])];
  m.status = 'ready';
  return m;
}

Future<SpyPlaylistStore> pumpHome(WidgetTester tester, LibraryModel lib) async {
  final spy = SpyPlaylistStore(lib);
  await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: HomeScreen(
          library: lib,
          player: PlayerService(),
          layoutPrefs: LayoutPrefs(),
          libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
          playlistStore: spy)));
  return spy;
}

/// The 'mix' row in the sidebar (the same text also appears nowhere else in
/// the fixture, but scoping makes that robust against future columns).
Finder sidebarTile(String name) => find.descendant(
    of: find.byKey(const Key('sidebar-panel')), matching: find.text(name));

void main() {
  group('selection clear (#30)', () {
    testWidgets('tapping the already-active playlist deselects it',
        (tester) async {
      final lib = fixtureLibrary();
      await pumpHome(tester, lib);

      await tester.tap(sidebarTile('mix'));
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, 'mix');
      expect(find.text('Newest Song'), findsNothing); // playlist view

      await tester.tap(sidebarTile('mix'));
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, isNull);
      expect(find.text('Newest Song'), findsOneWidget); // back to Library
    });

    testWidgets(
        'the active playlist row shows a ✕ affordance that clears back to '
        'Library (and only the active row shows it)', (tester) async {
      final lib = fixtureLibrary();
      await pumpHome(tester, lib);

      final clearKey = find.byKey(const Key('clear-playlist-mix'));
      expect(clearKey, findsNothing, reason: 'no ✕ while inactive');

      await tester.tap(sidebarTile('mix'));
      await tester.pumpAndSettle();
      expect(clearKey, findsOneWidget);

      await tester.tap(clearKey);
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, isNull);
      expect(clearKey, findsNothing);
      expect(find.text('Newest Song'), findsOneWidget);
    });

    testWidgets('tapping Library clears the active playlist', (tester) async {
      final lib = fixtureLibrary();
      await pumpHome(tester, lib);

      await tester.tap(sidebarTile('mix'));
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, 'mix');

      await tester.tap(sidebarTile('Library'));
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, isNull);
      expect(find.text('Newest Song'), findsOneWidget);
    });
  });

  group('create playlist dialog', () {
    testWidgets(
        'happy path: + New playlist -> name -> Create calls the store and '
        'closes the dialog', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.byKey(const Key('new-playlist')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('playlist-name-field')), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('playlist-name-field')), 'roadtrip');
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(spy.created, ['roadtrip']);
      expect(find.byKey(const Key('playlist-name-field')), findsNothing);
    });

    testWidgets('empty name is rejected in-dialog, store never called',
        (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.byKey(const Key('new-playlist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(find.text('Playlist name cannot be empty.'), findsOneWidget);
      expect(find.byKey(const Key('playlist-name-field')), findsOneWidget,
          reason: 'dialog stays open');
      expect(spy.created, isEmpty);
    });

    testWidgets(
        'duplicate name (an existing merged playlist name) is rejected '
        'in-dialog', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.byKey(const Key('new-playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('playlist-name-field')), 'mix');
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(find.text('A playlist named "mix" already exists.'),
          findsOneWidget);
      expect(spy.created, isEmpty);
    });
  });

  group('delete playlist', () {
    testWidgets(
        'right-click -> Delete playlist -> confirm calls the store',
        (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(sidebarTile('mix'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Delete playlist'), findsOneWidget);

      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Delete playlist?'), findsOneWidget); // confirm dialog

      await tester.tap(find.byKey(const Key('confirm-delete-playlist')));
      await tester.pumpAndSettle();
      expect(spy.deleted, ['mix']);
    });

    testWidgets('cancelling the confirm dialog does not delete',
        (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(sidebarTile('mix'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(spy.deleted, isEmpty);
      expect(sidebarTile('mix'), findsOneWidget);
    });
  });

  group('track context menu playlist items', () {
    testWidgets(
        '"Add to playlist" submenu lists the playlists and adds the track '
        'to the chosen one', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.text('Newest Song'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Add to playlist ▸'), findsOneWidget);
      expect(find.text('Remove from playlist'), findsNothing,
          reason: 'not in playlist view');

      await tester.tap(find.text('Add to playlist ▸'));
      await tester.pumpAndSettle();

      // 'mix' also names the sidebar row -- scope to the submenu item.
      final mixItem = find.widgetWithText(PopupMenuItem<int>, 'mix');
      expect(mixItem, findsOneWidget);
      expect(find.text('New playlist...'), findsOneWidget);

      await tester.tap(mixItem);
      await tester.pumpAndSettle();
      expect(spy.added, [('mix', 'a')]);
    });

    testWidgets(
        '"New playlist..." in the submenu creates the playlist and adds '
        'the track to it in one flow', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.text('Oldest Song'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist ▸'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New playlist...'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('playlist-name-field')), 'fresh');
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(spy.created, ['fresh']);
      expect(spy.added, [('fresh', 'b')]);
    });

    testWidgets(
        'in playlist view, "Remove from playlist" removes the track from '
        'the active playlist', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(sidebarTile('mix'));
      await tester.pumpAndSettle();
      expect(lib.activePlaylist, 'mix');

      await tester.tap(find.text('Oldest Song'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Remove from playlist'), findsOneWidget);

      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      expect(spy.removed, [('mix', 'b')]);
    });
  });
}
