// Last modified: 2026-07-31--1743
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/sync/playlist_reconciler.dart';
import 'package:fooplayer_app/sync/sync_transport.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

core.PlaylistFile _pf(
  String id,
  String name,
  List<String> trackIds,
  String modified, {
  String by = 'dev',
  String created = '2026-07-01T00:00:00Z',
}) => core.PlaylistFile(
  id: id,
  name: name,
  trackIds: trackIds,
  created: DateTime.parse(created),
  modified: DateTime.parse(modified),
  modifiedBy: by,
);

void main() {
  late Directory localHome;
  late Directory nasHome;
  late LocalDirTransport transport;

  setUp(() {
    localHome = Directory.systemTemp.createTempSync('reconciler_local');
    nasHome = Directory.systemTemp.createTempSync('reconciler_nas');
    transport = LocalDirTransport(nasHome);
  });

  tearDown(() {
    if (localHome.existsSync()) localHome.deleteSync(recursive: true);
    if (nasHome.existsSync()) nasHome.deleteSync(recursive: true);
  });

  group('PlaylistReconciler.run', () {
    test(
      'remote-newer flows to local, backing up the overwritten local version',
      () async {
        final oldLocal = _pf(
          'p_1',
          'roadtrip',
          ['a'],
          '2026-07-31T11:00:00Z',
          by: 'tablet',
        );
        final newRemote = _pf(
          'p_1',
          'roadtrip',
          ['a', 'b'],
          '2026-07-31T12:00:00Z',
          by: 'desktop',
        );
        await core.savePlaylistFile(localHome, oldLocal);
        await core.savePlaylistFile(nasHome, newRemote);

        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: transport,
          localLabel: 'tablet',
        );
        final notes = await reconciler.run();

        final localState = core.loadPlaylistsDir(localHome);
        expect(localState.playlists['p_1']!.trackIds, ['a', 'b']);

        final backupDir = Directory(
          '${localHome.path}/${core.playlistsDirName}/${core.playlistBackupDirName}',
        );
        expect(backupDir.existsSync(), isTrue);
        final backups = backupDir.listSync().whereType<File>().toList();
        expect(backups, hasLength(1));
        expect(backups.single.path, contains('p_1--'));
        final backedUp = core.PlaylistFile.fromJson(
          jsonDecode(backups.single.readAsStringSync()),
        );
        expect(backedUp!.trackIds, ['a']); // the OLD local content

        expect(notes, isNotEmpty);
        expect(notes.single, contains('NAS')); // remote's label won
      },
    );

    test(
      'local-newer flows to remote, backing up the overwritten remote version',
      () async {
        final newLocal = _pf(
          'p_1',
          'roadtrip',
          ['a', 'b'],
          '2026-07-31T12:00:00Z',
          by: 'tablet',
        );
        final oldRemote = _pf(
          'p_1',
          'roadtrip',
          ['a'],
          '2026-07-31T11:00:00Z',
          by: 'desktop',
        );
        await core.savePlaylistFile(localHome, newLocal);
        await core.savePlaylistFile(nasHome, oldRemote);

        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: transport,
          localLabel: 'tablet',
        );
        final notes = await reconciler.run();

        final remoteBytes = await transport.readFile(
          '${core.playlistsDirName}/p_1.json',
        );
        final remotePlaylist = core.PlaylistFile.fromJson(
          jsonDecode(utf8.decode(remoteBytes!)),
        );
        expect(remotePlaylist!.trackIds, ['a', 'b']);

        final backupDir = Directory(
          '${nasHome.path}/${core.playlistsDirName}/${core.playlistBackupDirName}',
        );
        expect(backupDir.existsSync(), isTrue);
        final backups = backupDir.listSync().whereType<File>().toList();
        expect(backups, hasLength(1));
        final backedUp = core.PlaylistFile.fromJson(
          jsonDecode(backups.single.readAsStringSync()),
        );
        expect(backedUp!.trackIds, ['a']); // the OLD remote content

        expect(notes, isNotEmpty);
        expect(notes.single, contains('tablet'));
      },
    );

    test(
      'local delete propagates: remote file removed+backed up, remote tombstoned',
      () async {
        // Remote still has the live (stale, from this device's POV) file.
        final remoteStillLive = _pf(
          'p_1',
          'old mix',
          ['a'],
          '2026-07-31T09:00:00Z',
          by: 'desktop',
        );
        await core.savePlaylistFile(nasHome, remoteStillLive);

        // Local has already been through PlaylistStore.deletePlaylist: no
        // more local playlist file, a local backup of what was deleted, and
        // a tombstone newer than remote's still-live file.
        await core.backupPlaylistFile(
          localHome,
          _pf('p_1', 'old mix', ['a'], '2026-07-31T09:00:00Z', by: 'desktop'),
          DateTime.parse('2026-07-31T10:00:00Z'),
        );
        await core.saveTombstones(localHome, {
          'p_1': core.PlaylistTombstone(
            deleted: DateTime.parse('2026-07-31T10:00:00Z'),
            name: 'old mix',
          ),
        });

        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: transport,
          localLabel: 'tablet',
        );
        final notes = await reconciler.run();

        // Remote file is gone.
        expect(
          await transport.readFile('${core.playlistsDirName}/p_1.json'),
          isNull,
        );

        // Remote backup of the removed content was written.
        final remoteBackupDir = Directory(
          '${nasHome.path}/${core.playlistsDirName}/${core.playlistBackupDirName}',
        );
        expect(remoteBackupDir.existsSync(), isTrue);
        expect(
          remoteBackupDir.listSync().whereType<File>().toList(),
          hasLength(1),
        );

        // Remote tombstones now record p_1's deletion.
        final remoteTombBytes = await transport.readFile(
          '${core.playlistsDirName}/${core.playlistTombstonesFileName}',
        );
        final remoteTombJson =
            jsonDecode(utf8.decode(remoteTombBytes!)) as Map<String, dynamic>;
        expect((remoteTombJson['tombstones'] as Map)['p_1'], isNotNull);

        expect(notes, isNotEmpty);
      },
    );

    test(
      'a corrupt remote playlist file is skipped, reported, and does not derail the rest',
      () async {
        final healthy = _pf('p_2', 'healthy', ['z'], '2026-07-31T12:00:00Z');
        await core.savePlaylistFile(nasHome, healthy);
        final badFile = File(
          '${nasHome.path}/${core.playlistsDirName}/p_bad.json',
        );
        badFile.createSync(recursive: true);
        badFile.writeAsStringSync('{ not valid json');

        final reconciler = PlaylistReconciler(
          localHome: localHome,
          transport: transport,
          localLabel: 'tablet',
        );
        final notes = await reconciler.run();

        final localState = core.loadPlaylistsDir(localHome);
        expect(localState.playlists['p_2']!.name, 'healthy');

        expect(notes.any((n) => n.contains('p_bad.json')), isTrue);
      },
    );

    test('files under backup/ are skipped entirely, never even parsed', () async {
      final badBackup = File(
        '${nasHome.path}/${core.playlistsDirName}/${core.playlistBackupDirName}/p_x--20260101-000000.json',
      );
      badBackup.createSync(recursive: true);
      badBackup.writeAsStringSync('{ not valid json');

      final reconciler = PlaylistReconciler(
        localHome: localHome,
        transport: transport,
        localLabel: 'tablet',
      );
      final notes = await reconciler.run();

      expect(notes, isEmpty);
      expect(core.loadPlaylistsDir(localHome).playlists, isEmpty);
    });

    test('identical local and remote produce no writes and no notes', () async {
      final p = _pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
      await core.savePlaylistFile(localHome, p);
      await core.savePlaylistFile(nasHome, p);

      final reconciler = PlaylistReconciler(
        localHome: localHome,
        transport: transport,
        localLabel: 'tablet',
      );
      final notes = await reconciler.run();

      expect(notes, isEmpty);
    });

    test('backup stamps use the injected clock, not wall-clock time', () async {
      final oldLocal = _pf('p_1', 'n', ['a'], '2026-07-31T11:00:00Z');
      final newRemote = _pf('p_1', 'n', ['a', 'b'], '2026-07-31T12:00:00Z');
      await core.savePlaylistFile(localHome, oldLocal);
      await core.savePlaylistFile(nasHome, newRemote);

      final reconciler = PlaylistReconciler(
        localHome: localHome,
        transport: transport,
        localLabel: 'tablet',
        now: () => DateTime.utc(2030, 1, 2, 3, 4, 5),
      );
      await reconciler.run();

      final backupDir = Directory(
        '${localHome.path}/${core.playlistsDirName}/${core.playlistBackupDirName}',
      );
      final backups = backupDir.listSync().whereType<File>().toList();
      expect(backups.single.path, contains('p_1--20300102-030405.json'));
    });
  });

  group('PlaylistSyncScheduler', () {
    test('a mutate-burst inside the debounce window collapses to one run', () {
      fakeAsync((async) {
        var calls = 0;
        final scheduler = PlaylistSyncScheduler(
          runReconcile: () async {
            calls++;
            return <String>[];
          },
          probe: () async => true,
        );

        scheduler.onPlaylistMutated();
        async.elapse(const Duration(seconds: 1));
        scheduler.onPlaylistMutated(); // restarts the 3s debounce window
        async.elapse(const Duration(seconds: 1));
        scheduler.onPlaylistMutated(); // restarts again
        async.elapse(const Duration(seconds: 5)); // now past the window
        async.flushMicrotasks();

        expect(calls, 1);
      });
    });

    test(
      'an unreachable probe skips the run silently, without throwing',
      () {
        fakeAsync((async) {
          var probeCalls = 0;
          var reconcileCalls = 0;
          final scheduler = PlaylistSyncScheduler(
            runReconcile: () async {
              reconcileCalls++;
              return <String>[];
            },
            probe: () async {
              probeCalls++;
              return false;
            },
          );

          scheduler.onAppStart();
          async.elapse(const Duration(milliseconds: 1));
          async.flushMicrotasks();

          expect(probeCalls, 1);
          expect(reconcileCalls, 0);
        });
      },
    );

    test('a reachable probe lets the reconcile run', () {
      fakeAsync((async) {
        var reconcileCalls = 0;
        final scheduler = PlaylistSyncScheduler(
          runReconcile: () async {
            reconcileCalls++;
            return <String>[];
          },
          probe: () async => true,
        );

        scheduler.onPeriodicTick();
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(reconcileCalls, 1);
      });
    });

    test(
      'overlapping triggers during a run coalesce into exactly one follow-up run',
      () async {
        var reconcileCalls = 0;
        final gate1 = Completer<void>();
        final gate2 = Completer<void>();
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();

        final scheduler = PlaylistSyncScheduler(
          runReconcile: () async {
            reconcileCalls++;
            if (reconcileCalls == 1) {
              firstStarted.complete();
              await gate1.future;
            } else if (reconcileCalls == 2) {
              secondStarted.complete();
              await gate2.future;
            }
            return <String>[];
          },
          probe: () async => true,
        );

        scheduler.onAppStart(); // run #1 starts, blocks on gate1
        await firstStarted.future;
        expect(reconcileCalls, 1);

        // Multiple overlapping triggers while run #1 is still in flight must
        // coalesce into exactly ONE follow-up run, not stack up three more.
        scheduler.onPeriodicTick();
        scheduler.onPeriodicTick();
        scheduler.onAppStart();

        gate1.complete(); // let run #1 finish
        await secondStarted.future; // the single coalesced follow-up starts
        expect(reconcileCalls, 2);

        gate2.complete();
        await scheduler.idle;
        expect(reconcileCalls, 2); // no third run
      },
    );

    test('idle resolves immediately when nothing has been triggered', () async {
      final scheduler = PlaylistSyncScheduler(
        runReconcile: () async => <String>[],
        probe: () async => true,
      );
      await scheduler.idle.timeout(const Duration(seconds: 1));
    });
  });
}
