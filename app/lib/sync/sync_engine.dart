// Last modified: 2026-07-31--1805
//
// SyncEngine: the orchestrator that turns Task 6's pure `planRootSync`
// decisions into a verified NAS->phone mirror. Per checked root it reads the
// remote manifest+listing, plans, checks free space, executes (download +
// verify + move, then renames, then deletes, then sidecar copies), records
// sync-state for what succeeded, and adopts the remote manifest as the
// root's own -- then, once every root is done, tells [LibraryModel] to
// rescan so the newly-landed files show up in the library. Also runs the
// playlist reconcile phase (Task 8) first, since that's cheap and
// independent of any root's music files.
//
// Every phase is best-effort per item: a single failed file is retried once,
// then recorded as a [SyncFailure] and skipped -- it never takes the rest of
// the root down with it. The one thing that DOES abort a root outright is
// losing the connection (3 consecutive transport-level failures) or an
// explicit [cancel]; either way, whatever already landed stays landed and
// sync-state is still saved, so the next run picks up exactly where this one
// stopped.
import 'dart:convert';
import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;

import '../model/activity_model.dart';
import '../model/library_model.dart';
import 'playlist_reconciler.dart';
import 'sync_settings.dart';
import 'sync_transport.dart';

/// One file this run couldn't sync, and why -- never fatal to the root it
/// happened in.
class SyncFailure {
  final String relPath;
  final String reason;
  SyncFailure({required this.relPath, required this.reason});

  @override
  String toString() => '$relPath: $reason';
}

/// The outcome of syncing one checked root.
class RootSyncResult {
  final String rootName;

  /// Brand-new files that landed this run -- fresh audio copies plus new
  /// sidecar files (`.artwork.json`, `.artwork/...`). [copiedBytes] is the
  /// total size of exactly those files.
  final int copied;
  final int copiedBytes;

  /// Existing audio files that were re-downloaded because their recorded
  /// sync-state no longer matches the remote listing (a retag, a re-encode
  /// -- anything that changed the file without moving it).
  final int updated;

  final int renamed;
  final int deleted;
  final int adopted;

  final List<String> unindexedLocal;
  final List<SyncFailure> failures;

  final bool aborted;
  final String? abortReason;

  RootSyncResult({
    required this.rootName,
    required this.copied,
    required this.copiedBytes,
    required this.updated,
    required this.renamed,
    required this.deleted,
    required this.adopted,
    required this.unindexedLocal,
    required this.failures,
    required this.aborted,
    this.abortReason,
  });
}

/// The result of one whole [SyncEngine.run] call.
class SyncReport {
  final List<String> playlistNotes;
  final List<RootSyncResult> roots;
  final DateTime finishedAt;

  SyncReport({
    required this.playlistNotes,
    required this.roots,
    required this.finishedAt,
  });

  /// True when anything didn't fully succeed -- an aborted root, or any
  /// per-file failure inside one that otherwise completed.
  bool get hadFailures =>
      roots.any((r) => r.aborted || r.failures.isNotEmpty);
}

/// A synced root's rename source/target pair or single-file download failed
/// only at the transport level (vs. a verification mismatch) -- distinguishes
/// "the network dropped" from "the file that landed is wrong", since only
/// the former counts toward the 3-consecutive-failures "connection lost"
/// abort. A corrupted remote manifest entry must never trip that abort: it
/// fails the same way every retry, forever, and the other files in the root
/// are all still perfectly reachable.
class _DownloadOutcome {
  final bool success;
  final bool transportFailure;
  const _DownloadOutcome({required this.success, required this.transportFailure});
}

class SyncEngine {
  final SyncTransport transport;
  final Directory localHome;
  final SyncSettings settings;
  final LibraryModel library;
  final ActivityModel activity;
  final Future<int> Function(String path) freeSpace;
  final PlaylistReconciler? reconciler;
  final DateTime Function() _now;

  bool _cancelled = false;

