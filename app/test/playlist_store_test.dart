// PlaylistStore CRUD (TODO #29): every mutation loads the FIRST root's
// .library.json fresh, mutates only its playlists section, saves via
// fooplayer_core's atomic saveManifest (.bak of the previous version), and
// refreshes LibraryModel's merged playlist state via reloadPlaylists --
// no full library reload. Playlists owned by another root's manifest are
// blocked with a clear message, and the store respects LibraryModel's
// busy discipline (brief retry against a rescan-held flag).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';

Future<Directory> _root(Directory tmp, String name) =>
    Directory('${tmp.path}/$name').create();

Future<void> _writeManifest(
  Directory root, {
  required Map<String, Object?> tracks,
  List<Map<String, Object?>> playlists = const [],
}) =>
    File('${root.path}/.library.json').writeAsString(jsonEncode({
      'schema': 1,
      'tracks': tracks,
      'playlists': playlists,
    }));

Map<String, Object?> _trackJson(String path, String dateAdded) =>
    {'paths': [path], 'date_added': dateAdded};

Map<String, dynamic> _readManifest(Directory root) =>
    jsonDecode(File('${root.path}/.library.json').readAsStringSync())
        as Map<String, dynamic>;

List<Map<String, dynamic>> _diskPlaylists(Directory root) =>
    (_readManifest(root)['playlists'] as List).cast<Map<String, dynamic>>();

