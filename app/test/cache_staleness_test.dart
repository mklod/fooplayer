// A tag-cache revision bump must REFRESH the library, never BLANK it.
//
// The regression this exists to prevent, and which actually happened on
// 2026-07-27: bumping kMetaCacheRevision (to correct which ID3 frame the
// artist comes from) discarded every cached entry, so the whole library lost
// its Title/Artist/Album/Time columns until a full re-read of 5473 files
// finished -- roughly ten minutes over the SMB share. One field changed; all
// of them went blank.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/model/library_model.dart';

Map<String, Object?> _entry({
  required String title,
  required String artist,
  int? durationMs = 210000,
  Object? rev = kMetaCacheRevision,
}) => {
      'title': title,
      'artist': artist,
      'album': 'An Album',
      'genre': null,
      'durationMs': durationMs,
      'trackNumber': null,
      'durationProbed': false,
      if (rev != null) 'rev': rev,
    };

Future<Directory> _root(Directory tmp) async {
  final root = await Directory('${tmp.path}/root').create();
  await File('${root.path}/.library.json').writeAsString(jsonEncode({
    'schema': 1,
    'tracks': {
      'fresh': {'date_added': '2024-01-01T00:00:00Z', 'paths': ['fresh.mp3']},
      'stale': {'date_added': '2024-01-02T00:00:00Z', 'paths': ['stale.mp3']},
    },
    'playlists': [],
  }));
  return root;
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('stalecache'));
  tearDown(() async => tmp.delete(recursive: true));

  test('an out-of-revision entry is still served, and flagged for re-read',
      () async {
    final f = File('${tmp.path}/cache.json');
    await f.writeAsString(jsonEncode({
      'fresh': _entry(title: 'Fresh Title', artist: 'Current Artist'),
      'stale': _entry(
          title: 'Stale Title', artist: 'Old Artist', rev: kMetaCacheRevision - 1),
    }));

    final cache = MetaCache.load(f);

    expect(cache.entries.keys, containsAll(['fresh', 'stale']),
        reason: 'the stale entry is KEPT -- stale tags beat blank ones');
    expect(cache.entries['stale']!.title, 'Stale Title');
    expect(cache.entries['stale']!.durationMs, 210000,
        reason: 'and its expensive duration survives the bump');
    expect(cache.staleIds, {'stale'},
        reason: 'flagged so a background pass re-reads exactly it');
  });

  test('an entry missing a required field is still evicted outright', () async {
    // Unchanged behaviour: those entries genuinely lack data the app needs,
    // so there is nothing worth showing while waiting.
    final f = File('${tmp.path}/cache.json');
    final noDuration = _entry(title: 'x', artist: 'y')..remove('durationMs');
    await f.writeAsString(jsonEncode({'a': noDuration}));

    expect(MetaCache.load(f).entries, isEmpty);
  });

  test('a library load shows stale tags immediately rather than placeholders',
      () async {
    final root = await _root(tmp);
    final cacheFile = File('${tmp.path}/cache.json');
    await cacheFile.writeAsString(jsonEncode({
      'fresh': _entry(title: 'Fresh Song', artist: 'Fresh Artist'),
      'stale': _entry(
          title: 'Stale Song', artist: 'Old Artist', rev: kMetaCacheRevision - 1),
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    final byId = {for (final t in model.allTracks) t.contentId: t};
    // The files don't exist, so the background re-read can find nothing --
    // which is exactly the interesting case: the cached values must still be
    // what the user sees, not filename-derived placeholders.
    expect(byId['stale']!.title, 'Stale Song');
    expect(byId['stale']!.durationMs, 210000,
        reason: 'the Time column must not go blank over a revision bump');
    expect(byId['fresh']!.title, 'Fresh Song');
  });

  test('durations persist into the manifest, surviving any cache loss',
      () async {
    final root = await _root(tmp);
    final cacheFile = File('${tmp.path}/cache.json');
    await cacheFile.writeAsString(jsonEncode({
      'fresh': _entry(title: 'Fresh Song', artist: 'A', durationMs: 123456),
      'stale': _entry(title: 'Stale Song', artist: 'B', durationMs: 654321),
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));
    await model.persistDurationsToManifests();

    final onDisk = jsonDecode(
        File('${root.path}/.library.json').readAsStringSync()) as Map<String, dynamic>;
    final tracks = onDisk['tracks'] as Map<String, dynamic>;
    expect((tracks['fresh'] as Map)['duration_ms'], 123456);
    expect((tracks['stale'] as Map)['duration_ms'], 654321);
    expect((tracks['fresh'] as Map)['date_added'], '2024-01-01T00:00:00Z',
        reason: 'the date it was written to protect is untouched');

    // Now throw the cache away entirely -- the durations must still be there.
    await cacheFile.delete();
    final reloaded = LibraryModel();
    await reloaded
        .load(libraryRoots: [root], cacheFile: File('${tmp.path}/gone.json'))
        .timeout(const Duration(seconds: 30));
    final byId = {for (final t in reloaded.allTracks) t.contentId: t};
    expect(byId['fresh']!.durationMs, 123456,
        reason: 'a lost cache must not cost the library its Time column');
    expect(byId['stale']!.durationMs, 654321);
  });
}
