// PlaylistStore CRUD (TODO #29; owning-root routing fixed post-report --
// see the "owning root" group below): every mutation loads the relevant
// root's .library.json fresh, mutates only its playlists section, saves via
// fooplayer_core's atomic saveManifest (.bak of the previous version), and
// refreshes LibraryModel's merged playlist state via reloadPlaylists -- no
// full library reload. [createPlaylist] always targets the FIRST root (a
// new playlist has no existing owner); every other mutation routes to
// whichever root the merge stamped the playlist as living in
// (ManifestPlaylist.rootPath), so a playlist that lives in the second (or
// third, ...) configured root is exactly as editable as one in the first.
// The store also respects LibraryModel's busy discipline (brief retry
// against a rescan-held flag).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/playlist_store.dart';

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
    await _writeManifest(
      rootA,
      tracks: {
        'a1': _trackJson('a1.mp3', '2024-01-01T00:00:00Z'),
        'a2': _trackJson('a2.mp3', '2024-01-02T00:00:00Z'),
      },
      playlists: [
        {
          'name': 'mix',
          'track_ids': ['a1'],
        },
      ],
    );
    await _writeManifest(
      rootB,
      tracks: {'b1': _trackJson('b1.mp3', '2024-01-03T00:00:00Z')},
      playlists: [
        {
          'name': 'mix',
          'track_ids': ['b1'],
        }, // merges as "mix (2)"
        {
          'name': 'unique',
          'track_ids': ['b1'],
        },
      ],
    );
    model = LibraryModel();
    await model
        .load(
          libraryRoots: [rootA, rootB],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));
    expect(model.status, 'ready');
    store = PlaylistStore(
      library: model,
      busyRetryEvery: const Duration(milliseconds: 20),
      busyRetryFor: const Duration(seconds: 2),
    );
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('createPlaylist round-trips: visible after reloadPlaylists, present '
      'in the first root\'s on-disk manifest, previous version preserved '
      'as .bak', () async {
    await store.createPlaylist('fresh');

    // Model refreshed via reloadPlaylists (no full reload needed).
    final created = model.playlists.singleWhere((pl) => pl.name == 'fresh');
    expect(created.trackIds, isEmpty);
    expect(created.rootPath, rootA.path, reason: 'created in the first root');

    // On disk: rootA's manifest gained the entry, rootB's untouched.
    expect(
      _diskPlaylists(rootA).map((p) => p['name']),
      containsAll(['mix', 'fresh']),
    );
    expect(
      _diskPlaylists(rootB).map((p) => p['name']),
      unorderedEquals(['mix', 'unique']),
    );

    // Atomic-save side effect: .bak holds the pre-op manifest.
    final bak = File('${rootA.path}/.library.json.bak');
    expect(bak.existsSync(), isTrue);
    final bakPlaylists =
        ((jsonDecode(bak.readAsStringSync())
                    as Map<String, dynamic>)['playlists']
                as List)
            .cast<Map<String, dynamic>>();
    expect(bakPlaylists.map((p) => p['name']), isNot(contains('fresh')));
  });

  test('addTrack / removeTrack round-trip on model and disk', () async {
    await store.createPlaylist('work');
    await store.addTrack('work', 'a2');

    expect(model.playlists.singleWhere((pl) => pl.name == 'work').trackIds, [
      'a2',
    ]);
    expect(
      _diskPlaylists(
        rootA,
      ).singleWhere((p) => p['name'] == 'work')['track_ids'],
      ['a2'],
    );

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
    expect(
      _diskPlaylists(
        rootA,
      ).singleWhere((p) => p['name'] == 'work')['track_ids'],
      ['a1'],
    );
  });

  test('addTracks / removeTracks (batch, used by the track list\'s '
      'multi-select context menu) round-trip on model and disk and report '
      'accurate added/removed counts', () async {
    await store.createPlaylist('batch');

    final added = await store.addTracks('batch', ['a1', 'a2']);
    expect(added, 2);
    expect(model.playlists.singleWhere((pl) => pl.name == 'batch').trackIds, [
      'a1',
      'a2',
    ]);
    expect(
      _diskPlaylists(
        rootA,
      ).singleWhere((p) => p['name'] == 'batch')['track_ids'],
      ['a1', 'a2'],
    );

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
    expect(
      _diskPlaylists(
        rootA,
      ).singleWhere((p) => p['name'] == 'batch')['track_ids'],
      isEmpty,
    );
  });

  test(
    'addTracks / removeTracks no-op (no manifest write, no throw) on an empty id list',
    () async {
      await store.createPlaylist('empty-batch');
      final before = _readManifest(rootA);

      expect(await store.addTracks('empty-batch', []), 0);
      expect(await store.removeTracks('empty-batch', []), 0);

      expect(
        _readManifest(rootA),
        before,
        reason: 'nothing written for a no-op batch',
      );
    },
  );

  test('deletePlaylist removes the entry from model and disk, and clears '
      'activePlaylist when the deleted playlist was the active one', () async {
    await store.createPlaylist('doomed');
    model.setPlaylist('doomed');
    expect(model.activePlaylist, 'doomed');

    await store.deletePlaylist('doomed');

    expect(model.playlists.map((pl) => pl.name), isNot(contains('doomed')));
    expect(
      _diskPlaylists(rootA).map((p) => p['name']),
      isNot(contains('doomed')),
    );
    expect(
      model.activePlaylist,
      isNull,
      reason: 'deleting the active playlist falls back to Library view',
    );
  });

  test('unique-name validation: rejects an existing name, a merge-suffixed '
      'display name, and a blank name -- without writing anything', () async {
    final before = _readManifest(rootA);

    expect(
      () => store.createPlaylist('mix'),
      throwsA(isA<PlaylistStoreException>()),
    );
    // "mix (2)" only exists as LibraryModel's merge suffix for rootB's
    // "mix" -- creating it for real would collide with that display name.
    expect(
      () => store.createPlaylist('mix (2)'),
      throwsA(isA<PlaylistStoreException>()),
    );
    expect(
      () => store.createPlaylist('   '),
      throwsA(isA<PlaylistStoreException>()),
    );

    expect(_readManifest(rootA), before, reason: 'nothing written on refusal');
  });

  group('owning-root routing -- the reported bug: a playlist NOT in the '
      'first root must still be editable, by writing THAT root\'s '
      'manifest rather than refusing', () {
    test('addTracks batch-adds to a playlist owned by the SECOND root, '
        'writing ONLY rootB\'s manifest in one write (rootA untouched, '
        '.bak preserved)', () async {
      final beforeA = _readManifest(rootA);
      expect(
        File('${rootB.path}/.library.json.bak').existsSync(),
        isFalse,
        reason: 'sanity: no prior write to rootB yet',
      );

      final added = await store.addTracks('unique', ['a1', 'a2']);

      expect(added, 2);
      expect(
        model.playlists.singleWhere((pl) => pl.name == 'unique').trackIds,
        ['b1', 'a1', 'a2'],
      );
      expect(
        _diskPlaylists(
          rootB,
        ).singleWhere((p) => p['name'] == 'unique')['track_ids'],
        ['b1', 'a1', 'a2'],
        reason: 'written to the OWNING root (rootB), not the first (rootA)',
      );
      expect(
        _readManifest(rootA),
        beforeA,
        reason: 'a playlist owned by rootB must not touch rootA at all',
      );
      expect(
        File('${rootB.path}/.library.json.bak').existsSync(),
        isTrue,
        reason: 'atomic save still produces a .bak, on the owning root',
      );
    });

    test('removeTracks batch-removes from a playlist owned by the SECOND '
        'root, writing ONLY rootB\'s manifest', () async {
      await store.addTracks('unique', ['a1', 'a2']); // seed 3 tracks total
      final beforeA = _readManifest(rootA);

      final removed = await store.removeTracks('unique', ['b1', 'a2']);

      expect(removed, 2);
      expect(
        model.playlists.singleWhere((pl) => pl.name == 'unique').trackIds,
        ['a1'],
      );
      expect(
        _diskPlaylists(
          rootB,
        ).singleWhere((p) => p['name'] == 'unique')['track_ids'],
        ['a1'],
      );
      expect(_readManifest(rootA), beforeA);
    });

    test('addTrack / removeTrack (single-track form) also route to the '
        'owning root, not the first', () async {
      final beforeA = _readManifest(rootA);

      await store.addTrack('unique', 'a2');
      expect(
        _diskPlaylists(
          rootB,
        ).singleWhere((p) => p['name'] == 'unique')['track_ids'],
        ['b1', 'a2'],
      );

      await store.removeTrack('unique', 'b1');
      expect(
        _diskPlaylists(
          rootB,
        ).singleWhere((p) => p['name'] == 'unique')['track_ids'],
        ['a2'],
      );

      expect(_readManifest(rootA), beforeA);
    });

    test('deletePlaylist removes a playlist owned by the SECOND root from '
        'rootB\'s manifest, leaving rootA untouched and rootB\'s OTHER '
        'playlist intact', () async {
      final beforeA = _readManifest(rootA);

      await store.deletePlaylist('unique');

      expect(model.playlists.map((pl) => pl.name), isNot(contains('unique')));
      expect(
        _diskPlaylists(rootB).map((p) => p['name']),
        isNot(contains('unique')),
      );
      expect(
        _diskPlaylists(rootB).map((p) => p['name']),
        contains('mix'),
        reason: 'rootB\'s other playlist (merged as "mix (2)") survives',
      );
      expect(_readManifest(rootA), beforeA);
    });

    test('deletePlaylist also resolves a merge-suffixed display name '
        '("mix (2)") back to its owning root correctly', () async {
      await store.deletePlaylist('mix (2)');

      expect(model.playlists.map((pl) => pl.name), isNot(contains('mix (2)')));
      // rootB's manifest-internal name is "mix" (unsuffixed) -- the suffix
      // is purely a merge-time display artifact.
      expect(
        _diskPlaylists(rootB).map((p) => p['name']),
        isNot(contains('mix')),
      );
      // rootA's own "mix" (unrelated playlist, same name) is untouched.
      expect(_diskPlaylists(rootA).map((p) => p['name']), contains('mix'));
    });

    test('createPlaylist still always targets the FIRST root, even though '
        'every other mutation now routes by ownership', () async {
      await store.createPlaylist('fresh2');

      expect(
        model.playlists.singleWhere((pl) => pl.name == 'fresh2').rootPath,
        rootA.path,
      );
      expect(_diskPlaylists(rootA).map((p) => p['name']), contains('fresh2'));
      expect(
        _diskPlaylists(rootB).map((p) => p['name']),
        isNot(contains('fresh2')),
      );
    });

    test('a playlist stamped with a root that is no longer configured '
        '(e.g. roots edited in Settings since the merge) is refused with '
        'a clear message instead of silently writing the wrong root', () async {
      final ghostRoot = '${tmp.path}/never-loaded';
      model.playlists = [
        ...model.playlists,
        ManifestPlaylist(
          name: 'ghost',
          trackIds: const ['a1'],
          rootPath: ghostRoot,
          sourceName: 'ghost',
          sourceIndex: 0,
        ),
      ];

      await expectLater(
        store.addTrack('ghost', 'a1'),
        throwsA(
          isA<PlaylistStoreException>().having(
            (e) => e.message,
            'message',
            contains(ghostRoot),
          ),
        ),
      );
    });
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

  test('busy discipline: a store write retries while the busy flag is held '
      'and succeeds once released; a hold outlasting the retry budget '
      'throws a clear busy error', () async {
    // Simulate a rescan holding the flag, released mid-retry.
    expect(model.tryBeginManifestWrite(), isTrue);
    final create = store.createPlaylist('patient');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      model.playlists.map((pl) => pl.name),
      isNot(contains('patient')),
      reason: 'must not write while the flag is held',
    );
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
        throwsA(
          isA<PlaylistStoreException>().having(
            (e) => e.message,
            'message',
            contains('busy'),
          ),
        ),
      );
    } finally {
      await model.endManifestWrite();
    }
  });

  test('store on a model with no roots loaded throws, not crashes', () async {
    final empty = LibraryModel();
    final s = PlaylistStore(library: empty);
    await expectLater(
      s.createPlaylist('x'),
      throwsA(isA<PlaylistStoreException>()),
    );
  });

  test('first root without a .library.json is refused (seed first) instead '
      'of fabricating an empty manifest', () async {
    final bare = await _root(tmp, 'bare');
    final m = LibraryModel();
    await m
        .load(
          libraryRoots: [bare, rootA],
          cacheFile: File('${tmp.path}/meta_cache2.json'),
        )
        .timeout(const Duration(seconds: 30));
    final s = PlaylistStore(library: m);
    await expectLater(
      s.createPlaylist('x'),
      throwsA(
        isA<PlaylistStoreException>().having(
          (e) => e.message,
          'message',
          contains('.library.json'),
        ),
      ),
    );
    expect(File('${bare.path}/.library.json').existsSync(), isFalse);
  });

  test('reloadPlaylists picks up an external manifest edit without touching '
      'allTracks, and re-applies the merge suffix convention', () async {
    final tracksBefore = model.allTracks;
    await _writeManifest(
      rootA,
      tracks: {
        'a1': _trackJson('a1.mp3', '2024-01-01T00:00:00Z'),
        'a2': _trackJson('a2.mp3', '2024-01-02T00:00:00Z'),
      },
      playlists: [
        {
          'name': 'mix',
          'track_ids': ['a1', 'a2'],
        },
        {'name': 'extra', 'track_ids': []},
      ],
    );

    model.reloadPlaylists();

    expect(
      model.playlists.map((pl) => pl.name),
      containsAll(['mix', 'extra', 'mix (2)', 'unique']),
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

  group('busy scope: enrichment must not block playlist writes', () {
    // The regression this group exists for: playlist mutations used to gate
    // on LibraryModel.busy, which stays set for the whole of load() --
    // including Part B's background tag enrichment. On a real 5k-track SMB
    // library that phase runs for minutes, so "add to playlist" was refused
    // for effectively the entire session, and because the refusal only
    // surfaced after PlaylistStore's retry deadline it looked like a silent
    // no-op. Enrichment writes only the AppData meta cache, so the lock is
    // now scoped to phases that actually touch a .library.json.
    test(
      'a write lands while a load is still enriching in the background',
      () async {
        // Enough phantom tracks (files that don't exist -> fast per-file
        // misses, but many isolate batches) that Part B is reliably still
        // running when the write below is attempted.
        final busyRoot = await _root(tmp, 'busyRoot');
        await _writeManifest(
          busyRoot,
          tracks: {
            for (var i = 0; i < 3000; i++)
              'p$i': _trackJson('p$i.mp3', '2024-02-01T00:00:00Z'),
          },
          playlists: [
            {'name': 'target', 'track_ids': <String>[]},
          ],
        );
        final freshModel = LibraryModel();
        // Impatient on purpose: the point is that the write goes through
        // WITHOUT waiting out enrichment. A generous retry window would hide
        // the bug here exactly as it hid it in the app -- there enrichment
        // outlasts any sane window, so the wait only ended in a refusal.
        final freshStore = PlaylistStore(
          library: freshModel,
          busyRetryEvery: const Duration(milliseconds: 10),
          busyRetryFor: const Duration(milliseconds: 150),
        );

        final loading = freshModel.load(
          libraryRoots: [busyRoot],
          cacheFile: File('${tmp.path}/busy_cache.json'),
        );
        // Wait for Part A to publish the instant feed and hand off to Part B.
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!freshModel.status.startsWith('ready (reading tags') &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(freshModel.status, startsWith('ready (reading tags'));
        expect(
          freshModel.busy,
          isTrue,
          reason:
              'enrichment is in flight -- the exact window that used to '
              'refuse every playlist write',
        );

        await freshStore.addTrack('target', 'p7');

        expect(
          freshModel.busy,
          isTrue,
          reason:
              'the write must have landed DURING enrichment, not after '
              'it quietly finished',
        );

        expect(
          _diskPlaylists(
            busyRoot,
          ).singleWhere((pl) => pl['name'] == 'target')['track_ids'],
          ['p7'],
        );
        await loading.timeout(const Duration(seconds: 60));
      },
    );

    test(
      'a write still waits for a phase that really touches the manifest',
      () async {
        // The other half of the contract: narrowing the lock must not remove
        // it. A held manifest phase (what rescan's scan/stamp/save takes) is
        // still refused, with the message the UI surfaces.
        expect(model.tryBeginManifestWrite(), isTrue);
        final impatient = PlaylistStore(
          library: model,
          busyRetryEvery: const Duration(milliseconds: 10),
          busyRetryFor: const Duration(milliseconds: 80),
        );
        await expectLater(
          impatient.addTrack('mix', 'a2'),
          throwsA(
            isA<PlaylistStoreException>().having(
              (e) => e.message,
              'message',
              contains('busy'),
            ),
          ),
        );
        await model.endManifestWrite();
        // ...and once released, the very same write goes through.
        await store.addTrack('mix', 'a2');
        expect(
          _diskPlaylists(
            rootA,
          ).singleWhere((pl) => pl['name'] == 'mix')['track_ids'],
          ['a1', 'a2'],
        );
      },
    );
  });
}
