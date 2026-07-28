// Adopting the cover images already on disk.
//
// The judgement this makes is "which of these six jpgs is the cover", in
// folders Mike describes as full of wrong and extraneous images -- so the
// ranking, and what it refuses, is the whole test.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/artwork/local_art_harvest.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:path/path.dart' as p;

/// A JPEG of [bytes] length -- real magic bytes so the store accepts it.
Uint8List _jpeg(int bytes) {
  final b = Uint8List(bytes);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  for (var i = 3; i < bytes; i++) {
    b[i] = i % 251;
  }
  return b;
}

void main() {
  group('picking the cover out of a messy folder', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('harvest'));
    tearDown(() async => dir.delete(recursive: true));

    Future<void> write(String name, int bytes) =>
        File(p.join(dir.path, name)).writeAsBytes(_jpeg(bytes));

    test('cover.jpg beats folder.jpg beats a WMP cache file', () async {
      await write('AlbumArt_{GUID}_Large.jpg', 40 * 1024);
      await write('folder.jpg', 40 * 1024);
      await write('cover.jpg', 40 * 1024);
      expect(p.basename(bestLocalArt(dir)!.path), 'cover.jpg');
    });

    test('a WMP cache file is adopted when it is all there is', () async {
      await write('AlbumArt_{ABC-123}_Large.jpg', 40 * 1024);
      expect(
        p.basename(bestLocalArt(dir)!.path),
        'AlbumArt_{ABC-123}_Large.jpg',
      );
    });

    test('the _small WMP thumbnail is never adopted', () async {
      await write('AlbumArt_{ABC}_Small.jpg', 40 * 1024);
      expect(
        bestLocalArt(dir),
        isNull,
        reason: 'a thumbnail is worse than no art at all',
      );
    });

    test('icons and thumbnails below the size floor are ignored', () async {
      await write('folder.jpg', 900);
      expect(bestLocalArt(dir), isNull);
    });

    test('within one rank, the larger file wins', () async {
      await write('AlbumArt_{A}_Large.jpg', 20 * 1024);
      await write('AlbumArt_{B}_Large.jpg', 90 * 1024);
      expect(p.basename(bestLocalArt(dir)!.path), 'AlbumArt_{B}_Large.jpg');
    });

    test('an unrelated photo is adopted only as a last resort', () async {
      await write('band photo.jpg', 40 * 1024);
      await write('front.jpg', 40 * 1024);
      expect(p.basename(bestLocalArt(dir)!.path), 'front.jpg');
    });

    test('a folder with no images yields null, and never throws', () async {
      await File(p.join(dir.path, 'notes.txt')).writeAsString('hi');
      expect(bestLocalArt(dir), isNull);
      expect(bestLocalArt(Directory(p.join(dir.path, 'nope'))), isNull);
    });
  });

  group('harvesting into the store', () {
    late Directory tmp;
    late ArtworkStoreRegistry stores;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('harvestrun');
      stores = ArtworkStoreRegistry(appDataDir: Directory(tmp.path));
    });
    tearDown(() async => tmp.delete(recursive: true));

    Future<Track> track({
      required String album,
      required String folder,
      bool embedded = false,
      String? image,
    }) async {
      final dir = Directory(p.join(tmp.path, 'root', folder));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'song.mp3')).writeAsBytes([0xFF, 0xFB]);
      if (image != null) {
        await File(p.join(dir.path, image)).writeAsBytes(_jpeg(40 * 1024));
      }
      return Track(
        contentId: folder,
        relPath: '$folder/song.mp3',
        rootPath: p.join(tmp.path, 'root'),
        dateAdded: DateTime.utc(2020),
        title: 'A Song',
        artist: 'An Artist',
        album: album,
        hasEmbeddedArt: embedded,
      );
    }

    test('adopts a local cover and records it in the sidecar', () async {
      final t = await track(album: 'Has Art', folder: 'a', image: 'cover.jpg');
      final report = await harvestLocalArt([t], stores);

      expect(report.adopted, 1);
      final store = stores.forRoot(t.rootPath);
      await store.ensureLoaded();
      final key = '${'an artist'}|${'has art'}';
      expect(
        store.entryFor(key),
        isNotNull,
        reason: 'the Art column and the embed pass both read this',
      );
      expect(store.entryFor(key)!.source, 'local');
      expect(await store.readImage(key), isNotNull);
    });

    test("a track that already carries embedded art is left alone", () async {
      final t = await track(
        album: 'Embedded',
        folder: 'b',
        embedded: true,
        image: 'folder.jpg',
      );
      final report = await harvestLocalArt([t], stores);

      expect(
        report.adopted,
        0,
        reason: "the file's own cover outranks a loose jpg beside it",
      );
      expect(report.albumsConsidered, 0);
    });

    test('an album with no local image is counted, not adopted', () async {
      final t = await track(album: 'Bare', folder: 'c');
      final report = await harvestLocalArt([t], stores);

      expect(report.adopted, 0);
      expect(report.skippedNoImage, 1);
      expect(report.summary, contains('no local image'));
    });

    test('an existing sidecar choice is never overwritten', () async {
      final t = await track(album: 'Chosen', folder: 'd', image: 'cover.jpg');
      final store = stores.forRoot(t.rootPath);
      await store.putImage(
        'an artist|chosen',
        _jpeg(30 * 1024),
        source: 'itunes',
      );

      final report = await harvestLocalArt([t], stores);
      expect(report.adopted, 0);
      expect(
        store.entryFor('an artist|chosen')!.source,
        'itunes',
        reason: 'a deliberate pick outranks a file found lying about',
      );
    });

    test(
      'one image serves every track of the album, and progress reports',
      () async {
        final a = await track(album: 'Shared', folder: 'e', image: 'cover.jpg');
        final b = Track(
          contentId: 'e2',
          relPath: 'e/song2.mp3',
          rootPath: a.rootPath,
          dateAdded: DateTime.utc(2020),
          title: 'Another',
          artist: 'An Artist',
          album: 'Shared',
        );
        final seen = <int>[];
        final report = await harvestLocalArt(
          [a, b],
          stores,
          onProgress: (done, total) => seen.add(total),
        );

        expect(report.adopted, 1, reason: 'one album, one adoption');
        expect(
          seen.every((t) => t == 1),
          isTrue,
          reason: 'both tracks collapse to a single album',
        );
      },
    );
  });
}
