// Multi-root library loading/merging (Plan 2a.2 Task 4): each configured
// root keeps its own `.library.json`; LibraryModel.load merges them --
// tracks dedupe by contentId (first root in the list wins), playlists are
// concatenated with same-name collisions suffixed " (2)", " (3)", ..., and
// a root with no manifest yet is skipped (not fatal) and reported via
// rootsMissingManifest.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';

Future<Directory> _root(Directory tmp, String name) =>
    Directory('${tmp.path}/$name').create();

Future<void> _writeManifest(
  Directory root, {
  required Map<String, Object?> tracks,
  List<Map<String, Object?>> playlists = const [],
}) => File('${root.path}/.library.json').writeAsString(
  jsonEncode({'schema': 1, 'tracks': tracks, 'playlists': playlists}),
);

Map<String, Object?> _trackJson(String path, String dateAdded) => {
  'paths': [path],
  'date_added': dateAdded,
};

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('multiroot'));
  tearDown(() async => tmp.delete(recursive: true));

  test('merges two roots: tracks dedupe by contentId (first root wins) and '
      'each surviving track is stamped with its own root path', () async {
    final rootA = await _root(tmp, 'rootA');
    final rootB = await _root(tmp, 'rootB');

    await _writeManifest(
      rootA,
      tracks: {
        'shared': _trackJson('A - Shared Song.mp3', '2024-01-01T00:00:00Z'),
        'only-a': _trackJson('A - Only.mp3', '2024-01-02T00:00:00Z'),
      },
    );
    await _writeManifest(
      rootB,
      tracks: {
        // Same contentId as rootA's, but a different path/date -- rootA's
        // manifest entry must win because rootA is listed first.
        'shared': _trackJson(
          'B - Shared Song Renamed.mp3',
          '2099-01-01T00:00:00Z',
        ),
        'only-b': _trackJson('B - Only.mp3', '2024-01-03T00:00:00Z'),
      },
    );

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [rootA, rootB],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    expect(model.rootsMissingManifest, isEmpty);
    expect(model.allTracks, hasLength(3)); // shared + only-a + only-b, not 4

    final shared = model.allTracks.firstWhere((t) => t.contentId == 'shared');
    expect(
      shared.relPath,
      'A - Shared Song.mp3',
      reason: 'rootA (listed first) wins the dedupe',
    );
    expect(shared.rootPath, rootA.path);
    expect(shared.dateAdded, DateTime.utc(2024, 1, 1));

    final onlyA = model.allTracks.firstWhere((t) => t.contentId == 'only-a');
    expect(onlyA.rootPath, rootA.path);
    final onlyB = model.allTracks.firstWhere((t) => t.contentId == 'only-b');
    expect(onlyB.rootPath, rootB.path);
  });

  test('merges playlists from both roots, suffixing a same-named playlist '
      'from the second root with " (2)"', () async {
    final rootA = await _root(tmp, 'rootA');
    final rootB = await _root(tmp, 'rootB');

    await _writeManifest(
      rootA,
      tracks: {'a1': _trackJson('a1.mp3', '2024-01-01T00:00:00Z')},
      playlists: [
        {
          'name': 'mix',
          'track_ids': ['a1'],
        },
      ],
    );
    await _writeManifest(
      rootB,
      tracks: {'b1': _trackJson('b1.mp3', '2024-01-02T00:00:00Z')},
      playlists: [
        {
          'name': 'mix',
          'track_ids': ['b1'],
        }, // collides with rootA's "mix"
        {
          'name': 'unique',
          'track_ids': ['b1'],
        },
      ],
    );

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [rootA, rootB],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    final names = model.playlists.map((p) => p.name).toList();
    expect(names, containsAll(['mix', 'mix (2)', 'unique']));

    final firstMix = model.playlists.firstWhere((p) => p.name == 'mix');
    expect(firstMix.trackIds, ['a1']);
    final secondMix = model.playlists.firstWhere((p) => p.name == 'mix (2)');
    expect(secondMix.trackIds, ['b1']);
  });

  test('a root with no .library.json yet is skipped (not fatal) and reported '
      'in rootsMissingManifest, while the other root still loads', () async {
    final withManifest = await _root(tmp, 'withManifest');
    final withoutManifest = await _root(tmp, 'withoutManifest');
    await _writeManifest(
      withManifest,
      tracks: {'only': _trackJson('only.mp3', '2024-01-01T00:00:00Z')},
    );
    // withoutManifest deliberately gets no .library.json written.

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [withManifest, withoutManifest],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    expect(model.rootsMissingManifest, [withoutManifest.path]);
    expect(model.allTracks, hasLength(1));
    expect(model.allTracks.single.contentId, 'only');
  });

  test('a root whose .library.json is corrupt is recorded in rootsFailed '
      '(not fatal) while the other root still loads its tracks', () async {
    final good = await _root(tmp, 'good');
    final bad = await _root(tmp, 'bad');
    await _writeManifest(
      good,
      tracks: {'only': _trackJson('only.mp3', '2024-01-01T00:00:00Z')},
    );
    // Garbage, not valid JSON at all -- loadManifestFile's jsonDecode
    // throws a FormatException parsing this.
    await File('${bad.path}/.library.json').writeAsString('{not valid json');

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [good, bad],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, isNot(startsWith('error')));
    expect(model.allTracks, hasLength(1));
    expect(model.allTracks.single.contentId, 'only');
    expect(model.rootsFailed, [bad.path]);
    expect(
      model.rootsMissingManifest,
      isEmpty,
      reason:
          'bad has a .library.json -- it exists, it just fails to '
          'parse, which is a different (and differently reported) case '
          'than a root with no manifest at all',
    );
  });

  test('a root whose .library.json is valid JSON but the wrong shape '
      '(e.g. missing the tracks map) is also recorded in rootsFailed, not '
      'fatal', () async {
    final good = await _root(tmp, 'good');
    final wrongShape = await _root(tmp, 'wrongShape');
    await _writeManifest(
      good,
      tracks: {'only': _trackJson('only.mp3', '2024-01-01T00:00:00Z')},
    );
    // Valid JSON, but schema/tracks are the wrong type -- loadManifestFile's
    // `j['schema'] as int` / `j['tracks'] as Map<String, dynamic>` casts
    // throw a TypeError, not a FormatException.
    await File(
      '${wrongShape.path}/.library.json',
    ).writeAsString(jsonEncode({'schema': 'nope', 'tracks': 'nope'}));

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [good, wrongShape],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, isNot(startsWith('error')));
    expect(model.allTracks, hasLength(1));
    expect(model.rootsFailed, [wrongShape.path]);
  });

  test('when every root is missing a manifest, load completes (not an error '
      'state) with no tracks and every root reported as missing', () async {
    final rootA = await _root(tmp, 'rootA');
    final rootB = await _root(tmp, 'rootB');

    final model = LibraryModel();
    await model
        .load(
          libraryRoots: [rootA, rootB],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.allTracks, isEmpty);
    expect(
      model.rootsMissingManifest,
      unorderedEquals([rootA.path, rootB.path]),
    );
    expect(model.status, isNot(startsWith('error')));
  });
}
