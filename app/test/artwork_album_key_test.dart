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
      expect(normalizeArtworkText('Random Access Memories (Deluxe Edition)'),
          'random access memories');
      expect(normalizeArtworkText('Yeezus [Explicit]'), 'yeezus');
      expect(normalizeArtworkText('Kid A {2009 Remaster}'), 'kid a');
    });

    test('drops trailing dash-qualifiers, including stacked ones', () {
      expect(normalizeArtworkText('Bloom - EP'), 'bloom');
      expect(normalizeArtworkText('Blue Lips - Single'), 'blue lips');
      expect(normalizeArtworkText('OK Computer - 2017 Remaster'), 'ok computer');
      expect(normalizeArtworkText('Nevermind - Deluxe Edition - Remastered'),
          'nevermind');
    });

    test('folds diacritics', () {
      expect(normalizeArtworkText('RÜFÜS DU SOL'), 'rufus du sol');
      expect(normalizeArtworkText('Sigur Rós'), 'sigur ros');
      expect(normalizeArtworkText('Motörhead'), 'motorhead');
      expect(normalizeArtworkText('Æther'), 'aether');
    });

    test('strips punctuation so spelling variants converge', () {
      expect(normalizeArtworkText("Rock 'n' Roll"),
          normalizeArtworkText('Rock n Roll'));
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

    test('every track of an album shares one key regardless of edition noise',
        () {
      final a = artworkAlbumKey(
          artist: 'Radiohead', album: 'OK Computer', title: 'Airbag');
      final b = artworkAlbumKey(
          artist: 'radiohead',
          album: 'OK Computer (Deluxe Edition)',
          title: 'Karma Police');
      expect(a, b);
    });

    test('empty album falls back to a single-track artist|title key', () {
      expect(
        artworkAlbumKey(artist: 'Aphex Twin', album: '', title: 'Avril 14th'),
        'aphex twin|avril 14th',
      );
      // Two loose files by the same artist must NOT collapse onto one key.
      expect(
        artworkAlbumKey(artist: 'Aphex Twin', album: '', title: 'Avril 14th'),
        isNot(artworkAlbumKey(
            artist: 'Aphex Twin', album: '', title: 'Xtal')),
      );
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
