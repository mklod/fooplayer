import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/metadata/tags.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, String relPath, {String rootPath = ''}) => Track(
  contentId: id,
  relPath: relPath,
  rootPath: rootPath,
  dateAdded: DateTime.utc(2024),
  title: 'x',
);

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mc'));
  tearDown(() async => tmp.delete(recursive: true));

  test('round-trips entries; corrupt file loads empty', () async {
    final f = File('${tmp.path}/meta_cache.json');
    final c = MetaCache.load(f);
    expect(c.entries, isEmpty);
    c.entries['id1'] = const TrackTags(
      title: 'T',
      artist: 'A',
      album: 'B',
      genre: 'G',
    );
    await c.save(f);
    expect(MetaCache.load(f).entries['id1']!.artist, 'A');
    f.writeAsStringSync('{nope');
    expect(MetaCache.load(f).entries, isEmpty);
  });

  test(
    'fillMetadata uses cache without touching files, reads misses',
    () async {
      final root = await Directory('${tmp.path}/lib').create();
      // On-disk file for the cache-miss track (junk bytes → filename fallback).
      await File(
        '${root.path}/Muse - New Born.mp3',
      ).writeAsBytes(List.filled(32, 0));
      final cache = MetaCache.load(File('${tmp.path}/meta_cache.json'));
      cache.entries['hit'] = const TrackTags(
        title: 'Cached',
        artist: 'CacheArtist',
      );

      final tracks = [
        tr(
          'hit',
          'does/not/exist.mp3',
          rootPath: root.path,
        ), // cache hit: file never touched
        tr('miss', 'Muse - New Born.mp3', rootPath: root.path),
      ];
      final filled = await fillMetadata(tracks, cache);
      expect(filled[0].artist, 'CacheArtist');
      expect(filled[1].artist, 'Muse');
      expect(filled[1].title, 'New Born');
      expect(cache.entries.containsKey('miss'), isTrue); // stored for next time
    },
  );

  test('missing file on cache miss keeps filename-derived fields', () async {
    final root = await Directory('${tmp.path}/lib2').create();
    final cache = MetaCache.load(File('${tmp.path}/mc2.json'));
    final filled = await fillMetadata([
      tr('gone', 'Artist X - Gone.mp3', rootPath: root.path),
    ], cache);
    expect(filled.single.artist, 'Artist X');
    expect(filled.single.title, 'Gone');
  });

  test('root-level track with unparseable bytes gets empty album', () async {
    final root = await Directory('${tmp.path}/lib3').create();
    // Root-level file with junk bytes (unparseable).
    await File('${root.path}/RootSong.mp3').writeAsBytes(List.filled(32, 0));
    final cache = MetaCache.load(File('${tmp.path}/mc3.json'));

    final filled = await fillMetadata([
      tr('root', 'RootSong.mp3', rootPath: root.path),
    ], cache);
    expect(filled.single.title, 'RootSong');
    expect(
      filled.single.album,
      '',
    ); // Should be empty, not the library folder name
  });

  test(
    'cache entries written before durationMs existed (key entirely absent) are treated as a miss',
    () async {
      final f = File('${tmp.path}/legacy_cache.json');
      // A pre-Task-6 cache file: no durationMs key at all on the entry.
      await f.writeAsString(
        jsonEncode({
          'legacy-id': {
            'title': 'Old Title',
            'artist': 'Old Artist',
            'album': 'Old Album',
            'genre': 'Old Genre',
          },
        }),
      );
      final cache = MetaCache.load(f);
      // Excluded from the loaded map entirely, so every caller's ordinary
      // `cache.entries[id] == null` miss check re-reads the file (and this
      // time backfills durationMs).
      expect(cache.entries.containsKey('legacy-id'), isFalse);
    },
  );

  test(
    'a cached entry with durationMs explicitly null (duration genuinely unknown) is still a hit',
    () async {
      final f = File('${tmp.path}/known_null_cache.json');
      await f.writeAsString(
        jsonEncode({
          'id': {
            'title': 'T',
            'artist': 'A',
            'album': 'B',
            'genre': 'G',
            'durationMs': null,
            'trackNumber': 4,
            'rev': kMetaCacheRevision,
          },
        }),
      );
      final cache = MetaCache.load(f);
      expect(cache.entries.containsKey('id'), isTrue);
      expect(cache.entries['id']!.durationMs, isNull);
    },
  );

  test(
    'cache entries written before trackNumber existed (key entirely absent) are treated as a miss',
    () async {
      final f = File('${tmp.path}/legacy_cache2.json');
      // A pre-track-number cache file: durationMs present (so it clears that
      // staleness check) but no trackNumber key at all on the entry.
      await f.writeAsString(
        jsonEncode({
          'legacy-id': {
            'title': 'Old Title',
            'artist': 'Old Artist',
            'album': 'Old Album',
            'genre': 'Old Genre',
            'durationMs': 200000,
          },
        }),
      );
      final cache = MetaCache.load(f);
      expect(cache.entries.containsKey('legacy-id'), isFalse);
    },
  );

  test(
    'a cached entry with trackNumber explicitly null (genuinely unknown) is still a hit',
    () async {
      final f = File('${tmp.path}/known_null_tracknum_cache.json');
      await f.writeAsString(
        jsonEncode({
          'id': {
            'title': 'T',
            'artist': 'A',
            'album': 'B',
            'genre': 'G',
            'durationMs': 200000,
            'trackNumber': null,
            'rev': kMetaCacheRevision,
          },
        }),
      );
      final cache = MetaCache.load(f);
      expect(cache.entries.containsKey('id'), isTrue);
      expect(cache.entries['id']!.trackNumber, isNull);
    },
  );

  test(
    'fillMetadata carries a cached durationMs into the returned Track',
    () async {
      final root = await Directory('${tmp.path}/lib5').create();
      final cache = MetaCache.load(File('${tmp.path}/mc5.json'));
      cache.entries['hasdur'] = const TrackTags(title: 'T', durationMs: 123456);
      final filled = await fillMetadata([
        tr('hasdur', 'x.mp3', rootPath: root.path),
      ], cache);
      expect(filled.single.durationMs, 123456);
    },
  );

  test(
    'fillMetadata carries a cached trackNumber into the returned Track',
    () async {
      final root = await Directory('${tmp.path}/lib6').create();
      final cache = MetaCache.load(File('${tmp.path}/mc6.json'));
      cache.entries['hasnum'] = const TrackTags(title: 'T', trackNumber: 5);
      final filled = await fillMetadata([
        tr('hasnum', 'x.mp3', rootPath: root.path),
      ], cache);
      expect(filled.single.trackNumber, 5);
    },
  );

  test(
    'fillMetadata on a cache miss backfills trackNumber from the filename prefix',
    () async {
      final root = await Directory('${tmp.path}/lib7').create();
      await File(
        '${root.path}/03 You Love Me (Remix).mp3',
      ).writeAsBytes(List.filled(32, 0)); // junk -> filename fallback
      final cache = MetaCache.load(File('${tmp.path}/mc7.json'));
      final filled = await fillMetadata([
        tr('miss2', '03 You Love Me (Remix).mp3', rootPath: root.path),
      ], cache);
      expect(filled.single.trackNumber, 3);
      expect(filled.single.title, 'You Love Me (Remix)');
    },
  );

  test(
    'readTagsBatch resolves each record independently: junk bytes and missing file both fall back to filename',
    () async {
      final root = await Directory('${tmp.path}/lib4').create();
      // Junk bytes -> unparseable -> filename fallback.
      final junkPath = '${root.path}/Muse - New Born.mp3';
      await File(junkPath).writeAsBytes(List.filled(32, 0));
      // Never created -> missing file -> filename fallback.
      final missingPath = '${root.path}/Artist X - Gone.mp3';

      final results = await readTagsBatch([
        ('junk-id', junkPath, 'Muse - New Born.mp3'),
        ('missing-id', missingPath, 'Artist X - Gone.mp3'),
      ]);

      expect(results.keys, {'junk-id', 'missing-id'});
      expect(results['junk-id']!.artist, 'Muse');
      expect(results['junk-id']!.title, 'New Born');
      expect(results['missing-id']!.artist, 'Artist X');
      expect(results['missing-id']!.title, 'Gone');
    },
  );

  group('needsDurationProbe', () {
    test('true only for a null-duration, not-yet-probed .mp3 entry', () {
      expect(
        needsDurationProbe(const TrackTags(title: 'T'), 'song.mp3'),
        isTrue,
      );
    });

    test('false once durationMs is known, regardless of durationProbed', () {
      expect(
        needsDurationProbe(
          const TrackTags(title: 'T', durationMs: 1000),
          'song.mp3',
        ),
        isFalse,
      );
    });

    test('false once durationProbed is already true, even with a null duration '
        '(the one-time budget is spent)', () {
      expect(
        needsDurationProbe(
          const TrackTags(title: 'T', durationProbed: true),
          'song.mp3',
        ),
        isFalse,
      );
    });

    test('false for a non-mp3 path, regardless of duration/probed state', () {
      expect(
        needsDurationProbe(const TrackTags(title: 'T'), 'song.flac'),
        isFalse,
      );
    });
  });

  group('fillMetadata: one-time mp3 duration reprobe', () {
    /// MPEG2.5 Layer III, 24 kbps @ 11025 Hz CBR frames (frame length 313
    /// bytes). `audio_metadata_reader`'s own MP3Parser can never compute a
    /// duration for MPEG2.5 (no branch for it in its bitrate/samples-per-
    /// frame tables -- see tags_test.dart's fallback-wiring group for the
    /// full explanation), so a cache entry seeded with `durationMs: null`
    /// for a file actually made of these bytes matches the real-world shape
    /// this feature targets, deterministically and without needing the
    /// `L:\music` fixture.
    List<int> mpeg25Frames(int frameCount) {
      const frameLen = 313;
      final header = [0xFF, 0xE3, 0x30, 0x00];
      final out = <int>[];
      for (var i = 0; i < frameCount; i++) {
        out.addAll(header);
        out.addAll(List.filled(frameLen - header.length, 0x00));
      }
      // A trailing ID3v1 "TAG" tag so audio_metadata_reader's MP3Parser
      // actually recognizes this as an mp3 it can parse at all (its
      // `canUserParser` requires an ID3v2 OR ID3v1 tag to be present --
      // plain frame bytes alone don't match any container parser, which
      // would take a different, uninteresting code path: _readRawTags
      // returning null and readTags never reaching the duration fallback).
      out.addAll([0x54, 0x41, 0x47, ...List.filled(125, 0x00)]);
      return out;
    }

    test('a cache-hit mp3 with durationMs:null and no prior probe is '
        're-read once, gaining a duration and durationProbed:true', () async {
      final root = await Directory('${tmp.path}/lib8').create();
      await File('${root.path}/song.mp3').writeAsBytes(mpeg25Frames(20));
      final cache = MetaCache.load(File('${tmp.path}/mc8.json'));
      // Shaped exactly like a pre-existing cache entry from before this
      // feature existed: real tags, durationMs null, no durationProbed key
      // (TrackTags.fromJson defaults that to false).
      cache.entries['id'] = const TrackTags(
        title: 'Cached Title',
        artist: 'Cached Artist',
        album: 'Cached Album',
      );

      final filled = await fillMetadata([
        tr('id', 'song.mp3', rootPath: root.path),
      ], cache);

      expect(filled.single.durationMs, 2086); // see mp3_duration_test.dart
      expect(cache.entries['id']!.durationProbed, isTrue);
      // Title/artist/album come from readTags' own filename-fallback merge
      // this time (the synthetic file has no ID3 tags of its own) -- the
      // important thing is the entry was genuinely re-read, not just
      // patched in place.
    });

    test('re-probing again after durationProbed:true is a no-op (the file '
        'is never re-read a second time)', () async {
      final root = await Directory('${tmp.path}/lib9').create();
      final path = '${root.path}/song.mp3';
      await File(path).writeAsBytes(mpeg25Frames(20));
      final cache = MetaCache.load(File('${tmp.path}/mc9.json'));
      cache.entries['id'] = const TrackTags(
        title: 'Real Title',
        durationMs: null,
        durationProbed: true,
      );

      final filled = await fillMetadata([
        tr('id', 'song.mp3', rootPath: root.path),
      ], cache);

      // Untouched: still null duration, still the original cached title --
      // proof the file was never opened a second time.
      expect(filled.single.durationMs, isNull);
      expect(filled.single.title, 'Real Title');
    });

    test('a null-duration mp3 entry whose file no longer exists keeps its '
        'cached tags untouched rather than downgrading to a filename '
        'placeholder', () async {
      final root = await Directory('${tmp.path}/lib10').create();
      // Deliberately never created on disk.
      final cache = MetaCache.load(File('${tmp.path}/mc10.json'));
      cache.entries['id'] = const TrackTags(
        title: 'Real Enriched Title',
        artist: 'Real Enriched Artist',
      );

      final filled = await fillMetadata([
        tr('id', 'gone.mp3', rootPath: root.path),
      ], cache);

      expect(filled.single.title, 'Real Enriched Title');
      expect(filled.single.artist, 'Real Enriched Artist');
      expect(
        cache.entries['id']!.durationProbed,
        isFalse,
        reason: 'nothing was actually probed -- the file is missing',
      );
    });
  });
}
