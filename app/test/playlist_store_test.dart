// PlaylistStore CRUD (TODO #29; Plan 3 Task 5 rewrite): every mutation
// resolves the playlist's id from LibraryModel.playlists, loads its sidecar
// file (`<home>/.playlists/<id>.json`) FRESH from disk, mutates it, saves
// via fooplayer_core's atomic savePlaylistFile, and refreshes LibraryModel's
// merged playlist state via reloadPlaylists -- no full library reload.
//
// This used to be one PlaylistStore per multi-root fixture with an
// "owning root" concept (a playlist lived in whichever root's manifest
// wrote it, and mutations had to route to that exact root) plus a
// busy-retry dance against LibraryModel's manifest write lock (playlists
// and rescans/durations shared one `.library.json` per root, so a rescan
// in flight could block a playlist write). Both of those are gone now that
// playlists live in one shared sidecar directory instead of per-root
// manifests: there is no "owning root" to route to, and sidecar writes
// never touch LibraryModel's manifest lock at all -- see
// playlist_sidecar_store_test.dart for the new sidecar-specific coverage
// (file shape, backup+tombstone on delete, onMutated, no-home refusal,
// fresh-reload-picks-up-external-edits).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

Future<void> _seedPlaylist(
  Directory home, {
  required String id,
  required String name,
  required List<String> trackIds,
  DateTime? created,
}) async {
  final t = created ?? DateTime.utc(2024, 1, 1);
  await core.savePlaylistFile(
    home,
    core.PlaylistFile(
      id: id,
      name: name,
      trackIds: trackIds,
      created: t,
      modified: t,
      modifiedBy: 'seed',
    ),
  );
}

core.PlaylistFile? _onDisk(Directory home, String id) =>
    core.loadPlaylistsDir(home).playlists[id];

