// Verifies the *production* wiring of the one-time mp3 duration reprobe
// (see meta_cache.dart's `needsDurationProbe`) inside LibraryModel.load's
// Part A/B -- as opposed to meta_cache_test.dart's coverage of the
// `fillMetadata` helper directly, which nothing in lib/ actually calls at
// runtime. This is the code path a real launch goes through.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/model/library_model.dart';

Future<Directory> _root(Directory tmp, String name) =>
    Directory('${tmp.path}/$name').create();

Future<void> _writeManifest(
  Directory root, {
  required Map<String, Object?> tracks,
}) =>
    File('${root.path}/.library.json').writeAsString(jsonEncode({
      'schema': 1,
      'tracks': tracks,
      'playlists': [],
    }));

Map<String, Object?> _trackJson(String path, String dateAdded) =>
    {'paths': [path], 'date_added': dateAdded};

/// MPEG2.5 Layer III, 24 kbps @ 11025 Hz CBR frames plus a trailing ID3v1
/// tag -- see tags_test.dart's fallback-wiring group for why this shape
/// deterministically makes `audio_metadata_reader` itself report a null
/// duration (no MPEG2.5 branch in its bitrate/samples-per-frame tables)
/// while `mp3_duration.dart`'s own estimator (independently unit-tested in
/// mp3_duration_test.dart) correctly computes one: 20 frames * 313 bytes =
/// 6260 audio bytes @ 24kbps = 2086667us = 2086ms.
List<int> _nullUpstreamDurationMp3Bytes() {
  const frameLen = 313;
  final header = [0xFF, 0xE3, 0x30, 0x00];
  final out = <int>[];
  for (var i = 0; i < 20; i++) {
    out.addAll(header);
    out.addAll(List.filled(frameLen - header.length, 0x00));
  }
  out.addAll([0x54, 0x41, 0x47, ...List.filled(125, 0x00)]); // ID3v1 "TAG"
  return out;
}

void main() {
  late Directory tmp;
  setUp(() async =>
      tmp = await Directory.systemTemp.createTemp('duration_probe_wiring'));
  tearDown(() async => tmp.delete(recursive: true));

  test(
      'a cache-hit mp3 with durationMs:null and no prior probe is queued for '
      "Part B's background enrichment, ending with a real duration and "
      'durationProbed:true on disk', () async {
    final root = await _root(tmp, 'lib');
    await File('${root.path}/song.mp3').writeAsBytes(_nullUpstreamDurationMp3Bytes());
    await _writeManifest(root, tracks: {
      'id1': _trackJson('song.mp3', '2024-01-01T00:00:00Z'),
    });
    final cacheFile = File('${tmp.path}/meta_cache.json');
    // Shaped exactly like a cache entry written before this feature
    // existed: real tags, durationMs null, no durationProbed key at all
    // (TrackTags.fromJson defaults that to false).
    await cacheFile.writeAsString(jsonEncode({
      'id1': {
        'title': 'Cached Title',
        'artist': 'Cached Artist',
        'album': 'Cached Album',
        'genre': null,
        'durationMs': null,
        'trackNumber': null,
      }
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    final t = model.allTracks.single;
    expect(t.durationMs, 2086);

    final onDisk = MetaCache.load(cacheFile);
    expect(onDisk.entries['id1']!.durationMs, 2086);
    expect(onDisk.entries['id1']!.durationProbed, isTrue);
    model.dispose();
  });

  test(
      'a cache-hit mp3 with durationMs:null whose file is missing keeps its '
      'cached tags untouched and is not queued for background enrichment',
      () async {
    final root = await _root(tmp, 'lib2');
    // Deliberately never created on disk.
    await _writeManifest(root, tracks: {
      'id1': _trackJson('gone.mp3', '2024-01-01T00:00:00Z'),
    });
    final cacheFile = File('${tmp.path}/meta_cache2.json');
    await cacheFile.writeAsString(jsonEncode({
      'id1': {
        'title': 'Real Enriched Title',
        'artist': 'Real Enriched Artist',
        'album': 'Real Enriched Album',
        'genre': null,
        'durationMs': null,
        'trackNumber': null,
      }
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    // Nothing was queued for enrichment -- status goes straight to 'ready',
    // never through 'ready (reading tags in background)'.
    expect(model.status, 'ready');
    final t = model.allTracks.single;
    expect(t.title, 'Real Enriched Title');
    expect(t.artist, 'Real Enriched Artist');
    expect(t.durationMs, isNull);

    final onDisk = MetaCache.load(cacheFile);
    expect(onDisk.entries['id1']!.durationProbed, isFalse,
        reason: 'nothing was actually probed -- the file is missing');
    model.dispose();
  });

  test('a cache-hit mp3 already marked durationProbed:true is left alone -- '
      'no background re-read', () async {
    final root = await _root(tmp, 'lib3');
    await File('${root.path}/song.mp3').writeAsBytes(_nullUpstreamDurationMp3Bytes());
    await _writeManifest(root, tracks: {
      'id1': _trackJson('song.mp3', '2024-01-01T00:00:00Z'),
    });
    final cacheFile = File('${tmp.path}/meta_cache3.json');
    await cacheFile.writeAsString(jsonEncode({
      'id1': {
        'title': 'Genuinely Unmeasurable',
        'artist': null,
        'album': null,
        'genre': null,
        'durationMs': null,
        'trackNumber': null,
        'durationProbed': true,
      }
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    final t = model.allTracks.single;
    expect(t.title, 'Genuinely Unmeasurable');
    expect(t.durationMs, isNull);
    model.dispose();
  });
}
