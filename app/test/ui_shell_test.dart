import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart';

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
        genre: 'Rock'),
    Track(
        contentId: 'b',
        relPath: 'b.mp3',
        rootPath: r'L:\Music\ElectroFolder',
        dateAdded: DateTime.utc(2020, 1, 1),
        title: 'Oldest Song',
        artist: 'Feed Me',
        album: 'Y',
        genre: 'Electronic'),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['b'])];
  m.status = 'ready';
  return m;
}

void main() {
  testWidgets('shows feed newest-first with sidebar playlists', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('mix'), findsOneWidget); // playlist in sidebar
    // Feed order: Newest above Oldest.
    final newestY = tester.getTopLeft(find.text('Newest Song')).dy;
    final oldestY = tester.getTopLeft(find.text('Oldest Song')).dy;
    expect(newestY, lessThan(oldestY));
  });

  testWidgets('selecting a playlist shows its tracks only', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    await tester.tap(find.text('mix'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);
  });

  testWidgets('folder selection cascades into artist panel and track list',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    // Both artists visible initially in the Artist panel.
    expect(find.text('Muse'), findsWidgets);
    expect(find.text('Feed Me'), findsWidgets);
    await tester.tap(find.text('RockFolder')); // select folder (basename display)
    await tester.pumpAndSettle();
    // Plain click = select AND drill in (see LibraryModel.drillIntoFolder).
    expect(lib.folderPath, [r'L:\Music\RockFolder']);
    expect(find.text('Feed Me'), findsNothing); // filtered out everywhere
    expect(find.text('Oldest Song'), findsNothing); // track list narrowed
    // The pane's entries were replaced by RockFolder's subdirectories --
    // its only track sits directly at root level, so no entries remain and
    // the other root is no longer listed.
    expect(find.text('ElectroFolder'), findsNothing);
    // The pinned header shows the breadcrumb of the drilled folder.
    expect(find.text('RockFolder'), findsOneWidget);
    // Clear via the pinned selection's X (only the Folder panel has a
    // selection at this point, so the close icon is unambiguous) -- back to
    // the top-level root list, filter fully cleared.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(lib.folderPath, isEmpty);
    expect(lib.folderSiblings, isEmpty);
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('ElectroFolder'), findsOneWidget); // root list is back
  });

  testWidgets(
      'Ctrl+click accumulates a second artist in the filter panel, and the '
      'track list shows the union of both artists\' tracks', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));

    // Scoped to the Artist panel: 'Muse'/'Feed Me' also appear in the track
    // list's Artist column, so an unscoped text finder would be ambiguous.
    final artistPanel = find.byKey(const Key('artist-filter-panel'));
    Finder artistValue(String label) =>
        find.descendant(of: artistPanel, matching: find.text(label));

    // Plain click selects just Muse -- Feed Me's track drops out.
    await tester.tap(artistValue('Muse'));
    await tester.pumpAndSettle();
    expect(lib.artistFilters, {'Muse'});
    expect(find.text('Newest Song'), findsOneWidget); // Muse's track
    expect(find.text('Oldest Song'), findsNothing); // Feed Me's track, filtered out

    // Ctrl+click Feed Me: accumulates rather than replacing.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(artistValue('Feed Me'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(lib.artistFilters, {'Muse', 'Feed Me'});
    // Union: both artists' tracks are visible now.
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsOneWidget);
    // Pinned header reflects the multi-selection.
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('now-playing bar hidden with no track, transport icons exist otherwise',
      (tester) async {
    // Wide enough that the shuffle/volume group (bundled together, hidden
    // below the 900px narrow threshold) is visible.
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    expect(find.byIcon(Icons.play_arrow), findsNothing); // no current track
    // Simulate a queue without touching media_kit natives; setVolume triggers
    // notifyListeners without creating the Player.
    player.queueController.setQueue(lib.allTracks, 0);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
  });

  testWidgets('AlbumArt caches its future across rebuilds, only re-fetching on contentId change',
      (tester) async {
    var callCount = 0;
    Future<List<int>?> countingLoader(File f) async {
      callCount++;
      return null;
    }

    var contentId = 'x';
    late StateSetter setState;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setter) {
          setState = setter;
          return AlbumArt(
            contentId: contentId,
            file: File('nonexistent.mp3'),
            loader: countingLoader,
          );
        },
      ),
    ));
    await tester.pump();
    expect(callCount, 1);

    // Rebuild 3 times with the same contentId: loader must not re-fire.
    setState(() {});
    await tester.pump();
    setState(() {});
    await tester.pump();
    setState(() {});
    await tester.pump();
    expect(callCount, 1);

    // Changing contentId triggers exactly one more fetch.
    setState(() {
      contentId = 'y';
    });
    await tester.pump();
    expect(callCount, 2);
  });

  testWidgets('now-playing bar does not overflow at narrow window widths',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    player.queueController.setQueue(lib.allTracks, 0);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'now-playing bar centers the LCD cluster on a wide surface',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final lib = fixtureLibrary();
    final player = PlayerService();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));
    player.queueController.setQueue(lib.allTracks, 0);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The title text must be fully present (no fixed crop) inside the LCD
    // cluster (found by walking from the title text to its ancestor
    // cluster container), and the cluster itself (keyed 'lcd') must sit
    // centered on the window, not merely somewhere left-of-center next to
    // the transport controls. (The same title also appears in the track
    // list behind the bar, so scope the title lookup to inside the
    // cluster.)
    final clusterFinder = find.byKey(const Key('lcd'));
    expect(clusterFinder, findsOneWidget);
    expect(
      find.descendant(of: clusterFinder, matching: find.text('Newest Song')),
      findsOneWidget,
    );
    final center = tester.getCenter(clusterFinder);
    expect(center.dx, closeTo(700, 40));
  });

  testWidgets(
      'dragging the sidebar divider resizes the sidebar SizedBox by the drag delta',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    final layoutPrefs = LayoutPrefs();
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(
            library: lib,
            player: player,
            layoutPrefs: layoutPrefs,
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}))));

    SizedBox sidebarBox() =>
        tester.widget<SizedBox>(find.byKey(const Key('sidebar-panel')));

    final oldWidth = sidebarBox().width;
    expect(oldWidth, kSidebarWidthDefault);

    await tester.drag(
        find.byKey(const Key('sidebar-divider')), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(sidebarBox().width, oldWidth! + 80);
    expect(layoutPrefs.sidebarWidth, oldWidth + 80);
  });
}
