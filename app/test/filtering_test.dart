import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/filtering.dart';
import 'package:fooplayer_app/model/track.dart';

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
    expect(applyFilters(lib, genre: 'Rock', artist: 'Muse').length, 2);
    expect(applyFilters(lib, search: 'mus').length, 3); // case-insensitive artist match
    expect(applyFilters(lib, genre: 'Rock', search: 'beta').single.contentId, 'b');
  });

  test('null filter matches all; genre filter excludes empty-genre tracks', () {
    expect(applyFilters(lib).length, 4);
    expect(applyFilters(lib, genre: 'Rock').map((t) => t.contentId), isNot(contains('d')));
  });

  test('applyFilters rootPath matches Track.rootPath exactly (folder filter)', () {
    final withRoots = [
      tr('a', 1, title: 'Alpha', rootPath: r'L:\Music\RootA'),
      tr('b', 2, title: 'Beta', rootPath: r'L:\Music\RootB'),
      tr('c', 3, title: 'Gamma', rootPath: r'L:\Music\RootA'),
    ];
    expect(applyFilters(withRoots, rootPath: r'L:\Music\RootA').map((t) => t.contentId),
        ['a', 'c']);
    expect(applyFilters(withRoots, rootPath: null).length, 3);
    // Exact match -- a differently-cased path does not match.
    expect(applyFilters(withRoots, rootPath: r'l:\music\roota'), isEmpty);
  });

  test('distinctValues dedupes case-insensitively, sorted', () {
    expect(distinctValues(lib, (t) => t.artist), ['Feed Me', 'Muse']);
    expect(distinctValues(lib, (t) => t.genre), ['Electronic', 'Rock']);
  });
}
