// LibraryModel.seedRoot: setting up a folder must not reset the library's
// download dates.
//
// Found live on the Galaxy Tab S9+. The music had been copied onto the
// tablet as one folder, so every file's mtime was the copy's timestamp
// (2026-07-29 02:17) -- the real download dates survived only in the
// .library.json that travelled with it. Adding /Music as a single root and
// tapping "Set up" wrote a fresh manifest dating all 467 tracks to the
// minute the button was pressed. That is precisely the failure the manifest
// architecture exists to prevent.
//
// Last modified: 2026-07-29--1300

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

Future<String> _writeTrack(File f, int fill) async {
  await f.writeAsBytes(List<int>.filled(64, fill));
  return contentIdForFile(f);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('seed-root'));
  tearDown(() async => tmp.delete(recursive: true));

  test(
    'seeding a parent folder adopts the dates from a manifest already '
    'inside it, instead of stamping everything with today',
    () async {
      final root = await Directory('${tmp.path}/Music').create();
      final sub = await Directory(
        '${root.path}/loose tracks - 2020 and later',
      ).create();

      final oldId = await _writeTrack(File('${sub.path}/After Dark.mp3'), 0x11);
      final subManifest = Manifest.empty();
      subManifest.tracks[oldId] = TrackEntry(
        dateAdded: '2020-12-17T03:49:25.481662Z',
        paths: ['After Dark.mp3'],
        durationMs: 259134,
      );
      await saveManifest(subManifest, sub);

      // A track that has never been catalogued anywhere.
      final newId = await _writeTrack(File('${root.path}/Brand New.mp3'), 0x22);

      final found = await LibraryModel().seedRoot(root);
      expect(found, 2);

      final written = loadManifest(root);
      expect(
        written.tracks[oldId]!.dateAdded,
        '2020-12-17T03:49:25.481662Z',
        reason: 'the date the folder brought with it, not the seed time',
      );
      expect(
        written.tracks[oldId]!.durationMs,
        259134,
        reason: 'a duration already paid for should not have to be re-read',
      );
      expect(written.tracks[oldId]!.paths, [
        'loose tracks - 2020 and later/After Dark.mp3',
      ]);

      // The genuinely new one is genuinely new.
      final mintedAt = DateTime.parse(written.tracks[newId]!.dateAdded);
      expect(
        DateTime.now().toUtc().difference(mintedAt).inMinutes.abs(),
        lessThan(5),
      );
    },
  );

  test(
    'a folder dropped into an already-set-up root keeps the dates in the '
    'manifest it brought with it',
    () async {
      // The workflow this root exists for: /Music is set up, then `monthly/`
      // is copied in later. Its files carry the copy's mtime; its manifest
      // carries the truth.
      final root = await Directory('${tmp.path}/Music').create();
      final firstId = await _writeTrack(File('${root.path}/first.mp3'), 0x11);
      final seeded = Manifest.empty();
      seeded.tracks[firstId] = TrackEntry(
        dateAdded: '2024-01-01T00:00:00.000Z',
        paths: ['first.mp3'],
      );
      await saveManifest(seeded, root);

      final library = LibraryModel();
      await library.load(
        libraryRoots: [root],
        cacheFile: File('${tmp.path}/meta_cache.json'),
      );
      expect(library.allTracks, hasLength(1));

      // Now the drop-in, manifest and all.
      final dropped = await Directory('${root.path}/monthly').create();
      final droppedId = await _writeTrack(
        File('${dropped.path}/2019 tune.mp3'),
        0x44,
      );
      final droppedManifest = Manifest.empty();
      droppedManifest.tracks[droppedId] = TrackEntry(
        dateAdded: '2019-06-06T00:00:00.000Z',
        paths: ['2019 tune.mp3'],
      );
      await saveManifest(droppedManifest, dropped);

      await library.rescan();

      final written = loadManifest(root);
      expect(written.tracks[droppedId]!.dateAdded, '2019-06-06T00:00:00.000Z');
      expect(
        written.tracks[firstId]!.dateAdded,
        '2024-01-01T00:00:00.000Z',
        reason: 'the root manifest stays the authority for what it knew',
      );
      expect(
        library.allTracks
            .firstWhere((t) => t.contentId == droppedId)
            .dateAdded,
        DateTime.utc(2019, 6, 6),
        reason: 'and the feed shows it in its real place, not at the top',
      );
    },
  );

  test('a folder with no manifest anywhere in it still seeds normally', () async {
    final root = await Directory('${tmp.path}/Fresh').create();
    final id = await _writeTrack(File('${root.path}/song.mp3'), 0x33);

    expect(await LibraryModel().seedRoot(root), 1);

    final written = loadManifest(root);
    final mintedAt = DateTime.parse(written.tracks[id]!.dateAdded);
    expect(
      DateTime.now().toUtc().difference(mintedAt).inMinutes.abs(),
      lessThan(5),
    );
  });
}
