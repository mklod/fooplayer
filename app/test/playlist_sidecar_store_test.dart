// PlaylistStore over the shared `.playlists/` sidecar (Plan 3 Task 5): the
// new-behavior coverage for the CRUD rewrite -- what changed from the old
// per-root-manifest design. UI-facing CRUD semantics (append order,
// dedupe-on-add, batch counts, name validation, ...) are unchanged and
// still covered by playlist_store_test.dart; this file pins the sidecar
// specifics: real files with the right shape, delete leaves a backup +
// tombstone, every mutation calls onMutated, a null libraryHome refuses
// clearly, and a mutation always reloads fresh so an external edit is never
// clobbered.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

/// A [LibraryModel] whose [LibraryModel.libraryHome] is [home] -- routed
/// through the real [LibraryModel.load] (not a private shortcut) with no
/// library roots, so `_sidecarPlaylists` still runs for real against
/// [home] but there is no track/manifest work to wait on.
Future<LibraryModel> _modelWithHome(Directory home) async {
  final model = LibraryModel();
  await model
      .load(
        libraryRoots: const [],
        cacheFile: File('${home.path}/meta_cache.json'),
        libraryHome: home.path,
      )
      .timeout(const Duration(seconds: 10));
  return model;
}

void main() {
  late Directory tmp;
  late Directory home;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plsidecar');
    home = await Directory('${tmp.path}/home').create();
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('createPlaylist writes a sidecar file with id/created/modified/'
      'modifiedBy, and the model sees it via reloadPlaylists', () async {
    final model = await _modelWithHome(home);
    final store = PlaylistStore(library: model, device: 'desktop');

    await store.createPlaylist('roadtrip');

    final entry = model.playlists.singleWhere((pl) => pl.name == 'roadtrip');
    expect(entry.id, isNotNull);

    final file = File('${home.path}/.playlists/${entry.id}.json');
    expect(file.existsSync(), isTrue);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(json['id'], entry.id);
    expect(json['name'], 'roadtrip');
    expect(json['track_ids'], isEmpty);
    expect(json['created'], isA<String>());
    expect(json['modified'], isA<String>());
    expect(json['modified_by'], 'desktop');
  });

  test('deletePlaylist writes a backup file and a tombstone, and removes '
      'the playlist file itself', () async {
    final model = await _modelWithHome(home);
    final store = PlaylistStore(library: model, device: 'desktop');
    await store.createPlaylist('doomed');
    final id = model.playlists.single.id!;

    await store.deletePlaylist('doomed');

    expect(model.playlists, isEmpty);
    expect(File('${home.path}/.playlists/$id.json').existsSync(), isFalse);

    final backupDir = Directory('${home.path}/.playlists/backup');
    expect(backupDir.existsSync(), isTrue);
    final backups = backupDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains(id))
        .toList();
    expect(backups, hasLength(1));
    final backupJson =
        jsonDecode(backups.single.readAsStringSync()) as Map<String, dynamic>;
    expect(backupJson['name'], 'doomed');

    final tombstones = core.loadPlaylistsDir(home).tombstones;
    expect(tombstones[id]?.name, 'doomed');
  });

  test('addTracks bumps modified and preserves append order on disk', () async {
    final model = await _modelWithHome(home);
    final store = PlaylistStore(library: model, device: 'desktop');
    await store.createPlaylist('work');
    final id = model.playlists.single.id!;
    final beforeModified = core.loadPlaylistsDir(home).playlists[id]!.modified;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final added = await store.addTracks('work', ['t2', 't1']);

    expect(added, 2);
    final after = core.loadPlaylistsDir(home).playlists[id]!;
    expect(after.trackIds, ['t2', 't1'], reason: 'append order preserved');
    expect(
      after.modified.isAfter(beforeModified),
      isTrue,
      reason: 'modified must advance so LWW/sync can tell this changed',
    );
    expect(after.modifiedBy, 'desktop');
  });

  test('a successful mutation calls onMutated -- create, add, remove, and '
      'delete each count as one', () async {
    var mutated = 0;
    final model = await _modelWithHome(home);
    final store = PlaylistStore(
      library: model,
      device: 'desktop',
      onMutated: () => mutated++,
    );

    await store.createPlaylist('x');
    expect(mutated, 1);
    await store.addTrack('x', 't1');
    expect(mutated, 2);
    await store.removeTrack('x', 't1');
    expect(mutated, 3);
    await store.deletePlaylist('x');
    expect(mutated, 4);
  });

  test('addTracks/removeTracks on an empty id list does not call onMutated '
      '(no-op, matching the pre-sidecar contract)', () async {
    var mutated = 0;
    final model = await _modelWithHome(home);
    final store = PlaylistStore(
      library: model,
      device: 'desktop',
      onMutated: () => mutated++,
    );
    await store.createPlaylist('x');
    expect(mutated, 1);

    expect(await store.addTracks('x', []), 0);
    expect(await store.removeTracks('x', []), 0);
    expect(mutated, 1, reason: 'no write happened, so no mutation signal');
  });

  test('no library home throws a clear, distinct message instead of the '
      'old "no library roots configured" one', () async {
    final model = LibraryModel(); // never loaded -- libraryHome stays null
    final store = PlaylistStore(library: model, device: 'desktop');

    await expectLater(
      store.createPlaylist('x'),
      throwsA(
        isA<PlaylistStoreException>().having(
          (e) => e.message,
          'message',
          contains('No library home for playlists'),
        ),
      ),
    );
  });

  test('every mutation re-loads fresh, so an edit written to disk between '
      'the last reload and the next mutation is picked up, not clobbered', () async {
    final model = await _modelWithHome(home);
    final store = PlaylistStore(library: model, device: 'desktop');
    await store.createPlaylist('shared');
    final id = model.playlists.single.id!;

    // Simulate another device's sync writing this exact playlist file
    // directly -- after our last reloadPlaylists(), before our next
    // mutation -- the way a real external edit would land.
    final external = core.PlaylistFile(
      id: id,
      name: 'shared',
      trackIds: ['external-track'],
      created: DateTime.now().toUtc(),
      modified: DateTime.now().toUtc(),
      modifiedBy: 'tablet',
    );
    await core.savePlaylistFile(home, external);

    await store.addTrack('shared', 'local-track');

    final after = core.loadPlaylistsDir(home).playlists[id]!;
    expect(
      after.trackIds,
      ['external-track', 'local-track'],
      reason:
          'the external edit survived because the mutation reloaded the '
          'file fresh from disk instead of mutating a stale in-memory copy',
    );
  });
}