void main() {
  late Directory tmp;
  late Directory home;
  late LibraryModel model;
  late PlaylistStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plstore');
    home = await Directory('${tmp.path}/home').create();
    await _seedPlaylist(
      home,
      id: 'p_mix',
      name: 'mix',
      trackIds: ['a1'],
      created: DateTime.utc(2024, 1, 1),
    );
    await _seedPlaylist(
      home,
      id: 'p_unique',
      name: 'unique',
      trackIds: ['b1'],
      created: DateTime.utc(2024, 1, 2),
    );
    model = LibraryModel();
    await model
        .load(
          libraryRoots: const [],
          cacheFile: File('${tmp.path}/meta_cache.json'),
          libraryHome: home.path,
        )
        .timeout(const Duration(seconds: 30));
    expect(model.playlists.map((p) => p.name), ['mix', 'unique']);
    store = PlaylistStore(library: model, device: 'desktop');
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('createPlaylist round-trips: visible after reloadPlaylists and '
      'present on disk under the shared home', () async {
    await store.createPlaylist('fresh');

    final created = model.playlists.singleWhere((pl) => pl.name == 'fresh');
    expect(created.trackIds, isEmpty);
    expect(created.id, isNotNull);
    expect(_onDisk(home, created.id!)?.name, 'fresh');
  });

  test('addTrack / removeTrack round-trip on model and disk', () async {
    await store.createPlaylist('work');
    final id = model.playlists.singleWhere((pl) => pl.name == 'work').id!;

    await store.addTrack('work', 'a2');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds, [
      'a2',
    ]);
    expect(_onDisk(home, id)?.trackIds, ['a2']);

    // Adding the same track again does not duplicate it.
    await store.addTrack('work', 'a2');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds, [
      'a2',
    ]);

    await store.addTrack('work', 'a1');
    expect(
      model.playlists.singleWhere((pl) => pl.name == 'work').trackIds,
      ['a2', 'a1'],
      reason: 'append order preserved',
    );

    await store.removeTrack('work', 'a2');
    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds, [
      'a1',
    ]);
    expect(_onDisk(home, id)?.trackIds, ['a1']);
  });

  test('addTracks / removeTracks (batch, used by the track list\'s '
      'multi-select context menu) round-trip on model and disk and report '
      'accurate added/removed counts', () async {
    await store.createPlaylist('batch');
    final id = model.playlists.singleWhere((pl) => pl.name == 'batch').id!;

    final added = await store.addTracks('batch', ['a1', 'a2']);
    expect(added, 2);
    expect(model.playlists.singleWhere((pl) => pl.name == 'batch').trackIds, [
      'a1',
      'a2',
    ]);
    expect(_onDisk(home, id)?.trackIds, ['a1', 'a2']);

    // Re-adding the same ids duplicates nothing -- reported count is 0.
    final addedAgain = await store.addTracks('batch', ['a1', 'a2']);
    expect(
      addedAgain,
      0,
      reason: 'both already present -- not counted as newly added',
    );
    expect(model.playlists.singleWhere((pl) => pl.name == 'batch').trackIds, [
      'a1',
      'a2',
    ]);

    final removed = await store.removeTracks('batch', ['a1', 'a2']);
    expect(removed, 2);
    expect(
      model.playlists.singleWhere((pl) => pl.name == 'batch').trackIds,
      isEmpty,
    );
    expect(_onDisk(home, id)?.trackIds, isEmpty);
  });

  test('addTracks / removeTracks no-op (no disk write, no throw) on an '
      'empty id list', () async {
    await store.createPlaylist('empty-batch');
    final id = model.playlists
        .singleWhere((pl) => pl.name == 'empty-batch')
        .id!;
    final before = _onDisk(home, id)!.modified;

    expect(await store.addTracks('empty-batch', []), 0);
    expect(await store.removeTracks('empty-batch', []), 0);

    expect(
      _onDisk(home, id)!.modified,
      before,
      reason: 'nothing written for a no-op batch',
    );
  });

  test('deletePlaylist removes the entry from model and disk, and clears '
      'activePlaylist when the deleted playlist was the active one', () async {
    await store.createPlaylist('doomed');
    final id = model.playlists.singleWhere((pl) => pl.name == 'doomed').id!;
    model.setPlaylist('doomed');
    expect(model.activePlaylist, 'doomed');

    await store.deletePlaylist('doomed');

    expect(model.playlists.map((pl) => pl.name), isNot(contains('doomed')));
    expect(_onDisk(home, id), isNull);
    expect(
      model.activePlaylist,
      isNull,
      reason: 'deleting the active playlist falls back to Library view',
    );
  });

  test('unique-name validation: rejects an existing name, a merge-suffixed '
      'display name, and a blank name -- without writing anything', () async {
    final beforeMix = _onDisk(home, 'p_mix');

    expect(
      () => store.createPlaylist('mix'),
      throwsA(isA<PlaylistStoreException>()),
    );
    expect(
      () => store.createPlaylist('   '),
      throwsA(isA<PlaylistStoreException>()),
    );

    // A merge-suffixed display name ("mix (2)") only exists once two
    // same-named playlists collide -- seed that collision, then confirm
    // creating the suffixed form itself is refused too, since it would
    // collide with that display name on the next merge.
    await _seedPlaylist(
      home,
      id: 'p_mix2',
      name: 'mix',
      trackIds: const [],
      created: DateTime.utc(2024, 1, 3),
    );
    model.reloadPlaylists();
    expect(model.playlists.map((p) => p.name), contains('mix (2)'));
    expect(
      () => store.createPlaylist('mix (2)'),
      throwsA(isA<PlaylistStoreException>()),
    );

    expect(_onDisk(home, 'p_mix')?.name, beforeMix?.name);
    expect(_onDisk(home, 'p_mix')?.trackIds, beforeMix?.trackIds);
  });

  test('mutating a nonexistent playlist throws', () async {
    expect(
      () => store.addTrack('nope', 'a1'),
      throwsA(isA<PlaylistStoreException>()),
    );
    expect(
      () => store.deletePlaylist('nope'),
      throwsA(isA<PlaylistStoreException>()),
    );
  });

  test('store on a model with no libraryHome throws, not crashes', () async {
    final empty = LibraryModel();
    final s = PlaylistStore(library: empty, device: 'desktop');
    await expectLater(
      s.createPlaylist('x'),
      throwsA(
        isA<PlaylistStoreException>().having(
          (e) => e.message,
          'message',
          contains('No library home'),
        ),
      ),
    );
  });

  test('reloadPlaylists picks up an external sidecar edit without touching '
      'allTracks, and re-applies the merge suffix convention', () async {
    final tracksBefore = model.allTracks;
    await _seedPlaylist(
      home,
      id: 'p_extra',
      name: 'extra',
      trackIds: const [],
      created: DateTime.utc(2024, 1, 4),
    );
    await core.savePlaylistFile(
      home,
      core.PlaylistFile(
        id: 'p_mix',
        name: 'mix',
        trackIds: ['a1', 'a2'],
        created: DateTime.utc(2024, 1, 1),
        modified: DateTime.utc(2024, 6, 1),
        modifiedBy: 'external',
      ),
    );

    model.reloadPlaylists();

    expect(
      model.playlists.map((pl) => pl.name),
      containsAll(['mix', 'extra', 'unique']),
    );
    expect(model.playlists.firstWhere((pl) => pl.name == 'mix').trackIds, [
      'a1',
      'a2',
    ]);
    expect(
      identical(model.allTracks, tracksBefore),
      isTrue,
      reason: 'playlist-only refresh must not reload the track list',
    );
  });
}
