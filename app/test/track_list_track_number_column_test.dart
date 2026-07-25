// The '#' track-number column (see ui/track_list.dart) is only meaningful
// when the view is unambiguously ONE album's track order -- selected in
// the Albums pane (albumFilters) or as a single album folder in the Folder
// pane (LibraryModel.folderSelectionIsSingleAlbum) -- or a playlist's
// curator-defined position. Everywhere else (the full library, a
// genre/artist filter spanning many albums) numbers from different albums
// would collide meaninglessly, so the column stays hidden. In playlist mode
// the column shows the track's 1-based position in the playlist, not its
// (possibly unrelated) tag track number.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
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
        dateAdded: DateTime.utc(2024, 2, 1),
        title: 'Nine',
        artist: 'Muse',
        album: 'AlbumX',
        durationMs: 305000,
        trackNumber: 9),
    Track(
        contentId: 'b',
        relPath: 'b.mp3',
        dateAdded: DateTime.utc(2024, 2, 2),
        title: 'Four',
        artist: 'Feed Me',
        album: 'AlbumX',
        durationMs: 187000,
        trackNumber: 4),
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
  testWidgets('library mode (no album filter, no playlist): no # header, no track-number column',
      (tester) async {
    final lib = fixtureLibrary();
    await pumpTrackList(tester, lib, PlayerService());

    expect(find.text('#'), findsNothing);
    // Neither track's tag number should be rendered anywhere in the row.
    expect(find.text('9'), findsNothing);
    expect(find.text('4'), findsNothing);
  });

  testWidgets(
      'exactly one album selected: # header appears, rows show the tag track number',
      (tester) async {
    final lib = fixtureLibrary();
    lib.setAlbums({'AlbumX'}); // also switches sort to trackNumber ascending

    await pumpTrackList(tester, lib, PlayerService());

    // setAlbums makes trackNumber the active sort column, so (like every
    // other active header -- see track_list_header_test.dart's "DATE ▼"
    // assertions) the '#' header carries its direction arrow too -- left
    // aligned like every other non-right-aligned header (label then arrow).
    expect(find.text('# ▲'), findsOneWidget);
    // Ascending trackNumber: 'b' (4) before 'a' (9).
    expect(find.text('4'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets(
      'two albums selected at once: no # column (numbers from different '
      'albums would collide meaninglessly)', (tester) async {
    final lib = fixtureLibrary();
    lib.setAlbums({'AlbumX', 'AlbumY'});

    await pumpTrackList(tester, lib, PlayerService());

    expect(find.text('#'), findsNothing);
    expect(find.text('# ▲'), findsNothing);
  });

  testWidgets(
      'regression (#27): a single album FOLDER selected in the Folder pane '
      'shows the # column with tag numbers in track order -- the exact '
      'real-world shape: an `albums` library root holding one folder per '
      'album, reached by drill-down, where the column used to stay hidden '
      'because only albumFilters was consulted', (tester) async {
    const albumsRoot = r'L:\music (original structure)\albums';
    const dir = 'Alina Baraz & Galimatias - Urban Flora';
    Track urban(String id, String file, int n) => Track(
          contentId: id,
          relPath: '$dir/$file',
          rootPath: albumsRoot,
          dateAdded: DateTime.utc(2016, 3, 14),
          title: file,
          artist: 'Alina Baraz & Galimatias',
          album: 'Urban Flora',
          trackNumber: n,
        );
    final lib = LibraryModel();
    lib.allTracks = [
      // Deliberately out of track order in allTracks.
      urban('u3', '03 Can I.mp3', 3),
      urban('u1', '01 Show Me.mp3', 1),
      urban('u8', '08 Unfold.mp3', 8),
    ];
    lib.status = 'ready';

    // Navigate exactly as the user does: drill into the albums root, then
    // into the album's folder. No Albums-pane selection ever happens.
    lib.drillIntoFolder(albumsRoot);
    lib.drillIntoFolder(dir);
    expect(lib.albumFilters, isEmpty); // sanity: folder pane only

    await pumpTrackList(tester, lib, PlayerService());

    // Column visible, trackNumber the active ascending sort.
    expect(find.text('# ▲'), findsOneWidget);
    // Every tag track number rendered.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    // And in album track order, not date/insertion order.
    expect(lib.visibleTracks.map((t) => t.trackNumber), [1, 3, 8]);
  });

  testWidgets(
      'playlist mode: # header appears, rows show playlist POSITION, not the tag track number',
      (tester) async {
    final lib = fixtureLibrary();
    lib.playlists = [
      const ManifestPlaylist(name: 'mix', trackIds: ['a', 'b']), // a first, b second
    ];
    lib.setPlaylist('mix');

    await pumpTrackList(tester, lib, PlayerService());

    expect(find.text('#'), findsOneWidget);
    // Positions (1-based), not the tag numbers (9 and 4).
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('9'), findsNothing);
    expect(find.text('4'), findsNothing);
  });
}
