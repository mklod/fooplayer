// Provider tests. Every one of them runs off hand-written fixtures through
// the injected fetch seam -- no test in this file opens a socket.
//
// Last modified: 2026-07-25--2113

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/providers.dart';

import 'support/artwork_fixtures.dart';

const q = ArtQuery(artist: 'Pink Floyd', album: 'The Dark Side of the Moon');
const okComputer = ArtQuery(artist: 'Radiohead', album: 'OK Computer');
const discovery = ArtQuery(artist: 'Daft Punk', album: 'Discovery');

const itunesHost = 'itunes.apple.com';
const deezerHost = 'api.deezer.com';
const mbHost = 'musicbrainz.org';

/// A limiter that never actually waits, for tests that aren't about pacing.
RateLimiter instantLimiter() => RateLimiter(
      minInterval: Duration.zero,
      sleep: (_) async {},
      now: DateTime.now,
    );

void main() {
  group('iTunes', () {
    test('parses albums, upgrades artwork to 600px, skips track rows',
        () async {
      final fake = FakeArtFetch.bodies(
          {itunesHost: loadArtFixture('itunes_dark_side.json')});
      final out = await searchItunes(q, fetch: fake.fetch);

      // 4 fixture rows -> 3 collections, and the track row is dropped.
      expect(out.length, 3);
      expect(out.every((c) => c.source == ArtSource.itunes), isTrue);

      final first = out.first;
      expect(first.title, 'The Dark Side of the Moon');
      expect(first.artist, 'Pink Floyd');
      expect(first.year, 1973);
      expect(first.width, 600);
      expect(first.url, contains('/600x600bb.jpg'));
      expect(first.url, isNot(contains('100x100')));
      expect(first.thumbUrl, contains('/200x200bb.jpg'));

      expect(out.map((c) => c.title),
          isNot(contains('Time'))); // the wrapperType:"track" row
    });

    test('request shape: entity=album and the query term', () async {
      final fake = FakeArtFetch.bodies(
          {itunesHost: loadArtFixture('itunes_empty.json')});
      await searchItunes(q, fetch: fake.fetch, limit: 7);

      final call = fake.callTo(itunesHost);
      expect(call.url.path, '/search');
      expect(call.url.queryParameters['entity'], 'album');
      expect(call.url.queryParameters['limit'], '7');
      expect(call.url.queryParameters['term'],
          'Pink Floyd The Dark Side of the Moon');
    });

    test('empty result set yields []', () async {
      final fake = FakeArtFetch.bodies(
          {itunesHost: loadArtFixture('itunes_empty.json')});
      expect(await searchItunes(q, fetch: fake.fetch), isEmpty);
    });

    test('itunesArtworkAtSize rewrites any square size segment', () {
      const url = 'https://is1-ssl.mzstatic.com/image/thumb/a/b/60x60bb.jpg';
      expect(itunesArtworkAtSize(url, 600), endsWith('/600x600bb.jpg'));
      expect(itunesArtworkAtSize('https://x/no-size.jpg', 600),
          'https://x/no-size.jpg');
    });
  });

  group('Deezer', () {
    test('parses albums and picks the largest cover', () async {
      final fake = FakeArtFetch.bodies(
          {deezerHost: loadArtFixture('deezer_discovery.json')});
      final out = await searchDeezer(discovery, fetch: fake.fetch);

      expect(out.length, 3);
      expect(out.first.source, ArtSource.deezer);
      expect(out.first.title, 'Discovery');
      expect(out.first.artist, 'Daft Punk');
      expect(out.first.width, 1000);
      expect(out.first.url, contains('1000x1000'));
      expect(out.first.thumbUrl, contains('250x250'));

      // Third entry has no cover_xl -> falls back to cover_big at 500px.
      expect(out[2].width, 500);
      expect(out[2].url, contains('500x500'));
      expect(out[2].artist, 'Pink Floyd Tribute Band');
    });

    test('uses advanced query syntax when both fields are present', () async {
      final fake = FakeArtFetch.bodies({deezerHost: '{"data":[]}'});
      await searchDeezer(discovery, fetch: fake.fetch);
      expect(fake.callTo(deezerHost).url.queryParameters['q'],
          'artist:"Daft Punk" album:"Discovery"');
    });

    test('falls back to a plain term when one field is missing', () async {
      final fake = FakeArtFetch.bodies({deezerHost: '{"data":[]}'});
      await searchDeezer(const ArtQuery(album: 'Discovery'), fetch: fake.fetch);
      expect(fake.callTo(deezerHost).url.queryParameters['q'], 'Discovery');
    });

    test('HTTP 200 error envelope yields [] (not a throw)', () async {
      final fake = FakeArtFetch.bodies(
          {deezerHost: loadArtFixture('deezer_error.json')});
      expect(await searchDeezer(discovery, fetch: fake.fetch), isEmpty);
    });
  });

  group('MusicBrainz / Cover Art Archive', () {
    test('turns release-groups into CAA front-cover candidates', () async {
      final fake = FakeArtFetch.bodies(
          {mbHost: loadArtFixture('musicbrainz_ok_computer.json')});
      final out = await searchCoverArtArchive(okComputer,
          fetch: fake.fetch, limiter: instantLimiter());

      expect(out.length, 3);
      expect(out.first.source, ArtSource.caa);
      expect(out.first.title, 'OK Computer');
      expect(out.first.artist, 'Radiohead');
      expect(out.first.year, 1997);
      expect(out.first.width, 500);
      expect(
          out.first.url,
          'https://coverartarchive.org/release-group/'
          'b1392450-e666-3926-a536-22c65f834433/front-500');
      expect(out.first.thumbUrl, endsWith('/front-250'));
    });

    test('joins multi-part artist credits with their join phrases', () async {
      final fake = FakeArtFetch.bodies(
          {mbHost: loadArtFixture('musicbrainz_ok_computer.json')});
      final out = await searchCoverArtArchive(okComputer,
          fetch: fake.fetch, limiter: instantLimiter());
      expect(out[2].artist, 'Vitamin String Quartet & The Section');
    });

    test('sends the required descriptive User-Agent', () async {
      final fake =
          FakeArtFetch.bodies({mbHost: loadArtFixture('musicbrainz_empty.json')});
      await searchCoverArtArchive(okComputer,
          fetch: fake.fetch, limiter: instantLimiter());

      final call = fake.callTo(mbHost);
      expect(call.headers['User-Agent'], kArtworkUserAgent);
      expect(call.headers['User-Agent'], contains('fooplayer/'));
      expect(call.headers['User-Agent'], contains('github.com/mklod/fooplayer'));
      expect(call.url.queryParameters['fmt'], 'json');
      expect(call.url.queryParameters['query'],
          'artist:"Radiohead" AND releasegroup:"OK Computer"');
    });

    test('rate limiter spaces consecutive requests >= 1s apart', () async {
      final clock = FakeClock();
      final limiter = RateLimiter(
        minInterval: kMusicBrainzMinInterval,
        sleep: clock.sleep,
        now: clock.now,
      );
      final fake =
          FakeArtFetch.bodies({mbHost: loadArtFixture('musicbrainz_empty.json')});

      // Three lookups fired at once, as the background pass would.
      await Future.wait([
        searchCoverArtArchive(okComputer, fetch: fake.fetch, limiter: limiter),
        searchCoverArtArchive(discovery, fetch: fake.fetch, limiter: limiter),
        searchCoverArtArchive(q, fetch: fake.fetch, limiter: limiter),
      ]);

      expect(fake.calls.length, 3);
      // First goes immediately; the next two each wait out the full second.
      expect(clock.waits, [kMusicBrainzMinInterval, kMusicBrainzMinInterval]);
    });

    test('rate limiter charges only the remaining gap', () async {
      final clock = FakeClock();
      final limiter = RateLimiter(
        minInterval: const Duration(seconds: 1),
        sleep: clock.sleep,
        now: clock.now,
      );
      await limiter.schedule(() async => clock.advance(
          const Duration(milliseconds: 400))); // request itself took 400ms
      await limiter.schedule(() async {});
      expect(clock.waits, [const Duration(milliseconds: 600)]);
    });

    test('a failing request does not wedge the limiter', () async {
      final clock = FakeClock();
      final limiter = RateLimiter(
        minInterval: Duration.zero,
        sleep: clock.sleep,
        now: clock.now,
      );
      await expectLater(
          limiter.schedule(() async => throw StateError('boom')), throwsA(isA<StateError>()));
      expect(await limiter.schedule(() async => 42), 42);
    });
  });

  group('error isolation (rule: never throw, always [])', () {
    final failureModes = <String, ArtHttpResponse Function(Uri)>{
      'HTTP 404': (_) => const ArtHttpResponse(statusCode: 404, body: '{}'),
      'HTTP 503 HTML error page': (_) => const ArtHttpResponse(
          statusCode: 503, body: '<html><body>Service Unavailable</body></html>'),
      'HTTP 200 truncated JSON': (_) =>
          const ArtHttpResponse(statusCode: 200, body: '{"results": [{"col'),
      'HTTP 200 empty body': (_) =>
          const ArtHttpResponse(statusCode: 200, body: ''),
      'HTTP 200 JSON array instead of object': (_) =>
          const ArtHttpResponse(statusCode: 200, body: '[]'),
      'HTTP 200 wrong shape': (_) => const ArtHttpResponse(
          statusCode: 200, body: '{"results": "not-a-list"}'),
      'HTTP 200 items of the wrong type': (_) => ArtHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'results': [42, null, 'nope'],
            'data': [42, null, 'nope'],
            'release-groups': [42, null, 'nope'],
          })),
      'HTTP 200 fields of the wrong type': (_) => ArtHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'results': [
              {
                'collectionName': 'X',
                'artworkUrl100': 'https://x/100x100bb.jpg',
                'releaseDate': 1973,
              }
            ],
            'data': [
              {'title': 'X', 'cover_xl': 'https://x.jpg', 'release_date': false}
            ],
            'release-groups': [
              {'id': 'abc', 'title': 'X', 'first-release-date': []}
            ],
          })),
    };

    for (final entry in failureModes.entries) {
      test('${entry.key} -> [] from every provider', () async {
        final fake = FakeArtFetch({
          itunesHost: entry.value,
          deezerHost: entry.value,
          mbHost: entry.value,
        });
        // Wrong-type-fields is the one case that must still parse cleanly
        // (dropping only the bad field), so assert survival rather than [].
        final expectNoThrowOnly =
            entry.key == 'HTTP 200 fields of the wrong type';

        for (final call in [
          searchItunes(q, fetch: fake.fetch),
          searchDeezer(q, fetch: fake.fetch),
          searchCoverArtArchive(q, fetch: fake.fetch, limiter: instantLimiter()),
        ]) {
          final out = await call;
          if (!expectNoThrowOnly) expect(out, isEmpty, reason: entry.key);
        }
      });
    }

    test('transport that throws (no network) -> [] from every provider',
        () async {
      expect(await searchItunes(q, fetch: throwingArtFetch), isEmpty);
      expect(await searchDeezer(q, fetch: throwingArtFetch), isEmpty);
      expect(
          await searchCoverArtArchive(q,
              fetch: throwingArtFetch, limiter: instantLimiter()),
          isEmpty);
      expect(
          await searchAll(q, fetch: throwingArtFetch, limiter: instantLimiter()),
          isEmpty);
    });

    test('bad-field payload still yields a usable candidate', () async {
      final fake = FakeArtFetch.bodies({
        itunesHost: jsonEncode({
          'results': [
            {
              'collectionName': 'X',
              'artistName': 'Y',
              'artworkUrl100': 'https://x/100x100bb.jpg',
              'releaseDate': 1973, // wrong type: must be ignored, not fatal
            }
          ]
        })
      });
      final out = await searchItunes(q, fetch: fake.fetch);
      expect(out.length, 1);
      expect(out.single.year, isNull);
    });

    test('empty query short-circuits without any request', () async {
      final fake = FakeArtFetch.bodies({itunesHost: '{}', deezerHost: '{}'});
      expect(await searchAll(const ArtQuery(), fetch: fake.fetch), isEmpty);
      expect(fake.calls, isEmpty);
    });
  });

  group('searchAll', () {
    test('unions all three providers in provider order', () async {
      final fake = FakeArtFetch.bodies({
        itunesHost: loadArtFixture('itunes_dark_side.json'),
        deezerHost: loadArtFixture('deezer_discovery.json'),
        mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
      });
      final out = await searchAll(q, fetch: fake.fetch, limiter: instantLimiter());

      expect(out.length, 3 + 3 + 3);
      expect(out.take(3).every((c) => c.source == ArtSource.itunes), isTrue);
      expect(out.skip(3).take(3).every((c) => c.source == ArtSource.deezer),
          isTrue);
      expect(out.skip(6).every((c) => c.source == ArtSource.caa), isTrue);
      expect(fake.calls.length, 3, reason: 'exactly one request per provider');
    });

    test('one provider down does not cost the others their results', () async {
      final fake = FakeArtFetch({
        itunesHost: (_) => ArtHttpResponse(
            statusCode: 200, body: loadArtFixture('itunes_dark_side.json')),
        deezerHost: (_) =>
            const ArtHttpResponse(statusCode: 500, body: 'server error'),
        mbHost: (_) => const ArtHttpResponse(statusCode: 503, body: 'busy'),
      });
      final out = await searchAll(q, fetch: fake.fetch, limiter: instantLimiter());
      expect(out.length, 3);
      expect(out.every((c) => c.source == ArtSource.itunes), isTrue);
    });
  });
}
