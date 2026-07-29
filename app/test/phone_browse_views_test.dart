// Last modified: 2026-07-24--1855
// Phone browse views (Plan 2b, task P3):
// - FoldersView: drill-down via folderEntries/drillIntoFolder, back
//   affordance pops one level, breadcrumb text line tracks the path;
// - ArtistsView: alphabetical, tap -> TrackListPage filtered to the artist,
//   row tap plays via the injected callback;
// - AlbumsView: tap -> album page sorted by trackNumber ascending;
// - PlaylistsView: create via dialog / long-press delete via confirm, both
//   through a spied PlaylistStore; tap -> playlist tracks in playlist order;
// - track long-press context sheet: Add to playlist -> store.addTrack,
//   View details -> read-only metadata dialog, and NO explorer/"View in
//   folder" entry on phone.
// All store writes are spied (SpyPlaylistStore) so no test touches disk;
// playback is spied via onPlayTrack so no media_kit Player is constructed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/browse_views.dart';
import 'package:fooplayer_app/ui/phone/track_list_page.dart';

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

const _root = r'C:\Lib';

/// Three tracks under one root: rock/Album X holds a two-track album
/// deliberately listed in reverse track order (Second before First) so the
/// album page's trackNumber sort is observable; jazz/ holds a third track
/// by a different artist. One playlist 'mix' references [c, a] -- an order
/// no column sort would produce.
LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'b',
      relPath: 'rock/Album X/02 Second.mp3',
      rootPath: _root,
      dateAdded: DateTime.utc(2026, 2, 1),
      title: 'Second Song',
      artist: 'Muse',
      album: 'Album X',
      trackNumber: 2,
      durationMs: 125000,
    ),
    Track(
      contentId: 'a',
      relPath: 'rock/Album X/01 First.mp3',
      rootPath: _root,
      dateAdded: DateTime.utc(2026, 1, 1),
      title: 'First Song',
      artist: 'Muse',
      album: 'Album X',
      trackNumber: 1,
      durationMs: 61000,
    ),
    Track(
      contentId: 'c',
      relPath: 'jazz/03 Jazz Tune.mp3',
      rootPath: _root,
      dateAdded: DateTime.utc(2026, 3, 1),
      title: 'Jazz Tune',
      artist: 'Feed Me',
      album: 'Album Y',
      trackNumber: 3,
    ),
  ];
  m.playlists = [
    const ManifestPlaylist(name: 'mix', trackIds: ['c', 'a']),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpView(WidgetTester tester, Widget view) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: view),
    ),
  );
}

double rowY(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(title)).dy;

