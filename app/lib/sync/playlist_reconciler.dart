// Last modified: 2026-07-31--1743
//
// The app-side executor for Task 2's pure `reconcilePlaylists`: reads the
// remote `.playlists/` sidecar over a `SyncTransport`, diffs it against the
// local sidecar, and performs whatever copies/deletes/tombstone-merges the
// LWW decision produced -- never any policy of its own. Also home to
// `PlaylistSyncScheduler`, the probe-gated, debounced, single-flight cadence
// that decides WHEN a reconcile run happens (app start, a 5-minute tick, or
// "something changed" from `PlaylistStore`), independent of what a run does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart' as core;

import 'sync_transport.dart';

/// The label a report line uses for "the other side" -- there is currently
/// only ever one remote (the NAS), so this is a constant rather than a
/// constructor parameter.
const _remoteLabel = 'NAS';

/// Executes one playlist reconcile pass between [localHome]'s `.playlists/`
/// sidecar and the `.playlists/` sidecar under [transport]'s base.
///
/// Every action [core.reconcilePlaylists] can produce is executed here:
/// copies write the winning side's file to the losing side, `backupFirst`
/// snapshots the side about to be overwritten/removed first (local via
/// [core.backupPlaylistFile]; remote via [SyncTransport.writeFile] into
/// `.playlists/backup/`), and tombstone actions merge one id into the
/// receiving side's tombstones map -- read once at the top of [run], mutated
/// in memory, and written back at most once per side, which preserves every
/// unrelated entry exactly as a literal read-modify-write per action would,
/// without the redundant repeat writes.
class PlaylistReconciler {
  final Directory localHome;
  final SyncTransport transport;
  final String localLabel;
  final DateTime Function() _now;

