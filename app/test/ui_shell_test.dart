import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/home_screen.dart';

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
        theme: ThemeData.dark(useMaterial3: true),
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
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(library: lib, player: player)));
    await tester.tap(find.text('mix'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);
  });
}
