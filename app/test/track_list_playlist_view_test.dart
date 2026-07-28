// The distinct playlist-view track-list layout (see ui/track_list.dart's
// _TrackListHeader/_TrackRow docs): when a playlist is the active view
// (LibraryModel.activePlaylist != null), the track list switches from the
// library's five sortable columns (Title/Artist/Album/Time/Date) to an
// iTunes-style four-column layout -- #, Song (small artwork thumbnail +
// title/artist stacked), Album, Time -- with plain (non-sortable) header
// labels and no Date column. The library view's own columns/sort headers are
// untouched (see track_list_header_test.dart for that regression coverage);
// selection/double-click/context-menu plumbing is shared between the two
// layouts (see track_list_multiselect_test.dart / playlist_ui_test.dart for
// the rest of that coverage in playlist mode -- this file only adds what
// those don't already pin: the new column shape, playlist-position pinning
// against mismatched tag numbers, and per-row artwork wiring).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart' show AlbumArt;
import 'package:fooplayer_app/ui/track_list.dart';

/// Three tracks whose TAG track numbers are deliberately unrelated to (and
/// non-overlapping with) the 1/2/3 playlist positions the 'mix' playlist
/// below will assign them, and to each other -- so any test that finds '1',
/// '2' or '3' can only be seeing playlist positions, and any test that finds
/// '42', '7' or '99' can only be seeing tag numbers leaking through.
LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      dateAdded: DateTime.utc(2024, 1, 1),
      title: 'Third Wheel',
      artist: 'Artist A',
      album: 'Album A',
      trackNumber: 42,
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      dateAdded: DateTime.utc(2024, 1, 2),
      title: 'Solo Star',
      artist: 'Artist B',
      album: 'Album B',
      trackNumber: 7,
    ),
    Track(
      contentId: 'c',
      relPath: 'c.mp3',
      dateAdded: DateTime.utc(2024, 1, 3),
      title: 'Wildcard',
      artist: 'Artist C',
      album: 'Album C',
      trackNumber: 99,
    ),
  ];
  // Playlist order b, c, a -> positions b=1, c=2, a=3 -- deliberately not the
  // allTracks insertion order and not the tag-number order either.
  m.playlists = [
    const ManifestPlaylist(name: 'mix', trackIds: ['b', 'c', 'a']),
  ];
  m.status = 'ready';
  return m;
}

/// Pure, in-memory [ArtworkResolver] stand-in (same technique as
/// artwork_ui_wiring_test.dart's FakeResolver): records every request and
/// never touches disk, so this file's wiring test can't flake on real file
/// I/O.
class _FakeResolver extends ArtworkResolver {
  _FakeResolver() : super(stores: ArtworkStoreRegistry(appDataDir: Directory('.')));

  final List<ArtworkRequest> requests = [];

  @override
  Future<List<int>?> resolve(ArtworkRequest req) async {
    requests.add(req);
    return null;
  }
}

Future<void> pumpTrackList(
  WidgetTester tester,
  LibraryModel lib,
  PlayerService player, {
  ArtworkResolver? artworkResolver,
  void Function(List<Track>, int)? onPlayTrack,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: TrackListView(
        library: lib,
        player: player,
        artworkResolver: artworkResolver,
        onPlayTrack: onPlayTrack,
      ),
    ),
  ),
);

/// Same double-click simulation as track_list_interaction_test.dart /
/// track_list_multiselect_test.dart.
Future<void> doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
}

/// The row containing [title] -- same ancestor-AnimatedContainer technique
/// track_list_interaction_test.dart's `_rowFillColor` uses to scope an
/// assertion to one specific row.
Finder rowOf(String title) => find
    .ancestor(of: find.text(title), matching: find.byType(AnimatedContainer))
    .first;

