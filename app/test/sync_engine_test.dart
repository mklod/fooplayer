// Last modified: 2026-07-31--1811
//
// SyncEngine integration tests: two real temp directories ("NAS" and
// "phone"), a real LocalDirTransport between them, and real small files
// with REAL content IDs (written as bytes, hashed with
// core.contentIdForFile when building the NAS manifest) -- so hash
// verification in these tests is honest, not stubbed. All fixture audio
// files use the `.wav` extension deliberately: it's the one audioExtensions
// entry that hits `audioRangeFor`'s default (whole-file) branch, so tiny
// synthetic byte content never runs into real MP3/FLAC frame parsing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/sync/playlist_reconciler.dart';
import 'package:fooplayer_app/sync/sync_engine.dart';
import 'package:fooplayer_app/sync/sync_settings.dart';
import 'package:fooplayer_app/sync/sync_transport.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

/// Delegates every call to [inner], counting downloads and optionally
/// notifying a callback after each one completes -- the seam the "no
/// re-download on rename" and "cancel mid-root" tests need.
class _CountingTransport implements SyncTransport {
  final SyncTransport inner;
  final void Function(String relPath)? onDownload;
  int downloadCalls = 0;
  final List<String> downloadedPaths = [];

  _CountingTransport(this.inner, {this.onDownload});

  @override
  Future<bool> probe() => inner.probe();
  @override
  Future<List<core.RemoteFile>> listTree(String relDir) => inner.listTree(relDir);
  @override
  Future<List<int>?> readFile(String relPath) => inner.readFile(relPath);
  @override
  Future<void> writeFile(String relPath, List<int> bytes) =>
      inner.writeFile(relPath, bytes);
  @override
  Future<void> downloadToFile(
    String relPath,
    File local, {
    void Function(int got, int total)? onProgress,
  }) async {
    await inner.downloadToFile(relPath, local, onProgress: onProgress);
    downloadCalls++;
    downloadedPaths.add(relPath);
    onDownload?.call(relPath);
  }

  @override
  Future<void> deleteRemote(String relPath) => inner.deleteRemote(relPath);
  @override
  Future<void> close() => inner.close();
}

/// Delegates every call to [inner], except `downloadToFile`: any relPath
/// [shouldFail] accepts throws instead of downloading -- deterministically,
/// on every attempt (including the engine's own one retry). Content-based
/// rather than count-based on purpose: directory listing order isn't
/// guaranteed, so a fake keyed on "fail after N calls" would make the
/// "3 consecutive failures" test depend on filesystem iteration order.
class _FailingTransport implements SyncTransport {
  final SyncTransport inner;
  final bool Function(String relPath) shouldFail;

  _FailingTransport(this.inner, this.shouldFail);

  @override
  Future<bool> probe() => inner.probe();
  @override
  Future<List<core.RemoteFile>> listTree(String relDir) => inner.listTree(relDir);
  @override
  Future<List<int>?> readFile(String relPath) => inner.readFile(relPath);
  @override
  Future<void> writeFile(String relPath, List<int> bytes) =>
      inner.writeFile(relPath, bytes);
  @override
  Future<void> downloadToFile(
    String relPath,
    File local, {
    void Function(int got, int total)? onProgress,
  }) {
    if (shouldFail(relPath)) {
      throw Exception('simulated transport failure for $relPath');
    }
    return inner.downloadToFile(relPath, local, onProgress: onProgress);
  }

  @override
  Future<void> deleteRemote(String relPath) => inner.deleteRemote(relPath);
  @override
  Future<void> close() => inner.close();
}

/// Real [LibraryModel] (never `.load()`-ed, so `reloadPlaylists` /
/// `rescan` / the manifest-write lock are all safe no-ops against empty
/// state) with a counter on `reloadPlaylists` so a test can observe whether
/// the engine called it.
class _RecordingLibraryModel extends LibraryModel {
  int reloadPlaylistsCalls = 0;

  @override
  void reloadPlaylists() {
    reloadPlaylistsCalls++;
    super.reloadPlaylists();
  }
}

