// Last modified: 2026-07-25--2214
//
// Plan 4 MERGE tests: the seam that joins A1 (providers + scoring), A2
// (sidecar store + resolution chain + background pass) and A3 (picker).
//
// The three branches were each green in isolation against their own stubs;
// the failure modes this file exists to catch are the ones only a joined
// build can have -- a normalizer that disagrees with the album key, the
// >=75/>=10 auto-apply rule being lost in translation, a picker choice that
// lands under a different key than the background pass would use, or the
// grid hammering a provider with one request per tile.
//
// NO NETWORK, as the plan requires: every ArtworkWiring here is constructed
// with a fake [ArtFetch] (provider JSON) and a fake image fetch, and file
// I/O only ever touches a temp dir the test creates and deletes. L:\music is
// never touched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_backfill.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/artwork/artwork_wiring.dart';
import 'package:fooplayer_app/artwork/picker_seams.dart';
import 'package:fooplayer_app/artwork/providers.dart';
import 'package:fooplayer_app/artwork/scoring.dart' as scoring;
import 'package:fooplayer_app/model/track.dart';
import 'package:path/path.dart' as p;

import 'support/artwork_fixtures.dart';

const itunesHost = 'itunes.apple.com';
const deezerHost = 'api.deezer.com';
const mbHost = 'musicbrainz.org';

/// Records every image URL asked for, and answers from a canned map.
/// Anything not in the map is "no bytes", i.e. a rejected candidate.
class FakeImageFetch {
  final Map<String, List<int>> byUrl;
  final List<String> requested = [];

  FakeImageFetch(this.byUrl);

  Future<List<int>?> call(String url) async {
    requested.add(url);
    return byUrl[url];
  }
}

/// Track fixture pointing at [file] under [root].
Track trackAt(
  Directory root,
  String relPath, {
  String artist = 'Pink Floyd',
  String album = 'The Dark Side of the Moon',
  String title = 'Time',
  String contentId = 't1',
}) => Track(
  contentId: contentId,
  relPath: relPath,
  rootPath: root.path,
  dateAdded: DateTime.utc(2024, 1, 1),
  title: title,
  artist: artist,
  album: album,
);

