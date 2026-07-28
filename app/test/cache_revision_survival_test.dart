// Saving the cache must not erase the fact that an entry needs re-reading.
//
// The bug this pins, which shipped and wasted a full library pass: entries
// kept for display but NOT re-read were stamped with the CURRENT revision on
// every save. The cache flushes every 5 batches, so within the first ~1000
// files the whole library was marked refreshed, and the 57 tracks whose tags
// the old parser had dropped were never revisited. The refresh reported
// itself complete while changing nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/metadata/tags.dart';

Map<String, Object?> _json({required String artist, required Object? rev}) => {
      'title': 'A Title',
      'artist': artist,
      'album': 'An Album',
      'genre': null,
      'durationMs': 1000,
      'trackNumber': null,
      'durationProbed': false,
      if (rev != null) 'rev': rev,
    };

void main() {
  late Directory tmp;
  late File cacheFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('revsurvive');
    cacheFile = File('${tmp.path}/cache.json');
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('a stale entry that was never re-read stays stale across a save',
      () async {
    await cacheFile.writeAsString(jsonEncode({
      'stale': _json(artist: 'Old', rev: kMetaCacheRevision - 1),
      'fresh': _json(artist: 'Current', rev: kMetaCacheRevision),
    }));

    final cache = MetaCache.load(cacheFile);
    expect(cache.staleIds, {'stale'});

    // A flush happens long before every file has been re-read.
    await cache.save(cacheFile);

    final reloaded = MetaCache.load(cacheFile);
    expect(reloaded.staleIds, {'stale'},
        reason: 'saving must not silently mark unread entries as refreshed');
    expect(reloaded.entries['stale']!.artist, 'Old');
  });

  test('an entry that WAS re-read stops being stale', () async {
    await cacheFile.writeAsString(jsonEncode({
      'a': _json(artist: 'Old', rev: kMetaCacheRevision - 1),
      'b': _json(artist: 'Old', rev: kMetaCacheRevision - 1),
    }));

    final cache = MetaCache.load(cacheFile);
    expect(cache.staleIds, {'a', 'b'});

    // Exactly what the enrichment pass does for each file it re-reads.
    cache.entries['a'] = const TrackTags(
      title: 'A Title',
      artist: 'Recovered',
      album: 'An Album',
      durationMs: 1000,
    );
    cache.markRefreshed('a');
    await cache.save(cacheFile);

    final reloaded = MetaCache.load(cacheFile);
    expect(reloaded.staleIds, {'b'}, reason: 'only the untouched one remains');
    expect(reloaded.entries['a']!.artist, 'Recovered');
  });

  test('an entry with no revision at all is treated as stale, not current',
      () async {
    await cacheFile.writeAsString(
        jsonEncode({'ancient': _json(artist: 'Old', rev: null)}));

    final cache = MetaCache.load(cacheFile);
    expect(cache.staleIds, {'ancient'});
    await cache.save(cacheFile);
    expect(MetaCache.load(cacheFile).staleIds, {'ancient'});
  });
}
