// Last modified: 2026-07-25--2208
//
// Plan 4 / A2: the throttled background best-guess pass.
//
// Covers: albums that already have art are skipped, the >=75/>=10
// auto-apply decision is respected verbatim (it lives behind the injected
// autoPick seam -- a null pick records a timestamped negative result and
// applies NOTHING), the negative cache suppresses automatic retries and is
// bypassed+cleared by a manual "Search again", concurrency is capped, and
// cancel() stops the pass promptly.
//
// Every provider/download call is an injected fake -- no test here opens a
// socket.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_backfill.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:path/path.dart' as p;

// putImage() now validates magic bytes (adversarial review finding 6), and
// this fixture flows all the way through applyImage -> putImage in every
// test that exercises a full "applied" pick, so it needs a real PNG
// signature prefix.
final downloadedBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7, 7];

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fooplayer_artwork_backfill');
    root = Directory(p.join(tmp.path, 'root'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ArtworkRequest req(String album, {Directory? inRoot}) {
    final r = inRoot ?? root;
    return ArtworkRequest(
      rootPath: r.path,
      file: File(p.join(r.path, '$album.mp3')),
      artist: 'Artist',
      album: album,
    );
  }

  Track trackFor(String album, {Directory? inRoot}) {
    final r = inRoot ?? root;
    return Track(
      contentId: album,
      relPath: '$album.mp3',
      rootPath: r.path,
      dateAdded: DateTime.utc(2026),
      title: album,
      artist: 'Artist',
      album: album,
    );
  }

  ({
    ArtworkResolver resolver,
    ArtworkStoreRegistry stores,
  }) makeResolver({Future<List<int>?> Function(File)? embedded}) {
    final stores = ArtworkStoreRegistry(appDataDir: appData);
    final resolver = ArtworkResolver(
      stores: stores,
      embeddedLoader: embedded ?? (_) async => null,
    );
    addTearDown(resolver.dispose);
    return (resolver: resolver, stores: stores);
  }

  test('applies a confident pick: downloads, stores, and refreshes', () async {
    final r = makeResolver();
    final searched = <String>[];
    final downloaded = <String>[];
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (q) async {
        searched.add(q.terms);
        return ['candidate'];
      },
      autoPick: (c, q) =>
          const ArtworkPick(url: 'https://example.invalid/a.jpg', source: 'itunes'),
      downloader: (url) async {
        downloaded.add(url);
        return downloadedBytes;
      },
    );

    var notified = 0;
    r.resolver.addListener(() => notified++);

    await backfill.run([req('Discovery')]);

    expect(searched, ['Artist Discovery']);
    expect(downloaded, ['https://example.invalid/a.jpg']);
    expect(backfill.appliedCount, 1);
    expect(notified, greaterThanOrEqualTo(1));

    final store = r.stores.forRoot(root.path);
    expect(store.entryFor('artist|discovery')?.source, 'itunes');
    expect(await store.readImage('artist|discovery'), downloadedBytes);
    expect(await r.resolver.resolve(req('Discovery')), downloadedBytes);
    // The chosen art landed under the ROOT, never in an album directory.
    expect(
      File(p.join(root.path, artworkCacheDirName,
              store.entryFor('artist|discovery')!.file))
          .existsSync(),
      isTrue,
    );
  });

  test('albums that already have art are never looked up', () async {
    // Embedded art present for every file.
    final r = makeResolver(embedded: (_) async => [1, 2, 3]);
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async {
        searches++;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run([req('Discovery'), req('Homework')]);
    expect(searches, 0);
    expect(backfill.appliedCount, 0);
  });

  test('no confident match: records a negative result and applies nothing',
      () async {
    final r = makeResolver();
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async => ['weak', 'also weak'],
      // A near-tie / low score -> A1's bestGuess returns null. A wrong cover
      // silently applied is worse than none.
      autoPick: (_, _) => null,
      downloader: (_) async => downloadedBytes,
    );

    final result = await backfill.lookupOne(req('Discovery'));
    expect(result, ArtworkLookupResult.noConfidentMatch);
    expect(backfill.appliedCount, 0);

    final store = r.stores.forRoot(root.path);
    expect(store.entryFor('artist|discovery'), isNull);
    expect(store.isNegative('artist|discovery'), isTrue);
    expect(store.sidecar.misses['artist|discovery']!.query, 'Artist Discovery');
  });

  test('the negative cache suppresses the next automatic lookup', () async {
    final r = makeResolver();
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async {
        searches++;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    expect(await backfill.lookupOne(req('Discovery')),
        ArtworkLookupResult.noConfidentMatch);
    expect(searches, 1);

    expect(await backfill.lookupOne(req('Discovery')),
        ArtworkLookupResult.suppressedByNegativeCache);
    expect(searches, 1, reason: 'no second query for a known-hopeless album');
  });

  test('manual "Search again" bypasses AND clears the negative cache',
      () async {
    final r = makeResolver();
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async {
        searches++;
        return ['candidate'];
      },
      autoPick: (_, _) => searches >= 2
          ? const ArtworkPick(url: 'https://example.invalid/b.jpg', source: 'deezer')
          : null,
      downloader: (_) async => downloadedBytes,
    );

    await backfill.lookupOne(req('Discovery'));
    final store = r.stores.forRoot(root.path);
    expect(store.isNegative('artist|discovery'), isTrue);

    final result =
        await backfill.lookupOne(req('Discovery'), bypassNegativeCache: true);
    expect(searches, 2);
    expect(result, ArtworkLookupResult.applied);
    expect(store.isNegative('artist|discovery'), isFalse);
    expect(store.entryFor('artist|discovery')?.source, 'deezer');
  });

  test('a provider that throws is not recorded as a negative result',
      () async {
    final r = makeResolver();
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async => throw const SocketException('offline'),
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    expect(await backfill.lookupOne(req('Discovery')),
        ArtworkLookupResult.searchFailed);
    expect(r.stores.forRoot(root.path).isNegative('artist|discovery'), isFalse,
        reason: 'a network failure says nothing about whether art exists');
  });

  test('a failed download applies nothing and does not poison the sidecar',
      () async {
    final r = makeResolver();
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async => ['candidate'],
      autoPick: (_, _) =>
          const ArtworkPick(url: 'https://example.invalid/c.jpg', source: 'caa'),
      downloader: (_) async => null,
    );

    expect(await backfill.lookupOne(req('Discovery')),
        ArtworkLookupResult.downloadFailed);
    expect(r.stores.forRoot(root.path).entryFor('artist|discovery'), isNull);
  });

  test('duplicate albums in the request list are looked up once', () async {
    final r = makeResolver();
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      search: (_) async {
        searches++;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run([req('Discovery'), req('Discovery'), req('Discovery')]);
    expect(searches, 1);
    expect(backfill.consideredCount, 1);
  });

  test('the SAME album under two roots is looked up once PER ROOT', () async {
    // The user's own library is exactly this shape: `L:\music` plus a
    // reorganized copy of the same albums under a second root. Deduping the
    // pass on the album key alone gave the album one lookup total, so the
    // second root's `.artwork.json` never got an entry (and no miss either,
    // so nothing ever marked it unresolved).
    final otherRoot = Directory(p.join(tmp.path, 'root2'))
      ..createSync(recursive: true);
    final r = makeResolver();
    final searched = <String>[];
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 1,
      search: (q) async {
        searched.add(q.terms);
        return ['candidate'];
      },
      autoPick: (_, _) => const ArtworkPick(
        url: 'https://example.invalid/a.jpg',
        source: 'itunes',
      ),
      downloader: (_) async => downloadedBytes,
    );

    await backfill.run([
      req('Discovery'),
      req('Discovery', inRoot: otherRoot),
    ]);

    expect(searched.length, 2, reason: 'one lookup per (root, album)');
    expect(backfill.consideredCount, 2);
    expect(backfill.appliedCount, 2);

    for (final dir in [root, otherRoot]) {
      final store = r.stores.forRoot(dir.path);
      expect(store.entryFor('artist|discovery'), isNotNull,
          reason: '${dir.path} must get its own sidecar entry');
      expect(await store.readImage('artist|discovery'), downloadedBytes);
      expect(File(p.join(dir.path, artworkSidecarName)).existsSync(), isTrue);
    }
  });

  test('two roots are still deduped WITHIN each root', () async {
    final otherRoot = Directory(p.join(tmp.path, 'root2'))
      ..createSync(recursive: true);
    final r = makeResolver();
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 1,
      search: (_) async {
        searches++;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run([
      req('Discovery'),
      req('Discovery'),
      req('Discovery', inRoot: otherRoot),
      req('Discovery', inRoot: otherRoot),
    ]);
    expect(searches, 2);
    expect(backfill.consideredCount, 2);
  });

  test('artworkBackfillRequests keeps the same album under two roots', () {
    Track at(String rootPath, String rel) => Track(
          contentId: '$rootPath/$rel',
          relPath: rel,
          rootPath: rootPath,
          dateAdded: DateTime.utc(2026),
          title: 'One',
          artist: 'Daft Punk',
          album: 'Discovery',
        );
    final requests = artworkBackfillRequests([
      at(root.path, 'a/1.mp3'),
      at(root.path, 'a/2.mp3'),
      at(p.join(tmp.path, 'root2'), 'Daft Punk/Discovery/1.mp3'),
    ]);
    expect(requests.length, 2);
    expect(requests.map((r) => r.rootPath).toSet().length, 2);
    expect(requests.map((r) => r.albumKey).toSet(), {'daft punk|discovery'});
  });

  group('"Remove artwork" is durable', () {
    ArtworkBackfill confidentBackfill(ArtworkResolver resolver, List<String> log) =>
        ArtworkBackfill(
          resolver: resolver,
          gap: Duration.zero,
          search: (q) async {
            log.add(q.terms);
            return ['candidate'];
          },
          autoPick: (_, _) => const ArtworkPick(
            url: 'https://example.invalid/auto.jpg',
            source: 'itunes',
          ),
          downloader: (_) async => downloadedBytes,
        );

    test('a removed cover is NOT silently re-applied by the next pass',
        () async {
      final r = makeResolver();
      final log = <String>[];
      final backfill = confidentBackfill(r.resolver, log);

      expect(await backfill.lookupOne(req('Discovery')),
          ArtworkLookupResult.applied);

      // The user rejects the auto-applied guess.
      await r.resolver.removeImage(req('Discovery'));
      final store = r.stores.forRoot(root.path);
      expect(store.entryFor('artist|discovery'), isNull);
      expect(store.isSuppressed('artist|discovery'), isTrue);

      // Next launch: a fresh pass must leave it alone.
      await backfill.run([req('Discovery')]);
      expect(log.length, 1, reason: 'no second query for a rejected album');
      expect(store.entryFor('artist|discovery'), isNull);
    });

    test('the suppression survives a restart and does not expire', () async {
      final r = makeResolver();
      final backfill = confidentBackfill(r.resolver, <String>[]);
      await backfill.lookupOne(req('Discovery'));
      await r.resolver.removeImage(req('Discovery'));

      // Reopen the sidecar from disk, well past the automatic-miss TTL.
      final reopened = ArtworkStore(
        root: root,
        appDataDir: appData,
        now: () => DateTime.now().toUtc().add(const Duration(days: 400)),
      );
      await reopened.ensureLoaded();
      expect(reopened.entryFor('artist|discovery'), isNull);
      expect(reopened.isSuppressed('artist|discovery'), isTrue);
      expect(reopened.isNegative('artist|discovery'), isTrue,
          reason: 'a user suppression has no TTL');
    });

    test('manual "Search again" lifts the suppression', () async {
      final r = makeResolver();
      final log = <String>[];
      final backfill = confidentBackfill(r.resolver, log);
      await backfill.lookupOne(req('Discovery'));
      await r.resolver.removeImage(req('Discovery'));

      final result =
          await backfill.lookupOne(req('Discovery'), bypassNegativeCache: true);
      expect(result, ArtworkLookupResult.applied);
      expect(log.length, 2);
      final store = r.stores.forRoot(root.path);
      expect(store.isSuppressed('artist|discovery'), isFalse);
      expect(store.entryFor('artist|discovery')?.source, 'itunes');
    });
  });

  test('never runs more than maxConcurrent lookups at once', () async {
    final r = makeResolver();
    var inFlight = 0;
    var peak = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 2,
      search: (_) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run(
      List.generate(8, (i) => req('Album $i')),
    );
    expect(peak, lessThanOrEqualTo(2));
    expect(backfill.consideredCount, 8);
  });

  test('cancel() stops the pass promptly and leaves nothing half-applied',
      () async {
    final r = makeResolver();
    var searches = 0;
    late ArtworkBackfill backfill;
    backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 1,
      search: (_) async {
        searches++;
        if (searches == 2) backfill.cancel();
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run(List.generate(20, (i) => req('Album $i')));
    expect(searches, 2, reason: 'stopped as soon as cancel() landed');
    expect(backfill.running, isFalse);
  });

  test('a new run supersedes the previous one instead of overlapping',
      () async {
    final r = makeResolver();
    var concurrentPasses = 0;
    var peakPasses = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 1,
      search: (_) async {
        concurrentPasses++;
        if (concurrentPasses > peakPasses) peakPasses = concurrentPasses;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        concurrentPasses--;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    final first = backfill.run(List.generate(6, (i) => req('First $i')));
    final second = backfill.run(List.generate(3, (i) => req('Second $i')));
    await Future.wait([first, second]);

    expect(peakPasses, 1);
    expect(backfill.running, isFalse);
  });

  test('enabled: false makes the automatic pass a no-op (but not the picker)',
      () async {
    final r = makeResolver();
    var searches = 0;
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      enabled: false,
      search: (_) async {
        searches++;
        return const [];
      },
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run([req('Discovery'), req('Homework')]);
    expect(searches, 0);
    expect(backfill.consideredCount, 0);
    // Nothing recorded -- crucially, no negative-cache entries that would
    // suppress the real providers for a fortnight once they are wired in.
    expect(r.stores.forRoot(root.path).isNegative('artist|discovery'), isFalse);

    // The picker's explicit path still works.
    await backfill.lookupOne(req('Discovery'));
    expect(searches, 1);
  });

  test('a burst of writes coalesces instead of rewriting per album', () async {
    final r = makeResolver();
    final backfill = ArtworkBackfill(
      resolver: r.resolver,
      gap: Duration.zero,
      maxConcurrent: 3,
      search: (_) async => const [],
      autoPick: (_, _) => null,
      downloader: (_) async => null,
    );

    await backfill.run(List.generate(30, (i) => req('Album $i')));

    // Every miss is still durably recorded...
    final reopened = ArtworkStore(root: root, appDataDir: appData);
    await reopened.ensureLoaded();
    expect(reopened.sidecar.misses.length, 30);
    // ...and the sidecar is intact (no interleaved/truncated write).
    expect(File(p.join(root.path, artworkSidecarTmpName)).existsSync(), isFalse);
  });

  test('artworkBackfillRequests collapses a library to one request per album',
      () {
    final tracks = [
      Track(
        contentId: '1',
        relPath: 'a/1.mp3',
        rootPath: root.path,
        dateAdded: DateTime.utc(2026),
        title: 'One',
        artist: 'Daft Punk',
        album: 'Discovery',
      ),
      Track(
        contentId: '2',
        relPath: 'a/2.mp3',
        rootPath: root.path,
        dateAdded: DateTime.utc(2026),
        title: 'Two',
        artist: 'Daft Punk',
        album: 'Discovery (Deluxe Edition)',
      ),
      Track(
        contentId: '3',
        relPath: 'b/3.mp3',
        rootPath: root.path,
        dateAdded: DateTime.utc(2026),
        title: 'Three',
        artist: 'Daft Punk',
        album: 'Homework',
      ),
    ];
    final requests = artworkBackfillRequests(tracks);
    expect(requests.map((r) => r.albumKey).toList(),
        ['daft punk|discovery', 'daft punk|homework']);
  });

  group('rescanThenBackfill (Fix 1: backfill after rescan)', () {
    test(
        'queues a pass over the tracks() snapshot taken AFTER rescan '
        'completes -- so newly-discovered albums are covered', () async {
      final r = makeResolver();
      final searched = <String>[];
      final backfill = ArtworkBackfill(
        resolver: r.resolver,
        gap: Duration.zero,
        search: (q) async {
          searched.add(q.terms);
          return const [];
        },
        autoPick: (_, _) => null,
        downloader: (_) async => null,
      );

      // A rescan that "discovers" a new track: empty until it completes,
      // exactly like LibraryModel.rescan() mutating allTracks.
      var tracks = <Track>[];
      Future<void> rescan() async {
        await Future<void>.delayed(Duration.zero);
        tracks = [trackFor('Discovery')];
      }

      await rescanThenBackfill(
        rescan: rescan,
        backfill: backfill,
        tracks: () => tracks,
      );

      expect(searched, ['Artist Discovery']);
    });

    test('awaits rescan in full before starting the backfill pass', () async {
      final r = makeResolver();
      final events = <String>[];
      final backfill = ArtworkBackfill(
        resolver: r.resolver,
        gap: Duration.zero,
        search: (q) async {
          events.add('search');
          return const [];
        },
        autoPick: (_, _) => null,
        downloader: (_) async => null,
      );

      final gate = Completer<void>();
      Future<void> rescan() async {
        events.add('rescan-start');
        await gate.future;
        events.add('rescan-end');
      }

      final future = rescanThenBackfill(
        rescan: rescan,
        backfill: backfill,
        tracks: () => [trackFor('Discovery')],
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, ['rescan-start'],
          reason: 'the backfill pass must not start until rescan settles');

      gate.complete();
      await future;
      expect(events, ['rescan-start', 'rescan-end', 'search']);
    });

    test('an empty post-rescan track list is a harmless no-op', () async {
      final r = makeResolver();
      var searches = 0;
      final backfill = ArtworkBackfill(
        resolver: r.resolver,
        gap: Duration.zero,
        search: (q) async {
          searches++;
          return const [];
        },
        autoPick: (_, _) => null,
        downloader: (_) async => null,
      );

      await rescanThenBackfill(
        rescan: () async {},
        backfill: backfill,
        tracks: () => const [],
      );

      expect(searches, 0);
    });
  });
}