  SyncEngine({
    required this.transport,
    required this.localHome,
    required this.settings,
    required this.library,
    required this.activity,
    required this.freeSpace,
    this.reconciler,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Stops the in-flight root after its current file finishes -- checked
  /// between files in every phase (copies/recopies, renames, deletes,
  /// sidecar copies). A root that was mid-execution when this fires reports
  /// `aborted: true, abortReason: 'cancelled'`, keeping whatever already
  /// landed; any root not yet started is simply never attempted (the caller
  /// gets back a report covering only what ran).
  void cancel() => _cancelled = true;

  Future<SyncReport> run() async {
    activity.start(ActivityIds.sync, 'Syncing');
    try {
      if (!await transport.probe()) {
        return SyncReport(
          playlistNotes: const [],
          roots: [
            RootSyncResult(
              // No real root name -- the NAS never answered, so no root was
              // even attempted. '' can't collide with an actual root
              // folder name, which is the only reason it's usable as a
              // sentinel here.
              rootName: '',
              copied: 0,
              copiedBytes: 0,
              updated: 0,
              renamed: 0,
              deleted: 0,
              adopted: 0,
              unindexedLocal: const [],
              failures: const [],
              aborted: true,
              abortReason: 'NAS unreachable',
            ),
          ],
          finishedAt: _now(),
        );
      }

      final playlistNotes = <String>[];
      final activeReconciler = reconciler;
      if (activeReconciler != null) {
        final notes = await activeReconciler.run();
        playlistNotes.addAll(notes);
        // Left deliberately unwired until this task: only a reconcile that
        // actually changed something needs the library to pick it up.
        if (notes.isNotEmpty) {
          library.reloadPlaylists();
        }
      }

      final rootNames = settings.roots.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList()
        ..sort();

      final results = <RootSyncResult>[];
      for (final rootName in rootNames) {
        results.add(await _syncRoot(rootName));
      }

      if (rootNames.isNotEmpty) {
        await library.rescan(quiet: true);
      }

      return SyncReport(
        playlistNotes: playlistNotes,
        roots: results,
        finishedAt: _now(),
      );
    } finally {
      activity.finish(ActivityIds.sync);
    }
  }

  Future<RootSyncResult> _syncRoot(String rootName) async {
    final localRootDir = Directory('${localHome.path}/$rootName');

    final manifestBytes = await transport.readFile(
      '$rootName/${core.manifestFileName}',
    );
    if (manifestBytes == null) {
      return _abortedRoot(rootName, 'remote manifest missing');
    }
    core.Manifest remoteManifest;
    try {
      remoteManifest = core.Manifest.fromJson(
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>,
      );
    } catch (e) {
      return _abortedRoot(rootName, 'remote manifest unparseable: $e');
    }

    final rawListing = await transport.listTree(rootName);
    final prefix = '$rootName/';
    final remoteListing = <core.RemoteFile>[
      for (final rf in rawListing)
        if (rf.relPath.startsWith(prefix))
          core.RemoteFile(
            relPath: rf.relPath.substring(prefix.length),
            size: rf.size,
            mtimeMs: rf.mtimeMs,
          ),
    ];
    final remoteFileByPath = {for (final rf in remoteListing) rf.relPath: rf};
    final remotePathToId = <String, String>{};
    remoteManifest.tracks.forEach((id, entry) {
      for (final path in entry.paths) {
        remotePathToId[path] = id;
      }
    });

    final localManifest = core.loadManifest(localRootDir);
    final localFiles = await _walkLocalAudioFiles(localRootDir);
    final stateFile = File(
      '${localRootDir.path}/${core.syncStateFileName}',
    );
    final state = core.SyncState.load(stateFile);

    final plan = core.planRootSync(
      remoteManifest: remoteManifest,
      remoteListing: remoteListing,
      localManifest: localManifest,
      localFiles: localFiles,
      state: state,
    );

    final free = await freeSpace(localRootDir.path);
    if (free < plan.totalBytes) {
      return RootSyncResult(
        rootName: rootName,
        copied: 0,
        copiedBytes: 0,
        updated: 0,
        renamed: 0,
        deleted: 0,
        adopted: 0,
        unindexedLocal: plan.unindexedLocal,
        failures: const [],
        aborted: true,
        abortReason:
            'insufficient free space: need ${plan.totalBytes} bytes, have $free',
      );
    }

    // Adoptions are pure bookkeeping (the file already exists locally with
    // the right content) -- record them regardless of what happens later in
    // this root, since they describe already-true state, not new work.
    var adoptedCount = 0;
    for (final path in plan.adoptions) {
      final rf = remoteFileByPath[path];
      if (rf == null) continue;
      state.entries[path] = core.SyncStateEntry(
        mtimeMs: rf.mtimeMs,
        size: rf.size,
      );
      adoptedCount++;
    }

    await _cleanSyncTmp(localRootDir);

    final failures = <SyncFailure>[];
    var copiedCount = 0;
    var copiedBytes = 0;
    var updatedCount = 0;
    var renamedCount = 0;
    var deletedCount = 0;
    var aborted = false;
    String? abortReason;
    var consecutiveTransportFailures = 0;
    var tmpIndex = 0;

    final totalOps = plan.copies.length +
        plan.recopies.length +
        plan.renames.length +
        plan.deletes.length +
        plan.sidecarCopies.length;
    var doneOps = 0;
    void reportProgress() {
      activity.progress(
        ActivityIds.sync,
        'Syncing $rootName',
        doneOps,
        totalOps,
      );
    }

    // --- copies + recopies: download, verify (size + content ID), move in.
    final downloadJobs = <(core.RemoteFile, bool isRecopy)>[
      for (final rf in plan.copies) (rf, false),
      for (final rf in plan.recopies) (rf, true),
    ];
    for (final job in downloadJobs) {
      if (_cancelled) {
        aborted = true;
        abortReason = 'cancelled';
        break;
      }
      final (rf, isRecopy) = job;
      final outcome = await _downloadAndVerify(
        rootName: rootName,
        localRootDir: localRootDir,
        remote: rf,
        index: tmpIndex++,
        expectedContentId: remotePathToId[rf.relPath],
        failures: failures,
      );
      doneOps++;
      reportProgress();
      if (outcome.success) {
        consecutiveTransportFailures = 0;
        state.entries[rf.relPath] = core.SyncStateEntry(
          mtimeMs: rf.mtimeMs,
          size: rf.size,
        );
        if (isRecopy) {
          updatedCount++;
        } else {
          copiedCount++;
          copiedBytes += rf.size;
        }
      } else if (outcome.transportFailure) {
        consecutiveTransportFailures++;
        if (consecutiveTransportFailures >= 3) {
          aborted = true;
          abortReason = 'connection lost';
          break;
        }
      }
    }

    // --- renames: local move only, never touches the transport.
    if (!aborted) {
      for (final entry in plan.renames.entries) {
        if (_cancelled) {
          aborted = true;
          abortReason = 'cancelled';
          break;
        }
        final localRel = entry.key;
        final remoteRel = entry.value;
        try {
          final src = File('${localRootDir.path}/$localRel');
          final dst = File('${localRootDir.path}/$remoteRel');
          await dst.parent.create(recursive: true);
          await _deleteIfExists(dst); // Windows rename won't overwrite
          await src.rename(dst.path);
          renamedCount++;
          state.entries.remove(localRel);
          // Keyed by the CURRENT remote listing's (mtime, size), not
          // whatever the old path's entry recorded: the file may well have
          // picked up a fresh mtime on the NAS as part of being moved, and
          // carrying the stale value forward would make the very next
          // planRootSync see a "state doesn't match remote listing"
          // mismatch and trigger a pointless recopy of a file that just got
          // here for free.
          final rf = remoteFileByPath[remoteRel];
          if (rf != null) {
            state.entries[remoteRel] = core.SyncStateEntry(
              mtimeMs: rf.mtimeMs,
              size: rf.size,
            );
          }
        } catch (e) {
          failures.add(SyncFailure(relPath: localRel, reason: 'rename failed: $e'));
        }
        doneOps++;
        reportProgress();
      }
    }

    // --- deletes: local removal of content that no longer exists remotely.
    if (!aborted) {
      for (final lp in plan.deletes) {
        if (_cancelled) {
          aborted = true;
          abortReason = 'cancelled';
          break;
        }
        try {
          final f = File('${localRootDir.path}/$lp');
          if (await f.exists()) await f.delete();
          deletedCount++;
          state.entries.remove(lp);
        } catch (e) {
          failures.add(SyncFailure(relPath: lp, reason: 'delete failed: $e'));
        }
        doneOps++;
        reportProgress();
      }
    }

    // --- sidecar copies: same download machinery, size-only verification.
    if (!aborted) {
      for (final rf in plan.sidecarCopies) {
        if (_cancelled) {
          aborted = true;
          abortReason = 'cancelled';
          break;
        }
        final outcome = await _downloadAndVerify(
          rootName: rootName,
          localRootDir: localRootDir,
          remote: rf,
          index: tmpIndex++,
          expectedContentId: null, // not content-addressed -- size check only
          failures: failures,
        );
        doneOps++;
        reportProgress();
        if (outcome.success) {
          consecutiveTransportFailures = 0;
          state.entries[rf.relPath] = core.SyncStateEntry(
            mtimeMs: rf.mtimeMs,
            size: rf.size,
          );
          copiedCount++;
          copiedBytes += rf.size;
        } else if (outcome.transportFailure) {
          consecutiveTransportFailures++;
          if (consecutiveTransportFailures >= 3) {
            aborted = true;
            abortReason = 'connection lost';
            break;
          }
        }
      }
    }

    // Sync-state records successes even when the root aborted mid-way, so a
    // re-run only re-plans what's actually missing.
    await state.save(stateFile);

    if (!aborted) {
      final acquired = await _acquireManifestWrite();
      if (!acquired) {
        failures.add(
          SyncFailure(
            relPath: core.manifestFileName,
            reason: 'manifest adopt skipped: library busy',
          ),
        );
      } else {
        try {
          await core.saveManifest(remoteManifest, localRootDir);
        } finally {
          await library.endManifestWrite();
        }
      }
    }

    return RootSyncResult(
      rootName: rootName,
      copied: copiedCount,
      copiedBytes: copiedBytes,
      updated: updatedCount,
      renamed: renamedCount,
      deleted: deletedCount,
      adopted: adoptedCount,
      unindexedLocal: plan.unindexedLocal,
      failures: failures,
      aborted: aborted,
      abortReason: abortReason,
    );
  }

  /// Downloads [remote] (root-relative) to a scratch name under
  /// `.sync_tmp/`, verifies it (size always; content ID too when
  /// [expectedContentId] is non-null), and moves it into place on success.
  /// One retry on top of the initial attempt -- covers both a genuine
  /// transport error and a verification mismatch, since either could in
  /// principle be transient. [transportFailure] on the returned outcome
  /// reflects only the LAST attempt's failure mode, which is what the
  /// caller's 3-consecutive-failures "connection lost" counter keys off of:
  /// a verification mismatch must never contribute to it, since a corrupted
  /// remote manifest entry fails identically forever and every other file
  /// in the root is still perfectly reachable.
  Future<_DownloadOutcome> _downloadAndVerify({
    required String rootName,
    required Directory localRootDir,
    required core.RemoteFile remote,
    required int index,
    required String? expectedContentId,
    required List<SyncFailure> failures,
  }) async {
    final remoteRelPath = '$rootName/${remote.relPath}';
    final tmpFile = File(
      '${localRootDir.path}/${core.syncTmpDirName}/${_tmpName(remote.relPath, index)}',
    );
    final finalFile = File('${localRootDir.path}/${remote.relPath}');

    String? failReason;
    var transportFailure = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      transportFailure = false;
      failReason = null;
      try {
        await transport.downloadToFile(remoteRelPath, tmpFile);
      } catch (e) {
        transportFailure = true;
        failReason = 'transport error: $e';
        continue;
      }

      final actualSize = await tmpFile.exists() ? await tmpFile.length() : -1;
      if (actualSize != remote.size) {
        failReason = 'size mismatch (expected ${remote.size}, got $actualSize)';
        await _deleteIfExists(tmpFile);
        continue;
      }

      if (expectedContentId != null) {
        final actualId = await core.contentIdForFile(tmpFile);
        if (actualId != expectedContentId) {
          failReason = 'content ID mismatch';
          await _deleteIfExists(tmpFile);
          continue;
        }
      }

      await finalFile.parent.create(recursive: true);
      await _deleteIfExists(finalFile); // Windows rename won't overwrite
      await tmpFile.rename(finalFile.path);
      return const _DownloadOutcome(success: true, transportFailure: false);
    }

    await _deleteIfExists(tmpFile);
    failures.add(
      SyncFailure(relPath: remote.relPath, reason: failReason ?? 'unknown failure'),
    );
    return _DownloadOutcome(success: false, transportFailure: transportFailure);
  }

  /// Polls [LibraryModel.tryBeginManifestWrite] every 100ms for up to 5s --
  /// the same retry discipline the old `PlaylistStore._acquireBusy` used
  /// against the same lock, before playlists moved to their own sidecar.
  Future<bool> _acquireManifestWrite() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!library.tryBeginManifestWrite()) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  Future<void> _cleanSyncTmp(Directory localRootDir) async {
    final dir = Directory('${localRootDir.path}/${core.syncTmpDirName}');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Every local audio file under [root], root-relative with forward
  /// slashes -- the same exclusions [core.planRootSync] itself applies to
  /// the remote side (`.sync_tmp/`, `.playlists/` are never library
  /// content), plus an audio-extension filter so a flattened `.sync_tmp`
  /// scratch name (which keeps its real extension) can never be mistaken
  /// for a real library file even if cleanup is skipped.
  Future<Set<String>> _walkLocalAudioFiles(Directory root) async {
    if (!await root.exists()) return {};
    final baseLen = root.path.length;
    final out = <String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relPath = entity.path
          .substring(baseLen)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/'), '');
      if (relPath.startsWith('${core.syncTmpDirName}/')) continue;
      if (relPath.startsWith('${core.playlistsDirName}/')) continue;
      if (!core.audioExtensions.contains(p.extension(relPath).toLowerCase())) {
        continue;
      }
      out.add(relPath);
    }
    return out;
  }

  RootSyncResult _abortedRoot(String rootName, String reason) => RootSyncResult(
    rootName: rootName,
    copied: 0,
    copiedBytes: 0,
    updated: 0,
    renamed: 0,
    deleted: 0,
    adopted: 0,
    unindexedLocal: const [],
    failures: const [],
    aborted: true,
    abortReason: reason,
  );

  static String _tmpName(String relPath, int index) =>
      '$index--${relPath.replaceAll('/', '_')}';

  static Future<void> _deleteIfExists(File f) async {
    if (await f.exists()) await f.delete();
  }
}
