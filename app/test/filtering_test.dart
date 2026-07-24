import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/filtering.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, int day,
        {String title = 't', String artist = '', String album = '', String genre = ''}) =>
    Track(
        contentId: id,
        relPath: '$id.mp3',
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

  test('distinctValues dedupes case-insensitively, sorted', () {
    expect(distinctValues(lib, (t) => t.artist), ['Feed Me', 'Muse']);
    expect(distinctValues(lib, (t) => t.genre), ['Electronic', 'Rock']);
  });
}
