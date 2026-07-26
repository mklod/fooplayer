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
final sidecarBytes = [2, 2, 2];
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

  ArtworkStoreRegistry registry() =>
      ArtworkStoreRegistry(appDataDir: appData);

  group('resolution chain precedence', () {
    test('embedded art wins over everything else (the plan\'s order)',
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
    });

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

    test('nothing anywhere resolves to null (caller shows the placeholder)',
        () async {
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);
      expect(await resolver.resolve(request()), isNull);
    });

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

    test('an embedded loader that throws falls through instead of surfacing',
        () async {
      File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(folderBytes);
      final resolver = ArtworkResolver(
        stores: registry(),
        embeddedLoader: (_) async => throw StateError('bad file'),
      );
      addTearDown(resolver.dispose);
      expect(await resolver.resolve(request()), folderBytes);
    });
  });

  group('caching and dedupe', () {
    test('concurrent requests for the same album share ONE resolution',
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
      expect(resolver.inFlightCount, 1,
          reason: 'in-flight guard collapses the second request');
      expect(identical(a, b), isTrue, reason: 'literally the same future');

      // Let the chain get as far as the (gated) embedded read.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);

      gate.complete(embeddedBytes);
      expect(await a, embeddedBytes);
      expect(await b, embeddedBytes);
      expect(calls, 1);
      expect(resolver.inFlightCount, 0);
    });

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

    test('invalidate() drops the album, bumps the revision and notifies',
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
    });

    test('a resolution that lands AFTER its album was invalidated is not cached',
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
      expect(await pending, embeddedBytes); // the caller still gets its answer
      expect(resolver.cachedAlbumCount, 0, reason: 'stale result not cached');

      expect(await resolver.resolve(request()), sidecarBytes);
      expect(calls, 2);
    });

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

    test('the same album key under two roots does not share a cached image',
        () async {
      final otherRoot = Directory(p.join(tmp.path, 'root2'))
        ..createSync(recursive: true);
      final reg = registry();
      await reg
          .forRoot(root.path)
          .putImage('daft punk|discovery', sidecarBytes, source: 'itunes');
      await reg
          .forRoot(otherRoot.path)
          .putImage('daft punk|discovery', folderBytes, source: 'deezer');

      final resolver = ArtworkResolver(
        stores: reg,
        embeddedLoader: (_) async => null,
      );
      addTearDown(resolver.dispose);

      final a = await resolver.resolve(ArtworkRequest(
          rootPath: root.path,
          file: audio,
          artist: 'Daft Punk',
          album: 'Discovery'));
      final b = await resolver.resolve(ArtworkRequest(
          rootPath: otherRoot.path,
          file: File(p.join(otherRoot.path, 'x.mp3')),
          artist: 'Daft Punk',
          album: 'Discovery'));
      expect(a, sidecarBytes);
      expect(b, folderBytes);
    });
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

      final entry = await resolver.applyImage(request(), sidecarBytes,
          source: 'url', query: 'https://example.invalid/a.jpg');
      expect(entry, isNotNull);
      expect(notified, 1);
      expect(await resolver.resolve(request()), sidecarBytes);
    });

    test('removeImage clears the pick and falls back down the chain',
        () async {
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
      expect(resolver.cachedAlbumCount, 0,
          reason: 'a backfill sweep must not evict the visible art');

      File(p.join(albumDir.path, 'cover.jpg')).writeAsBytesSync(coverBytes);
      expect(await resolver.hasArt(request()), isTrue);
    });
  });

  group('ArtworkRequest.forTrack', () {
    test('derives file path and album key from the track', () {
      final req = ArtworkRequest.forTrack(Track(
        contentId: 'x',
        relPath: 'Daft Punk/Discovery/01 One More Time.mp3',
        rootPath: root.path,
        dateAdded: DateTime.utc(2026),
        title: 'One More Time',
        artist: 'Daft Punk',
        album: 'Discovery (Deluxe Edition)',
      ));
      expect(req.albumKey, 'daft punk|discovery');
      expect(p.equals(req.file.path, audio.path), isTrue);
      expect(req.query.terms, 'Daft Punk Discovery (Deluxe Edition)');
    });
  });
}
