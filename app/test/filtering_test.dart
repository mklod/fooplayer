import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/filtering.dart';
import 'package:fooplayer_app/model/track.dart';

Track _trackAt(String relPath, {String rootPath = r'L:\Music'}) => Track(
      contentId: relPath,
      relPath: relPath,
      rootPath: rootPath,
      dateAdded: DateTime.utc(2024, 1, 1),
      title: relPath,
    );

Track tr(String id, int day,
        {String title = 't',
        String artist = '',
        String album = '',
        String genre = '',
        String rootPath = ''}) =>
    Track(
        contentId: id,
        relPath: '$id.mp3',
        rootPath: rootPath,
        dateAdded: DateTime.utc(2024, 1, day),
        title: title,
        artist: artist,
        album: album,
        genre: genre);

void main() {
  final lib = [
    tr('a', 1, title: 'Alpha', artist: 'Muse', album: 'Origin', genre: 'Rock'),
    tr('b', 3, title: 'Beta', artist: 'Muse', album: 'Absolution', genre: 'Rock'),
    tr('c', 2, title: 'Gamma', artist: 'Feed Me', album: 'Calamari', genre: 'Electronic'),
    tr('d', 4, title: 'delta', artist: 'muse', album: 'Origin', genre: ''),
  ];

  test('sortByDateAddedDesc newest first, input not mutated', () {
    final sorted = sortByDateAddedDesc(lib);
    expect(sorted.map((t) => t.contentId).toList(), ['d', 'b', 'c', 'a']);
    expect(lib.first.contentId, 'a');
  });

  test('applyFilters ANDs genre/artist and search', () {
    expect(applyFilters(lib, genre: 'Rock').length, 2);
    expect(applyFilters(lib, genre: 'Rock', artist: {'Muse'}).length, 2);
    expect(applyFilters(lib, search: 'mus').length, 3); // case-insensitive artist match
    expect(applyFilters(lib, genre: 'Rock', search: 'beta').single.contentId, 'b');
  });

  test('null/empty filter matches all; genre filter excludes empty-genre tracks', () {
    expect(applyFilters(lib).length, 4);
    expect(applyFilters(lib, genre: 'Rock').map((t) => t.contentId), isNot(contains('d')));
  });

  test('applyFilters rootPath matches Track.rootPath exactly (folder filter)', () {
    final withRoots = [
      tr('a', 1, title: 'Alpha', rootPath: r'L:\Music\RootA'),
      tr('b', 2, title: 'Beta', rootPath: r'L:\Music\RootB'),
      tr('c', 3, title: 'Gamma', rootPath: r'L:\Music\RootA'),
    ];
    expect(
        applyFilters(withRoots, rootPath: {r'L:\Music\RootA'}).map((t) => t.contentId),
        ['a', 'c']);
    expect(applyFilters(withRoots, rootPath: const {}).length, 3);
    // Exact match -- a differently-cased path does not match.
    expect(applyFilters(withRoots, rootPath: {r'l:\music\roota'}), isEmpty);
  });

  test('applyFilters artist/album sets OR within the panel, case-insensitively', () {
    // Two artists selected: tracks from either match (union), not just one.
    expect(
        applyFilters(lib, artist: {'Muse', 'Feed Me'}).map((t) => t.contentId).toSet(),
        {'a', 'b', 'c', 'd'}); // Muse/muse (a,b,d) + Feed Me (c)
    // A single selected value still narrows as before.
    expect(applyFilters(lib, artist: {'Feed Me'}).single.contentId, 'c');
    // Case-insensitive membership, same as the old single-value [eq].
    expect(applyFilters(lib, artist: {'MUSE'}).map((t) => t.contentId).toSet(),
        {'a', 'b', 'd'});
    // Album set ORs the same way, and ANDs with a simultaneous artist set.
    expect(
        applyFilters(lib, artist: {'Muse'}, album: {'Origin', 'Absolution'})
            .map((t) => t.contentId)
            .toSet(),
        {'a', 'b', 'd'});
  });

  test('distinctValues dedupes case-insensitively, sorted', () {
    expect(distinctValues(lib, (t) => t.artist), ['Feed Me', 'Muse']);
    expect(distinctValues(lib, (t) => t.genre), ['Electronic', 'Rock']);
  });

  test(
      'regression (adversarial review, LOW): trackInFolderScope matches the '
      'sub prefix case-insensitively, mirroring subfolderNames\' '
      'casing-agnostic dedupe', () {
    const scope = (root: r'L:\Music', sub: 'Rock');
    // A case-sensitive filesystem can hold both "Rock/x.mp3" and
    // "rock/y.mp3" as distinct tracks; subfolderNames merges them into one
    // Folder-pane entry ("Rock", first casing seen), so selecting it must
    // not silently drop the differently-cased one.
    expect(trackInFolderScope(_trackAt('Rock/x.mp3'), scope), isTrue);
    expect(trackInFolderScope(_trackAt('rock/y.mp3'), scope), isTrue);
    expect(trackInFolderScope(_trackAt('ROCK/z.mp3'), scope), isTrue);
    // Still segment-safe: a longer sibling name is not a false match.
    expect(trackInFolderScope(_trackAt('Rocket/w.mp3'), scope), isFalse);
    // Still root-sensitive: exact root match required regardless of casing.
    expect(
        trackInFolderScope(
            _trackAt('Rock/x.mp3', rootPath: r'L:\OtherMusic'), scope),
        isFalse);
  });

  group('isSingleAlbum (backs the Folder-pane album view, #27)', () {
    test('all tracks sharing one non-empty album -> true', () {
      expect(
          isSingleAlbum([
            tr('a', 1, album: 'Urban Flora'),
            tr('b', 2, album: 'Urban Flora'),
          ]),
          isTrue);
    });

    test('album comparison is case-insensitive, like applyFilters', () {
      expect(
          isSingleAlbum([
            tr('a', 1, album: 'Urban Flora'),
            tr('b', 2, album: 'urban flora'),
          ]),
          isTrue);
    });

    test('two different albums -> false', () {
      expect(
          isSingleAlbum([
            tr('a', 1, album: 'Urban Flora'),
            tr('b', 2, album: 'Origin'),
          ]),
          isFalse);
    });

    test('any empty-album track disqualifies the set', () {
      expect(
          isSingleAlbum([
            tr('a', 1, album: 'Urban Flora'),
            tr('b', 2, album: ''),
          ]),
          isFalse);
    });

    test('empty list -> false (nothing to show a track order for)', () {
      expect(isSingleAlbum(const []), isFalse);
    });
  });
}
