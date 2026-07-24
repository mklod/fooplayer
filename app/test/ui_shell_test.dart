import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(contentId: 'a', relPath: 'a.mp3', dateAdded: DateTime.utc(2026, 7, 1), title: 'Newest Song', artist: 'Muse', album: 'X', genre: 'Rock'),
    Track(contentId: 'b', relPath: 'b.mp3', dateAdded: DateTime.utc(2020, 1, 1), title: 'Oldest Song', artist: 'Feed Me', album: 'Y', genre: 'Electronic'),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['b'])];
  m.status = 'ready';
  return m;
}

void main() {
  testWidgets('shows feed newest-first with sidebar playlists', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(library: lib, player: player)));
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
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(library: lib, player: player)));
    await tester.tap(find.text('mix'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);
  });

  testWidgets('genre selection cascades into artist panel and track list',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(library: lib, player: player)));
    // Both artists visible initially in the Artist panel.
    expect(find.text('Muse'), findsWidgets);
    expect(find.text('Feed Me'), findsWidgets);
    await tester.tap(find.text('Rock')); // select genre
    await tester.pumpAndSettle();
    expect(lib.genreFilter, 'Rock');
    expect(find.text('Feed Me'), findsNothing); // filtered out everywhere
    expect(find.text('Oldest Song'), findsNothing); // track list narrowed
    await tester.tap(find.text('Rock')); // tap again clears
    await tester.pumpAndSettle();
    expect(lib.genreFilter, isNull);
    expect(find.text('Oldest Song'), findsOneWidget);
  });

  testWidgets('now-playing bar hidden with no track, transport icons exist otherwise',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(library: lib, player: player)));
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
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(library: lib, player: player)));
    player.queueController.setQueue(lib.allTracks, 0);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
