// Last modified: 2026-08-04--1844
import 'dart:convert';
import 'dart:io';
import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

Manifest mf(Map<String, List<String>> idToPaths) => Manifest(
    schema: 1,
    tracks: idToPaths.map((id, paths) => MapEntry(
        id, TrackEntry(dateAdded: '2026-01-01T00:00:00Z', paths: paths))),
    playlists: []);
RemoteFile rf(String rel, {int size = 100, int mtime = 1000}) =>
    RemoteFile(relPath: rel, size: size, mtimeMs: mtime);

void main() {
  group('planRootSync', () {
    test('new remote file is a copy', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3')],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.deletes, isEmpty);
    });

    test('retag with unchanged size still recopies (mtime moved)', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3', size: 100, mtime: 2000)],
        localManifest: mf({'idA': ['a.mp3']}),
        localFiles: {'a.mp3'},
        state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.recopies.map((f) => f.relPath), ['a.mp3']);
    });

    test('changed size, unchanged mtime also recopies', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3', size: 200, mtime: 1000)],
        localManifest: mf({'idA': ['a.mp3']}),
        localFiles: {'a.mp3'},
        state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.recopies.map((f) => f.relPath), ['a.mp3']);
    });

    test('matching state entry (same mtime+size) is a no-op', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3', size: 100, mtime: 1000)],
        localManifest: mf({'idA': ['a.mp3']}),
        localFiles: {'a.mp3'},
        state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.copies, isEmpty);
      expect(plan.recopies, isEmpty);
      expect(plan.adoptions, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('hand-seeded file with matching IDs is adopted, not copied', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3')],
        localManifest: mf({'idA': ['a.mp3']}),
        localFiles: {'a.mp3'},
        state: SyncState({}),
      );
      expect(plan.adoptions, ['a.mp3']);
      expect(plan.copies, isEmpty);
      expect(plan.recopies, isEmpty);
    });

    test('same path, no state entry, but local manifest has a different '
        'content ID for it -> recopy, not adoption', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3')],
        localManifest: mf({'idB': ['a.mp3']}),
        localFiles: {'a.mp3'},
        state: SyncState({}),
      );
      expect(plan.recopies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.adoptions, isEmpty);
    });

    test('same path, no state entry, local manifest does not know the path '
        'at all -> recopy (unknown, not adoption)', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3')],
        localManifest: mf({}),
        localFiles: {'a.mp3'},
        state: SyncState({}),
      );
      expect(plan.recopies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.adoptions, isEmpty);
    });

    test('moved on NAS becomes a local rename, not copy+delete', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['new/a.mp3']}),
        remoteListing: [rf('new/a.mp3')],
        localManifest: mf({'idA': ['old/a.mp3']}),
        localFiles: {'old/a.mp3'},
        state: SyncState({'old/a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.renames, {'old/a.mp3': 'new/a.mp3'});
      expect(plan.copies, isEmpty);
      expect(plan.deletes, isEmpty);
    });

    test('a shared rename source is claimed by only one of two duplicate '
        'remote targets; the other falls through to a copy, never dropped', () {
      final plan = planRootSync(
        remoteManifest: mf({'idX': ['new/a.mp3', 'new/a_dup.mp3']}),
        remoteListing: [rf('new/a.mp3'), rf('new/a_dup.mp3')],
        localManifest: mf({'idX': ['old/a.mp3']}),
        localFiles: {'old/a.mp3'},
        state: SyncState({'old/a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      // Exactly one rename, keyed off the sole local source.
      expect(plan.renames.length, 1);
      expect(plan.renames.keys, ['old/a.mp3']);
      // Exactly one copy, for whichever remote path didn't win the rename.
      expect(plan.copies.length, 1);
      // Together, the rename's target and the copy's path cover both remote
      // paths -- neither one silently vanished from the plan.
      final covered = {...plan.renames.values, ...plan.copies.map((f) => f.relPath)};
      expect(covered, {'new/a.mp3', 'new/a_dup.mp3'});
      expect(plan.deletes, isEmpty);
    });

    test('three-way duplicate: one rename source, three remote targets '
        '-> one rename + two copies, all three remote paths covered', () {
      final plan = planRootSync(
        remoteManifest: mf({
          'idX': ['new/a.mp3', 'new/a_dup1.mp3', 'new/a_dup2.mp3']
        }),
        remoteListing: [
          rf('new/a.mp3'),
          rf('new/a_dup1.mp3'),
          rf('new/a_dup2.mp3'),
        ],
        localManifest: mf({'idX': ['old/a.mp3']}),
        localFiles: {'old/a.mp3'},
        state: SyncState({'old/a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.renames.length, 1);
      expect(plan.renames.keys, ['old/a.mp3']);
      expect(plan.copies.length, 2);
      final covered = {...plan.renames.values, ...plan.copies.map((f) => f.relPath)};
      expect(covered, {'new/a.mp3', 'new/a_dup1.mp3', 'new/a_dup2.mp3'});
      expect(plan.deletes, isEmpty);
    });

    test('gone from NAS is a local delete; unindexed local is spared', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [],
        localManifest: mf({'idA': ['a.mp3']}),
        localFiles: {'a.mp3', 'stray.mp3'},
        state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.deletes, ['a.mp3']);
      expect(plan.unindexedLocal, ['stray.mp3']);
    });

    test('a duplicate-content local path whose ID still has a remote home '
        'elsewhere is neither deleted nor renamed', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['dup1.mp3']}),
        remoteListing: [rf('dup1.mp3', size: 100, mtime: 1000)],
        localManifest: mf({'idA': ['dup1.mp3', 'dup2.mp3']}),
        localFiles: {'dup1.mp3', 'dup2.mp3'},
        state: SyncState(
            {'dup1.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
      );
      expect(plan.deletes, isEmpty);
      expect(plan.renames, isEmpty);
      expect(plan.unindexedLocal, isEmpty);
      expect(plan.copies, isEmpty);
      expect(plan.recopies, isEmpty);
    });

    test('remote-listed-but-unindexed remote file is skipped, not copied', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [rf('b.mp3')],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies, isEmpty);
      expect(plan.recopies, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('.hash_cache.json in the listing is ignored', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3'), rf(hashCacheName)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.sidecarCopies, isEmpty);
    });

    test('.library.json, .library.json.bak, .sync_state.json in the '
        'listing are all ignored', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [
          rf('a.mp3'),
          rf(manifestFileName),
          rf(manifestBakName),
          rf(syncStateFileName),
        ],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.sidecarCopies, isEmpty);
    });

    test('files under .sync_tmp/ and .playlists/ in the listing are ignored', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [
          rf('a.mp3'),
          rf('$syncTmpDirName/partial.mp3'),
          rf('$playlistsDirName/roadtrip.json'),
        ],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.recopies, isEmpty);
      expect(plan.sidecarCopies, isEmpty);
    });

    test('sidecar copy on new/changed .artwork.json; unchanged one is left '
        'alone', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [rf('.artwork.json', size: 500, mtime: 3000)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.sidecarCopies.map((f) => f.relPath), ['.artwork.json']);

      final unchanged = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [rf('.artwork.json', size: 500, mtime: 3000)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState(
            {'.artwork.json': SyncStateEntry(mtimeMs: 3000, size: 500)}),
      );
      expect(unchanged.sidecarCopies, isEmpty);
      expect(unchanged.isEmpty, isTrue);
    });

    test('folder images (folder/cover/front x jpg/jpeg/png) sync like '
        'sidecars, case-insensitively; other images are ignored', () {
      // Reported live: albums whose desktop art came from a cover.jpg
      // showed no art on the phone -- images were never copied at all.
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['Album/a.mp3']}),
        remoteListing: [
          rf('Album/a.mp3'),
          rf('Album/cover.jpg', size: 200),
          rf('Album/Folder.PNG', size: 300), // case variant still matches
          rf('Album/front.jpeg', size: 400),
          rf('Album/scan001.jpg', size: 999), // booklet scan: not artwork
          rf('Album/back.png', size: 999), // not a resolver name
        ],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['Album/a.mp3']);
      expect(
        plan.sidecarCopies.map((f) => f.relPath).toSet(),
        {'Album/cover.jpg', 'Album/Folder.PNG', 'Album/front.jpeg'},
      );

      // A synced-state match skips the recopy, same as .artwork.json.
      final unchanged = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [rf('Album/cover.jpg', size: 200)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState(
            {'Album/cover.jpg': SyncStateEntry(mtimeMs: 1000, size: 200)}),
      );
      expect(unchanged.sidecarCopies, isEmpty);
    });

    test('a file that is neither audio, sidecar, nor excluded is ignored '
        'entirely', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3']}),
        remoteListing: [rf('a.mp3'), rf('readme.txt', size: 999)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.sidecarCopies, isEmpty);
      expect(plan.totalBytes, 100); // readme.txt's 999 bytes never counted
    });

    test('audio extension matching is case-insensitive', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['A.MP3']}),
        remoteListing: [rf('A.MP3')],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.copies.map((f) => f.relPath), ['A.MP3']);
    });

    test('sidecar copy on a changed file under .artwork/', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [rf('.artwork/ab/cd1234.jpg', size: 900, mtime: 4000)],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({
          '.artwork/ab/cd1234.jpg': SyncStateEntry(mtimeMs: 1, size: 1),
        }),
      );
      expect(plan.sidecarCopies.map((f) => f.relPath),
          ['.artwork/ab/cd1234.jpg']);
    });

    test('empty everything -> isEmpty', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [],
        localManifest: mf({}),
        localFiles: {},
        state: SyncState({}),
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.totalBytes, 0);
    });

    test('isEmpty ignores unindexedLocal: a plan with only unindexed '
        'local files reports isEmpty true', () {
      final plan = planRootSync(
        remoteManifest: mf({}),
        remoteListing: [],
        localManifest: mf({}),
        localFiles: {'stray.mp3'},
        state: SyncState({}),
      );
      expect(plan.unindexedLocal, ['stray.mp3']);
      expect(plan.copies, isEmpty);
      expect(plan.deletes, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('totalBytes sums copies + recopies + sidecarCopies, not '
        'unindexedLocal/deletes/renames/adoptions', () {
      final plan = planRootSync(
        remoteManifest: mf({'idA': ['a.mp3'], 'idB': ['b.mp3']}),
        remoteListing: [
          rf('a.mp3', size: 111, mtime: 1000), // copy
          rf('b.mp3', size: 222, mtime: 5000), // recopy
          rf('.artwork.json', size: 333, mtime: 9000), // sidecar copy
        ],
        localManifest: mf({'idB': ['b.mp3']}),
        localFiles: {'b.mp3', 'stray.mp3'},
        state: SyncState({
          'b.mp3': SyncStateEntry(mtimeMs: 1, size: 222), // mtime differs
        }),
      );
      expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
      expect(plan.recopies.map((f) => f.relPath), ['b.mp3']);
      expect(plan.sidecarCopies.map((f) => f.relPath), ['.artwork.json']);
      expect(plan.unindexedLocal, ['stray.mp3']);
      expect(plan.totalBytes, 111 + 222 + 333);
    });
  });

  group('SyncState', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('syncst'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save then load round-trips entries', () async {
      final state = SyncState({
        'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100),
        '.artwork.json': SyncStateEntry(mtimeMs: 2000, size: 50),
      });
      final f = File('${dir.path}/$syncStateFileName');
      await state.save(f);

      final loaded = SyncState.load(f);
      expect(loaded.entries.keys, unorderedEquals(['a.mp3', '.artwork.json']));
      expect(loaded.entries['a.mp3']!.mtimeMs, 1000);
      expect(loaded.entries['a.mp3']!.size, 100);
      expect(loaded.entries['.artwork.json']!.mtimeMs, 2000);
      expect(loaded.entries['.artwork.json']!.size, 50);
    });

    test('load on a missing file returns empty state, not an error', () {
      final loaded = SyncState.load(File('${dir.path}/$syncStateFileName'));
      expect(loaded.entries, isEmpty);
    });

    test('load on a corrupt file returns empty state, not an error', () {
      final f = File('${dir.path}/$syncStateFileName');
      f.writeAsStringSync('{not json');
      final loaded = SyncState.load(f);
      expect(loaded.entries, isEmpty);
    });

    test('load on valid JSON with the wrong shape returns empty state', () {
      final f = File('${dir.path}/$syncStateFileName');
      f.writeAsStringSync('{"schema": 1, "entries": "nope"}');
      final loaded = SyncState.load(f);
      expect(loaded.entries, isEmpty);
    });

    test('a malformed individual entry is dropped; well-formed siblings '
        'still load (per-entry tolerance, not whole-file)', () {
      final f = File('${dir.path}/$syncStateFileName');
      f.writeAsStringSync(jsonEncode({
        'schema': 1,
        'entries': {
          'good.mp3': {'mtimeMs': 1000, 'size': 100},
          'bad_shape.mp3': {'mtimeMs': 'not a number', 'size': 100},
          'bad_type.mp3': 'not even a map',
          'also_good.mp3': {'mtimeMs': 2000, 'size': 200},
        },
      }));
      final loaded = SyncState.load(f);
      expect(loaded.entries.keys, unorderedEquals(['good.mp3', 'also_good.mp3']));
      expect(loaded.entries['good.mp3']!.mtimeMs, 1000);
      expect(loaded.entries['also_good.mp3']!.size, 200);
    });

    test('save is atomic: no .tmp file left behind, second save replaces', () async {
      final f = File('${dir.path}/$syncStateFileName');
      await SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1, size: 1)}).save(f);
      await SyncState({'b.mp3': SyncStateEntry(mtimeMs: 2, size: 2)}).save(f);
      expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
      final loaded = SyncState.load(f);
      expect(loaded.entries.keys, ['b.mp3']);
    });
  });
}
