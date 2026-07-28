// Last modified: 2026-07-25--2230
//
// Adversarial-review Fix 1: the background artwork backfill pass never
// re-ran after a rescan. Both the periodic timer (main.dart) and the
// Refresh button (ui/home_screen.dart) called `LibraryModel.rescan()`
// directly, with no path back to `ArtworkBackfill.run(...)` -- so an album
// added to a watched folder after launch (or one that missed the
// launch-time pass to a transient network failure) never got automatic
// artwork until the app was restarted.
//
// This test pins the Refresh-button half of the fix: tapping it, with
// [HomeScreen.artworkBackfill] wired, must queue a backfill pass over the
// CURRENT track list once the rescan settles. It fails against the
// pre-fix code two ways: `HomeScreen` has no `artworkBackfill` parameter at
// all (compile error), and even if one is added without wiring the
// Refresh button through it, the search seam below is never called.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_backfill.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';
import 'package:path/path.dart' as p;

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Song A',
      artist: 'Daft Punk',
      album: 'Discovery',
    ),
  ];
  m.status = 'ready';
  return m;
}

void main() {
  testWidgets('Refresh button queues a backfill pass once the rescan settles', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('fooplayer_refresh_bf_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Windows can briefly hold a handle (the store's background file
        // I/O may not have fully released it yet); a leftover temp dir is
        // harmless.
      }
    });
    final appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);

    final stores = ArtworkStoreRegistry(appDataDir: appData);
    final resolver = ArtworkResolver(
      stores: stores,
      embeddedLoader: (_) async => null,
    );
    addTearDown(resolver.dispose);

    final searched = <String>[];
    final backfill = ArtworkBackfill(
      resolver: resolver,
      gap: Duration.zero,
      search: (q) async {
        searched.add(q.terms);
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    final library = fixtureLibrary();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
          library: library,
          player: PlayerService(),
          layoutPrefs: LayoutPrefs(),
          libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
          artworkBackfill: backfill,
        ),
      ),
    );
    await tester.pump();

    // The rescan-then-backfill chain does real, non-fake-clock async work
    // (LibraryModel.rescan's guards, ArtworkStore's real file I/O) and is
    // never tied to a widget rebuild, so nothing schedules a new frame for
    // pumpAndSettle to wait on. Invoke the button's callback directly
    // inside [WidgetTester.runAsync] (the REAL async zone) so it isn't
    // starved waiting on flutter_test's fake microtask/timer queue, which
    // only advances on an explicit pump().
    await tester.runAsync(() async {
      final button = tester.widget<ListTile>(
        find.byKey(const Key('rescan-library')),
      );
      button.onTap!();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (searched.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // Let the pass fully settle (recordMiss + the sidecar's async save)
      // before returning -- otherwise its file I/O can still be in flight
      // when this test's tearDown tries to delete the temp dir, which is
      // flaky on Windows (a held handle fails the delete).
      while (backfill.running && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(
      searched,
      ['Daft Punk Discovery'],
      reason:
          'the Refresh button must chain a backfill pass over the '
          'current tracks once its rescan settles, exactly like the '
          'periodic timer and the launch-time rescan do',
    );
  });

  testWidgets(
    'Refresh button with no artworkBackfill wired still rescans (no crash)',
    (tester) async {
      final library = fixtureLibrary();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: HomeScreen(
            library: library,
            player: PlayerService(),
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('rescan-library')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
