// The phone drawer laid out like the desktop sidebar, and the app's
// persistent footer (asked for 2026-09-18).
//
// Drawer: Library, Queue, a folding Playlists section, a folding Folders
// section, then the browse views only the phone has (Artists, Albums).
// Footer: how big the library is and a rescan on the left, sync on the
// right -- the two actions that were buried in the drawer.
//
// Last modified: 2026-09-18--2010
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/sync/sync_engine.dart';
import 'package:fooplayer_app/sync/sync_settings.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';
import 'package:fooplayer_app/ui/sync_view.dart';

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
      album: 'Absolution',
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      rootPath: r'L:\Music\ElectroFolder',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Oldest Song',
      artist: 'Feed Me',
      album: 'Calamari Tuesday',
    ),
  ];
  m.playlists = [const ManifestPlaylist(name: 'road trip', trackIds: ['b'])];
  m.status = 'ready';
  return m;
}

Future<void> pumpShell(
  WidgetTester tester,
  LibraryModel library, {
  SyncUiSeams? syncUi,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: PhoneShell(
        library: library,
        player: PlayerService(),
        store: PlaylistStore(library: library, device: 'test'),
        onPlayTrack: (_, _) {},
        onTrackLongPress: (_, _) {},
        openNowPlayingOnPlay: false,
        syncUi: syncUi,
      ),
    ),
  );
}

Future<void> openDrawer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the drawer reads Library, Playlists, Folders, then the rest', (
    tester,
  ) async {
    await pumpShell(tester, fixtureLibrary());
    await openDrawer(tester);

    double y(Key k) => tester.getTopLeft(find.byKey(k)).dy;
    expect(
      y(const Key('phone-drawer-library')),
      lessThan(y(const Key('phone-section-playlists'))),
    );
    expect(
      y(const Key('phone-section-playlists')),
      lessThan(y(const Key('phone-section-folders'))),
    );
    expect(
      y(const Key('phone-section-folders')),
      lessThan(y(const Key('phone-drawer-artists'))),
    );
    expect(
      y(const Key('phone-drawer-artists')),
      lessThan(y(const Key('phone-drawer-albums'))),
    );
  });

  testWidgets('both sections start folded', (tester) async {
    await pumpShell(tester, fixtureLibrary());
    await openDrawer(tester);

    expect(find.byKey(const Key('phone-playlist-road trip')), findsNothing);
    expect(find.byKey(const Key('phone-folder-RockFolder')), findsNothing);
  });

  testWidgets('Playlists opens to the playlists themselves', (tester) async {
    await pumpShell(tester, fixtureLibrary());
    await openDrawer(tester);

    await tester.tap(find.byKey(const Key('phone-section-playlists')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phone-playlist-road trip')), findsOneWidget);

    // One tap from the drawer to that playlist's tracks, rather than
    // three through the Playlists page.
    await tester.tap(find.byKey(const Key('phone-playlist-road trip')));
    await tester.pumpAndSettle();
    expect(find.text('road trip'), findsWidgets);
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);
  });

  testWidgets('Folders opens to the library roots, by name', (tester) async {
    final lib = fixtureLibrary();
    await pumpShell(tester, lib);
    await openDrawer(tester);

    await tester.tap(find.byKey(const Key('phone-section-folders')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phone-folder-RockFolder')), findsOneWidget);
    expect(find.byKey(const Key('phone-folder-ElectroFolder')), findsOneWidget);

    await tester.tap(find.byKey(const Key('phone-folder-RockFolder')));
    await tester.pumpAndSettle();
    expect(
      lib.folderPath,
      [r'L:\Music\RockFolder'],
      reason: 'the Folders view opens inside the root you picked',
    );
  });

  testWidgets('the footer shows the track count, and follows the library', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pumpShell(tester, lib);

    expect(
      tester.widget<Text>(find.byKey(const Key('phone-footer-count'))).data,
      '2 tracks',
    );

    // A rescan finding a track is what moves this in production; the
    // setter plus a notification is the same thing without the isolate.
    lib.allTracks = [
      ...lib.allTracks,
      Track(
        contentId: 'c',
        relPath: 'c.mp3',
        rootPath: r'L:\Music\RockFolder',
        dateAdded: DateTime.utc(2026, 9, 18),
        title: 'Third Song',
      ),
    ];
    // The list setter is silent by design; a rescan is what notifies in
    // production. Any library notification repaints the footer, which is
    // the property under test.
    lib.setSort(SortColumn.title);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('phone-footer-count'))).data,
      '3 tracks',
    );
  });

  testWidgets('the footer carries rescan on the left and sync on the right', (
    tester,
  ) async {
    var ran = 0;
    await pumpShell(
      tester,
      fixtureLibrary(),
      syncUi: SyncUiSeams(
        currentSettings: SyncSettings.new,
        onSave: (_) {},
        runSync: () async {
          ran++;
          return SyncReport(
            playlistNotes: const [],
            roots: const [],
            finishedAt: DateTime(2026, 9, 18),
          );
        },
        probe: () async => true,
        discoverRoots: () async => const [],
        cancelSync: () async {},
      ),
    );

    final rescan = find.byKey(const Key('phone-footer-rescan'));
    final sync = find.byKey(const Key('phone-footer-sync'));
    expect(rescan, findsOneWidget);
    expect(sync, findsOneWidget);
    expect(
      tester.getCenter(rescan).dx,
      lessThan(tester.getCenter(sync).dx),
      reason: 'rescan sits with the count on the left, sync on the right',
    );

    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(ran, 1);
  });

  testWidgets('no sync wiring means no sync button', (tester) async {
    await pumpShell(tester, fixtureLibrary());
    expect(find.byKey(const Key('phone-footer-sync')), findsNothing);
    expect(find.byKey(const Key('phone-footer-count')), findsOneWidget);
  });
}