/// 1x1 transparent PNG -- valid image bytes without any asset access.
final Uint8List pngBytes = Uint8List.fromList(const [
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

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('artwork_wiring_');
    root = Directory(p.join(tmp.path, 'music'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows sometimes holds a handle briefly; a leftover temp dir is
      // harmless.
    }
  });

  ArtworkWiring buildWiring({
    FakeArtFetch? provider,
    FakeImageFetch? imageFetch,
    bool backfillEnabled = true,
    ArtworkLocalReader? readLocal,
    bool preferSidecar = true,
    ArtworkEmbeddedLoader? embeddedLoader,
    RateLimiter? caaLimiter,
  }) {
    final stores = ArtworkStoreRegistry(appDataDir: appData);
    return ArtworkWiring(
      stores: stores,
      resolver: ArtworkResolver(
        stores: stores,
        preferSidecar: preferSidecar,
        embeddedLoader: embeddedLoader ?? (_) async => null,
      ),
      fetch: (provider ?? FakeArtFetch({})).fetch,
      imageFetch: (imageFetch ?? FakeImageFetch({})).call,
      readLocal: readLocal ?? (_) async => null,
      caaLimiter: caaLimiter,
      backfillEnabled: backfillEnabled,
      gap: Duration.zero,
    );
  }

  FakeArtFetch itunesOnly(String fixture) =>
      FakeArtFetch.bodies({'itunes.apple.com': loadArtFixture(fixture)});

  group('one normalizer, one album key', () {
    test('picker, scorer and store all derive the same key for a track', () {
      final t = trackAt(
        root,
        'a.mp3',
        artist: 'Sigur Rós',
        album: 'Ágætis Byrjun (Deluxe Edition)',
        title: 'Svefn-g-englar',
      );
      final fromPicker = albumKeyForTrack(t);
      final fromResolver = ArtworkRequest.forTrack(t).albumKey;
      final fromScorer = scoring.albumKey(
        artist: t.artist,
        album: t.album,
        title: t.title,
      );
      expect(fromPicker, fromResolver);
      expect(fromPicker, fromScorer);
      expect(fromPicker, 'sigur ros|agaetis byrjun');
    });

    test('picker and resolver still agree for a fully-untagged track '
        '(adversarial review finding 7 -- the per-file fallback key)', () {
      // Two untagged rips, same filename-derived title ("01" from
      // "01.mp3"), in two different folders under the same root.
      final a = trackAt(
        root,
        'Album A/01.mp3',
        artist: '',
        album: '',
        title: '01',
        contentId: 'a',
      );
      final b = trackAt(
        root,
        'Album B/01.mp3',
        artist: '',
        album: '',
        title: '01',
        contentId: 'b',
      );

      // [ArtworkServices.albumKey] (what the picker displays/looks up) and
      // [ArtworkRequest.forTrack] (what the resolver/store actually key
      // off) MUST still agree for each track -- a mismatch here would make
      // the picker's "current selection" lookup miss what was really
      // stored.
      expect(albumKeyForTrack(a), ArtworkRequest.forTrack(a).albumKey);
      expect(albumKeyForTrack(b), ArtworkRequest.forTrack(b).albumKey);

      // And the actual point of the fix: the two different files no longer
      // collapse onto the same key.
      expect(albumKeyForTrack(a), isNot(albumKeyForTrack(b)));
    });

    test('the picker no longer carries its own placeholder normalizer', () {
      // The old A3 placeholder folded no diacritics and knew nothing about
      // "- EP" tails; these two cases are exactly where it diverged.
      expect(normalizeArtworkKeyPart('Björk'), 'bjork');
      expect(normalizeArtworkKeyPart('Bloom - EP'), 'bloom');
      expect(
        normalizeArtworkKeyPart('Simon & Garfunkel'),
        'simon and garfunkel',
      );
    });

    test("a query's derived key matches the track it was built from", () {
      final t = trackAt(root, 'a.mp3', album: '', title: 'Loose Single');
      expect(
        artworkQueryForTrack(t).albumKey,
        ArtworkRequest.forTrack(t).albumKey,
      );
    });
  });

  group('A1 -> A2 auto-apply adapter', () {
    test('a clear winner is picked and carries the sidecar source id', () {
      final w = buildWiring();
      final pick = w.autoPick(
        [
          const ArtCandidate(
            url: 'https://x/dsotm.jpg',
            source: ArtSource.itunes,
            title: 'The Dark Side of the Moon',
            artist: 'Pink Floyd',
            width: 600,
          ),
          const ArtCandidate(
            url: 'https://x/other.jpg',
            source: ArtSource.deezer,
            title: 'Now That is What I Call Music 42',
            artist: 'Various Artists',
            width: 500,
          ),
        ],
        const ArtworkQuery(
          artist: 'Pink Floyd',
          album: 'The Dark Side of the Moon',
        ),
      );
      expect(pick, isNotNull);
      expect(pick!.url, 'https://x/dsotm.jpg');
      expect(pick.source, 'itunes'); // wire spelling, not Enum.name
    });

    test(
      'a near-tie between two DIFFERENT albums returns null (>=10 margin)',
      () {
        final w = buildWiring();
        final pick = w.autoPick([
          const ArtCandidate(
            url: 'https://x/gh1.jpg',
            source: ArtSource.itunes,
            title: 'Greatest Hits',
            artist: 'Queen',
            width: 600,
          ),
          const ArtCandidate(
            url: 'https://x/gh2.jpg',
            source: ArtSource.itunes,
            title: 'Greatest Hits II',
            artist: 'Queen',
            width: 600,
          ),
        ], const ArtworkQuery(artist: 'Queen', album: 'Greatest Hits'));
        expect(pick, isNull, reason: 'ambiguous -> defer to the picker');
      },
    );

    test('an empty / non-candidate list is null, never a throw', () {
      final w = buildWiring();
      const q = ArtworkQuery(artist: 'A', album: 'B');
      expect(w.autoPick(const [], q), isNull);
      expect(w.autoPick(<dynamic>['junk', 42], q), isNull);
    });
  });

  group('provider search adapter', () {
    test('real provider JSON becomes ranked picker candidates', () async {
      final provider = itunesOnly('itunes_dark_side.json');
      final w = buildWiring(provider: provider);
      final found = await w.searchCandidates(
        'Pink Floyd',
        'The Dark Side of the Moon',
      );
      expect(found, isNotEmpty);
      final top = toPickerCandidate(found.first);
      expect(top.source, 'itunes');
      expect(top.url, contains('600x600bb'));
      expect(top.resolutionLabel, '600 × 600');
      // Ranked best-first by the shared scorer.
      expect(found.first.title, 'The Dark Side of the Moon');
    });

    test('results are cached per album key; forceRefresh re-queries', () async {
      final provider = itunesOnly('itunes_dark_side.json');
      final w = buildWiring(provider: provider);
      await w.searchCandidates('Pink Floyd', 'The Dark Side of the Moon');
      final afterFirst = provider.calls.length;
      await w.searchCandidates('Pink Floyd', 'The Dark Side of the Moon');
      expect(provider.calls.length, afterFirst, reason: 'served from cache');
      await w.searchCandidates(
        'Pink Floyd',
        'The Dark Side of the Moon',
        forceRefresh: true,
      );
      expect(provider.calls.length, greaterThan(afterFirst));
    });

    test(
      'a transport that throws degrades to [] rather than an exception',
      () async {
        final stores = ArtworkStoreRegistry(appDataDir: appData);
        final w = ArtworkWiring(
          stores: stores,
          resolver: ArtworkResolver(stores: stores),
          fetch: throwingArtFetch,
          imageFetch: (_) async => null,
        );
        expect(await w.searchCandidates('A', 'B'), isEmpty);
      },
    );

    group('picker priority + CAA budget through the real seam '
        '(adversarial review finding 2)', () {
      test("the picker's search jumps a queue of background backfill "
          'lookups on the shared CAA limiter', () async {
        final clock = FakeClock();
        final limiter = RateLimiter(
          minInterval: kMusicBrainzMinInterval,
          sleep: clock.sleep,
          now: clock.now,
        );
        final provider = FakeArtFetch.bodies({
          itunesHost: '{"results": []}',
          deezerHost: '{"data": []}',
          mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
        });
        final w = buildWiring(provider: provider, caaLimiter: limiter);
        final order = <String>[];

        // A handful of queued background lookups, exactly what
        // ArtworkBackfill's own workers would be doing via searchForBackfill.
        for (var i = 0; i < 5; i++) {
          unawaited(
            w
                .searchForBackfill(
                  ArtworkQuery(artist: 'Bg', album: 'Album $i'),
                )
                .then((_) => order.add('background-$i')),
          );
        }

        // The user opens the picker for a DIFFERENT album right after.
        unawaited(
          w
              .searchCandidates(
                'Radiohead',
                'OK Computer',
                priority: RateLimitPriority.interactive,
              )
              .then((_) => order.add('interactive')),
        );

        while (order.length < 6) {
          await Future<void>.delayed(Duration.zero);
        }

        // 'background-0' was already dispatched (t=0, nothing queued yet)
        // by the time the interactive request arrived -- everything queued
        // BEHIND it must yield.
        expect(order.first, 'background-0');
        expect(
          order[1],
          'interactive',
          reason:
              "the picker's search must not sit behind several "
              "already-queued background lookups on MusicBrainz -- "
              "that's the 'spinner waits minutes' bug this fixes",
        );
      });

      test('a picker search proceeds with iTunes/Deezer results when CAA '
          'never answers, instead of hanging', () async {
        final caaGate = Completer<void>(); // never completed in this test
        Future<ArtHttpResponse> fetch(
          Uri url, {
          Map<String, String>? headers,
        }) async {
          if (url.host == mbHost) {
            await caaGate.future;
            return const ArtHttpResponse(statusCode: 200, body: '{}');
          }
          if (url.host == itunesHost) {
            return ArtHttpResponse(
              statusCode: 200,
              body: loadArtFixture('itunes_dark_side.json'),
            );
          }
          return const ArtHttpResponse(statusCode: 200, body: '{"data": []}');
        }

        final stores = ArtworkStoreRegistry(appDataDir: appData);
        final w = ArtworkWiring(
          stores: stores,
          resolver: ArtworkResolver(stores: stores),
          fetch: fetch,
          imageFetch: (_) async => null,
          caaLimiter: RateLimiter(
            minInterval: Duration.zero,
            sleep: (_) async {},
          ),
          gap: Duration.zero,
        );

        final sw = Stopwatch()..start();
        final found = await w.searchCandidates(
          'Pink Floyd',
          'The Dark Side of the Moon',
          priority: RateLimitPriority.interactive,
          caaBudget: const Duration(milliseconds: 100),
        );
        sw.stop();

        expect(found.any((c) => c.source == ArtSource.itunes), isTrue);
        expect(found.any((c) => c.source == ArtSource.caa), isFalse);
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'a picker search must return once its budget for CAA '
              'expires, not hang on a slow/stuck provider',
        );
      });

      test('searchForBackfill (the automatic pass) keeps waiting for CAA -- '
          'no budget applied to the background path', () async {
        final provider = FakeArtFetch.bodies({
          itunesHost: '{"results": []}',
          deezerHost: '{"data": []}',
          mbHost: loadArtFixture('musicbrainz_ok_computer.json'),
        });
        final w = buildWiring(
          provider: provider,
          caaLimiter: RateLimiter(
            minInterval: Duration.zero,
            sleep: (_) async {},
          ),
        );
        final found = await w.searchForBackfill(
          const ArtworkQuery(artist: 'Radiohead', album: 'OK Computer'),
        );
        expect(
          found.whereType<ArtCandidate>().any((c) => c.source == ArtSource.caa),
          isTrue,
          reason:
              'the background pass has nobody waiting on it and must '
              'still get a CAA answer that arrives promptly',
        );
      });
    });
  });

  group('picker services', () {
    test('applying a candidate writes the sidecar under the TRACK key, not '
        'the shared album key, and refreshes every surface', () async {
      final images = FakeImageFetch({'https://x/cover.jpg': pngBytes});
      final w = buildWiring(imageFetch: images);
      final track = trackAt(root, 'Pink Floyd/DSOTM/01.flac');
      var revisions = 0;
      w.resolver.addListener(() => revisions++);

      await w.services.apply(
        track,
        albumKeyForTrack(track),
        const ArtworkChoice(
          source: ArtworkSource.itunes,
          url: 'https://x/cover.jpg',
          query: 'Pink Floyd The Dark Side of the Moon',
        ),
      );

      final sidecar = File(p.join(root.path, '.artwork.json'));
      expect(sidecar.existsSync(), isTrue);
      final json = jsonDecode(sidecar.readAsStringSync()) as Map;
      expect(json['schema'], 1);
      // A hand pick from the picker is a statement about THIS track and
      // nothing else -- it never writes the album key, which is what let a
      // pick made for one track silently replace the cover on every OTHER
      // track sharing that album label (see ArtworkApplyScope's doc).
      final artMap = json['art'] as Map;
      expect(artMap.containsKey(albumKeyForTrack(track)), isFalse);
      final art = artMap[trackArtKey(track.contentId)] as Map;
      expect(art['source'], 'itunes');
      expect(art['query'], 'Pink Floyd The Dark Side of the Moon');
      expect(art['origin'], 'https://x/cover.jpg');
      // Image landed in <root>/.artwork/, never in the album directory, and
      // there is exactly one of them now -- one key, one write, one file.
      expect(Directory(p.join(root.path, '.artwork')).listSync().length, 1);
      expect(
        Directory(p.join(root.path, 'Pink Floyd')).existsSync(),
        isFalse,
        reason: 'nothing is ever written inside an album dir',
      );
      // Resolver was invalidated so the now-playing bar re-resolves.
      expect(revisions, greaterThan(0));
      // ... and the chain now serves the picked bytes.
      final shown = await w.resolver.resolve(ArtworkRequest.forTrack(track));
      expect(shown, pngBytes);
    });

    test('an explicit pick outranks embedded tag art', () async {
      final images = FakeImageFetch({'https://x/cover.jpg': pngBytes});
      final embedded = Uint8List.fromList([1, 2, 3, 4]);
      final w = buildWiring(
        imageFetch: images,
        embeddedLoader: (_) async => embedded,
      );
      final track = trackAt(root, 'a/b.flac');
      expect(
        await w.resolver.resolve(ArtworkRequest.forTrack(track)),
        embedded,
        reason: 'no pick yet -> embedded art, exactly as before',
      );
      await w.services.apply(
        track,
        albumKeyForTrack(track),
        const ArtworkChoice(
          source: ArtworkSource.itunes,
          url: 'https://x/cover.jpg',
        ),
      );
      expect(
        await w.resolver.resolve(ArtworkRequest.forTrack(track)),
        pngBytes,
        reason: 'the user asked for this cover; it must actually show',
      );
    });

    test('choose-file reads the local path and records source=local', () async {
      final local = File(p.join(tmp.path, 'chosen.png'))
        ..writeAsBytesSync(pngBytes);
      final w = buildWiring(readLocal: readLocalArtworkFile);
      final track = trackAt(root, 'a/b.flac');
      await w.services.apply(
        track,
        albumKeyForTrack(track),
        ArtworkChoice(source: ArtworkSource.local, localPath: local.path),
      );
      // Filed under the track's own key -- a hand pick never touches the
      // album key (see the test above).
      final entry = w.stores
          .forRoot(root.path)
          .entryFor(trackArtKey(track.contentId));
      expect(entry, isNotNull);
      expect(entry!.source, 'local');
      expect(entry.origin, local.path);
      expect(entry.file, endsWith('.png'));
    });

    test('a download that fails throws, so the picker reports it instead of '
        'silently storing nothing', () async {
      final w = buildWiring(imageFetch: FakeImageFetch({}));
      final track = trackAt(root, 'a/b.flac');
      await expectLater(
        w.services.apply(
          track,
          albumKeyForTrack(track),
          const ArtworkChoice(
            source: ArtworkSource.url,
            url: 'https://x/missing.jpg',
          ),
        ),
        throwsA(isA<ArtworkApplyFailure>()),
      );
      expect(File(p.join(root.path, '.artwork.json')).existsSync(), isFalse);
    });

    test(
      'currentSelectionId marks the applied candidate; remove clears it',
      () async {
        final images = FakeImageFetch({'https://x/cover.jpg': pngBytes});
        final w = buildWiring(imageFetch: images);
        final track = trackAt(root, 'a/b.flac');
        final key = albumKeyForTrack(track);
        expect(w.services.currentSelectionId(track, key), isNull);

        await w.services.apply(
          track,
          key,
          const ArtworkChoice(
            source: ArtworkSource.itunes,
            url: 'https://x/cover.jpg',
          ),
        );
        expect(
          w.services.currentSelectionId(track, key),
          'https://x/cover.jpg',
        );

        await w.services.remove(track, key);
        expect(w.services.currentSelectionId(track, key), isNull);
        // Idempotent: removing again is a no-op, not an error.
        await w.services.remove(track, key);
      },
    );

    test('"Search again" bypasses AND clears the negative cache', () async {
      final provider = itunesOnly('itunes_dark_side.json');
      final w = buildWiring(provider: provider);
      final track = trackAt(root, 'a/b.flac');
      final key = albumKeyForTrack(track);
      final store = w.stores.forRoot(root.path);
      await store.ensureLoaded();
      await store.recordMiss(key, query: 'whatever');
      expect(store.isNegative(key), isTrue);

      final found = await w.services.search(
        track,
        artworkQueryForTrack(track),
        forceRefresh: true,
      );
      expect(found, isNotEmpty);
      expect(
        store.isNegative(key),
        isFalse,
        reason: 'a user-initiated retry must not stay suppressed',
      );
    });

    test(
      'the picker search loads the sidecar before the grid is built',
      () async {
        // currentSelectionId is synchronous; it can only be right if search()
        // awaited ensureLoaded(). Write a sidecar behind the store's back and
        // check the picker still sees it.
        final key = albumKeyForTrack(trackAt(root, 'a/b.flac'));
        File(p.join(root.path, '.artwork.json')).writeAsStringSync(
          jsonEncode({
            'schema': 1,
            'art': {
              key: {
                'file': 'x.jpg',
                'source': 'deezer',
                'pickedAt': DateTime.utc(2026).toIso8601String(),
                'query': 'q',
                'origin': 'https://x/prev.jpg',
              },
            },
            'misses': <String, dynamic>{},
          }),
        );
        final w = buildWiring(provider: itunesOnly('itunes_empty.json'));
        final track = trackAt(root, 'a/b.flac');
        expect(w.services.currentSelectionId(track, key), isNull);
        await w.services.search(track, artworkQueryForTrack(track));
        expect(w.services.currentSelectionId(track, key), 'https://x/prev.jpg');
      },
    );
  });

  group('image cache manners', () {
    test('one request per URL no matter how many tiles ask', () async {
      final images = FakeImageFetch({'u': pngBytes});
      final cache = ArtworkImageCache(fetch: images.call);
      final all = await Future.wait([
        for (var i = 0; i < 8; i++) cache.bytes('u'),
      ]);
      expect(images.requested, ['u']);
      expect(all.every((b) => b != null), isTrue);
      // Second round is served from the cache, still one request.
      await cache.bytes('u');
      expect(images.requested, ['u']);
    });

    test(
      'a failed fetch is cached as "no bytes" and not retried in a loop',
      () async {
        final images = FakeImageFetch({});
        final cache = ArtworkImageCache(fetch: images.call);
        expect(await cache.bytes('gone'), isNull);
        expect(await cache.bytes('gone'), isNull);
        expect(images.requested, ['gone']);
      },
    );

    test('never more than maxConcurrent fetches are open at once', () async {
      var open = 0;
      var peak = 0;
      final cache = ArtworkImageCache(
        maxConcurrent: 3,
        fetch: (url) async {
          open++;
          peak = open > peak ? open : peak;
          await Future<void>.delayed(Duration.zero);
          open--;
          return pngBytes;
        },
      );
      await Future.wait([for (var i = 0; i < 20; i++) cache.bytes('u$i')]);
      expect(peak, lessThanOrEqualTo(3));
    });

    test('the LRU is bounded', () async {
      final cache = ArtworkImageCache(
        maxEntries: 4,
        fetch: (_) async => pngBytes,
      );
      for (var i = 0; i < 20; i++) {
        await cache.bytes('u$i');
      }
      expect(cache.cachedCount, 4);
    });

    test('an empty URL never reaches the transport', () async {
      final images = FakeImageFetch({});
      final cache = ArtworkImageCache(fetch: images.call);
      expect(await cache.bytes(''), isNull);
      expect(images.requested, isEmpty);
    });
  });

  group('background best-guess pass, end to end', () {
    test('a confident album is auto-applied from real provider JSON', () async {
      final provider = itunesOnly('itunes_dark_side.json');
      final images = FakeImageFetch({});
      final w = buildWiring(provider: provider, imageFetch: images);
      final track = trackAt(root, 'Pink Floyd/DSOTM/01.flac');
      // The downloader answers whatever URL the scorer settled on.
      final pick = w.autoPick(
        await w.searchCandidates(track.artist, track.album),
        ArtworkRequest.forTrack(track).query,
      );
      expect(pick, isNotNull);
      images.byUrl[pick!.url] = pngBytes;

      final result = await w.backfill.lookupOne(ArtworkRequest.forTrack(track));
      expect(result, ArtworkLookupResult.applied);

      final entry = w.stores
          .forRoot(root.path)
          .entryFor(albumKeyForTrack(track));
      expect(entry, isNotNull);
      expect(entry!.source, 'itunes');
      expect(entry.origin, pick.url);
      expect(File(p.join(root.path, '.artwork.json')).existsSync(), isTrue);
    });

    test('an ambiguous album records a miss and applies nothing', () async {
      final provider = itunesOnly('itunes_greatest_hits.json');
      final w = buildWiring(provider: provider);
      final track = trackAt(
        root,
        'Queen/GH/01.flac',
        artist: 'Queen',
        album: 'Greatest Hits',
      );
      final result = await w.backfill.lookupOne(ArtworkRequest.forTrack(track));
      expect(result, ArtworkLookupResult.noConfidentMatch);
      final store = w.stores.forRoot(root.path);
      expect(store.entryFor(albumKeyForTrack(track)), isNull);
      expect(store.isNegative(albumKeyForTrack(track)), isTrue);
    });

    test('albums that already show art are never looked up', () async {
      final provider = itunesOnly('itunes_dark_side.json');
      final w = buildWiring(
        provider: provider,
        embeddedLoader: (_) async => pngBytes,
      );
      final track = trackAt(root, 'a/b.flac');
      final result = await w.backfill.lookupOne(ArtworkRequest.forTrack(track));
      expect(result, ArtworkLookupResult.alreadyHadArt);
      expect(provider.calls, isEmpty, reason: 'no provider traffic at all');
    });

    test(
      'the pass is off when disabled, but the manual path still works',
      () async {
        final provider = itunesOnly('itunes_dark_side.json');
        final w = buildWiring(provider: provider, backfillEnabled: false);
        final track = trackAt(root, 'a/b.flac');
        await w.backfill.run([ArtworkRequest.forTrack(track)]);
        expect(provider.calls, isEmpty);
        await w.backfill.lookupOne(ArtworkRequest.forTrack(track));
        expect(provider.calls, isNotEmpty);
      },
    );
  });

  group('small adapters', () {
    test('ArtCandidate -> PickerCandidate is lossless', () {
      const c = ArtCandidate(
        url: 'https://x/full.jpg',
        thumbUrl: 'https://x/thumb.jpg',
        source: ArtSource.caa,
        title: 'OK Computer',
        artist: 'Radiohead',
        year: 1997,
        width: 500,
      );
      final pc = toPickerCandidate(c);
      expect(pc.url, c.url);
      expect(pc.thumbUrl, c.thumbUrl);
      expect(pc.source, 'caa');
      expect(artworkSourceLabel(pc.source), 'Cover Art Archive');
      expect(pc.title, c.title);
      expect(pc.artist, c.artist);
      expect(pc.year, 1997);
      expect(pc.width, 500);
      expect(pc.previewUrl, 'https://x/thumb.jpg');
    });

    test('the stored extension follows the source, defaulting to .jpg', () {
      expect(artworkExtensionFor('https://x/a/cover.png'), '.png');
      expect(artworkExtensionFor('https://x/a/cover.JPG?v=2'), '.jpg');
      expect(artworkExtensionFor(r'C:\pics\art.webp'), '.webp');
      expect(artworkExtensionFor('https://x/600x600bb'), '.jpg');
      expect(artworkExtensionFor('https://x/a.tiff'), '.jpg');
    });
  });
}
