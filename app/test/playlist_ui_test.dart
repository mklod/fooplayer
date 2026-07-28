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
import 'package:fooplayer_app/ui/track_list.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

class SpyPlaylistStore extends PlaylistStore {
  SpyPlaylistStore(LibraryModel library) : super(library: library);

  final created = <String>[];
  final deleted = <String>[];
  final added = <(String, String)>[];
  final removed = <(String, String)>[];

  /// One-write-per-call log, distinct from [added]'s per-track entries --
  /// lets multi-select tests assert the manifest was written exactly ONCE
  /// for a whole batch rather than once per track (see track_list.dart's
  /// _showAddToPlaylistMenu / "Remove from playlist" action, both of which
  /// call the batch [addTracks]/[removeTracks] below, never the singular
  /// [addTrack]/[removeTrack] per track).
  final addTracksCalls = <(String, List<String>)>[];
  final removeTracksCalls = <(String, List<String>)>[];

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

  @override
  Future<int> addTracks(String name, List<String> contentIds) async {
    addTracksCalls.add((name, List<String>.of(contentIds)));
    for (final id in contentIds) {
      added.add((name, id));
    }
    return contentIds.length;
  }

  @override
  Future<int> removeTracks(String name, List<String> contentIds) async {
    removeTracksCalls.add((name, List<String>.of(contentIds)));
    for (final id in contentIds) {
      removed.add((name, id));
    }
    return contentIds.length;
  }
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
  m.playlists = [
    const ManifestPlaylist(name: 'mix', trackIds: ['b']),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpHomeWithStore(
  WidgetTester tester,
  LibraryModel lib,
  PlaylistStore store,
) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: HomeScreen(
      library: lib,
      player: PlayerService(),
      layoutPrefs: LayoutPrefs(),
      libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
      playlistStore: store,
    ),
  ),
);

Future<SpyPlaylistStore> pumpHome(WidgetTester tester, LibraryModel lib) async {
  final spy = SpyPlaylistStore(lib);
  await pumpHomeWithStore(tester, lib, spy);
  return spy;
}

/// A store where every mutation refuses with a [PlaylistStoreException] --
/// stands in for a real refusal (e.g. the reported bug's cross-root
/// ownership block) to prove the UI surfaces it via a visible SnackBar
/// rather than swallowing it silently.
class RefusingPlaylistStore extends PlaylistStore {
  RefusingPlaylistStore(LibraryModel library) : super(library: library);

  @override
  Future<int> addTracks(String name, List<String> contentIds) async {
    throw PlaylistStoreException(
      'Playlist "$name" lives in another root\'s library and can\'t be '
      'edited from here.',
    );
  }

  @override
  Future<void> deletePlaylist(String name) async {
    throw PlaylistStoreException('Refused: cannot delete "$name".');
  }
}

/// The 'mix' row in the sidebar (the same text also appears nowhere else in
/// the fixture, but scoping makes that robust against future columns).
Finder sidebarTile(String name) => find.descendant(
  of: find.byKey(const Key('sidebar-panel')),
  matching: find.text(name),
);

