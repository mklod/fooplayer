import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/metadata/tags.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, String relPath) => Track(
    contentId: id, relPath: relPath, dateAdded: DateTime.utc(2024), title: 'x');

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mc'));
  tearDown(() async => tmp.delete(recursive: true));

  test('round-trips entries; corrupt file loads empty', () async {
    final f = File('${tmp.path}/meta_cache.json');
    final c = MetaCache.load(f);
    expect(c.entries, isEmpty);
    c.entries['id1'] = const TrackTags(title: 'T', artist: 'A', album: 'B', genre: 'G');
    await c.save(f);
    expect(MetaCache.load(f).entries['id1']!.artist, 'A');
    f.writeAsStringSync('{nope');
    expect(MetaCache.load(f).entries, isEmpty);
  });

  test('fillMetadata uses cache without touching files, reads misses', () async {
    final root = await Directory('${tmp.path}/lib').create();
    // On-disk file for the cache-miss track (junk bytes → filename fallback).
    await File('${root.path}/Muse - New Born.mp3').writeAsBytes(List.filled(32, 0));
    final cache = MetaCache.load(File('${tmp.path}/meta_cache.json'));
    cache.entries['hit'] = const TrackTags(title: 'Cached', artist: 'CacheArtist');

    final tracks = [
      tr('hit', 'does/not/exist.mp3'), // cache hit: file never touched
      tr('miss', 'Muse - New Born.mp3'),
    ];
    final filled = await fillMetadata(tracks, root, cache);
    expect(filled[0].artist, 'CacheArtist');
    expect(filled[1].artist, 'Muse');
    expect(filled[1].title, 'New Born');
    expect(cache.entries.containsKey('miss'), isTrue); // stored for next time
  });

  test('missing file on cache miss keeps filename-derived fields', () async {
    final root = await Directory('${tmp.path}/lib2').create();
    final cache = MetaCache.load(File('${tmp.path}/mc2.json'));
    final filled = await fillMetadata([tr('gone', 'Artist X - Gone.mp3')], root, cache);
    expect(filled.single.artist, 'Artist X');
    expect(filled.single.title, 'Gone');
  });

  test('root-level track with unparseable bytes gets empty album', () async {
    final root = await Directory('${tmp.path}/lib3').create();
    // Root-level file with junk bytes (unparseable).
    await File('${root.path}/RootSong.mp3').writeAsBytes(List.filled(32, 0));
    final cache = MetaCache.load(File('${tmp.path}/mc3.json'));

    final filled = await fillMetadata([tr('root', 'RootSong.mp3')], root, cache);
    expect(filled.single.title, 'RootSong');
    expect(filled.single.album, ''); // Should be empty, not the library folder name
  });
}
