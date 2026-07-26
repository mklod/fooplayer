// Scorer tests. Pure functions plus fixture-driven ranking -- no IO, no
// network, no clock.
//
// Last modified: 2026-07-25--2113

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/providers.dart';
import 'package:fooplayer_app/artwork/scoring.dart';

import 'support/artwork_fixtures.dart';

const itunesHost = 'itunes.apple.com';
const deezerHost = 'api.deezer.com';
const mbHost = 'musicbrainz.org';

ArtCandidate cand({
  required String artist,
  required String title,
  ArtSource source = ArtSource.itunes,
  int? width = 600,
  String? url,
}) =>
    ArtCandidate(
      url: url ?? 'https://example.test/${source.id}/$artist-$title.jpg',
      source: source,
      title: title,
      artist: artist,
      width: width,
    );

Future<List<ArtCandidate>> itunesFrom(String fixture, ArtQuery q) =>
    searchItunes(q,
        fetch: FakeArtFetch.bodies({itunesHost: loadArtFixture(fixture)}).fetch);

void main() {
  group('normalizeText', () {
    const cases = <String, String>{
      'The Dark Side of the Moon': 'the dark side of the moon',
      // Bracketed edition/explicit suffixes, including nested brackets.
      'The Dark Side of the Moon (2011 Remastered Version)':
          'the dark side of the moon',
      'Abbey Road [Explicit]': 'abbey road',
      'Album (Deluxe (2011) Edition)': 'album',
      'Discovery (Remastered)': 'discovery',
      // Noise-only dash tails, repeated.
      'Songs - EP': 'songs',
      'Album - 2011 Remaster - Deluxe Edition': 'album',
      'Nevermind - Single': 'nevermind',
      // A meaningful dash tail survives (as tokens).
      'Kid A - Part Two': 'kid a part two',
      // Diacritics.
      'Björk': 'bjork',
      'Sigur Rós': 'sigur ros',
      'Motörhead': 'motorhead',
      'Beyoncé': 'beyonce',
      'Blue Öyster Cult': 'blue oyster cult',
      'Mötley Crüe': 'motley crue',
      'Håkan Hellström': 'hakan hellstrom',
      'Æther': 'aether',
      'Straße': 'strasse',
      // Punctuation and apostrophes.
      "Rock 'n' Roll!": 'rock n roll',
      'AC/DC': 'ac dc',
      "Don't Stop": 'dont stop',
      'Simon & Garfunkel': 'simon and garfunkel',
      'Wu-Tang Clan': 'wu tang clan',
      '  Multiple   Spaces  ': 'multiple spaces',
      '': '',
    };

    cases.forEach((input, expected) {
      test('"$input" -> "$expected"', () {
        expect(normalizeText(input), expected);
      });
    });

    test('null normalizes to empty', () => expect(normalizeText(null), ''));

    test('is idempotent', () {
      for (final input in cases.keys) {
        final once = normalizeText(input);
        expect(normalizeText(once), once, reason: input);
      }
    });

    test('a title that is nothing but a bracketed group normalizes to empty',
        () {
      expect(normalizeText('( )'), '');
    });
  });

  group('albumKey', () {
    test('joins normalized artist and album', () {
      expect(albumKey(artist: 'Pink Floyd', album: 'The Dark Side of the Moon'),
          'pink floyd|the dark side of the moon');
    });

    test('edition variants collapse to the same key', () {
      expect(
        albumKey(artist: 'Pink Floyd', album: 'The Dark Side of the Moon'),
        albumKey(
            artist: 'Pink Floyd',
            album: 'The Dark Side of the Moon (2011 Remastered Version)'),
      );
    });

    test('falls back to artist|title when the album is missing', () {
      expect(albumKey(artist: 'Aphex Twin', album: '', title: 'Windowlicker'),
          'aphex twin|windowlicker');
      expect(albumKey(artist: 'Aphex Twin', title: 'Windowlicker'),
          'aphex twin|windowlicker');
    });

    test('two album-less tracks by one artist do not collide', () {
      expect(
        albumKey(artist: 'Aphex Twin', title: 'Windowlicker'),
        isNot(albumKey(artist: 'Aphex Twin', title: 'Come to Daddy')),
      );
    });

    test('candidateKey uses the candidate own artist/title', () {
      expect(
        candidateKey(cand(artist: 'Pink Floyd', title: 'The Dark Side of the Moon')),
        'pink floyd|the dark side of the moon',
      );
    });
  });

  group('similarity', () {
    test('identical text scores 1.0', () {
      expect(textSimilarity('Radiohead', 'Radiohead'), 1.0);
      expect(textSimilarity('OK Computer', 'ok computer'), 1.0);
    });

    test('normalization differences are free', () {
      expect(textSimilarity('Björk', 'Bjork'), 1.0);
      expect(textSimilarity('Simon & Garfunkel', 'Simon and Garfunkel'), 1.0);
      expect(
          textSimilarity('Discovery', 'Discovery (Remastered)'), 1.0);
    });

    test('a leading "The" barely costs anything', () {
      expect(textSimilarity('The Beatles', 'Beatles'), greaterThan(0.7));
    });

    test('extra words cost real points (superset is not a match)', () {
      expect(textSimilarity('OK Computer', 'OK Computer OKNOTOK 1997 2017'),
          lessThan(0.7));
    });

    test('unrelated text scores low', () {
      expect(textSimilarity('Pink Floyd', 'Easy Star All-Stars'),
          lessThan(0.35));
    });

    test('a blank side is missing evidence, not a match', () {
      expect(textSimilarity('', 'Radiohead'), 0.0);
      expect(textSimilarity('Radiohead', ''), 0.0);
      expect(textSimilarity('', ''), 0.0);
      expect(textSimilarity(null, null), 0.0);
    });
  });

  group('component scores', () {
    test('provider priors are iTunes 5 > Deezer 4 > CAA 3', () {
      expect(providerPrior(ArtSource.itunes), 5);
      expect(providerPrior(ArtSource.deezer), 4);
      expect(providerPrior(ArtSource.caa), 3);
    });

    test('resolution bonus is 0..5 and 0 for unknown width', () {
      expect(resolutionBonus(null), 0);
      expect(resolutionBonus(0), 0);
      expect(resolutionBonus(120), 1);
      expect(resolutionBonus(300), 2);
      expect(resolutionBonus(500), 3);
      expect(resolutionBonus(600), 4);
      expect(resolutionBonus(1000), 5);
      expect(resolutionBonus(3000), 5);
    });

    test('a perfect match maxes out at 100 and components sum to the total',
        () {
      const q = ArtQuery(artist: 'Daft Punk', album: 'Discovery');
      final s = scoreCandidate(
          q,
          cand(
              artist: 'Daft Punk',
              title: 'Discovery',
              source: ArtSource.itunes,
              width: 1000));
      expect(s.artistScore, kArtistWeight);
      expect(s.albumScore, kAlbumWeight);
      expect(s.providerScore, 5);
      expect(s.resolutionScore, 5);
      expect(s.score, 100);
    });

    test('an unknown local artist can never reach the auto-apply threshold',
        () {
      const q = ArtQuery(artist: '', album: 'Discovery');
      final s = scoreCandidate(
          q, cand(artist: 'Daft Punk', title: 'Discovery', width: 1000));
      expect(s.score, lessThan(kAutoApplyMinScore));
    });
  });

  group('ranking against captured payloads', () {
    const q =
        ArtQuery(artist: 'Pink Floyd', album: 'The Dark Side of the Moon');

    test('the real album outranks a soundalike from the same response',
        () async {
      final cands = await itunesFrom('itunes_dark_side.json', q);
      final ranked = rankCandidates(q, cands);

      expect(ranked.length, 3);
      expect(ranked.first.candidate.artist, 'Pink Floyd');
      expect(ranked.first.candidate.title, 'The Dark Side of the Moon');
      expect(ranked.last.candidate.artist, 'Easy Star All-Stars');
      expect(ranked.first.score, greaterThan(90));
      expect(ranked.last.score, lessThan(kAutoApplyMinScore));
    });

    test('the plain title wins the tie against its own remaster', () async {
      final cands = await itunesFrom('itunes_dark_side.json', q);
      final ranked = rankCandidates(q, cands);
      expect(ranked[0].candidate.title, 'The Dark Side of the Moon');
      expect(ranked[1].candidate.title,
          'The Dark Side of the Moon (2011 Remastered Version)');
      expect(ranked[0].score, ranked[1].score,
          reason: 'the normalizer makes them equal; the tiebreak decides');
    });

    test('edition variants stay in the grid but collapse for the margin',
        () async {
      final cands = await itunesFrom('itunes_dark_side.json', q);
      expect(rankCandidates(q, cands).length, 3,
          reason: 'the picker shows every distinct image');
      expect(rankDistinctAlbums(q, cands).length, 2,
          reason: 'DSOTM + its remaster are one album; Dub Side is another');
    });

    test('auto-applies the confident match', () async {
      final cands = await itunesFrom('itunes_dark_side.json', q);
      final guess = bestGuessScored(q, cands);
      expect(guess, isNotNull);
      expect(guess!.candidate.artist, 'Pink Floyd');
      expect(guess.score, greaterThanOrEqualTo(kAutoApplyMinScore));
    });

    test('Deezer payload ranks the real artist over a tribute band', () async {
      const dq = ArtQuery(artist: 'Daft Punk', album: 'Discovery');
      final cands = await searchDeezer(dq,
          fetch: FakeArtFetch.bodies(
              {deezerHost: loadArtFixture('deezer_discovery.json')}).fetch);
      final guess = bestGuess(dq, cands);
      expect(guess, isNotNull);
      expect(guess!.artist, 'Daft Punk');
      expect(guess.width, 1000);
    });

    test('MusicBrainz payload: the album beats its own box set by >= 10',
        () async {
      const mq = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
      final cands = await searchCoverArtArchive(mq,
          fetch: FakeArtFetch.bodies(
              {mbHost: loadArtFixture('musicbrainz_ok_computer.json')}).fetch,
          limiter: RateLimiter(
              minInterval: Duration.zero, sleep: (_) async {}));
      final ranked = rankDistinctAlbums(mq, cands);
      expect(ranked.length, 3);
      expect(ranked[0].candidate.title, 'OK Computer');
      expect(ranked[0].score - ranked[1].score,
          greaterThanOrEqualTo(kAutoApplyMinMargin));
      expect(bestGuess(mq, cands)!.title, 'OK Computer');
    });

    test('three providers agreeing is corroboration, not a tie', () async {
      const mq = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
      final cands = [
        cand(
            artist: 'Radiohead',
            title: 'OK Computer',
            source: ArtSource.itunes,
            width: 600),
        cand(
            artist: 'Radiohead',
            title: 'OK Computer',
            source: ArtSource.deezer,
            width: 1000),
        cand(
            artist: 'Radiohead',
            title: 'OK Computer',
            source: ArtSource.caa,
            width: 500),
      ];
      expect(rankCandidates(mq, cands).length, 3);
      expect(rankDistinctAlbums(mq, cands).length, 1);
      final guess = bestGuess(mq, cands);
      expect(guess, isNotNull);
      expect(guess!.source, ArtSource.itunes,
          reason: 'equal scores break on the provider prior');
    });
  });

  group('auto-apply rule (>= 75 AND >= 10 margin)', () {
    test('a near-tie between two real albums returns null', () async {
      const q = ArtQuery(artist: 'Queen', album: 'Greatest Hits');
      final cands = await itunesFrom('itunes_greatest_hits.json', q);
      final ranked = rankDistinctAlbums(q, cands);

      expect(ranked.length, 2);
      expect(ranked[0].score, greaterThanOrEqualTo(kAutoApplyMinScore),
          reason: 'the top candidate is confident enough on its own...');
      expect(ranked[0].score - ranked[1].score, lessThan(kAutoApplyMinMargin),
          reason: '...but Greatest Hits II is too close to call');
      expect(bestGuess(q, cands), isNull);
    });

    test('a confident top with no runner-up applies', () {
      const q = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
      expect(bestGuess(q, [cand(artist: 'Radiohead', title: 'OK Computer')]),
          isNotNull);
    });

    test('a weak top never applies, however far ahead it is', () {
      const q = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
      final cands = [
        cand(artist: 'Metallica', title: 'Ride the Lightning'),
        cand(artist: 'Boards of Canada', title: 'Geogaddi'),
      ];
      final ranked = rankDistinctAlbums(q, cands);
      expect(ranked.first.score, lessThan(kAutoApplyMinScore));
      expect(bestGuess(q, cands), isNull);
    });

    test('no candidates -> null', () {
      expect(bestGuess(const ArtQuery(artist: 'A', album: 'B'), const []),
          isNull);
      expect(
          bestGuessScored(const ArtQuery(artist: 'A', album: 'B'), const []),
          isNull);
    });

    test('the thresholds are overridable for a manual/forced apply', () {
      const q = ArtQuery(artist: 'Queen', album: 'Greatest Hits');
      final cands = [
        cand(artist: 'Queen', title: 'Greatest Hits'),
        cand(artist: 'Queen', title: 'Greatest Hits II'),
      ];
      expect(bestGuess(q, cands), isNull);
      expect(bestGuess(q, cands, minMargin: 0), isNotNull);
    });
  });

  group('determinism', () {
    const q = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
    final cands = [
      cand(artist: 'Radiohead', title: 'OK Computer', source: ArtSource.caa, width: 500),
      cand(artist: 'Radiohead', title: 'Kid A', source: ArtSource.itunes),
      cand(artist: 'Radiohead', title: 'OK Computer', source: ArtSource.deezer, width: 1000),
      cand(artist: 'Muse', title: 'OK Computer', source: ArtSource.itunes),
    ];

    test('input order does not change the ranking', () {
      final a = rankCandidates(q, cands).map((s) => s.candidate.url).toList();
      final b = rankCandidates(q, cands.reversed).map((s) => s.candidate.url).toList();
      expect(b, a);
    });

    test('repeated runs are byte-identical', () {
      final a = rankCandidates(q, cands).map((s) => s.score).toList();
      final b = rankCandidates(q, cands).map((s) => s.score).toList();
      expect(b, a);
    });

    test('dedupe drops repeated URLs, keeping first appearance', () {
      final dup = cand(
          artist: 'Radiohead', title: 'OK Computer', url: 'https://x/a.jpg');
      final other = cand(
          artist: 'Radiohead',
          title: 'OK Computer',
          source: ArtSource.deezer,
          url: 'https://x/a.jpg');
      final out = dedupeCandidates([dup, other, ...cands]);
      expect(out.length, 1 + cands.length);
      expect(out.first.source, ArtSource.itunes);
    });
  });

  group('ArtCandidate / ArtSource', () {
    test('source ids are the sidecar vocabulary and round-trip', () {
      expect(ArtSource.values.map((s) => s.id).toList(),
          ['itunes', 'deezer', 'caa', 'local', 'url', 'embedded']);
      for (final s in ArtSource.values) {
        expect(ArtSource.fromId(s.id), s);
      }
      expect(ArtSource.fromId('spotify'), isNull);
      expect(ArtSource.fromId(null), isNull);
    });

    test('thumbUrl defaults to url', () {
      expect(
          const ArtCandidate(
                  url: 'https://x/a.jpg',
                  source: ArtSource.local,
                  title: 't',
                  artist: 'a')
              .thumbUrl,
          'https://x/a.jpg');
    });

    test('json round-trip', () {
      final c = cand(artist: 'Daft Punk', title: 'Discovery', width: 1000);
      expect(ArtCandidate.fromJson(c.toJson()), c);
    });

    test('fromJson rejects unusable payloads', () {
      expect(ArtCandidate.fromJson(null), isNull);
      expect(ArtCandidate.fromJson('nope'), isNull);
      expect(ArtCandidate.fromJson({'source': 'itunes'}), isNull);
      expect(ArtCandidate.fromJson({'url': 'https://x', 'source': 'aol'}),
          isNull);
    });

    test('ArtQuery term and emptiness', () {
      expect(const ArtQuery(artist: 'A', album: 'B').term, 'A B');
      expect(const ArtQuery(album: 'B').term, 'B');
      expect(const ArtQuery().isEmpty, isTrue);
      expect(const ArtQuery(artist: '  ').isEmpty, isTrue);
    });
  });
}
