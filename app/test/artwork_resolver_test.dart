// Last modified: 2026-07-25--2115
//
// Plan 4 / A2: the display resolution chain.
//
// Covers the plan's A2 test list for the resolver half: chain precedence
// (embedded -> sidecar choice -> folder/cover/front.jpg -> null), in-memory
// caching, in-flight dedupe of concurrent same-album requests, invalidation
// on a pick, and the bounded LRU. No network: the only "loaders" here are
// injected fakes and files this test writes into its own temp dir.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:path/path.dart' as p;

final embeddedBytes = [1, 1, 1];
// putImage() now validates magic bytes (adversarial review finding 6), and
// sidecarBytes is the only one of these five fixtures that ever flows
// through it (the others stand in for embedded-tag reads or sibling files
// on disk, neither of which putImage sees) -- so it alone needs a real PNG
// signature prefix. The distinguishing [2, 2, 2] tail is kept so it still
// reads as "the sidecar one" and stays distinct from every other fixture.
final sidecarBytes = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  2,
  2,
  2,
  2,
];
final folderBytes = [3, 3, 3];
final coverBytes = [4, 4, 4];
final frontBytes = [5, 5, 5];

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;
  late Directory albumDir;
  late File audio;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fooplayer_artwork_resolver');
    root = Directory(p.join(tmp.path, 'root'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
    albumDir = Directory(p.join(root.path, 'Daft Punk', 'Discovery'))
      ..createSync(recursive: true);
    audio = File(p.join(albumDir.path, '01 One More Time.mp3'))
      ..writeAsBytesSync([0]);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ArtworkRequest request({String title = 'One More Time'}) => ArtworkRequest(
    rootPath: root.path,
    file: audio,
    artist: 'Daft Punk',
    album: 'Discovery',
    title: title,
  );

  ArtworkStoreRegistry registry() => ArtworkStoreRegistry(appDataDir: appData);

  group('resolution chain precedence', () {
    test(
      'embedded art wins over everything else (the plan\'s order)',
      () async {
        final reg = registry();
        await reg
            .forRoot(root.path)
            .putImage(request().albumKey, sidecarBytes, source: 'itunes');
        File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);

        final resolver = ArtworkResolver(
          stores: reg,
          embeddedLoader: (_) async => embeddedBytes,
        );
        addTearDown(resolver.dispose);

        expect(await resolver.resolve(request()), embeddedBytes);
      },
    );

    test('sidecar choice wins when there is no embedded art', () async {
      final reg = registry();
      await reg
          .forRoot(root.path)
          .putImage(request().albumKey, sidecarBytes, source: 'deezer');
      File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);

      final resolver = ArtworkResolver(
        stores: reg,
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);

      expect(await resolver.resolve(request()), sidecarBytes);
    });

    test('sibling image is the last resort, folder > cover > front', () async {
      File(p.join(albumDir.path, 'front.jpg')).writeAsBytesSync(frontBytes);
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);
      expect(await resolver.resolve(request()), frontBytes);

      File(p.join(albumDir.path, 'cover.jpg')).writeAsBytesSync(coverBytes);
      resolver.invalidateAll();
      expect(await resolver.resolve(request()), coverBytes);

      File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);
      resolver.invalidateAll();
      expect(await resolver.resolve(request()), folderBytes);
    });

    test(
      'nothing anywhere resolves to null (caller shows the placeholder)',
      () async {
        final resolver = ArtworkResolver(
          stores: registry(),
          embeddedLoader: (_) async => null,
        );
        addTearDown(resolver.dispose);
        expect(await resolver.resolve(request()), isNull);
      },
    );

    test('preferSidecar: true flips embedded and the recorded pick', () async {
      final reg = registry();
      await reg
          .forRoot(root.path)
          .putImage(request().albumKey, sidecarBytes, source: 'local');

      final resolver = ArtworkResolver(
        stores: reg,
        embeddedLoader: (_) async => embeddedBytes,
        preferSidecar: true,
      );
      addTearDown(resolver.dispose);
      expect(await resolver.resolve(request()), sidecarBytes);
    });

    test(
      'an embedded loader that throws falls through instead of surfacing',
      () async {
        File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);
        final resolver = ArtworkResolver(
          stores: registry(),
          embeddedLoader: (_) async => throw StateError('bad file'),
        );
        addTearDown(resolver.dispose);
        expect(await resolver.resolve(request()), folderBytes);
      },
    );
  });

  group('caching and dedupe', () {
    test(
      'concurrent requests for the same album share ONE resolution',
      () async {
        var calls = 0;
        final gate = Completer<List<int>?>();
        final resolver = ArtworkResolver(
          stores: registry(),
          embeddedLoader: (_) {
            calls++;
            return gate.future;
          },
        );
        addTearDown(resolver.dispose);

        // Two different TRACKS of the same album -> same album key.
        final a = resolver.resolve(request(title: 'One More Time'));
        final b = resolver.resolve(request(title: 'Aerodynamic'));
        expect(
          resolver.inFlightCount,
          1,
          reason: 'in-flight guard collapses the second request',
        );
        expect(identical(a, b), isTrue, reason: 'literally the same future');

        // Let the chain get as far as the (gated) embedded read.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls, 1);

        gate.complete(embeddedBytes);
        expect(await a, embeddedBytes);
        expect(await b, embeddedBytes);
        expect(calls, 1);
        expect(resolver.inFlightCount, 0);
      },
    );

    test('a resolved album is served from memory, not re-read', () async {
      var calls = 0;
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async {
          calls++;
          return embeddedBytes;
        },
      );
      addTearDown(resolver.dispose);

      final first = await resolver.resolve(request());
      final second = await resolver.resolve(request(title: 'Aerodynamic'));
      expect(calls, 1);
      // Same instance back, so Image.memory never re-decodes.
      expect(identical(first, second), isTrue);
    });

    test('a null result is cached too (no repeated tag parses)', () async {
      var calls = 0;
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async {
          calls++;
          return null;
        },
      );
      addTearDown(resolver.dispose);

      expect(await resolver.resolve(request()), isNull);
      expect(await resolver.resolve(request()), isNull);
      expect(calls, 1);
    });

    test(
      'invalidate() drops the album, bumps the revision and notifies',
      () async {
        var calls = 0;
        final resolver = ArtworkResolver(
          stores: registry(),
          embeddedLoader: (_) async {
            calls++;
            return embeddedBytes;
          },
        );
        addTearDown(resolver.dispose);

        await resolver.resolve(request());
        var notified = 0;
        resolver.addListener(() => notified++);
        final before = resolver.revision;

        resolver.invalidate(request().albumKey);
        expect(notified, 1);
        expect(resolver.revision, greaterThan(before));

        await resolver.resolve(request());
        expect(calls, 2);
      },
    );

    test(
      'a resolution that lands AFTER its album was invalidated is not cached',
      () async {
        var calls = 0;
        final gate = Completer<List<int>?>();
        final resolver = ArtworkResolver(
          stores: registry(),
          embeddedLoader: (_) {
            calls++;
            return calls == 1 ? gate.future : Future.value(sidecarBytes);
          },
        );
        addTearDown(resolver.dispose);

        final pending = resolver.resolve(request());
        resolver.invalidate(request().albumKey);
        gate.complete(embeddedBytes);
        expect(
          await pending,
          embeddedBytes,
        ); // the caller still gets its answer
        expect(resolver.cachedAlbumCount, 0, reason: 'stale result not cached');

        expect(await resolver.resolve(request()), sidecarBytes);
        expect(calls, 2);
      },
    );

    test('the byte cache is bounded (LRU eviction)', () async {
      var calls = 0;
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async {
          calls++;
          return embeddedBytes;
        },
        maxCachedAlbums: 2,
      );
      addTearDown(resolver.dispose);

      ArtworkRequest req(String album) => ArtworkRequest(
        rootPath: root.path,
        file: audio,
        artist: 'Daft Punk',
        album: album,
      );

      await resolver.resolve(req('Discovery'));
      await resolver.resolve(req('Homework'));
      await resolver.resolve(req('Human After All'));
      expect(resolver.cachedAlbumCount, 2);

      await resolver.resolve(req('Discovery')); // evicted -> resolved again
      expect(calls, 4);
    });

    test('invalidate() drops the matching in-flight future too, so a '
        'resolve() issued right after does not get handed stale bytes '
        '(adversarial review finding 3)', () async {
      // Exact interleave the reviewer's probe script demonstrated:
      // preferSidecar: true (production's default), a slow embedded read
      // still in flight when applyImage() writes a brand-new sidecar entry
      // and calls invalidate(), then a SECOND resolve() call for the same
      // request -- exactly what AlbumArt's _onArtworkChanged does when it
      // sees the resolver's revision bump.
      final reg = registry();
      final store = reg.forRoot(root.path);
      final slowGate = Completer<void>();
      var embeddedCalls = 0;

      final resolver = ArtworkResolver(
        stores: reg,
        preferSidecar: true,
        embeddedLoader: (_) async {
          embeddedCalls++;
          await slowGate.future;
          return null; // no embedded art
        },
      );
      addTearDown(resolver.dispose);

      final req = request();

      // Step 1: first resolve() -- falls through preferSidecar (no entry
      // yet) into the slow embedded read.
      final first = resolver.resolve(req);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Step 2: a pick lands WHILE step 1 is still stuck in the slow read.
      await resolver.applyImage(req, sidecarBytes, source: 'itunes');
      expect(store.entryFor(req.albumKey), isNotNull);

      // Step 3: a forced re-resolve for the SAME request, right after the
      // pick -- must NOT be handed the stale pre-invalidation future.
      final second = resolver.resolve(req);
      expect(
        identical(first, second),
        isFalse,
        reason:
            'invalidate() must evict the in-flight slot so a '
            'post-invalidation resolve() starts fresh',
      );

      slowGate.complete();
      final firstResult = await first;
      final secondResult = await second;

      // The original in-flight caller still gets its own (now-stale)
      // answer -- that future was already running and can't be cancelled.
      expect(firstResult, isNull);
      // But the NEW request, issued after the pick landed, must see the
      // freshly-applied cover, not old/placeholder art.
      expect(
        secondResult,
        sidecarBytes,
        reason:
            'a widget re-resolving immediately after a pick must see '
            'the new cover, not be stuck on stale/placeholder art',
      );
      expect(
        embeddedCalls,
        1,
        reason:
            'the second resolve found the sidecar entry via '
            'preferSidecar and never needed a second embedded read',
      );

      // Sanity: a third resolve() once everything has settled also sees
      // the correct art -- confirms this was purely an in-flight-dedupe
      // staleness bug, not a data bug.
      expect(await resolver.resolve(req), sidecarBytes);
    });

    test('a stale in-flight completion does not evict a NEWER in-flight '
        'future for the same key', () async {
      // Guards the identity check in resolve(): if invalidate() dropped the
      // slot and a fresh resolve() installed its own future there, the OLD
      // future's completion must not blow away the NEW one before it's had
      // a chance to be awaited/cached.
      final reg = registry();
      var calls = 0;
      final gates = <Completer<List<int>?>>[];
      final resolver = ArtworkResolver(
        stores: reg,
        embeddedLoader: (_) {
          final gate = Completer<List<int>?>();
          gates.add(gate);
          calls++;
          return gate.future;
        },
      );
      addTearDown(resolver.dispose);

      final req = request();
      final first = resolver.resolve(req); // installs gates[0]
      await Future<void>.delayed(const Duration(milliseconds: 10));

      resolver.invalidate(req.albumKey); // drops the slot
      final second = resolver.resolve(req); // installs gates[1]
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 2);

      // The OLD resolution finishes now, AFTER the new one is in flight.
      gates[0].complete(embeddedBytes);
      await first;
      // The new in-flight future must still be findable at [key] -- a
      // third resolve() right now must share it, not start a THIRD read.
      final third = resolver.resolve(req);
      expect(
        identical(second, third),
        isTrue,
        reason:
            'the stale completion must not have evicted the newer '
            'in-flight future',
      );

      gates[1].complete(sidecarBytes);
      expect(await second, sidecarBytes);
      expect(await third, sidecarBytes);
      expect(calls, 2, reason: 'no spurious third resolution');
    });

    test(
      'the same album key under two roots does not share a cached image',
      () async {
        final otherRoot = Directory(p.join(tmp.path, 'root2'))
          ..createSync(recursive: true);
        final reg = registry();
        // A putImage() payload (unlike folderBytes' usual role as a raw
        // sibling-file write below, which never goes through the magic-byte
        // check) needs a real image signature.
        final otherRootBytes = [
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 3, 3, 3, 3, //
        ];
        await reg
            .forRoot(root.path)
            .putImage('daft punk|discovery', sidecarBytes, source: 'itunes');
        await reg
            .forRoot(otherRoot.path)
            .putImage('daft punk|discovery', otherRootBytes, source: 'deezer');

        final resolver = ArtworkResolver(
          stores: reg,
          embeddedLoader: (_) async => null,
        );
        addTearDown(resolver.dispose);

        final a = await resolver.resolve(
          ArtworkRequest(
            rootPath: root.path,
            file: audio,
            artist: 'Daft Punk',
            album: 'Discovery',
          ),
        );
        final b = await resolver.resolve(
          ArtworkRequest(
            rootPath: otherRoot.path,
            file: File(p.join(otherRoot.path, 'x.mp3')),
            artist: 'Daft Punk',
            album: 'Discovery',
          ),
        );
        expect(a, sidecarBytes);
        expect(b, otherRootBytes);
      },
    );
  });

  group('apply / remove', () {
    test('applyImage stores the pick and refreshes every surface', () async {
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);

      expect(await resolver.resolve(request()), isNull);
      var notified = 0;
      resolver.addListener(() => notified++);

      final entry = await resolver.applyImage(
        request(),
        sidecarBytes,
        source: 'url',
        query: 'https://example.invalid/a.jpg',
      );
      expect(entry, isNotNull);
      expect(notified, 1);
      expect(await resolver.resolve(request()), sidecarBytes);
    });

    test('removeImage clears the pick and falls back down the chain', () async {
      File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);

      await resolver.applyImage(request(), sidecarBytes, source: 'local');
      expect(await resolver.resolve(request()), sidecarBytes);

      await resolver.removeImage(request());
      expect(await resolver.resolve(request()), folderBytes);
    });
  });

  group('hasArt', () {
    test('true/false without polluting the display cache', () async {
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);

      expect(await resolver.hasArt(request()), isFalse);
      expect(
        resolver.cachedAlbumCount,
        0,
        reason: 'a backfill sweep must not evict the visible art',
      );

      File(p.join(albumDir.path, 'cover.jpg')).writeAsBytesSync(coverBytes);
      expect(await resolver.hasArt(request()), isTrue);
    });
  });

  group('ArtworkRequest.forTrack', () {
    test('derives file path and album key from the track', () {
      final req = ArtworkRequest.forTrack(
        Track(
          contentId: 'x',
          relPath: 'Daft Punk/Discovery/01 One More Time.mp3',
          rootPath: root.path,
          dateAdded: DateTime.utc(2026),
          title: 'One More Time',
          artist: 'Daft Punk',
          album: 'Discovery (Deluxe Edition)',
        ),
      );
      expect(req.albumKey, 'daft punk|discovery');
      expect(p.equals(req.file.path, audio.path), isTrue);
      expect(req.query.terms, 'Daft Punk Discovery (Deluxe Edition)');
    });
  });
}