  PlaylistReconciler({
    required this.localHome,
    required this.transport,
    required this.localLabel,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Runs one full reconcile pass and returns every non-empty action note
  /// plus a note for each corrupt file (either side) that had to be
  /// skipped -- an empty list means nothing happened. Never throws on a
  /// malformed remote file; a broken playlist or tombstones file is skipped
  /// and reported, exactly like [core.loadPlaylistsDir] treats a broken
  /// local one.
  Future<List<String>> run() async {
    final local = core.loadPlaylistsDir(localHome);
    final remote = await _loadRemoteState();

    final actions = core.reconcilePlaylists(
      local,
      remote,
      localLabel: localLabel,
      remoteLabel: _remoteLabel,
    );

    final localTombstones = Map<String, core.PlaylistTombstone>.of(
      local.tombstones,
    );
    final remoteTombstones = Map<String, core.PlaylistTombstone>.of(
      remote.tombstones,
    );
    var localTombstonesChanged = false;
    var remoteTombstonesChanged = false;

    for (final action in actions) {
      switch (action.op) {
        case core.PlaylistSyncOp.copyToLocal:
          final rp = remote.playlists[action.id];
          // reconcilePlaylists guarantees rp != null for this op, but never
          // trust a decision result enough to crash the executor over it.
          if (rp == null) break;
          if (action.backupFirst) {
            final lp = local.playlists[action.id];
            if (lp != null) {
              await core.backupPlaylistFile(localHome, lp, _now());
            }
          }
          await core.savePlaylistFile(localHome, rp);
          break;

        case core.PlaylistSyncOp.copyToRemote:
          final lp = local.playlists[action.id];
          if (lp == null) break;
          if (action.backupFirst) {
            final rp = remote.playlists[action.id];
            if (rp != null) await _backupRemote(rp);
          }
          await _writeRemotePlaylist(lp);
          break;

        case core.PlaylistSyncOp.deleteLocal:
          final lp = local.playlists[action.id];
          if (action.backupFirst && lp != null) {
            await core.backupPlaylistFile(localHome, lp, _now());
          }
          await core.removePlaylistFile(localHome, action.id);
          break;

        case core.PlaylistSyncOp.deleteRemote:
          final rp = remote.playlists[action.id];
          if (action.backupFirst && rp != null) await _backupRemote(rp);
          await transport.deleteRemote(
            '${core.playlistsDirName}/${action.id}.json',
          );
          break;

        case core.PlaylistSyncOp.tombstoneToLocal:
          // Always sourced from remote's tombstone -- reconcilePlaylists
          // only ever emits this op when remote.tombstones[id] is the newer
          // (or only) one.
          final t = remote.tombstones[action.id];
          if (t != null) {
            localTombstones[action.id] = t;
            localTombstonesChanged = true;
          }
          break;

        case core.PlaylistSyncOp.tombstoneToRemote:
          final t = local.tombstones[action.id];
          if (t != null) {
            remoteTombstones[action.id] = t;
            remoteTombstonesChanged = true;
          }
          break;
      }
    }

    if (localTombstonesChanged) {
      await core.saveTombstones(localHome, localTombstones);
    }
    if (remoteTombstonesChanged) {
      await transport.writeFile(
        '${core.playlistsDirName}/${core.playlistTombstonesFileName}',
        _tombstonesBytes(remoteTombstones),
      );
    }

    return [
      for (final a in actions)
        if (a.note.isNotEmpty) a.note,
      for (final name in local.corruptFiles)
        'skipped corrupt playlist file "$name" on $localLabel',
      for (final name in remote.corruptFiles)
        'skipped corrupt playlist file "$name" on $_remoteLabel',
    ];
  }

  /// Builds the remote [core.PlaylistSidecarState] the same tolerant way
  /// [core.loadPlaylistsDir] builds the local one, just over [transport]
  /// instead of `dart:io` directly: list `.playlists/`, skip anything under
  /// `backup/` and any leftover `.tmp`, parse `tombstones.json` and every
  /// other `*.json` with the same tolerant [core.PlaylistFile.fromJson] /
  /// [core.PlaylistTombstone.fromJson] discipline -- a file that doesn't
  /// parse is recorded in `corruptFiles`, never fatal.
  Future<core.PlaylistSidecarState> _loadRemoteState() async {
    final entries = await transport.listTree(core.playlistsDirName);
    final playlists = <String, core.PlaylistFile>{};
    final corrupt = <String>[];
    var tombstones = <String, core.PlaylistTombstone>{};

    final prefix = '${core.playlistsDirName}/';
    final backupPrefix = '$prefix${core.playlistBackupDirName}/';
    for (final rf in entries) {
      final relPath = rf.relPath;
      if (!relPath.startsWith(prefix)) continue;
      if (relPath.startsWith(backupPrefix)) continue;
      if (!relPath.endsWith('.json')) continue; // also excludes stray .tmp

      final basename = relPath.substring(prefix.length);
      final bytes = await transport.readFile(relPath);
      if (bytes == null) continue; // vanished between list and read

      if (basename == core.playlistTombstonesFileName) {
        final parsed = _parseTombstones(bytes);
        if (parsed == null) {
          corrupt.add(basename);
        } else {
          tombstones = parsed;
        }
        continue;
      }

      final p = _parsePlaylist(bytes);
      if (p == null) {
        corrupt.add(basename);
      } else {
        playlists[p.id] = p;
      }
    }

    return core.PlaylistSidecarState(playlists, tombstones, corrupt);
  }

  core.PlaylistFile? _parsePlaylist(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is Map<String, dynamic>) return core.PlaylistFile.fromJson(j);
    } catch (_) {}
    return null;
  }

