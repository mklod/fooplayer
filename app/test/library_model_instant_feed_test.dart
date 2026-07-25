// Regression tests for the "blank artist/album at launch" defect: Part A of
// LibraryModel.load (the instant feed) used to leave a cache-miss track's
// Title as the manifest's raw, unsplit filename (see manifest_io.dart --
// every track's `title` starts out as `p.basenameWithoutExtension(path)`)
// until background enrichment (Part B) reached that file, which could be
// minutes into a large first-run scan. Since parseFromFilename is pure
// string manipulation (no file I/O), Part A now runs it synchronously over
// every cache miss so Title/Artist/Album are already properly split by the
// time the very first frame renders.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';

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

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('instant_feed'));
  tearDown(() async => tmp.delete(recursive: true));

  test(
      'with an empty tag cache, tracks have properly split artist/title/album '
      'the moment Part A finishes -- not the raw manifest filename', () async {
    final root = await _root(tmp, 'lib');
    await _writeManifest(root, tracks: {
      'id1': _trackJson(
          'albums/RÜFÜS du Sol - The Life/RÜFÜS du Sol - The Life.mp3',
          '2024-01-01T00:00:00Z'),
    });

    final model = LibraryModel();
    List<Track>? afterPartA;
    // Part A's own notifyListeners() sets status to 'ready' (nothing left to
    // enrich) or 'ready (reading tags in background)' (Part B still to run)
    // -- either way that's the FIRST time status carries "ready", which is
    // exactly the state right after Part A applied its synchronous
    // filename-parse and before Part B's (here: missing-file-fallback,
    // since no real audio file exists on disk) enrichment has run at all.
    model.addListener(() {
      if (afterPartA == null && model.status.startsWith('ready')) {
        afterPartA = List<Track>.of(model.allTracks);
      }
    });

    await model
        .load(libraryRoots: [root], cacheFile: File('${tmp.path}/meta_cache.json'))
        .timeout(const Duration(seconds: 30));

    expect(afterPartA, isNotNull);
    final t = afterPartA!.single;
    expect(t.title, 'The Life');
    expect(t.artist, 'RÜFÜS du Sol');
    expect(t.album, 'RÜFÜS du Sol - The Life');
  });

  test('a manifest filename with a leading track number is split into '
      'trackNumber and a clean title, immediately in Part A', () async {
    final root = await _root(tmp, 'lib2');
    await _writeManifest(root, tracks: {
      'id2': _trackJson('Album/03 You Love Me (Remix).mp3', '2024-01-01T00:00:00Z'),
    });

    final model = LibraryModel();
    List<Track>? afterPartA;
    model.addListener(() {
      if (afterPartA == null && model.status.startsWith('ready')) {
        afterPartA = List<Track>.of(model.allTracks);
      }
    });

    await model
        .load(libraryRoots: [root], cacheFile: File('${tmp.path}/meta_cache2.json'))
        .timeout(const Duration(seconds: 30));

    expect(afterPartA, isNotNull);
    final t = afterPartA!.single;
    expect(t.trackNumber, 3);
    expect(t.title, 'You Love Me (Remix)');
  });

  test('a cached track (already tag-enriched) is untouched by the '
      'filename-parse fallback -- it keeps its real cached tags', () async {
    final root = await _root(tmp, 'lib3');
    await _writeManifest(root, tracks: {
      'id3': _trackJson('Some Raw Filename.mp3', '2024-01-01T00:00:00Z'),
    });
    final cacheFile = File('${tmp.path}/meta_cache3.json');
    await cacheFile.writeAsString(jsonEncode({
      'id3': {
        'title': 'Real Tagged Title',
        'artist': 'Real Tagged Artist',
        'album': 'Real Tagged Album',
        'genre': 'Rock',
        'durationMs': 200000,
        'trackNumber': 5,
      }
    }));

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    final t = model.allTracks.single;
    expect(t.title, 'Real Tagged Title');
    expect(t.artist, 'Real Tagged Artist');
    expect(t.album, 'Real Tagged Album');
    expect(t.trackNumber, 5);
  });
}
