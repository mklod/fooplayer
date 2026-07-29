// Telling a compilation from an album, without being told.
//
// Artwork is filed per album, identified by artist + title. On a
// various-artists record that produces one "album" per track, each asking a
// provider for a release nobody made -- "Anberlin - Alternative Times Vol
// 110". Measured on Mike's library: 119 folders in the `alternative times`
// root produced 2,394 separate artwork entries, and 2,023 of its tracks had
// no cover.
//
// The files cannot answer the question (312 of 400 sampled carry no
// album-artist frame, none carry a compilation flag), so it is inferred, and
// these tests are the inference: what counts, what doesn't, and that the two
// cases key differently without ever colliding.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/album_key.dart';
import 'package:fooplayer_app/artwork/compilation.dart';
import 'package:fooplayer_app/model/track.dart';

Track _t({
  required String artist,
  required String album,
  String folder = 'VA-Alternative_Times_Vol_110',
  String file = 'song.mp3',
  String root = r'L:\alt',
}) => Track(
  contentId: '$folder/$file',
  relPath: '$folder/$file',
  rootPath: root,
  dateAdded: DateTime.utc(2009),
  title: 'A Title',
  artist: artist,
  album: album,
);

/// [n] tracks in one folder, each by a different artist.
List<Track> _various(int n, {String album = 'Alternative Times Vol 110'}) => [
  for (var i = 0; i < n; i++)
    _t(artist: 'Artist $i', album: album, file: 'track$i.mp3'),
];

void main() {
  group('the rule', () {
    test('a 23-track volume with 23 artists is a compilation', () {
      final marked = markCompilations(_various(23));
      expect(marked.every((t) => t.isCompilation), isTrue);
    });

    test('a normal album is not, however many tracks', () {
      final album = [
        for (var i = 0; i < 12; i++)
          _t(artist: 'Portishead', album: 'Dummy', file: 'track$i.mp3'),
      ];
      expect(markCompilations(album).any((t) => t.isCompilation), isFalse);
    });

    test('an album with a few guest features is still an album', () {
      // Twelve tracks, four distinct names in the artist field. This is the
      // case a raw "more than two artists" rule would get wrong.
      final tracks = [
        for (var i = 0; i < 12; i++)
          _t(
            artist: i < 3 ? 'Kanye West feat. Guest $i' : 'Kanye West',
            album: 'Graduation',
            file: 'track$i.mp3',
          ),
      ];
      expect(markCompilations(tracks).any((t) => t.isCompilation), isFalse);
      expect(isCompilationGroup(artists: 4, tracks: 12), isFalse);
    });

    test('two artists is a split single, not a compilation', () {
      expect(isCompilationGroup(artists: 2, tracks: 2), isFalse);
      expect(isCompilationGroup(artists: 3, tracks: 3), isTrue);
    });

    test('loose singles sharing a folder are untouched', () {
      // A date folder of unrelated downloads: different artists, but no
      // album tag, so each is its own thing and none is a compilation.
      final loose = [
        for (var i = 0; i < 8; i++)
          _t(artist: 'Artist $i', album: '', folder: '2007-09',
              file: 'song$i.mp3'),
      ];
      expect(markCompilations(loose).any((t) => t.isCompilation), isFalse);
    });

    test('two volumes in different folders are judged separately', () {
      final tracks = [
        ..._various(6),
        for (var i = 0; i < 6; i++)
          _t(
            artist: 'Radiohead',
            album: 'OK Computer',
            folder: 'Radiohead - OK Computer',
            file: 'track$i.mp3',
          ),
      ];
      final marked = markCompilations(tracks);
      expect(marked.where((t) => t.isCompilation), hasLength(6));
      expect(
        marked.where((t) => t.isCompilation).every((t) => t.album.contains('Alternative')),
        isTrue,
      );
    });

    test('an unchanged list is returned as the same instance', () {
      final album = [_t(artist: 'A', album: 'B')];
      expect(identical(markCompilations(album), album), isTrue);
    });

    test('an empty list is fine', () {
      expect(markCompilations(const []), isEmpty);
    });
  });

  group('the key', () {
    test('every track of a compilation lands on one key', () {
      final marked = markCompilations(_various(23));
      final keys = marked.map(albumKeyForTrack).toSet();
      expect(keys, hasLength(1), reason: '23 tracks, one cover');
    });

    test('the key carries no artist, and cannot look like one', () {
      final key = albumKeyForTrack(markCompilations(_various(5)).first);
      expect(key.contains('Artist'), isFalse);
      expect(key.startsWith('\x02'), isTrue);
      expect(
        key.contains('va-alternative_times_vol_110'),
        isTrue,
        reason: 'folder-scoped, so two "Greatest Hits" never pool',
      );
    });

    test('two same-titled compilations in different folders stay apart', () {
      final a = markCompilations(_various(4, album: 'Greatest Hits'));
      final b = markCompilations([
        for (var i = 0; i < 4; i++)
          _t(
            artist: 'Artist $i',
            album: 'Greatest Hits',
            folder: 'Some Other Comp',
            file: 'track$i.mp3',
          ),
      ]);
      expect(albumKeyForTrack(a.first), isNot(albumKeyForTrack(b.first)));
    });

    test('a normal album keeps the artist|album key it always had', () {
      final t = _t(artist: 'Portishead', album: 'Dummy');
      expect(albumKeyForTrack(t), 'portishead|dummy');
    });

    test('a compilation key can never collide with an ordinary one', () {
      // Both markers are control characters, which the normalizer strips from
      // every real artist and album string.
      final comp = albumKeyForTrack(markCompilations(_various(3)).first);
      final plain = albumKeyForTrack(_t(artist: 'X', album: 'Y'));
      expect(comp.contains('|'), isTrue);
      expect(plain.contains('\x02'), isFalse);
      expect(comp, isNot(plain));
    });
  });
}