void main() {
  group('FoldersView', () {
    testWidgets('drills down through folders and back pops one level', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpView(
        tester,
        FoldersView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      // With a single library root the pane OPENS INSIDE it: its subfolders
      // and its tracks, straight away. There is no root-list level to sit on
      // -- that was one row you had to tap before you could see anything --
      // so no back affordance and no 'All ›' prefix either.
      expect(lib.folderPath, [_root]);
      expect(find.byKey(const Key('folders-back')), findsNothing);
      expect(find.text('All folders'), findsNothing);
      expect(find.text('jazz'), findsOneWidget);
      expect(find.text('rock'), findsOneWidget);
      expect(find.text('Jazz Tune'), findsOneWidget);
      expect(find.text('Lib'), findsOneWidget);

      // Drill into rock: only its subfolder + tracks remain.
      await tester.tap(find.text('rock'));
      await tester.pumpAndSettle();
      expect(lib.folderPath, [_root, 'rock']);
      expect(find.text('Album X'), findsOneWidget);
      expect(find.text('jazz'), findsNothing);
      expect(find.text('Jazz Tune'), findsNothing);
      expect(find.text('First Song'), findsOneWidget);
      expect(find.text('Lib › rock'), findsOneWidget);

      // Back pops exactly one level -- and that lands at the top, because
      // the root IS the top.
      await tester.tap(find.byKey(const Key('folders-back')));
      await tester.pumpAndSettle();
      expect(lib.folderPath, [_root]);
      expect(find.text('rock'), findsOneWidget);
      expect(find.text('Lib'), findsOneWidget);
      expect(
        find.byKey(const Key('folders-back')),
        findsNothing,
        reason: 'nothing above the sole root to go back to',
      );
    });

    testWidgets('tapping a track row plays it', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      final played = <(int, String)>[];
      await pumpView(
        tester,
        FoldersView(
          library: lib,
          store: store,
          onPlayTrack: (tracks, i) => played.add((i, tracks[i].contentId)),
        ),
      );

      await tester.tap(find.text('Lib'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jazz Tune'));
      expect(played, [(0, 'c')]); // newest-first default: c is newest
    });
  });

  group('ArtistsView', () {
    testWidgets('lists artists alphabetically and tap filters the page', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      final played = <String>[];
      await pumpView(
        tester,
        ArtistsView(
          library: lib,
          store: store,
          onPlayTrack: (tracks, i) => played.add(tracks[i].contentId),
        ),
      );

      // Alphabetical: Feed Me above Muse.
      expect(rowY(tester, 'Feed Me'), lessThan(rowY(tester, 'Muse')));

      await tester.tap(find.text('Muse'));
      await tester.pumpAndSettle();

      // Filtered to Muse's tracks only.
      expect(find.text('First Song'), findsOneWidget);
      expect(find.text('Second Song'), findsOneWidget);
      expect(find.text('Jazz Tune'), findsNothing);

      // Row tap plays through the injected callback.
      await tester.tap(find.text('First Song'));
      expect(played, ['a']);
    });

    testWidgets('lists ALL artists even while a folder drill-down is active '
        '(phone drawer views are independent -- no hidden folder scope)', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      // Simulate FoldersView drill-down into rock/ (only Muse lives there).
      lib.drillIntoFolder('rock'); // already inside the sole root
      // Sanity: the desktop-scoped getter WOULD hide Feed Me here.
      expect(lib.artists, ['Muse']);

      await pumpView(
        tester,
        ArtistsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      // The phone Artists view must ignore that scope entirely.
      expect(find.text('Feed Me'), findsOneWidget);
      expect(find.text('Muse'), findsOneWidget);
    });
  });

  group('AlbumsView', () {
    testWidgets('album page sorts by trackNumber ascending', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpView(
        tester,
        AlbumsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      expect(find.text('Album X'), findsOneWidget);
      expect(find.text('Album Y'), findsOneWidget);

      await tester.tap(find.text('Album X'));
      await tester.pumpAndSettle();

      // allTracks lists Second before First; the album page must show
      // trackNumber order: First (1) above Second (2).
      expect(find.text('Jazz Tune'), findsNothing);
      expect(rowY(tester, 'First Song'), lessThan(rowY(tester, 'Second Song')));
    });

    testWidgets('lists ALL albums even while a folder drill-down is active', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      // Drill into jazz/ (only Album Y lives there).
      lib.drillIntoFolder('jazz'); // already inside the sole root
      // Sanity: the desktop-scoped getter WOULD hide Album X here.
      expect(lib.albums, ['Album Y']);

      await pumpView(
        tester,
        AlbumsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      expect(find.text('Album X'), findsOneWidget);
      expect(find.text('Album Y'), findsOneWidget);
    });
  });

  group('PlaylistsView', () {
    testWidgets('create dialog goes through the store', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpView(
        tester,
        PlaylistsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      await tester.tap(find.byKey(const Key('playlist-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playlist-name-field')),
        'road trip',
      );
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(store.created, ['road trip']);
    });

    testWidgets('long-press delete confirms first', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpView(
        tester,
        PlaylistsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      await tester.longPress(find.text('mix'));
      await tester.pumpAndSettle();
      expect(find.text('Delete playlist?'), findsOneWidget);

      // Cancel deletes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.deleted, isEmpty);

      // Confirmed delete goes through the store.
      await tester.longPress(find.text('mix'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-playlist')));
      await tester.pumpAndSettle();
      expect(store.deleted, ['mix']);
    });

    testWidgets('tap opens the playlist in playlist order', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpView(
        tester,
        PlaylistsView(library: lib, store: store, onPlayTrack: (_, _) {}),
      );

      expect(find.text('2 tracks'), findsOneWidget);
      await tester.tap(find.text('mix'));
      await tester.pumpAndSettle();

      // Playlist order is [c, a]: Jazz Tune above First Song -- an order
      // neither date nor track number would produce.
      expect(find.text('Second Song'), findsNothing);
      expect(rowY(tester, 'Jazz Tune'), lessThan(rowY(tester, 'First Song')));
    });
  });

  group('track long-press context sheet', () {
    Future<void> pumpAllTracksPage(
      WidgetTester tester,
      LibraryModel lib,
      SpyPlaylistStore store,
    ) {
      return tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: TrackListPage(
            title: 'All',
            library: lib,
            store: store,
            onPlayTrack: (_, _) {},
            tracksOf: (l) => l.allTracks,
          ),
        ),
      );
    }

    testWidgets('Add to playlist adds via the store', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpAllTracksPage(tester, lib, store);

      await tester.longPress(find.text('First Song'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-add-to-playlist')), findsOneWidget);
      // Phone sheet must NOT offer the desktop explorer entry.
      expect(find.text('View in folder'), findsNothing);

      await tester.tap(find.byKey(const Key('sheet-add-to-playlist')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-playlist-mix')), findsOneWidget);
      expect(find.byKey(const Key('sheet-new-playlist')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sheet-playlist-mix')));
      await tester.pumpAndSettle();
      expect(store.added, [('mix', 'a')]);
    });

    testWidgets('New playlist… creates then adds', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpAllTracksPage(tester, lib, store);

      await tester.longPress(find.text('Jazz Tune'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-add-to-playlist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-new-playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playlist-name-field')),
        'fresh',
      );
      await tester.tap(find.byKey(const Key('playlist-name-create')));
      await tester.pumpAndSettle();

      expect(store.created, ['fresh']);
      expect(store.added, [('fresh', 'c')]);
    });

    testWidgets('View details opens the metadata dialog '
        '(title / artist / album / duration / path)', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpAllTracksPage(tester, lib, store);

      await tester.longPress(find.text('First Song'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-view-details')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sheet-view-details')));
      await tester.pumpAndSettle();

      final dialog = find.byKey(const Key('track-details-dialog'));
      expect(dialog, findsOneWidget);
      Finder inDialog(String text) =>
          find.descendant(of: dialog, matching: find.text(text));
      expect(inDialog('First Song'), findsOneWidget);
      expect(inDialog('Muse'), findsOneWidget);
      expect(inDialog('Album X'), findsOneWidget);
      expect(inDialog('1:01'), findsOneWidget); // 61000ms
      // Path = p.join(rootPath, relPath) -- assert on the stable relPath
      // tail so the test doesn't depend on the host's path separator.
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('01 First.mp3'),
        ),
        findsOneWidget,
      );

      // Close returns to the page with no store writes.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(store.added, isEmpty);
      expect(store.created, isEmpty);
    });

    testWidgets('rows show duration right-aligned text', (tester) async {
      final lib = fixtureLibrary();
      final store = SpyPlaylistStore(lib);
      await pumpAllTracksPage(tester, lib, store);

      expect(find.text('2:05'), findsOneWidget); // 125000ms
      expect(find.text('1:01'), findsOneWidget); // 61000ms
      // Subtitle line: artist — album.
      expect(find.text('Muse — Album X'), findsNWidgets(2));
    });
  });
}