void main() {
  late Directory nasHome;
  late Directory localHome;

  setUp(() {
    nasHome = Directory.systemTemp.createTempSync('sync_engine_nas');
    localHome = Directory.systemTemp.createTempSync('sync_engine_local');
  });

  tearDown(() {
    if (nasHome.existsSync()) nasHome.deleteSync(recursive: true);
    if (localHome.existsSync()) localHome.deleteSync(recursive: true);
  });

  /// Writes [length] synthetic bytes (seeded off [seed], so different
  /// tracks never collide) to `<nasHome>/<rootName>/<relPath>`, optionally
  /// forcing the mtime forward so a later "this changed" check can't land
  /// on a same-second false negative, and returns the REAL content ID for
  /// what got written.
  Future<String> writeNasTrack(
    String rootName,
    String relPath,
    int seed, {
    int length = 300,
    DateTime? mtime,
  }) async {
    final bytes = List<int>.generate(length, (i) => (seed + i) % 256);
    final f = File('${nasHome.path}/$rootName/$relPath');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    if (mtime != null) await f.setLastModified(mtime);
    return core.contentIdForFile(f);
  }

  Future<void> writeNasManifest(
    String rootName,
    Map<String, List<String>> idToPaths,
  ) async {
    final manifest = core.Manifest(
      schema: 1,
      tracks: {
        for (final entry in idToPaths.entries)
          entry.key: core.TrackEntry(
            dateAdded: DateTime.utc(2026, 1, 1).toIso8601String(),
            paths: entry.value,
          ),
      },
      playlists: [],
    );
    await core.saveManifest(manifest, Directory('${nasHome.path}/$rootName'));
  }

  SyncEngine buildEngine({
    required List<String> rootNames,
    SyncTransport? transport,
    LibraryModel? library,
    ActivityModel? activity,
    Future<int> Function(String path)? freeSpace,
    PlaylistReconciler? reconciler,
  }) {
    return SyncEngine(
      transport: transport ?? LocalDirTransport(nasHome),
      localHome: localHome,
      settings: SyncSettings(roots: {for (final r in rootNames) r: true}),
      library: library ?? LibraryModel(),
      activity: activity ?? ActivityModel(),
      freeSpace: freeSpace ?? (_) async => 1 << 40,
      reconciler: reconciler,
    );
  }

  group('SyncEngine.run -- root sync', () {
    test(
      'fresh root fully mirrors: files land verified and state is recorded; '
      'a second run is a no-op that still replaces the manifest (with .bak)',
      () async {
        final idA = await writeNasTrack('RootA', 'Artist/a.wav', 1);
        final idB = await writeNasTrack('RootA', 'Artist/b.wav', 99);
        await writeNasManifest('RootA', {
          idA: ['Artist/a.wav'],
          idB: ['Artist/b.wav'],
        });

        final engine = buildEngine(rootNames: ['RootA']);

        final r1 = (await engine.run()).roots.single;
        expect(r1.aborted, isFalse);
        expect(r1.copied, 2);
        expect(r1.updated, 0);
        expect(r1.failures, isEmpty);

        final localA = File('${localHome.path}/RootA/Artist/a.wav');
        final localB = File('${localHome.path}/RootA/Artist/b.wav');
        expect(localA.existsSync(), isTrue);
        expect(localB.existsSync(), isTrue);
        expect(await core.contentIdForFile(localA), idA);
        expect(await core.contentIdForFile(localB), idB);

        final localManifest = core.loadManifest(
          Directory('${localHome.path}/RootA'),
        );
        expect(localManifest.tracks.keys.toSet(), {idA, idB});

        final stateFile = File(
          '${localHome.path}/RootA/${core.syncStateFileName}',
        );
        expect(stateFile.existsSync(), isTrue);

        // Second run: nothing changed on the NAS -- pure no-op.
        final r2 = (await engine.run()).roots.single;
        expect(r2.aborted, isFalse);
        expect(r2.copied, 0);
        expect(r2.updated, 0);
        expect(r2.renamed, 0);
        expect(r2.deleted, 0);
        expect(r2.adopted, 0);
        expect(r2.failures, isEmpty);

        // The manifest write is unconditional (metadata could differ even
        // with no file changes), so the second run's saveManifest found run
        // 1's manifest already there and backed it up.
        final bak = File('${localHome.path}/RootA/${core.manifestBakName}');
        expect(bak.existsSync(), isTrue);
      },
    );

    test(
      'NAS-side retag (mtime+size change) triggers a recopy, not a fresh copy',
      () async {
        final idA = await writeNasTrack('RootA', 'a.wav', 1);
        await writeNasManifest('RootA', {
          idA: ['a.wav'],
        });

        final engine = buildEngine(rootNames: ['RootA']);
        final r1 = (await engine.run()).roots.single;
        expect(r1.copied, 1);

        final forwardMtime = DateTime.now().toUtc().add(const Duration(days: 1));
        final newId = await writeNasTrack(
          'RootA',
          'a.wav',
          2,
          length: 500,
          mtime: forwardMtime,
        );
        await writeNasManifest('RootA', {
          newId: ['a.wav'],
        });

        final r2 = (await engine.run()).roots.single;
        expect(r2.aborted, isFalse);
        expect(r2.updated, 1);
        expect(r2.copied, 0);
        expect(r2.failures, isEmpty);

        final localA = File('${localHome.path}/RootA/a.wav');
        expect(await core.contentIdForFile(localA), newId);
      },
    );

    test('NAS-side move produces a local rename, never a re-download', () async {
      final idA = await writeNasTrack('RootA', 'old/a.wav', 1);
      await writeNasManifest('RootA', {
        idA: ['old/a.wav'],
      });

      final plainTransport = LocalDirTransport(nasHome);
      final r1 = (await buildEngine(
        rootNames: ['RootA'],
        transport: plainTransport,
      ).run()).roots.single;
      expect(r1.copied, 1);
      expect(File('${localHome.path}/RootA/old/a.wav').existsSync(), isTrue);

      // Move on the NAS: same bytes, new path, manifest updated to match.
      final oldFile = File('${nasHome.path}/RootA/old/a.wav');
      final bytes = await oldFile.readAsBytes();
      await oldFile.delete();
      final newFile = File('${nasHome.path}/RootA/new/a.wav');
      await newFile.parent.create(recursive: true);
      await newFile.writeAsBytes(bytes);
      await writeNasManifest('RootA', {
        idA: ['new/a.wav'],
      });

      final counting = _CountingTransport(plainTransport);
      final r2 = (await buildEngine(
        rootNames: ['RootA'],
        transport: counting,
      ).run()).roots.single;

      expect(r2.aborted, isFalse);
      expect(r2.renamed, 1);
      expect(r2.copied, 0);
      expect(
        counting.downloadCalls,
        0,
        reason: 'a rename must never re-download the file',
      );
      expect(File('${localHome.path}/RootA/old/a.wav').existsSync(), isFalse);
      final relocated = File('${localHome.path}/RootA/new/a.wav');
      expect(relocated.existsSync(), isTrue);
      expect(await core.contentIdForFile(relocated), idA);
    });

    test('NAS-side delete produces a local delete, listed in the report', () async {
      final idA = await writeNasTrack('RootA', 'a.wav', 1);
      final idB = await writeNasTrack('RootA', 'b.wav', 2);
      await writeNasManifest('RootA', {
        idA: ['a.wav'],
        idB: ['b.wav'],
      });

      final engine = buildEngine(rootNames: ['RootA']);
      await engine.run();

      await File('${nasHome.path}/RootA/a.wav').delete();
      await writeNasManifest('RootA', {
        idB: ['b.wav'],
      });

      final r2 = (await engine.run()).roots.single;
      expect(r2.aborted, isFalse);
      expect(r2.deleted, 1);
      expect(File('${localHome.path}/RootA/a.wav').existsSync(), isFalse);
      expect(File('${localHome.path}/RootA/b.wav').existsSync(), isTrue);
    });

    test(
      'a corrupted remote-manifest content ID fails just that file; the rest still land',
      () async {
        await writeNasTrack('RootA', 'a.wav', 1);
        final idB = await writeNasTrack('RootA', 'b.wav', 2);
        await writeNasManifest('RootA', {
          'not-the-real-content-id-for-a': ['a.wav'],
          idB: ['b.wav'],
        });

        final result = (await buildEngine(
          rootNames: ['RootA'],
        ).run()).roots.single;

        expect(result.aborted, isFalse);
        expect(result.copied, 1); // only b.wav
        expect(result.failures, hasLength(1));
        expect(result.failures.single.relPath, 'a.wav');
        expect(File('${localHome.path}/RootA/a.wav').existsSync(), isFalse);
        expect(File('${localHome.path}/RootA/b.wav').existsSync(), isTrue);
      },
    );

    test('insufficient free space aborts the root before anything copies', () async {
      final idA = await writeNasTrack('RootA', 'a.wav', 1, length: 500);
      await writeNasManifest('RootA', {
        idA: ['a.wav'],
      });

      final result = (await buildEngine(
        rootNames: ['RootA'],
        freeSpace: (_) async => 10,
      ).run()).roots.single;

      expect(result.aborted, isTrue);
      expect(result.abortReason, contains('free space'));
      expect(result.copied, 0);
      expect(File('${localHome.path}/RootA/a.wav').existsSync(), isFalse);
    });

    test(
      'stale .sync_tmp garbage from an interrupted run is cleaned, and the run completes',
      () async {
        final idA = await writeNasTrack('RootA', 'a.wav', 1);
        await writeNasManifest('RootA', {
          idA: ['a.wav'],
        });

        final garbage = File(
          '${localHome.path}/RootA/${core.syncTmpDirName}/garbage.wav',
        );
        await garbage.parent.create(recursive: true);
        await garbage.writeAsBytes([1, 2, 3]);

        final result = (await buildEngine(
          rootNames: ['RootA'],
        ).run()).roots.single;

        expect(result.aborted, isFalse);
        expect(result.copied, 1);
        expect(result.failures, isEmpty);
        expect(garbage.existsSync(), isFalse);
        expect(File('${localHome.path}/RootA/a.wav').existsSync(), isTrue);
      },
    );

    test(
      'an unparseable remote manifest aborts only that root; the other root still syncs',
      () async {
        final idA = await writeNasTrack('RootGood', 'a.wav', 1);
        await writeNasManifest('RootGood', {
          idA: ['a.wav'],
        });

        final badManifest = File(
          '${nasHome.path}/RootBad/${core.manifestFileName}',
        );
        await badManifest.parent.create(recursive: true);
        await badManifest.writeAsString('{ not valid json');

        final report = await buildEngine(
          rootNames: ['RootBad', 'RootGood'],
        ).run();

        final good = report.roots.firstWhere((r) => r.rootName == 'RootGood');
        final bad = report.roots.firstWhere((r) => r.rootName == 'RootBad');

        expect(good.aborted, isFalse);
        expect(good.copied, 1);
        expect(bad.aborted, isTrue);
        expect(bad.abortReason, contains('unparseable'));
      },
    );

    test(
      'a remote root with no manifest at all is aborted (not crashed), others still sync',
      () async {
        final idA = await writeNasTrack('RootGood', 'a.wav', 1);
        await writeNasManifest('RootGood', {
          idA: ['a.wav'],
        });
        await Directory('${nasHome.path}/RootMissing').create(recursive: true);

        final report = await buildEngine(
          rootNames: ['RootGood', 'RootMissing'],
        ).run();

        final missing = report.roots.firstWhere(
          (r) => r.rootName == 'RootMissing',
        );
        expect(missing.aborted, isTrue);
        expect(missing.abortReason, isNotNull);
      },
    );

    test(
      '3 consecutive transport failures abort the root as "connection lost", '
      'reporting what completed',
      () async {
        final idKeep1 = await writeNasTrack('RootA', 'keep1.wav', 1);
        final idKeep2 = await writeNasTrack('RootA', 'keep2.wav', 2);
        await writeNasManifest('RootA', {
          idKeep1: ['keep1.wav'],
          idKeep2: ['keep2.wav'],
        });

        final plainTransport = LocalDirTransport(nasHome);
        final r1 = (await buildEngine(
          rootNames: ['RootA'],
          transport: plainTransport,
        ).run()).roots.single;
        expect(r1.aborted, isFalse);
        expect(r1.copied, 2);

        // keep1/keep2 are already fully synced after run 1 (state matches
        // the listing), so this run's plan.copies consists ONLY of the
        // three new "bad" files -- no interleaving with keep1/keep2, so
        // directory-listing order can't affect the "3 consecutive" count.
        final idBad1 = await writeNasTrack('RootA', 'bad1.wav', 3);
        final idBad2 = await writeNasTrack('RootA', 'bad2.wav', 4);
        final idBad3 = await writeNasTrack('RootA', 'bad3.wav', 5);
        await writeNasManifest('RootA', {
          idKeep1: ['keep1.wav'],
          idKeep2: ['keep2.wav'],
          idBad1: ['bad1.wav'],
          idBad2: ['bad2.wav'],
          idBad3: ['bad3.wav'],
        });

        final failing = _FailingTransport(
          plainTransport,
          (relPath) => relPath.contains('bad'),
        );
        final r2 = (await buildEngine(
          rootNames: ['RootA'],
          transport: failing,
        ).run()).roots.single;

        expect(r2.aborted, isTrue);
        expect(r2.abortReason, 'connection lost');
        expect(r2.copied, 0, reason: 'nothing NEW landed this run');
        expect(r2.failures, hasLength(3));
        expect(r2.failures.map((f) => f.relPath).toSet(), {
          'bad1.wav',
          'bad2.wav',
          'bad3.wav',
        });

        expect(File('${localHome.path}/RootA/keep1.wav').existsSync(), isTrue);
        expect(File('${localHome.path}/RootA/keep2.wav').existsSync(), isTrue);
        for (final bad in ['bad1.wav', 'bad2.wav', 'bad3.wav']) {
          expect(File('${localHome.path}/RootA/$bad').existsSync(), isFalse);
        }
      },
    );

    test(
      'cancel() stops the root after the in-flight file, reporting "cancelled"',
      () async {
        final idA = await writeNasTrack('RootA', 'a.wav', 1);
        final idB = await writeNasTrack('RootA', 'b.wav', 2);
        final idC = await writeNasTrack('RootA', 'c.wav', 3);
        await writeNasManifest('RootA', {
          idA: ['a.wav'],
          idB: ['b.wav'],
          idC: ['c.wav'],
        });

        late SyncEngine engine;
        var downloadsSeen = 0;
        final transport = _CountingTransport(
          LocalDirTransport(nasHome),
          onDownload: (_) {
            downloadsSeen++;
            if (downloadsSeen == 1) engine.cancel();
          },
        );
        engine = buildEngine(rootNames: ['RootA'], transport: transport);

        final result = (await engine.run()).roots.single;

        expect(result.aborted, isTrue);
        expect(result.abortReason, 'cancelled');
        expect(result.copied, 1);
        expect(downloadsSeen, 1);
      },
    );
  });

  group('SyncEngine.run -- probe', () {
    test(
      'an unreachable NAS aborts the whole run before touching playlists',
      () async {
        // A reconciler pointed at the (reachable) NAS home, wired with local
        // vs. remote playlist content that WOULD diverge-and-copy if
        // reconciler.run() actually executed -- so "it never ran" is
        // checked behaviorally (the local file is untouched afterward),
        // not by a dead counter that nothing increments.
        final oldLocal = core.PlaylistFile(
          id: 'p_1',
          name: 'roadtrip',
          trackIds: ['a'],
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse('2026-07-31T11:00:00Z'),
          modifiedBy: 'tablet',
        );
        final newRemote = core.PlaylistFile(
          id: 'p_1',
          name: 'roadtrip',
          trackIds: ['a', 'b'],
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse('2026-07-31T12:00:00Z'),
          modifiedBy: 'desktop',
        );
        await core.savePlaylistFile(localHome, oldLocal);
        await core.savePlaylistFile(nasHome, newRemote);

        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: LocalDirTransport(nasHome),
          localLabel: 'tablet',
        );
        // The ENGINE's own transport (what probe() checks) points at a
        // directory that doesn't exist -- probe() fails fast. The
        // reconciler above has its own, separately-reachable transport,
        // exactly like the real app would wire them.
        final deadTransport = LocalDirTransport(
          Directory('${nasHome.path}/does-not-exist'),
        );

        final engine = SyncEngine(
          transport: deadTransport,
          localHome: localHome,
          settings: SyncSettings(roots: {'RootA': true}),
          library: LibraryModel(),
          activity: ActivityModel(),
          freeSpace: (_) async => 1 << 40,
          reconciler: reconciler,
        );

        final report = await engine.run();

        expect(report.playlistNotes, isEmpty);
        expect(report.roots, hasLength(1));
        expect(report.roots.single.aborted, isTrue);

        final localState = core.loadPlaylistsDir(localHome);
        expect(
          localState.playlists['p_1']!.trackIds,
          ['a'],
          reason: 'unchanged -- the reconciler never ran',
        );
      },
    );
  });

  group('SyncEngine.run -- playlists', () {
    test('a reconcile that returns notes triggers library.reloadPlaylists()', () async {
      final oldLocal = core.PlaylistFile(
        id: 'p_1',
        name: 'roadtrip',
        trackIds: ['a'],
        created: DateTime.parse('2026-07-01T00:00:00Z'),
        modified: DateTime.parse('2026-07-31T11:00:00Z'),
        modifiedBy: 'tablet',
      );
      final newRemote = core.PlaylistFile(
        id: 'p_1',
        name: 'roadtrip',
        trackIds: ['a', 'b'],
        created: DateTime.parse('2026-07-01T00:00:00Z'),
        modified: DateTime.parse('2026-07-31T12:00:00Z'),
        modifiedBy: 'desktop',
      );
      await core.savePlaylistFile(localHome, oldLocal);
      await core.savePlaylistFile(nasHome, newRemote);

      final transport = LocalDirTransport(nasHome);
      final reconciler = PlaylistReconciler(
        localHome: localHome,
        transport: transport,
        localLabel: 'tablet',
      );
      final library = _RecordingLibraryModel();

      final engine = SyncEngine(
        transport: transport,
        localHome: localHome,
        settings: SyncSettings(roots: {}), // no roots checked -- isolate this phase
        library: library,
        activity: ActivityModel(),
        freeSpace: (_) async => 1 << 40,
        reconciler: reconciler,
      );

      final report = await engine.run();

      expect(report.playlistNotes, isNotEmpty);
      expect(library.reloadPlaylistsCalls, 1);
    });

    test(
      'a reconcile with nothing to do does not call library.reloadPlaylists()',
      () async {
        final same = core.PlaylistFile(
          id: 'p_1',
          name: 'n',
          trackIds: ['x'],
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse('2026-07-31T12:00:00Z'),
          modifiedBy: 'tablet',
        );
        await core.savePlaylistFile(localHome, same);
        await core.savePlaylistFile(nasHome, same);

        final transport = LocalDirTransport(nasHome);
        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: transport,
          localLabel: 'tablet',
        );
        final library = _RecordingLibraryModel();

        final engine = SyncEngine(
          transport: transport,
          localHome: localHome,
          settings: SyncSettings(roots: {}),
          library: library,
          activity: ActivityModel(),
          freeSpace: (_) async => 1 << 40,
          reconciler: reconciler,
        );

        final report = await engine.run();

        expect(report.playlistNotes, isEmpty);
        expect(library.reloadPlaylistsCalls, 0);
      },
    );

    test('no reconciler injected -- playlist phase is simply skipped', () async {
      final report = await buildEngine(rootNames: []).run();
      expect(report.playlistNotes, isEmpty);
    });
  });

  group('SyncSettings', () {
    test('defaults', () {
      final s = SyncSettings();
      expect(s.host, 'murkyserver');
      expect(s.share, 'drop');
      expect(s.basePath, 'music (original structure)');
      expect(s.roots, isEmpty);
      expect(s.anyChecked, isFalse);
    });

    test('anyChecked is true iff at least one root is checked', () {
      final s = SyncSettings(roots: {'A': false, 'B': false});
      expect(s.anyChecked, isFalse);
      s.roots['B'] = true;
      expect(s.anyChecked, isTrue);
    });

    test('toJson/fromConfig round-trip', () {
      final original = SyncSettings(
        host: 'myserver',
        share: 'myshare',
        basePath: 'music',
        roots: {'RootA': true, 'RootB': false},
      );

      final restored = SyncSettings.fromConfig({'sync': original.toJson()});

      expect(restored, isNotNull);
      expect(restored!.host, 'myserver');
      expect(restored.share, 'myshare');
      expect(restored.basePath, 'music');
      expect(restored.roots, {'RootA': true, 'RootB': false});
    });

    test('fromConfig returns null when "sync" is absent', () {
      expect(SyncSettings.fromConfig({}), isNull);
    });

    test('fromConfig returns null when "sync" is present but not a map', () {
      expect(SyncSettings.fromConfig({'sync': 'nonsense'}), isNull);
    });

    test('fromConfig fills in defaults for a partially-specified block', () {
      final restored = SyncSettings.fromConfig({
        'sync': {
          'roots': {'X': true},
        },
      });

      expect(restored, isNotNull);
      expect(restored!.host, 'murkyserver');
      expect(restored.share, 'drop');
      expect(restored.basePath, 'music (original structure)');
      expect(restored.roots, {'X': true});
    });
  });
}
