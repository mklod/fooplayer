// Provider tests. Every one of them runs off hand-written fixtures through
// the injected fetch seam -- no test in this file opens a socket.
//
// Last modified: 2026-07-25--2113

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/artwork_fixtures.dart';

/// 1x1 transparent PNG -- real magic bytes for the tests that need
/// [httpArtworkBytes] to accept the response.
final onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

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
    test(
      'parses albums, upgrades artwork to 600px, skips track rows',
      () async {
        final fake = FakeArtFetch.bodies({
          itunesHost: loadArtFixture('itunes_dark_side.json'),
        });
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

        expect(
          out.map((c) => c.title),
          isNot(contains('Time')),
        ); // the wrapperType:"track" row
      },
    );

    test('request shape: entity=album and the query term', () async {
      final fake = FakeArtFetch.bodies({
        itunesHost: loadArtFixture('itunes_empty.json'),
      });
      await searchItunes(q, fetch: fake.fetch, limit: 7);

      final call = fake.callTo(itunesHost);
      expect(call.url.path, '/search');
      expect(call.url.queryParameters['entity'], 'album');
      expect(call.url.queryParameters['limit'], '7');
      expect(
        call.url.queryParameters['term'],
        'Pink Floyd The Dark Side of the Moon',
      );
    });

    test('empty result set yields []', () async {
      final fake = FakeArtFetch.bodies({
        itunesHost: loadArtFixture('itunes_empty.json'),
      });
      expect(await searchItunes(q, fetch: fake.fetch), isEmpty);
    });

    test('itunesArtworkAtSize rewrites any square size segment', () {
      const url = 'https://is1-ssl.mzstatic.com/image/thumb/a/b/60x60bb.jpg';
      expect(itunesArtworkAtSize(url, 600), endsWith('/600x600bb.jpg'));
      expect(
        itunesArtworkAtSize('https://x/no-size.jpg', 600),
        'https://x/no-size.jpg',
      );
    });
  });

  group('Deezer', () {
    test('parses albums and picks the largest cover', () async {
      final fake = FakeArtFetch.bodies({
        deezerHost: loadArtFixture('deezer_discovery.json'),
      });
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
      expect(
        fake.callTo(deezerHost).url.queryParameters['q'],
        'artist:"Daft Punk" album:"Discovery"',
      );
    });

    test('falls back to a plain term when one field is missing', () async {
      final fake = FakeArtFetch.bodies({deezerHost: '{"data":[]}'});
      await searchDeezer(const ArtQuery(album: 'Discovery'), fetch: fake.fetch);
      expect(fake.callTo(deezerHost).url.queryParameters['q'], 'Discovery');
    });

    test('HTTP 200 error envelope yields [] (not a throw)', () async {
      final fake = FakeArtFetch.bodies({
        deezerHost: loadArtFixture('deezer_error.json'),
      });
      expect(await searchDeezer(discovery, fetch: fake.fetch), isEmpty);
    });
  });

  group('MusicBrainz / Cover Art Archive', () {
    test('turns release-groups into CAA front-cover candidates', () async {
      final fake = FakeArtFetch.bodies({
        mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
      });
      final out = await searchCoverArtArchive(
        okComputer,
        fetch: fake.fetch,
        limiter: instantLimiter(),
      );

      expect(out.length, 3);
      expect(out.first.source, ArtSource.caa);
      expect(out.first.title, 'OK Computer');
      expect(out.first.artist, 'Radiohead');
      expect(out.first.year, 1997);
      expect(out.first.width, 500);
      expect(
        out.first.url,
        'https://coverartarchive.org/release-group/'
        'b1392450-e666-3926-a536-22c65f834433/front-500',
      );
      expect(out.first.thumbUrl, endsWith('/front-250'));
    });

    test('joins multi-part artist credits with their join phrases', () async {
      final fake = FakeArtFetch.bodies({
        mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
      });
      final out = await searchCoverArtArchive(
        okComputer,
        fetch: fake.fetch,
        limiter: instantLimiter(),
      );
      expect(out[2].artist, 'Vitamin String Quartet & The Section');
    });

    test('sends the required descriptive User-Agent', () async {
      final fake = FakeArtFetch.bodies({
        mbHost: loadArtFixture('musicbrainz_empty.json'),
      });
      await searchCoverArtArchive(
        okComputer,
        fetch: fake.fetch,
        limiter: instantLimiter(),
      );

      final call = fake.callTo(mbHost);
      expect(call.headers['User-Agent'], kArtworkUserAgent);
      expect(call.headers['User-Agent'], contains('fooplayer/'));
      expect(
        call.headers['User-Agent'],
        contains('github.com/mklod/fooplayer'),
      );
      expect(call.url.queryParameters['fmt'], 'json');
      expect(
        call.url.queryParameters['query'],
        'artist:"Radiohead" AND releasegroup:"OK Computer"',
      );
    });

    test('rate limiter spaces consecutive requests >= 1s apart', () async {
      final clock = FakeClock();
      final limiter = RateLimiter(
        minInterval: kMusicBrainzMinInterval,
        sleep: clock.sleep,
        now: clock.now,
      );
      final fake = FakeArtFetch.bodies({
        mbHost: loadArtFixture('musicbrainz_empty.json'),
      });

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
      await limiter.schedule(
        () async => clock.advance(const Duration(milliseconds: 400)),
      ); // request itself took 400ms
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
        limiter.schedule(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(await limiter.schedule(() async => 42), 42);
    });

    group('priority lane (adversarial review finding 2)', () {
      test('an interactive request queued BEHIND several background ones '
          'still jumps to the front', () async {
        final clock = FakeClock();
        final limiter = RateLimiter(
          minInterval: kMusicBrainzMinInterval,
          sleep: clock.sleep,
          now: clock.now,
        );
        final order = <String>[];

        // Simulates ~a few of the "700 albums queued" background pass
        // lookups already sitting in the limiter...
        for (var i = 0; i < 5; i++) {
          unawaited(
            limiter.schedule(() async {
              order.add('background-$i');
            }),
          );
        }
        // ...then the picker's interactive search arrives.
        unawaited(
          limiter.schedule(
            () async => order.add('interactive'),
            priority: RateLimitPriority.interactive,
          ),
        );

        // Let the whole queue drain (fake clock, so this doesn't take real
        // wall-clock seconds).
        while (order.length < 6) {
          await Future<void>.delayed(Duration.zero);
        }

        // The first dispatch (t=0, no wait yet) had ALREADY started before
        // the interactive request was even scheduled -- that one can't be
        // preempted (it's not "queued", it's already running). Every
        // request queued behind it, though, must yield to the interactive
        // one.
        expect(order.first, 'background-0');
        expect(
          order[1],
          'interactive',
          reason:
              'the interactive request must cut in front of every '
              'still-QUEUED background request, even though it arrived '
              'last',
        );
      });

      test('the pacing gap is identical for both lanes -- priority reorders '
          'the queue, it does not relax the 1 req/sec ceiling', () async {
        final clock = FakeClock();
        final limiter = RateLimiter(
          minInterval: kMusicBrainzMinInterval,
          sleep: clock.sleep,
          now: clock.now,
        );
        unawaited(limiter.schedule(() async {}));
        unawaited(
          limiter.schedule(
            () async {},
            priority: RateLimitPriority.interactive,
          ),
        );
        unawaited(limiter.schedule(() async {}));

        while (clock.waits.length < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          clock.waits,
          [kMusicBrainzMinInterval, kMusicBrainzMinInterval],
          reason:
              'three dispatches, still spaced a full interval apart '
              'regardless of the priority mix',
        );
      });

      test('an interactive request that arrives WHILE the limiter is mid-wait '
          'still cuts in front of an already-queued background one', () async {
        final clock = FakeClock();
        final order = <String>[];
        var injected = false;
        late final RateLimiter limiter;
        limiter = RateLimiter(
          minInterval: kMusicBrainzMinInterval,
          sleep: (d) async {
            // Fires while the limiter is waiting out the pacing gap AFTER
            // dispatching 'first' -- 'background-1' is already queued at
            // this point. The interactive request injected here must still
            // beat it: WHICH item runs next is decided AFTER this wait
            // returns, not before -- exactly the race the fix targets.
            if (!injected) {
              injected = true;
              unawaited(
                limiter.schedule(
                  () async => order.add('interactive'),
                  priority: RateLimitPriority.interactive,
                ),
              );
            }
            await clock.sleep(d);
          },
          now: clock.now,
        );

        unawaited(limiter.schedule(() async => order.add('first')));
        unawaited(limiter.schedule(() async => order.add('background-1')));

        while (order.length < 3) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(order, ['first', 'interactive', 'background-1']);
      });

      test('within one priority tier, order is plain FIFO', () async {
        final clock = FakeClock();
        final limiter = RateLimiter(
          minInterval: Duration.zero,
          sleep: clock.sleep,
          now: clock.now,
        );
        final order = <int>[];
        for (var i = 0; i < 4; i++) {
          unawaited(
            limiter.schedule(
              () async => order.add(i),
              priority: RateLimitPriority.interactive,
            ),
          );
        }
        while (order.length < 4) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(order, [0, 1, 2, 3]);
      });
    });
  });

  group('error isolation (rule: never throw, always [])', () {
    final failureModes = <String, ArtHttpResponse Function(Uri)>{
      'HTTP 404': (_) => const ArtHttpResponse(statusCode: 404, body: '{}'),
      'HTTP 503 HTML error page': (_) => const ArtHttpResponse(
        statusCode: 503,
        body: '<html><body>Service Unavailable</body></html>',
      ),
      'HTTP 200 truncated JSON': (_) =>
          const ArtHttpResponse(statusCode: 200, body: '{"results": [{"col'),
      'HTTP 200 empty body': (_) =>
          const ArtHttpResponse(statusCode: 200, body: ''),
      'HTTP 200 JSON array instead of object': (_) =>
          const ArtHttpResponse(statusCode: 200, body: '[]'),
      'HTTP 200 wrong shape': (_) => const ArtHttpResponse(
        statusCode: 200,
        body: '{"results": "not-a-list"}',
      ),
      'HTTP 200 items of the wrong type': (_) => ArtHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'results': [42, null, 'nope'],
          'data': [42, null, 'nope'],
          'release-groups': [42, null, 'nope'],
        }),
      ),
      'HTTP 200 fields of the wrong type': (_) => ArtHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'results': [
            {
              'collectionName': 'X',
              'artworkUrl100': 'https://x/100x100bb.jpg',
              'releaseDate': 1973,
            },
          ],
          'data': [
            {'title': 'X', 'cover_xl': 'https://x.jpg', 'release_date': false},
          ],
          'release-groups': [
            {'id': 'abc', 'title': 'X', 'first-release-date': []},
          ],
        }),
      ),
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
          searchCoverArtArchive(
            q,
            fetch: fake.fetch,
            limiter: instantLimiter(),
          ),
        ]) {
          final out = await call;
          if (!expectNoThrowOnly) expect(out, isEmpty, reason: entry.key);
        }
      });
    }

    test(
      'transport that throws (no network) -> [] from every provider',
      () async {
        expect(await searchItunes(q, fetch: throwingArtFetch), isEmpty);
        expect(await searchDeezer(q, fetch: throwingArtFetch), isEmpty);
        expect(
          await searchCoverArtArchive(
            q,
            fetch: throwingArtFetch,
            limiter: instantLimiter(),
          ),
          isEmpty,
        );
        expect(
          await searchAll(
            q,
            fetch: throwingArtFetch,
            limiter: instantLimiter(),
          ),
          isEmpty,
        );
      },
    );

    test('bad-field payload still yields a usable candidate', () async {
      final fake = FakeArtFetch.bodies({
        itunesHost: jsonEncode({
          'results': [
            {
              'collectionName': 'X',
              'artistName': 'Y',
              'artworkUrl100': 'https://x/100x100bb.jpg',
              'releaseDate': 1973, // wrong type: must be ignored, not fatal
            },
          ],
        }),
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
      final out = await searchAll(
        q,
        fetch: fake.fetch,
        limiter: instantLimiter(),
      );

      expect(out.length, 3 + 3 + 3);
      expect(out.take(3).every((c) => c.source == ArtSource.itunes), isTrue);
      expect(
        out.skip(3).take(3).every((c) => c.source == ArtSource.deezer),
        isTrue,
      );
      expect(out.skip(6).every((c) => c.source == ArtSource.caa), isTrue);
      expect(fake.calls.length, 3, reason: 'exactly one request per provider');
    });

    test('one provider down does not cost the others their results', () async {
      final fake = FakeArtFetch({
        itunesHost: (_) => ArtHttpResponse(
          statusCode: 200,
          body: loadArtFixture('itunes_dark_side.json'),
        ),
        deezerHost: (_) =>
            const ArtHttpResponse(statusCode: 500, body: 'server error'),
        mbHost: (_) => const ArtHttpResponse(statusCode: 503, body: 'busy'),
      });
      final out = await searchAll(
        q,
        fetch: fake.fetch,
        limiter: instantLimiter(),
      );
      expect(out.length, 3);
      expect(out.every((c) => c.source == ArtSource.itunes), isTrue);
    });

    group('caaBudget (adversarial review finding 2)', () {
      test('iTunes/Deezer results are returned without waiting on a slow '
          'CAA past the budget', () async {
        final caaGate = Completer<ArtHttpResponse>(); // never completes here
        Future<ArtHttpResponse> fetch(
          Uri url, {
          Map<String, String>? headers,
        }) async {
          if (url.host == mbHost) return caaGate.future;
          if (url.host == itunesHost) {
            return ArtHttpResponse(
              statusCode: 200,
              body: loadArtFixture('itunes_dark_side.json'),
            );
          }
          if (url.host == deezerHost) {
            return ArtHttpResponse(
              statusCode: 200,
              body: loadArtFixture('deezer_discovery.json'),
            );
          }
          return const ArtHttpResponse(statusCode: 404, body: '');
        }

        final sw = Stopwatch()..start();
        final out = await searchAll(
          q,
          fetch: fetch,
          limiter: instantLimiter(),
          caaBudget: const Duration(milliseconds: 50),
        );
        sw.stop();

        expect(out.any((c) => c.source == ArtSource.itunes), isTrue);
        expect(out.any((c) => c.source == ArtSource.deezer), isTrue);
        expect(
          out.any((c) => c.source == ArtSource.caa),
          isFalse,
          reason: 'CAA never answered within the budget',
        );
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'must not have waited anywhere near a full provider '
              'timeout for CAA -- that is exactly what starved the '
              "picker's spinner before this fix",
        );
      });

      test('CAA that answers WITHIN the budget is still included', () async {
        final fake = FakeArtFetch.bodies({
          itunesHost: loadArtFixture('itunes_dark_side.json'),
          deezerHost: loadArtFixture('deezer_discovery.json'),
          mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
        });
        final out = await searchAll(
          q,
          fetch: fake.fetch,
          limiter: instantLimiter(),
          caaBudget: const Duration(seconds: 3),
        );
        expect(
          out.any((c) => c.source == ArtSource.caa),
          isTrue,
          reason:
              'a budget is a ceiling, not a reason to drop a fast '
              'CAA answer',
        );
      });

      test('no caaBudget (the automatic/background pass default) waits for '
          'CAA exactly as before this fix', () async {
        final fake = FakeArtFetch.bodies({
          itunesHost: loadArtFixture('itunes_dark_side.json'),
          deezerHost: loadArtFixture('deezer_discovery.json'),
          mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
        });
        final out = await searchAll(
          q,
          fetch: fake.fetch,
          limiter: instantLimiter(),
        );
        expect(out.any((c) => c.source == ArtSource.caa), isTrue);
      });
    });
  });

  group('httpArtworkBytes (streamed download, cap + validation)', () {
    // [MockClient.streaming] hands back whatever [http.StreamedResponse] the
    // handler returns, so unlike the basic (Response-based) MockClient this
    // lets a test control the response's stream directly -- including
    // feeding it in multiple discrete chunks, which is what proves the
    // early-abort behavior below rather than just its end result.
    Future<List<int>?> download(
      Future<http.StreamedResponse> Function(
        http.BaseRequest request,
        http.ByteStream bodyStream,
      )
      handler,
    ) => httpArtworkBytes(
      'https://example.test/cover.jpg',
      clientFactory: () => MockClient.streaming(handler),
    );

    test('a valid image under the cap is returned', () async {
      final result = await download(
        (request, body) async =>
            http.StreamedResponse(Stream.value(onePixelPng), 200),
      );
      expect(result, onePixelPng);
    });

    test('a non-200 status is rejected', () async {
      final result = await download(
        (request, body) async =>
            http.StreamedResponse(Stream.value(onePixelPng), 404),
      );
      expect(result, isNull);
    });

    test('an empty body is rejected', () async {
      final result = await download(
        (request, body) async =>
            http.StreamedResponse(const Stream.empty(), 200),
      );
      expect(result, isNull);
    });

    test(
      'an HTML body served with a 200 (e.g. a redirect/error landing page '
      'for a URL that is not a direct image link) is rejected -- never '
      'stored as a "successful" pick (adversarial review finding 6)',
      () async {
        final html = utf8.encode(
          '<!doctype html><html><body>Not Found</body></html>' * 5,
        );
        final result = await download(
          (request, body) async => http.StreamedResponse(
            Stream.value(html),
            200,
            headers: const {'content-type': 'text/html'},
          ),
        );
        expect(result, isNull);
      },
    );

    test('a truncated/non-image binary blob is also rejected', () async {
      final junk = List<int>.generate(64, (i) => i * 7 % 256);
      final result = await download(
        (request, body) async => http.StreamedResponse(Stream.value(junk), 200),
      );
      expect(result, isNull);
    });

    group('byte cap (adversarial review finding 5)', () {
      test('a declared Content-Length already over the cap is rejected '
          'WITHOUT ever subscribing to the body stream', () async {
        var subscribed = false;
        Stream<List<int>> body() async* {
          subscribed = true;
          yield onePixelPng;
        }

        final result = await download(
          (request, bodyStream) async => http.StreamedResponse(
            body(),
            200,
            contentLength: kArtworkMaxBytes + 1,
          ),
        );

        expect(result, isNull);
        expect(
          subscribed,
          isFalse,
          reason:
              'an already-oversize declared length must short-circuit '
              'before reading a single byte of the body',
        );
      });

      test(
        'a response with no declared length that trickles past the cap '
        'is aborted early -- not every chunk is pulled from the stream',
        () async {
          final chunk = Uint8List(1024 * 1024); // 1 MB, all zero
          // Deliberately far more chunks than needed to cross the cap, so a
          // failure to abort early is obvious (pulled would equal this).
          const totalChunksOffered = 40; // 40 MB offered, cap is 12 MB
          var pulled = 0;
          Stream<List<int>> chunks() async* {
            for (var i = 0; i < totalChunksOffered; i++) {
              pulled++;
              yield chunk;
            }
          }

          final result = await download(
            (request, bodyStream) async => http.StreamedResponse(chunks(), 200),
          );

          expect(result, isNull);
          expect(
            pulled,
            lessThan(totalChunksOffered),
            reason:
                'the download must abort the instant the running total '
                'passes the cap, not after consuming the whole (deliberately '
                'oversized) stream',
          );
          expect(
            pulled,
            lessThanOrEqualTo(kArtworkMaxBytes ~/ chunk.length + 1),
          );
        },
      );

      test('a real-world-sized cover well under the cap is still accepted '
          '(the cap does not clip legitimate large art)', () async {
        final big =
            Uint8List(500 * 1024) // 500 KB
              ..setRange(0, onePixelPng.length, onePixelPng);
        final result = await download(
          (request, bodyStream) async =>
              http.StreamedResponse(Stream.value(big), 200),
        );
        expect(result, big);
      });
    });
  });
}