  Map<String, core.PlaylistTombstone>? _parseTombstones(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is Map<String, dynamic>) {
        final raw = j['tombstones'];
        if (raw is Map<String, dynamic>) {
          final out = <String, core.PlaylistTombstone>{};
          raw.forEach((id, v) {
            if (v is Map<String, dynamic>) {
              final t = core.PlaylistTombstone.fromJson(v);
              if (t != null) out[id] = t;
            }
          });
          return out;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeRemotePlaylist(core.PlaylistFile p) => transport
      .writeFile('${core.playlistsDirName}/${p.id}.json', _playlistBytes(p));

  /// `.playlists/backup/<id>--<stamp>.json`, using [_now] (not wall-clock
  /// time) so tests are deterministic -- same stamp format as
  /// [core.backupPlaylistFile]'s.
  Future<void> _backupRemote(core.PlaylistFile p) => transport.writeFile(
    '${core.playlistsDirName}/${core.playlistBackupDirName}/${p.id}--${_stamp(_now())}.json',
    _playlistBytes(p),
  );

  List<int> _playlistBytes(core.PlaylistFile p) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson()));

  List<int> _tombstonesBytes(Map<String, core.PlaylistTombstone> t) =>
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'tombstones': t.map((k, v) => MapEntry(k, v.toJson())),
        }),
      );

  static String _stamp(DateTime now) {
    final u = now.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}'
        '-${two(u.hour)}${two(u.minute)}${two(u.second)}';
  }
}

/// Decides WHEN [PlaylistReconciler.run] (or an equivalent) happens, via the
/// injected [runReconcile]/[probe] seams -- this class has no I/O of its
/// own, which is what makes it testable without a real transport.
///
/// Three triggers, one cadence policy:
/// - [onAppStart] / [onPeriodicTick]: fire immediately.
/// - [onPlaylistMutated]: debounced by [editDebounce] (default 3s) so a
///   burst of playlist edits collapses into one run instead of one per edit.
///
/// Whatever the trigger, the underlying run is single-flight: a trigger that
/// arrives while a run is already in progress doesn't start a second
/// concurrent run, and doesn't get dropped either -- it sets a flag that
/// causes exactly ONE follow-up run once the current one finishes (repeated
/// triggers during that time all coalesce into that same one flag, not a
/// queue). [probe] gates every run: an unreachable NAS silently skips
/// (no error, no retry loop of its own -- the next trigger tries again).
class PlaylistSyncScheduler {
  final Future<List<String>> Function() runReconcile;
  final Future<bool> Function() probe;
  final Duration editDebounce;

  Timer? _debounceTimer;
  bool _running = false;
  bool _rerunRequested = false;
  Completer<void>? _idleCompleter;

  PlaylistSyncScheduler({
    required this.runReconcile,
    required this.probe,
    this.editDebounce = const Duration(seconds: 3),
  });

  void onAppStart() {
    _ensureBusy();
    _startRunOrQueue();
  }

  void onPeriodicTick() {
    _ensureBusy();
    _startRunOrQueue();
  }

  void onPlaylistMutated() {
    _ensureBusy();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(editDebounce, () {
      _debounceTimer = null;
      _startRunOrQueue();
    });
  }

  /// Resolves once no debounce timer is pending and no run (including any
  /// coalesced follow-up) is in flight -- i.e. there is nothing left this
  /// scheduler is going to do on its own. Already-resolved when nothing has
  /// been triggered yet.
  Future<void> get idle => _idleCompleter?.future ?? Future.value();

  void _ensureBusy() {
    _idleCompleter ??= Completer<void>();
  }

  void _startRunOrQueue() {
    if (_running) {
      _rerunRequested = true;
      return;
    }
    _running = true;
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    do {
      _rerunRequested = false;
      try {
        if (await probe()) {
          await runReconcile();
        }
      } catch (_) {
        // A transient I/O failure just means "try again on the next
        // trigger" -- never leave the scheduler stuck mid-run over it.
      }
    } while (_rerunRequested);
    _running = false;
    _maybeSettle();
  }

  void _maybeSettle() {
    if (_running || _debounceTimer != null) return;
    _idleCompleter?.complete();
    _idleCompleter = null;
  }
}
