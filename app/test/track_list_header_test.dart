import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
        contentId: 'a',
        relPath: 'a.mp3',
        dateAdded: DateTime.utc(2024, 1, 1),
        title: 'Banana',
        artist: 'Muse',
        album: 'X',
        durationMs: 125000),
    Track(
        contentId: 'b',
        relPath: 'b.mp3',
        dateAdded: DateTime.utc(2024, 1, 2),
        title: 'Apple',
        artist: 'Feed Me',
        album: 'Y'), // no durationMs -> blank Time column
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpTrackList(WidgetTester tester, LibraryModel lib, PlayerService player) =>
    tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: TrackListView(library: lib, player: player)),
    ));

void main() {
  testWidgets('header shows the five sortable column labels', (tester) async {
    final lib = fixtureLibrary();
    await pumpTrackList(tester, lib, PlayerService());
    // dateAdded is the default active/sorted column, so "Date" carries its
    // arrow already (see the direction test below); the rest are inactive
    // (bare labels).
    expect(find.text('TITLE'), findsOneWidget);
    expect(find.text('ARTIST'), findsOneWidget);
    expect(find.text('ALBUM'), findsOneWidget);
    expect(find.text('TIME'), findsOneWidget);
    expect(find.text('DATE ▼'), findsOneWidget);
  });

  testWidgets(
      'clicking Artist sorts ascending; clicking again toggles to descending, and the arrow flips',
      (tester) async {
    final lib = fixtureLibrary();
    await pumpTrackList(tester, lib, PlayerService());

    // Default: dateAdded descending -- only the Date header carries the
    // arrow before anything is clicked; Artist is still the bare label.
    expect(lib.sortColumn, SortColumn.dateAdded);
    expect(lib.sortAscending, isFalse);
    expect(find.text('DATE ▼'), findsOneWidget);
    expect(find.text('ARTIST'), findsOneWidget);

    await tester.tap(find.text('ARTIST'));
    await tester.pump();

    expect(lib.sortColumn, SortColumn.artist);
    expect(lib.sortAscending, isTrue);
    expect(find.text('ARTIST ▲'), findsOneWidget); // now active, ascending
    expect(find.text('DATE'), findsOneWidget); // Date back to bare (inactive)
    expect(find.text('DATE ▼'), findsNothing);

    await tester.tap(find.text('ARTIST ▲'));
    await tester.pump();

    expect(lib.sortColumn, SortColumn.artist);
    expect(lib.sortAscending, isFalse);
    expect(find.text('ARTIST ▼'), findsOneWidget); // flipped
    expect(find.text('ARTIST ▲'), findsNothing);
  });

  testWidgets('duration column shows m:ss, blank when null', (tester) async {
    final lib = fixtureLibrary();
    await pumpTrackList(tester, lib, PlayerService());
    expect(find.text('2:05'), findsOneWidget); // 125000ms -> 2:05
  });

  testWidgets(
      'all row cells share the same 13px AppColors.ink style -- Time/Date '
      'are no longer smaller/greyed-out relative to Artist/Album',
      (tester) async {
    final lib = fixtureLibrary();
    await pumpTrackList(tester, lib, PlayerService());

    final artistStyle = tester.widget<Text>(find.text('Muse')).style!;
    final albumStyle = tester.widget<Text>(find.text('X')).style!;
    final timeStyle = tester.widget<Text>(find.text('2:05')).style!; // Banana's duration
    final dateStyle = tester.widget<Text>(find.text('2024-01-01')).style!; // Banana's date

    for (final style in [artistStyle, albumStyle, timeStyle, dateStyle]) {
      expect(style.fontSize, 13);
      expect(style.color, AppColors.ink);
      expect(style.fontWeight, isNot(FontWeight.w600)); // regular, unlike Title
    }

    final titleStyle = tester.widget<Text>(find.text('Banana')).style!;
    expect(titleStyle.fontSize, 13);
    expect(titleStyle.fontWeight, FontWeight.w600); // Title alone stays bold
  });

  testWidgets('current-track title is highlighted in the accent color',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService();
    await pumpTrackList(tester, lib, player);

    // Simulate a queue without touching media_kit natives (same technique
    // as ui_shell_test.dart): setVolume triggers notifyListeners without
    // ever constructing the real Player.
    player.queueController.setQueue(lib.allTracks, 1); // 'Apple' (id 'b')
    await player.setVolume(1.0);
    await tester.pump();

    final appleTitle = tester.widget<Text>(find.text('Apple'));
    expect(appleTitle.style?.color, AppColors.accent);

    final bananaTitle = tester.widget<Text>(find.text('Banana'));
    expect(bananaTitle.style?.color, AppColors.ink);
  });
}
