// Last modified: 2026-07-24--1855
//
// Widget tests for PhoneSearchPage: opened from the shell's AppBar search
// icon, its AppBar TextField live-filters the feed (title/artist/album
// substring), results play on tap, and the query stays local (backing out
// leaves LibraryModel.search untouched).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/phone_search_page.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'old',
      relPath: 'old.mp3',
      dateAdded: DateTime.utc(2020, 1, 1),
      title: 'Oldest Song',
      artist: 'Feed Me',
      album: 'Calamari Tuesday',
    ),
    Track(
      contentId: 'new',
      relPath: 'new.mp3',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: 'Newest Song',
      artist: 'Muse',
      album: 'Absolution',
    ),
  ];
  m.status = 'ready';
  return m;
}

void main() {
  testWidgets('search icon opens the page; typing filters the feed live', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    final played = <(List<Track>, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PhoneShell(
          library: lib,
          player: PlayerService(),
          onPlayTrack: (tracks, index) => played.add((tracks, index)),
          onTrackLongPress: (_, _) {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('phone-search')));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneSearchPage), findsOneWidget);
    // Empty query: the whole feed shows.
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsOneWidget);

    // Artist substring match, case-insensitive, filtering live.
    await tester.enterText(find.byKey(const Key('phone-search-field')), 'muse');
    await tester.pump();
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsNothing);

    // Tap plays from the RESULT list (queue = what's on screen).
    await tester.tap(find.text('Newest Song'));
    await tester.pump();
    expect(played, hasLength(1));
    final (queue, index) = played.single;
    expect(queue.map((t) => t.title).toList(), ['Newest Song']);
    expect(index, 0);

    // The page's query is local -- the library's own search filter (used
    // by the desktop panels) must remain untouched.
    expect(lib.search, isEmpty);

    // Clearing restores the full feed.
    await tester.enterText(find.byKey(const Key('phone-search-field')), '');
    await tester.pump();
    expect(find.text('Oldest Song'), findsOneWidget);
  });

  testWidgets('no match shows an empty result list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PhoneSearchPage(
          library: fixtureLibrary(),
          onPlayTrack: (_, _) {},
          onTrackLongPress: (_, _) {},
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('phone-search-field')),
      'zzz no such',
    );
    await tester.pump();
    expect(find.text('Newest Song'), findsNothing);
    expect(find.text('Oldest Song'), findsNothing);
  });
}
