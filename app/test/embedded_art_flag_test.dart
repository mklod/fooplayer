// Keeping the Emb column honest after an embed pass.
//
// The column reads a flag captured when the file's tags were last read. The
// pass rewrites tags but nothing re-reads them, so a finished run left every
// file it had just written still showing as bare -- which is exactly how a
// successful pass gets reported as a failure ("El Manana appears to have
// artwork, but it is not embedded"). Both files on disk had the cover; the
// app was quoting a stale cache.
//
// The second group here guards a quieter version of the same bug: the
// duration write-back rebuilds the whole TrackTags, so any field it forgets
// to copy across reverts to its default. It was forgetting this one, which
// darkened the column again as soon as a track was played.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/model/library_model.dart';

Map<String, Object?> _entry({
  bool hasEmbeddedArt = false,
  int? durationMs,
}) => {
  'title': 'A Song',
  'artist': 'An Artist',
  'album': 'An Album',
  'genre': null,
  'durationMs': durationMs,
  'trackNumber': 3,
  'durationProbed': true,
  'hasEmbeddedArt': hasEmbeddedArt,
  'rev': kMetaCacheRevision,
};

Future<LibraryModel> _load(
  Directory tmp,
  File cacheFile, {
  required Map<String, Object?> cache,
}) async {
  final root = await Directory('${tmp.path}/lib').create();
  await File('${root.path}/.library.json').writeAsString(
    jsonEncode({
      'schema': 1,
      'tracks': {
        'id1': {
          'paths': ['a/song.mp3'],
          'date_added': '2024-01-01T00:00:00Z',
        },
        'id2': {
          'paths': ['a/other.mp3'],
          'date_added': '2024-01-01T00:00:00Z',
        },
      },
      'playlists': <Object?>[],
    }),
  );
  await cacheFile.writeAsString(jsonEncode(cache));
  final model = LibraryModel();
  await model
      .load(libraryRoots: [root], cacheFile: cacheFile)
      .timeout(const Duration(seconds: 30));
  return model;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('embflag'));
  tearDown(() async => tmp.delete(recursive: true));

  group('markEmbeddedArt', () {
    test('flips the in-memory tracks and notifies, so the column redraws '
        'without a library-wide re-read', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _load(
        tmp,
        cacheFile,
        cache: {'id1': _entry(), 'id2': _entry()},
      );
      var notified = 0;
      model.addListener(() => notified++);

      await model.markEmbeddedArt(['id1']);

      final byId = {for (final t in model.allTracks) t.contentId: t};
      expect(byId['id1']!.hasEmbeddedArt, isTrue);
      expect(
        byId['id2']!.hasEmbeddedArt,
        isFalse,
        reason: 'only the files the pass actually wrote',
      );
      expect(notified, greaterThan(0));
      model.dispose();
    });

    test('persists to the cache with every other tag field intact', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _load(
        tmp,
        cacheFile,
        cache: {'id1': _entry(durationMs: 214000)},
      );

      await model.markEmbeddedArt(['id1']);

      final entry = MetaCache.load(cacheFile).entries['id1']!;
      expect(entry.hasEmbeddedArt, isTrue);
      expect(entry.title, 'A Song');
      expect(entry.artist, 'An Artist');
      expect(entry.album, 'An Album');
      expect(entry.durationMs, 214000);
      expect(entry.trackNumber, 3);
      expect(entry.durationProbed, isTrue);
      model.dispose();
    });

    test('an id with no cache entry is not given a fabricated one', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _load(tmp, cacheFile, cache: {'id1': _entry()});

      // load() enriches, so both ids have an entry by now. Rewind the file
      // to knowing only id1 -- the real race is a still-running scan whose
      // cache snapshot simply never touched the other track.
      await cacheFile.writeAsString(jsonEncode({'id1': _entry()}));
      expect(
        MetaCache.load(cacheFile).entries['id2'],
        isNull,
        reason: 'fixture: id2 must be a genuine cache miss',
      );

      // A fabricated entry for id2 would carry durationMs+trackNumber keys
      // and so read as already-enriched, hiding the track from real tag
      // reading forever.
      await model.markEmbeddedArt(['id1', 'id2']);

      final reloaded = MetaCache.load(cacheFile);
      expect(reloaded.entries['id1']!.hasEmbeddedArt, isTrue);
      expect(reloaded.entries['id2'], isNull);
      model.dispose();
    });

    test('an empty list touches nothing', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _load(tmp, cacheFile, cache: {'id1': _entry()});
      var notified = 0;
      model.addListener(() => notified++);

      await model.markEmbeddedArt(const []);

      expect(notified, 0);
      model.dispose();
    });
  });

  group('the duration write-back', () {
    test('regression: playing a track no longer clears its embedded-art '
        'flag in the cache', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _load(
        tmp,
        cacheFile,
        cache: {'id1': _entry(hasEmbeddedArt: true)},
      );

      model.updateDuration('id1', 214000);
      await model.flushPendingDurationSaves();

      final entry = MetaCache.load(cacheFile).entries['id1']!;
      expect(entry.durationMs, 214000);
      expect(
        entry.hasEmbeddedArt,
        isTrue,
        reason: 'the rewrite must carry every field it is not changing',
      );
      model.dispose();
    });
  });
}