void main() {
  late Directory tmp;
  late Directory rootA;
  late Directory rootB;
  late LibraryModel model;
  late PlaylistStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plstore');
    rootA = await _root(tmp, 'rootA');
    rootB = await _root(tmp, 'rootB');
    await _writeManifest(rootA, tracks: {
      'a1': _trackJson('a1.mp3', '2024-01-01T00:00:00Z'),
      'a2': _trackJson('a2.mp3', '2024-01-02T00:00:00Z'),
    }, playlists: [
      {'name': 'mix', 'track_ids': ['a1']},
    ]);
    await _writeManifest(rootB, tracks: {
      'b1': _trackJson('b1.mp3', '2024-01-03T00:00:00Z'),
    }, playlists: [
      {'name': 'mix', 'track_ids': ['b1']}, // merges as "mix (2)"
      {'name': 'unique', 'track_ids': ['b1']},
    ]);
    model = LibraryModel();
    await model.load(
      libraryRoots: [rootA, rootB],
      cacheFile: File('${tmp.path}/meta_cache.json'),
    ).timeout(const Duration(seconds: 30));
    expect(model.status, 'ready');
    store = PlaylistStore(
      library: model,
      busyRetryEvery: const Duration(milliseconds: 20),
      busyRetryFor: const Duration(seconds: 2),
    );
  });

  tearDown(() async => tmp.delete(recursive: true));

  test(
      'createPlaylist round-trips: visible after reloadPlaylists, present '
      'in the first root\'s on-disk manifest, previous version preserved '
      'as .bak', () async {
    await store.createPlaylist('fresh');

    // Model refreshed via reloadPlaylists (no full reload needed).
    final created = model.playlists.singleWhere((pl) => pl.name == 'fresh');
    expect(created.trackIds, isEmpty);
    expect(created.rootPath, rootA.path, reason: 'created in the first root');

    // On disk: rootA's manifest gained the entry, rootB's untouched.
    expect(_diskPlaylists(rootA).map((p) => p['name']),
        containsAll(['mix', 'fresh']));
    expect(_diskPlaylists(rootB).map((p) => p['name']),
        unorderedEquals(['mix', 'unique']));

    // Atomic-save side effect: .bak holds the pre-op manifest.
    final bak = File('${rootA.path}/.library.json.bak');
    expect(bak.existsSync(), isTrue);
    final bakPlaylists =
        ((jsonDecode(bak.readAsStringSync()) as Map<String, dynamic>)[
                'playlists'] as List)
            .cast<Map<String, dynamic>>();
    expect(bakPlaylists.map((p) => p['name']), isNot(contains('fresh')));
  });

  test('addTrack / removeTrack round-trip on model and disk', () async {
    await store.createPlaylist('work');
    await store.addTrack('work', 'a2');

    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds,
        ['a2']);
    expect(
        _diskPlaylists(rootA)
            .singleWhere((p) => p['name'] == 'work')['track_ids'],
        ['a2']);

    // Adding the same track again does not duplicate it.
    await store.addTrack('work', 'a2');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds,
        ['a2']);

    await store.addTrack('work', 'a1');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds,
        ['a2', 'a1'], reason: 'append order preserved');

    await store.removeTrack('work', 'a2');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds,
        ['a1']);
    expect(
        _diskPlaylists(rootA)
            .singleWhere((p) => p['name'] == 'work')['track_ids'],
        ['a1']);
  });

  test(
      'deletePlaylist removes the entry from model and disk, and clears '
      'activePlaylist when the deleted playlist was the active one',
      () async {
    await store.createPlaylist('doomed');
    model.setPlaylist('doomed');
    expect(model.activePlaylist, 'doomed');

    await store.deletePlaylist('doomed');

    expect(model.playlists.map((pl) => pl.name), isNot(contains('doomed')));
    expect(_diskPlaylists(rootA).map((p) => p['name']),
        isNot(contains('doomed')));
    expect(model.activePlaylist, isNull,
        reason: 'deleting the active playlist falls back to Library view');
  });

  test(
      'unique-name validation: rejects an existing name, a merge-suffixed '
      'display name, and a blank name -- without writing anything',
      () async {
    final before = _readManifest(rootA);

    expect(() => store.createPlaylist('mix'),
        throwsA(isA<PlaylistStoreException>()));
    // "mix (2)" only exists as LibraryModel's merge suffix for rootB's
    // "mix" -- creating it for real would collide with that display name.
    expect(() => store.createPlaylist('mix (2)'),
        throwsA(isA<PlaylistStoreException>()));
    expect(() => store.createPlaylist('   '),
        throwsA(isA<PlaylistStoreException>()));

    expect(_readManifest(rootA), before, reason: 'nothing written on refusal');
  });

  test(
      'ownership block: mutating a playlist that lives in ANOTHER root\'s '
      'manifest throws (naming the owning root) and touches no manifest',
      () async {
    // "mix (2)" and "unique" are rootB's; the store writes only rootA.
    final beforeA = _readManifest(rootA);
    final beforeB = _readManifest(rootB);

    for (final op in <Future<void> Function()>[
      () => store.deletePlaylist('mix (2)'),
      () => store.addTrack('unique', 'a1'),
      () => store.removeTrack('unique', 'b1'),
    ]) {
      await expectLater(
        op(),
        throwsA(isA<PlaylistStoreException>().having(
            (e) => e.message, 'message', contains(rootB.path))),
      );
    }

    expect(_readManifest(rootA), beforeA);
    expect(_readManifest(rootB), beforeB);
    expect(model.playlists.map((pl) => pl.name),
        containsAll(['mix', 'mix (2)', 'unique']),
        reason: 'blocked -- and definitely not a silent no-op delete');
  });

  test('mutating a nonexistent playlist throws', () async {
    expect(() => store.addTrack('nope', 'a1'),
        throwsA(isA<PlaylistStoreException>()));
    expect(() => store.deletePlaylist('nope'),
        throwsA(isA<PlaylistStoreException>()));
  });

  test(
      'busy discipline: a store write retries while the busy flag is held '
      'and succeeds once released; a hold outlasting the retry budget '
      'throws a clear busy error', () async {
    // Simulate a rescan holding the flag, released mid-retry.
    expect(model.tryBeginManifestWrite(), isTrue);
    final create = store.createPlaylist('patient');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(model.playlists.map((pl) => pl.name), isNot(contains('patient')),
        reason: 'must not write while the flag is held');
    await model.endManifestWrite();
    await create;
    expect(model.playlists.map((pl) => pl.name), contains('patient'));

    // A hold that outlasts the budget: bounded failure, not a hang.
    final impatient = PlaylistStore(
      library: model,
      busyRetryEvery: const Duration(milliseconds: 10),
      busyRetryFor: const Duration(milliseconds: 100),
    );
    expect(model.tryBeginManifestWrite(), isTrue);
    try {
      await expectLater(
        impatient.createPlaylist('blocked'),
        throwsA(isA<PlaylistStoreException>()
            .having((e) => e.message, 'message', contains('busy'))),
      );
    } finally {
      await model.endManifestWrite();
    }
  });

  test('store on a model with no roots loaded throws, not crashes', () async {
    final empty = LibraryModel();
    final s = PlaylistStore(library: empty);
    await expectLater(
        s.createPlaylist('x'), throwsA(isA<PlaylistStoreException>()));
  });

  test(
      'first root without a .library.json is refused (seed first) instead '
      'of fabricating an empty manifest', () async {
    final bare = await _root(tmp, 'bare');
    final m = LibraryModel();
    await m.load(
      libraryRoots: [bare, rootA],
      cacheFile: File('${tmp.path}/meta_cache2.json'),
    ).timeout(const Duration(seconds: 30));
    final s = PlaylistStore(library: m);
    await expectLater(
      s.createPlaylist('x'),
      throwsA(isA<PlaylistStoreException>()
          .having((e) => e.message, 'message', contains('.library.json'))),
    );
    expect(File('${bare.path}/.library.json').existsSync(), isFalse);
  });

  test(
      'reloadPlaylists picks up an external manifest edit without touching '
      'allTracks, and re-applies the merge suffix convention', () async {
    final tracksBefore = model.allTracks;
    await _writeManifest(rootA, tracks: {
      'a1': _trackJson('a1.mp3', '2024-01-01T00:00:00Z'),
      'a2': _trackJson('a2.mp3', '2024-01-02T00:00:00Z'),
    }, playlists: [
      {'name': 'mix', 'track_ids': ['a1', 'a2']},
      {'name': 'extra', 'track_ids': []},
    ]);

    model.reloadPlaylists();

    expect(model.playlists.map((pl) => pl.name),
        containsAll(['mix', 'extra', 'mix (2)', 'unique']));
    expect(model.playlists.firstWhere((pl) => pl.name == 'mix').trackIds,
        ['a1', 'a2']);
    expect(identical(model.allTracks, tracksBefore), isTrue,
        reason: 'playlist-only refresh must not reload the track list');
  });
}
