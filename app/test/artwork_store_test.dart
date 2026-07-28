// Last modified: 2026-07-25--2208
//
// Plan 4 / A2: `.artwork.json` sidecar storage.
//
// Covers the plan's A2 test list for the storage half: sidecar round-trip,
// atomic tmp->rename with a `.bak`, the read-only-root fallback to the app
// data dir (entries flagged `external: true`), and the timestamped
// negative-result cache. No network anywhere -- this file only ever touches
// temp directories it creates itself.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/album_key.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:path/path.dart' as p;

const _key = 'daft punk|discovery';

/// PNG magic number -- putImage() now validates magic bytes (adversarial
/// review finding 6), so every fixture standing in for "some image bytes"
/// in this file needs a real signature prefix. The distinguishing tail is
/// kept so byte-for-byte equality assertions (`expect(x, _bytes)`) still
/// tell fixtures apart from one another.
const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
List<int> _pngFixture(List<int> tail) => [..._pngMagic, ...tail];

final _bytes = _pngFixture(List<int>.generate(64, (i) => i));

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fooplayer_artwork_store');
    root = Directory(p.join(tmp.path, 'root'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows can briefly hold a handle; a leaked temp dir is harmless.
    }
  });

  ArtworkStore newStore({DateTime Function()? now, Duration? ttl}) =>
      ArtworkStore(
        root: root,
        appDataDir: appData,
        now: now,
        negativeTtl: ttl ?? defaultArtworkNegativeTtl,
      );

  group('sidecar round-trip', () {
    test(
      'putImage writes the image under <root>/.artwork/ and records it',
      () async {
        final store = newStore();
        final entry = await store.putImage(
          _key,
          _bytes,
          source: 'itunes',
          query: 'daft punk discovery',
        );

        expect(entry, isNotNull);
        expect(entry!.source, 'itunes');
        expect(entry.external, isFalse);
        expect(entry.file, '${artworkHash(_key)}.jpg');

        final img = File(p.join(root.path, artworkCacheDirName, entry.file));
        expect(img.existsSync(), isTrue);
        expect(img.readAsBytesSync(), _bytes);

        final sidecar = File(p.join(root.path, artworkSidecarName));
        expect(sidecar.existsSync(), isTrue);
        final json = jsonDecode(sidecar.readAsStringSync()) as Map;
        expect(json['schema'], 1);
        expect((json['art'] as Map)[_key], isA<Map>());
        expect(((json['art'] as Map)[_key] as Map)['source'], 'itunes');
        expect(
          ((json['art'] as Map)[_key] as Map)['query'],
          'daft punk discovery',
        );
        // Never writes into an album directory, only the root's own dot-files.
        expect(json.containsKey('tracks'), isFalse);
      },
    );

    test(
      'a fresh store over the same root reads back entry and bytes',
      () async {
        await newStore().putImage(_key, _bytes, source: 'deezer');

        final reopened = newStore();
        await reopened.ensureLoaded();
        final entry = reopened.entryFor(_key);
        expect(entry, isNotNull);
        expect(entry!.source, 'deezer');
        expect(await reopened.readImage(_key), _bytes);
        expect(reopened.entryFor('nobody|nothing'), isNull);
        expect(await reopened.readImage('nobody|nothing'), isNull);
      },
    );

    test('putImage rejects bytes that are not a recognized image, as a '
        'backstop against a caller that skipped/lost its own validation '
        '(adversarial review finding 6)', () async {
      final store = newStore();
      final html = utf8.encode('<html><body>Not an image</body></html>');

      final entry = await store.putImage(_key, html, source: 'url');

      expect(
        entry,
        isNull,
        reason:
            'a non-image payload must never be stored as a '
            '"successful" pick',
      );
      expect(store.entryFor(_key), isNull);
      final cacheDir = Directory(p.join(root.path, artworkCacheDirName));
      expect(
        cacheDir.existsSync(),
        isFalse,
        reason: 'nothing should even be written to disk for rejected bytes',
      );
    });

    test(
      'putImage still accepts a real image after a rejected attempt',
      () async {
        final store = newStore();
        final html = utf8.encode('<html>nope</html>');
        expect(await store.putImage(_key, html, source: 'url'), isNull);

        final entry = await store.putImage(_key, _bytes, source: 'itunes');
        expect(entry, isNotNull);
        expect(await store.readImage(_key), _bytes);
      },
    );

    test('replacing a pick with a DIFFERENT extension deletes the prior '
        'file (adversarial review finding 4)', () async {
      final store = newStore();
      final first = await store.putImage(
        _key,
        _bytes,
        source: 'itunes',
        extension: '.jpg',
      );
      final firstImg = File(
        p.join(root.path, artworkCacheDirName, first!.file),
      );
      expect(firstImg.existsSync(), isTrue);
      expect(first.file, '${artworkHash(_key)}.jpg');

      final pngBytes = _pngFixture(List<int>.generate(32, (i) => 255 - i));
      final second = await store.putImage(
        _key,
        pngBytes,
        source: 'local',
        extension: '.png',
      );
      expect(second, isNotNull);
      expect(second!.file, '${artworkHash(_key)}.png');

      // The NEW file exists with the NEW bytes...
      final secondImg = File(
        p.join(root.path, artworkCacheDirName, second.file),
      );
      expect(secondImg.existsSync(), isTrue);
      expect(secondImg.readAsBytesSync(), pngBytes);
      // ...and the OLD .jpg is gone, not left behind as an orphan.
      expect(
        firstImg.existsSync(),
        isFalse,
        reason:
            'a replace with a different extension must not leave '
            'the prior pick\'s file behind forever',
      );

      // The .artwork/ dir holds exactly the current pick's file.
      final cacheDir = Directory(p.join(root.path, artworkCacheDirName));
      final names = cacheDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.endsWith('.tmp'))
          .toList();
      expect(names, [second.file]);
    });

    test('replacing a pick with the SAME extension still works (no crash, '
        'no orphan of itself)', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes', extension: '.jpg');
      final replaced = _pngFixture(List<int>.generate(64, (i) => 63 - i));
      final second = await store.putImage(
        _key,
        replaced,
        source: 'local',
        extension: '.jpg',
      );
      expect(second, isNotNull);
      expect(await store.readImage(_key), replaced);

      final cacheDir = Directory(p.join(root.path, artworkCacheDirName));
      final names = cacheDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.endsWith('.tmp'))
          .toList();
      expect(names, [second!.file]);
    });

    test('remove() drops the entry, deletes the image and persists', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'local');
      final img = store.imageFileFor(_key)!;
      expect(img.existsSync(), isTrue);

      await store.remove(_key);
      expect(store.entryFor(_key), isNull);
      expect(img.existsSync(), isFalse);

      final reopened = newStore();
      await reopened.ensureLoaded();
      expect(reopened.entryFor(_key), isNull);
    });

    test(
      'a corrupt sidecar degrades to "nothing recorded", never throws',
      () async {
        File(
          p.join(root.path, artworkSidecarName),
        ).writeAsStringSync('{ not json at all');
        final store = newStore();
        await store.ensureLoaded();
        expect(store.entryFor(_key), isNull);
        // ...and it can still be written over.
        expect(await store.putImage(_key, _bytes, source: 'url'), isNotNull);
      },
    );
  });

  group('atomicity', () {
    test(
      'leaves no .tmp behind and creates a .bak on the second save',
      () async {
        final store = newStore();
        await store.putImage(_key, _bytes, source: 'itunes');

        final sidecar = File(p.join(root.path, artworkSidecarName));
        final bak = File(p.join(root.path, artworkSidecarBakName));
        final tmpFile = File(p.join(root.path, artworkSidecarTmpName));

        expect(sidecar.existsSync(), isTrue);
        expect(tmpFile.existsSync(), isFalse, reason: 'tmp renamed into place');
        expect(bak.existsSync(), isFalse, reason: 'nothing to back up yet');

        final firstContents = sidecar.readAsStringSync();
        await store.putImage('other|album', _bytes, source: 'deezer');

        expect(bak.existsSync(), isTrue);
        expect(
          bak.readAsStringSync(),
          firstContents,
          reason: '.bak holds the PREVIOUS complete sidecar',
        );
        expect(tmpFile.existsSync(), isFalse);
        final reloaded =
            jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
        expect(
          (reloaded['art'] as Map).keys,
          containsAll([_key, 'other|album']),
        );
      },
    );

    test(
      'concurrent saves are serialized -- no interleaved renames, no loss',
      () async {
        final store = newStore();
        await Future.wait([
          store.putImage('a|1', _bytes, source: 'itunes'),
          store.putImage('a|2', _bytes, source: 'itunes'),
          store.putImage('a|3', _bytes, source: 'itunes'),
        ]);

        final reopened = newStore();
        await reopened.ensureLoaded();
        expect(reopened.entryFor('a|1'), isNotNull);
        expect(reopened.entryFor('a|2'), isNotNull);
        expect(reopened.entryFor('a|3'), isNotNull);
        expect(
          File(p.join(root.path, artworkSidecarTmpName)).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'a mutation made while a save is queued still lands on disk',
      () async {
        final store = newStore();
        // Fire a burst without awaiting: the coalescer must fold these into
        // the smallest number of writes that still contains all of them.
        final futures = [
          for (var i = 0; i < 25; i++)
            store.recordMiss('burst|$i', query: 'q$i'),
        ];
        await Future.wait(futures);

        final reopened = newStore();
        await reopened.ensureLoaded();
        expect(reopened.sidecar.misses.length, 25);
        for (var i = 0; i < 25; i++) {
          expect(reopened.isNegative('burst|$i'), isTrue);
        }
        expect(
          File(p.join(root.path, artworkSidecarTmpName)).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'does not touch the library manifest sitting in the same root',
      () async {
        final manifest = File(p.join(root.path, '.library.json'))
          ..writeAsStringSync('{"schema":1,"tracks":{},"playlists":[]}');
        final before = manifest.readAsStringSync();

        final store = newStore();
        await store.putImage(_key, _bytes, source: 'itunes');
        await store.recordMiss('x|y');

        expect(manifest.readAsStringSync(), before);
        expect(
          File(p.join(root.path, '.library.json.bak')).existsSync(),
          isFalse,
        );
      },
    );
  });

  group('read-only root fallback', () {
    late Directory unwritableRoot;

    setUp(() {
      // A directory path whose PARENT is a regular file can never be
      // created or written -- a deterministic, cross-platform stand-in for
      // a read-only share that needs no ACL fiddling.
      final blocker = File(p.join(tmp.path, 'blocker'))
        ..writeAsStringSync('not a directory');
      unwritableRoot = Directory(p.join(blocker.path, 'music'));
    });

    ArtworkStore roStore() =>
        ArtworkStore(root: unwritableRoot, appDataDir: appData);

    test(
      'falls back to the app data dir and flags the entry external',
      () async {
        final store = roStore();
        final entry = await store.putImage(
          _key,
          _bytes,
          source: 'itunes',
          query: 'daft punk discovery',
        );

        expect(entry, isNotNull);
        expect(entry!.external, isTrue);
        expect(store.external, isTrue);

        final img = File(p.join(store.externalDir.path, entry.file));
        expect(img.existsSync(), isTrue);
        expect(img.readAsBytesSync(), _bytes);
        expect(
          File(p.join(store.externalDir.path, artworkSidecarName)).existsSync(),
          isTrue,
        );
      },
    );

    test('external entries survive a reopen', () async {
      await roStore().putImage(_key, _bytes, source: 'itunes');

      final reopened = roStore();
      await reopened.ensureLoaded();
      expect(reopened.entryFor(_key)?.external, isTrue);
      expect(await reopened.readImage(_key), _bytes);
    });

    test('two different roots get separate external buckets', () async {
      final blocker2 = File(p.join(tmp.path, 'blocker2'))
        ..writeAsStringSync('x');
      final other = ArtworkStore(
        root: Directory(p.join(blocker2.path, 'music')),
        appDataDir: appData,
      );
      final a = roStore();
      expect(a.externalDir.path, isNot(other.externalDir.path));

      final otherBytes = _pngFixture(const [9, 9, 9, 9]);
      await a.putImage(_key, _bytes, source: 'itunes');
      await other.putImage(_key, otherBytes, source: 'deezer');

      // Same album key, two roots -- no collision.
      expect(await a.readImage(_key), _bytes);
      expect(await other.readImage(_key), otherBytes);
    });
  });

  group('negative-result cache', () {
    test(
      'recordMiss makes isNegative true and persists across reopen',
      () async {
        final store = newStore();
        expect(store.isNegative(_key), isFalse);
        await store.recordMiss(_key, query: 'daft punk discovery');
        expect(store.isNegative(_key), isTrue);

        final reopened = newStore();
        await reopened.ensureLoaded();
        expect(reopened.isNegative(_key), isTrue);
        expect(reopened.sidecar.misses[_key]!.query, 'daft punk discovery');
      },
    );

    test('expires after the TTL', () async {
      var clock = DateTime.utc(2026, 1, 1);
      final store = newStore(now: () => clock, ttl: const Duration(days: 14));
      await store.recordMiss(_key);
      expect(store.isNegative(_key), isTrue);

      clock = clock.add(const Duration(days: 13, hours: 23));
      expect(store.isNegative(_key), isTrue);
      clock = clock.add(const Duration(hours: 2));
      expect(store.isNegative(_key), isFalse);
    });

    test('clearMiss forgets it (what manual "Search again" calls)', () async {
      final store = newStore();
      await store.recordMiss(_key);
      await store.clearMiss(_key);
      expect(store.isNegative(_key), isFalse);

      final reopened = newStore();
      await reopened.ensureLoaded();
      expect(reopened.isNegative(_key), isFalse);
    });

    test('storing art clears any recorded miss for the same album', () async {
      final store = newStore();
      await store.recordMiss(_key);
      await store.putImage(_key, _bytes, source: 'itunes');
      expect(store.isNegative(_key), isFalse);
    });
  });

  group('user suppression ("Remove artwork" is durable)', () {
    test('remove() records a suppression that survives a reopen', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes', query: 'daft punk');
      await store.remove(_key);

      expect(store.entryFor(_key), isNull);
      expect(store.isSuppressed(_key), isTrue);
      expect(store.isNegative(_key), isTrue);

      final reopened = newStore();
      await reopened.ensureLoaded();
      expect(reopened.entryFor(_key), isNull);
      expect(reopened.isSuppressed(_key), isTrue);
      expect(
        reopened.isNegative(_key),
        isTrue,
        reason: 'the auto pass must not re-apply a rejected cover',
      );
      expect(
        reopened.sidecar.misses[_key]!.query,
        'daft punk',
        reason: 'keeps what was searched, for the picker',
      );
    });

    test('a suppression never expires, unlike an automatic miss', () async {
      var clock = DateTime.utc(2026, 1, 1);
      final store = newStore(now: () => clock, ttl: const Duration(days: 14));
      await store.putImage(_key, _bytes, source: 'itunes');
      await store.recordMiss('auto|miss');
      await store.remove(_key);

      clock = clock.add(const Duration(days: 400));
      expect(
        store.isNegative('auto|miss'),
        isFalse,
        reason: 'an automatic miss still expires',
      );
      expect(store.isNegative(_key), isTrue);
      expect(store.isSuppressed(_key), isTrue);
    });

    test('clearMiss (manual "Search again") lifts it', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes');
      await store.remove(_key);
      await store.clearMiss(_key);
      expect(store.isSuppressed(_key), isFalse);
      expect(store.isNegative(_key), isFalse);

      final reopened = newStore();
      await reopened.ensureLoaded();
      expect(reopened.isNegative(_key), isFalse);
    });

    test('picking a new image lifts it', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes');
      await store.remove(_key);
      await store.putImage(
        _key,
        _pngFixture(const [1, 2, 3, 4]),
        source: 'local',
      );
      expect(store.isSuppressed(_key), isFalse);
      expect(store.isNegative(_key), isFalse);
      expect(store.entryFor(_key)?.source, 'local');
    });

    test('remove(suppress: false) stays a plain mechanical removal', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes');
      await store.remove(_key, suppress: false);
      expect(store.entryFor(_key), isNull);
      expect(store.isSuppressed(_key), isFalse);
      expect(store.isNegative(_key), isFalse);
    });

    test('the suppressed flag round-trips through the sidecar JSON', () async {
      final store = newStore();
      await store.putImage(_key, _bytes, source: 'itunes');
      await store.remove(_key);

      final json =
          jsonDecode(
                File(p.join(root.path, artworkSidecarName)).readAsStringSync(),
              )
              as Map;
      expect(((json['misses'] as Map)[_key] as Map)['suppressed'], isTrue);

      // An automatic miss must NOT carry the flag.
      await store.recordMiss('auto|miss');
      final json2 =
          jsonDecode(
                File(p.join(root.path, artworkSidecarName)).readAsStringSync(),
              )
              as Map;
      expect(
        (json2['misses'] as Map)['auto|miss'],
        isNot(contains('suppressed')),
      );
    });
  });

  group('write-location probe (must never block the UI isolate)', () {
    test('probes once for the whole lifetime of a store', () async {
      final store = newStore();
      expect(
        store.writeDirProbeCount,
        0,
        reason: 'nothing probed until something is actually written',
      );

      await store.putImage(_key, _bytes, source: 'itunes');
      expect(store.writeDirProbeCount, 1);

      for (var i = 0; i < 10; i++) {
        await store.recordMiss('miss|$i');
      }
      await store.putImage('another|album', _bytes, source: 'deezer');
      expect(
        store.writeDirProbeCount,
        1,
        reason: 'the probe is memoized, not re-run per save',
      );
    });

    test('concurrent first writes share ONE probe', () async {
      final store = newStore();
      await Future.wait([
        for (var i = 0; i < 6; i++)
          store.putImage('burst|$i', _bytes, source: 'itunes'),
      ]);
      expect(store.writeDirProbeCount, 1);
      expect(store.sidecar.art.length, 6);
    });

    test(
      'a store with NO writable location memoizes that outcome too',
      () async {
        // Both the root AND the app data dir sit under a regular file, so
        // neither can ever be created: the "nothing is writable" branch.
        final blocker = File(p.join(tmp.path, 'blocker-all'))
          ..writeAsStringSync('not a directory');
        final store = ArtworkStore(
          root: Directory(p.join(blocker.path, 'music')),
          appDataDir: Directory(p.join(blocker.path, 'appdata')),
        );

        expect(await store.putImage(_key, _bytes, source: 'itunes'), isNull);
        for (var i = 0; i < 10; i++) {
          await store.recordMiss('miss|$i');
        }
        expect(
          store.writeDirProbeCount,
          1,
          reason: 'a failed probe must not be retried once per save',
        );
      },
    );
  });

  group('empty root (fixture tracks default Track.rootPath to "")', () {
    test('never reads or writes relative to the working directory', () async {
      final cwdSidecar = File(
        p.join(Directory.current.path, artworkSidecarName),
      );
      final cwdCache = Directory(
        p.join(Directory.current.path, artworkCacheDirName),
      );
      expect(
        cwdSidecar.existsSync(),
        isFalse,
        reason: 'precondition: nothing here yet',
      );

      final store = ArtworkStore(root: Directory(''), appDataDir: appData);
      await store.ensureLoaded();
      final entry = await store.putImage(_key, _bytes, source: 'itunes');

      expect(entry?.external, isTrue);
      expect(cwdSidecar.existsSync(), isFalse);
      expect(cwdCache.existsSync(), isFalse);
      expect(await store.readImage(_key), _bytes);
    });
  });

  group('ArtworkStoreRegistry', () {
    test('memoizes one store per root', () {
      final reg = ArtworkStoreRegistry(appDataDir: appData);
      final a = reg.forRoot(root.path);
      expect(identical(reg.forRoot(root.path), a), isTrue);
      expect(identical(reg.forRoot(p.join(tmp.path, 'other')), a), isFalse);
    });
  });

  group('entryFor before the sidecar is loaded', () {
    // Regression: the library view's "Art" column reads entryFor
    // SYNCHRONOUSLY, and nothing in that view ever triggered a load -- so an
    // album whose cover came from the sidecar (a harvested local file, or an
    // online lookup like Gorillaz "El Manana") showed a blank Art cell
    // however much artwork it had. The store answered honestly; it had never
    // read the file. main.dart now preloads every root's sidecar at startup.
    test(
      'answers "nothing recorded" until ensureLoaded, then the truth',
      () async {
        final tmp = await Directory.systemTemp.createTemp('sidecarload');
        addTearDown(() => tmp.delete(recursive: true));
        final root = await Directory('${tmp.path}/root').create();
        await File('${root.path}/$artworkSidecarName').writeAsString(
          jsonEncode({
            'schema': artworkSidecarSchema,
            'art': {
              'gorillaz|el manana': {
                'file': 'abc.jpg',
                'source': 'itunes',
                'pickedAt': '2026-07-28T00:00:00.000Z',
              },
            },
            'misses': <String, dynamic>{},
          }),
        );

        final store = ArtworkStore(root: root, appDataDir: tmp);
        expect(
          store.entryFor('gorillaz|el manana'),
          isNull,
          reason: 'not yet loaded -- this is the state the column hit',
        );

        await store.ensureLoaded();
        expect(store.entryFor('gorillaz|el manana'), isNotNull);
        expect(store.entryFor('gorillaz|el manana')!.source, 'itunes');
      },
    );
  });
}