void main() {
  group('playlist view: distinct four-column layout', () {
    testWidgets(
        'header shows #, SONG, ALBUM, TIME -- no Date, no Title/Artist split',
        (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      await pumpTrackList(tester, lib, PlayerService());

      expect(find.text('#'), findsOneWidget);
      expect(find.text('SONG'), findsOneWidget);
      expect(find.text('ALBUM'), findsOneWidget);
      expect(find.text('TIME'), findsOneWidget);
      expect(find.text('DATE'), findsNothing);
      expect(find.text('TITLE'), findsNothing);
      expect(find.text('ARTIST'), findsNothing);
    });

    testWidgets(
        'playlist headers are plain labels, not sort controls: tapping one '
        'does not change LibraryModel.sortColumn', (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      await pumpTrackList(tester, lib, PlayerService());

      final before = lib.sortColumn;
      await tester.tap(find.text('SONG'));
      await tester.pump();
      expect(lib.sortColumn, before);

      await tester.tap(find.text('ALBUM'));
      await tester.pump();
      expect(lib.sortColumn, before);

      // And no arrow ever appears next to a playlist header label (arrows
      // are how the library view marks the active sort column).
      expect(find.textContaining('▲'), findsNothing);
      expect(find.textContaining('▼'), findsNothing);
    });

    testWidgets(
        'library (non-playlist) view is unaffected: still the five sortable '
        'columns, no artwork thumbnails', (tester) async {
      final lib = fixtureLibrary(); // activePlaylist stays null
      await pumpTrackList(tester, lib, PlayerService());

      expect(find.text('TITLE'), findsOneWidget);
      expect(find.text('ARTIST'), findsOneWidget);
      expect(find.text('ALBUM'), findsOneWidget);
      expect(find.text('TIME'), findsOneWidget);
      expect(find.text('DATE'), findsNothing); // dateAdded is active sort
      expect(find.text('DATE ▼'), findsOneWidget);
      expect(find.text('SONG'), findsNothing);
      expect(find.byType(AlbumArt), findsNothing);
    });

    testWidgets(
        "position numbers are the playlist's 1-based order, not tag track "
        'numbers -- pinned per-row against a fixture whose tag numbers are '
        'scrambled relative to playlist order', (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      await pumpTrackList(tester, lib, PlayerService());

      // Tag numbers must never leak into the '#' column.
      expect(find.text('42'), findsNothing);
      expect(find.text('7'), findsNothing);
      expect(find.text('99'), findsNothing);

      // Playlist order b, c, a -> positions 1, 2, 3, pinned to the row that
      // actually holds each title (not just "somewhere in the tree").
      expect(find.descendant(of: rowOf('Solo Star'), matching: find.text('1')),
          findsOneWidget);
      expect(find.descendant(of: rowOf('Wildcard'), matching: find.text('2')),
          findsOneWidget);
      expect(find.descendant(of: rowOf('Third Wheel'), matching: find.text('3')),
          findsOneWidget);
    });
  });

  group('playlist view: row artwork', () {
    testWidgets(
        'each row renders its own AlbumArt thumbnail, keyed to its track -- '
        'and the list still works when no resolver is provided',
        (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      await pumpTrackList(tester, lib, PlayerService());
      await tester.pumpAndSettle();

      final art = tester.widgetList<AlbumArt>(find.byType(AlbumArt)).toList();
      expect(art.length, 3);
      expect(art.map((w) => w.contentId).toSet(), {'a', 'b', 'c'});
      // Scaled-down square thumbnail, distinct from the now-playing bar's
      // own sizes (56 default / 200 big / 44 compact).
      expect(art.every((w) => w.size == 36), isTrue);
      expect(art.every((w) => w.resolver == null), isTrue);

      // Selection/double-click still resolve fine with rows built this way.
      await tester.tap(find.text('Solo Star'));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      expect(lib.selectedTrackIds, {'b'});
    });

    testWidgets(
        "with an artworkResolver wired, every row's thumbnail resolves "
        'through it (not the embedded-only fallback loader)', (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      final resolver = _FakeResolver();
      await pumpTrackList(tester, lib, PlayerService(),
          artworkResolver: resolver);
      await tester.pumpAndSettle();

      final art = tester.widgetList<AlbumArt>(find.byType(AlbumArt)).toList();
      expect(art.length, 3);
      expect(art.every((w) => identical(w.resolver, resolver)), isTrue);
      expect(resolver.requests.length, 3);
      expect(resolver.requests.map((r) => r.albumKey).toSet(),
          {'artist a|album a', 'artist b|album b', 'artist c|album c'});
    });
  });

  group('playlist view: existing row behaviors survive the new layout', () {
    testWidgets('double-click plays and selects the right track',
        (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      final played = <Track>[];
      var playedIndex = -1;
      await pumpTrackList(
        tester,
        lib,
        PlayerService(),
        onPlayTrack: (tracks, index) {
          played
            ..clear()
            ..addAll(tracks);
          playedIndex = index;
        },
      );

      await doubleTap(tester, find.text('Wildcard'));

      // Playlist order b, c, a -> 'Wildcard' (c) is index 1.
      expect(playedIndex, 1);
      expect(played[playedIndex].contentId, 'c');
      expect(lib.selectedTrackIds, {'c'});
    });

    testWidgets('right-click still opens the context menu on a playlist row',
        (tester) async {
      final lib = fixtureLibrary();
      lib.setPlaylist('mix');
      await pumpTrackList(tester, lib, PlayerService());

      await tester.tap(find.text('Solo Star'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('View in folder'), findsOneWidget);
      expect(find.text('Remove from playlist'), findsOneWidget);
    });
  });
}