void main() {
  group('selection clear (#30)', () {
    testWidgets('tapping the already-active playlist deselects it', (
      tester,
    ) async {
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
      'Library (and only the active row shows it)',
      (tester) async {
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
      },
    );

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
      'closes the dialog',
      (tester) async {
        final lib = fixtureLibrary();
        final spy = await pumpHome(tester, lib);

        await tester.tap(find.byKey(const Key('new-playlist')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playlist-name-field')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('playlist-name-field')),
          'roadtrip',
        );
        await tester.tap(find.byKey(const Key('playlist-name-create')));
        await tester.pumpAndSettle();

        expect(spy.created, ['roadtrip']);
        expect(find.byKey(const Key('playlist-name-field')), findsNothing);
      },
    );

    testWidgets('empty name is rejected in-dialog, store never called', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.byKey(const Key('new-playlist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(find.text('Playlist name cannot be empty.'), findsOneWidget);
      expect(
        find.byKey(const Key('playlist-name-field')),
        findsOneWidget,
        reason: 'dialog stays open',
      );
      expect(spy.created, isEmpty);
    });

    testWidgets('duplicate name (an existing merged playlist name) is rejected '
        'in-dialog', (tester) async {
      final lib = fixtureLibrary();
      final spy = await pumpHome(tester, lib);

      await tester.tap(find.byKey(const Key('new-playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playlist-name-field')),
        'mix',
      );
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(
        find.text('A playlist named "mix" already exists.'),
        findsOneWidget,
      );
      expect(spy.created, isEmpty);
    });
  });

  group('delete playlist', () {
    testWidgets('right-click -> Delete playlist -> confirm calls the store', (
      tester,
    ) async {
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

    testWidgets('cancelling the confirm dialog does not delete', (
      tester,
    ) async {
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
      'to the chosen one',
      (tester) async {
        final lib = fixtureLibrary();
        final spy = await pumpHome(tester, lib);

        await tester.tap(find.text('Newest Song'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Add to playlist ▸'), findsOneWidget);
        expect(
          find.text('Remove from playlist'),
          findsNothing,
          reason: 'not in playlist view',
        );

        await tester.tap(find.text('Add to playlist ▸'));
        await tester.pumpAndSettle();

        // 'mix' also names the sidebar row -- scope to the submenu item.
        final mixItem = find.widgetWithText(PopupMenuItem<int>, 'mix');
        expect(mixItem, findsOneWidget);
        expect(find.text('New playlist...'), findsOneWidget);

        await tester.tap(mixItem);
        await tester.pumpAndSettle();
        expect(spy.added, [('mix', 'a')]);
      },
    );

    testWidgets(
      '"New playlist..." in the submenu creates the playlist and adds '
      'the track to it in one flow',
      (tester) async {
        final lib = fixtureLibrary();
        final spy = await pumpHome(tester, lib);

        await tester.tap(find.text('Oldest Song'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist ▸'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New playlist...'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('playlist-name-field')),
          'fresh',
        );
        await tester.tap(find.byKey(const Key('playlist-name-create')));
        await tester.pumpAndSettle();

        expect(spy.created, ['fresh']);
        expect(spy.added, [('fresh', 'b')]);
      },
    );

    testWidgets(
      'in playlist view, "Remove from playlist" removes the track from '
      'the active playlist',
      (tester) async {
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
      },
    );
  });

  // Regression coverage for the reported bug's second half: a
  // PlaylistStoreException (e.g. the ownership refusal fixed above) must
  // always reach the screen, and a success report must not silently
  // disappear either. Both flow through a ScaffoldMessenger captured
  // BEFORE the "Add to playlist" popup menu opens (see
  // ui/playlist_dialogs.dart's showPlaylistError doc and
  // ui/track_list.dart's _showTrackContextMenu), so neither depends on the
  // triggering row's own BuildContext still being mounted by the time the
  // store call resolves.
  group('store results are always surfaced (never silently swallowed)', () {
    testWidgets(
      'a successful "Add to playlist" reports the count via a SnackBar, '
      'using the messenger captured before the popup menu opened',
      (tester) async {
        final lib = fixtureLibrary();
        final spy = await pumpHome(tester, lib);

        await tester.tap(find.text('Newest Song'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist ▸'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(PopupMenuItem<int>, 'mix'));
        await tester.pumpAndSettle();

        expect(spy.added, [('mix', 'a')]);
        expect(find.text('Added 1 track to "mix"'), findsOneWidget);
      },
    );

    testWidgets('a PlaylistStoreException thrown by addTracks (e.g. the '
        'cross-root ownership refusal) surfaces its exact message via a '
        'SnackBar instead of vanishing', (tester) async {
      final lib = fixtureLibrary();
      final store = RefusingPlaylistStore(lib);
      await pumpHomeWithStore(tester, lib, store);

      await tester.tap(find.text('Newest Song'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist ▸'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<int>, 'mix'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Playlist "mix" lives in another root\'s library and '
          'can\'t be edited from here.',
        ),
        findsOneWidget,
        reason: 'the refusal must be visible, not a silent no-op',
      );
    });

    testWidgets(
      'a PlaylistStoreException thrown by deletePlaylist surfaces its '
      'message via a SnackBar instead of vanishing',
      (tester) async {
        final lib = fixtureLibrary();
        final store = RefusingPlaylistStore(lib);
        await pumpHomeWithStore(tester, lib, store);

        await tester.tap(sidebarTile('mix'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete playlist'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-playlist')));
        await tester.pumpAndSettle();

        expect(find.text('Refused: cannot delete "mix".'), findsOneWidget);
      },
    );
  });

  testWidgets('playlist banner shows the name and a track/duration summary', (
    tester,
  ) async {
    // Matches the reference layout Mike sent: cover + title + "N tracks ·
    // MM min" above the four columns.
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final lib = LibraryModel()
      ..allTracks = [
        Track(
          contentId: 'a',
          relPath: 'a.mp3',
          rootPath: r'L:\M',
          dateAdded: DateTime.utc(2026),
          title: 'One',
          artist: 'X',
          album: 'Alpha',
          durationMs: 180000,
        ),
        Track(
          contentId: 'b',
          relPath: 'b.mp3',
          rootPath: r'L:\M',
          dateAdded: DateTime.utc(2026),
          title: 'Two',
          artist: 'Y',
          album: 'Beta',
          durationMs: 240000,
        ),
      ]
      ..playlists = [
        const ManifestPlaylist(name: 'Autumn Vibes', trackIds: ['a', 'b']),
      ]
      ..status = 'ready';
    lib.setPlaylist('Autumn Vibes');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TrackListView(library: lib, player: PlayerService()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('playlist-banner-title')), findsOneWidget);
    expect(find.text('Autumn Vibes'), findsWidgets);
    // 180s + 240s = 7 min
    expect(find.text('2 tracks · 7 min'), findsOneWidget);
  });
}
