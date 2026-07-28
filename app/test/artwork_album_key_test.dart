// Last modified: 2026-07-25--2115
//
// Plan 4 / A2: the shared album-key normalizer. The key is what ties every
// track of an album to one artwork entry (and, at merge time, what A1's
// scorer normalizes with), so its edge cases are pinned here.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/album_key.dart';

void main() {
  group('normalizeArtworkText', () {
    test('lowercases and collapses whitespace', () {
      expect(normalizeArtworkText('  The   BLACK   Keys '), 'the black keys');
    });

    test('drops bracketed suffixes', () {
      expect(
        normalizeArtworkText('Random Access Memories (Deluxe Edition)'),
        'random access memories',
      );
      expect(normalizeArtworkText('Yeezus [Explicit]'), 'yeezus');
      expect(normalizeArtworkText('Kid A {2009 Remaster}'), 'kid a');
    });

    test('drops trailing dash-qualifiers, including stacked ones', () {
      expect(normalizeArtworkText('Bloom - EP'), 'bloom');
      expect(normalizeArtworkText('Blue Lips - Single'), 'blue lips');
      expect(
        normalizeArtworkText('OK Computer - 2017 Remaster'),
        'ok computer',
      );
      expect(
        normalizeArtworkText('Nevermind - Deluxe Edition - Remastered'),
        'nevermind',
      );
    });

    test('folds diacritics', () {
      expect(normalizeArtworkText('RÜFÜS DU SOL'), 'rufus du sol');
      expect(normalizeArtworkText('Sigur Rós'), 'sigur ros');
      expect(normalizeArtworkText('Motörhead'), 'motorhead');
      expect(normalizeArtworkText('Æther'), 'aether');
    });

    test('strips punctuation so spelling variants converge', () {
      expect(
        normalizeArtworkText("Rock 'n' Roll"),
        normalizeArtworkText('Rock n Roll'),
      );
      expect(normalizeArtworkText('Vol. 2'), normalizeArtworkText('Vol 2'));
      expect(normalizeArtworkText('AC/DC'), 'ac dc');
    });

    test('is total: null/blank/punctuation-only input yields empty', () {
      expect(normalizeArtworkText(null), '');
      expect(normalizeArtworkText('   '), '');
      expect(normalizeArtworkText('!!!...'), '');
    });
  });

  group('artworkAlbumKey', () {
    test('is artist|album, normalized on both sides', () {
      expect(
        artworkAlbumKey(artist: 'Sigur Rós', album: '( )', title: 'Untitled 1'),
        'sigur ros|untitled 1',
      );
      expect(
        artworkAlbumKey(artist: 'Daft Punk', album: 'Discovery'),
        'daft punk|discovery',
      );
    });

    test(
      'every track of an album shares one key regardless of edition noise',
      () {
        final a = artworkAlbumKey(
          artist: 'Radiohead',
          album: 'OK Computer',
          title: 'Airbag',
        );
        final b = artworkAlbumKey(
          artist: 'radiohead',
          album: 'OK Computer (Deluxe Edition)',
          title: 'Karma Police',
        );
        expect(a, b);
      },
    );

    test('empty album falls back to a single-track artist|title key', () {
      expect(
        artworkAlbumKey(artist: 'Aphex Twin', album: '', title: 'Avril 14th'),
        'aphex twin|avril 14th',
      );
      // Two loose files by the same artist must NOT collapse onto one key.
      expect(
        artworkAlbumKey(artist: 'Aphex Twin', album: '', title: 'Avril 14th'),
        isNot(artworkAlbumKey(artist: 'Aphex Twin', album: '', title: 'Xtal')),
      );
    });

    group('fully-untagged fallback (adversarial review finding 7)', () {
      test('artist AND album both blank: two different files with the SAME '
          'filename-derived title in DIFFERENT folders no longer collide', () {
        // Exactly the reported scenario: two untagged rips, each named
        // "01.mp3", in two different album folders. Before the fix both
        // produced the identical key '|01' and shared one artwork entry.
        final a = artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
          rootPath: r'L:\music',
          relPath: r'Album A\01.mp3',
        );
        final b = artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
          rootPath: r'L:\music',
          relPath: r'Album B\01.mp3',
        );
        expect(a, isNot(b));
      });

      test('the OLD title-collapsed key is what the pre-fix code produced', () {
        // Documents the exact regression: with no rootPath/relPath at all
        // (the pre-fix call shape), both untagged "01.mp3" files really did
        // collapse onto the same key -- this is the bug, pinned so the fix
        // above is legible against it.
        final withoutFileIdentity = artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
        );
        expect(withoutFileIdentity, '|01');
      });

      test('same file, same call, is idempotent (stable across resolves)', () {
        String key() => artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
          rootPath: r'L:\music',
          relPath: r'Album A\01.mp3',
        );
        expect(key(), key());
      });

      test('different tracks of the SAME untagged file (rootPath+relPath) '
          'still key identically, so re-resolving the same file is a cache '
          'hit', () {
        final first = artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
          rootPath: r'L:\music',
          relPath: r'Album A\01.mp3',
        );
        final second = artworkAlbumKey(
          artist: '',
          album: '',
          title: '01',
          rootPath: r'L:\music',
          relPath: r'Album A\01.mp3',
        );
        expect(first, second);
      });

      test('a blank title does not change the outcome -- rootPath/relPath '
          'alone is enough to disambiguate', () {
        final a = artworkAlbumKey(
          artist: '',
          album: '',
          rootPath: r'L:\music',
          relPath: r'Album A\01.mp3',
        );
        final b = artworkAlbumKey(
          artist: '',
          album: '',
          rootPath: r'L:\music',
          relPath: r'Album B\01.mp3',
        );
        expect(a, isNot(b));
      });

      test('artist present but album blank is UNAFFECTED (only the fully '
          'blank case changes)', () {
        // A track with a real artist tag already disambiguates well enough
        // via artist|title -- this finding is scoped to artist AND album
        // both being blank, so this case's behavior must not change even
        // when rootPath/relPath are supplied.
        expect(
          artworkAlbumKey(
            artist: 'Aphex Twin',
            album: '',
            title: 'Avril 14th',
            rootPath: r'L:\music',
            relPath: r'Selected Ambient Works\01.mp3',
          ),
          'aphex twin|avril 14th',
        );
      });

      test('no rootPath/relPath given (e.g. a file-less ArtworkQuery '
          'lookup) keeps the old artist|title fallback -- nothing to key '
          'the file identity off of', () {
        expect(
          artworkAlbumKey(artist: '', album: '', title: 'Untitled'),
          '|untitled',
        );
      });
    });
  });

  group('artworkHash', () {
    test('is stable, 16 hex chars, and filename-safe', () {
      final h = artworkHash('daft punk|discovery');
      expect(h, artworkHash('daft punk|discovery'));
      expect(h.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(h), isTrue);
    });

    test('different keys hash differently', () {
      expect(artworkHash('a|b'), isNot(artworkHash('a|c')));
      expect(artworkHash(''), isNot(artworkHash('x')));
    });
  });
}
