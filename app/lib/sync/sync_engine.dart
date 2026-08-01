// Last modified: 2026-07-31--1853
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

/// The result of one [SyncEngine._downloadAndVerify] attempt: whether the
/// file ended up correctly in place, and -- when it didn't -- whether the
/// failure happened at the transport level (vs. a verification mismatch or
/// an unexpected local filesystem error). Distinguishes "the network
/// dropped" from "the file that landed is wrong", since only the former
/// counts toward the 3-consecutive-failures "connection lost" abort. A
/// corrupted remote manifest entry must never trip that abort: it fails the
/// same way every retry, forever, and the other files in the root are all
/// still perfectly reachable.
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
    // A fresh run always starts un-cancelled -- otherwise an engine that
    // gets reused (or a stray cancel() called before run() even started)
    // would report every subsequent root as 'cancelled' forever.
    _cancelled = false;
    activity.start(ActivityIds.sync, 'Syncing');
    try {
      bool reachable;
      try {
        reachable = await transport.probe();
      } catch (_) {
        // A probe that throws is exactly as unreachable as one that
        // returns false -- never let it escape run() as an exception.
        reachable = false;
      }
      if (!reachable) {
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
        // Only a reconcile that actually changed something needs the
        // library to pick it up.
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
        // Once cancelled, a root already in flight finishes aborting itself
        // (checked between its own files); every root that hasn't STARTED
        // yet is simply never attempted -- no network round-trip, no
        // manifest touch -- matching cancel()'s doc above.
        if (_cancelled) break;
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

    // Captured as soon as sync-state has been loaded, so the catch-all
    // below can still persist whatever succeeded before an unexpected
    // exception -- an SMB drop mid-listTree, a corrupt local manifest with
    // no usable .bak, a disk error on the final rename -- turns THIS root
    // into an abort rather than taking the whole run() down with it.
    core.SyncState? stateForRecovery;
    File? stateFileForRecovery;

    try {
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

      // core.loadManifest deliberately rethrows a TypeError (not a
      // FormatException) when the local .library.json is valid JSON but the
      // wrong shape (e.g. `tracks` stored as a list) and there's no .bak to
      // fall back to -- a real, documented data-corruption signal (first
      // sync / hand-seeded / tampered root; saveManifest only starts
      // rotating a .bak after the first successful local write). That's not
      // a programming bug, so the outer `on Exception` catch-all below must
      // not be the only thing standing between it and taking down the whole
      // run() -- catch it here, specifically, before it can ever reach that
      // net.
      core.Manifest localManifest;
      try {
        localManifest = core.loadManifest(localRootDir);
      } on TypeError catch (e) {
        return _abortedRoot(rootName, 'local manifest unreadable: $e');
      }
      final localFiles = await _walkLocalAudioFiles(localRootDir);
      final stateFile = File(
        '${localRootDir.path}/${core.syncStateFileName}',
      );
      final state = core.SyncState.load(stateFile);
      stateForRecovery = state;
      stateFileForRecovery = stateFile;

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
            // Carry the REMOVED old path's own recorded entry forward,
            // falling back to the current listing's (mtime, size) only when
            // there was none to carry (e.g. a path sync-state never tracked).
            // Content IDs hash the audio range only (ID3/APE tags excluded
            // for mp3/flac), so a file can be moved AND retagged in the same
            // NAS session while still planning as a pure rename here. If we
            // stamped the new entry from the CURRENT (post-retag) listing,
            // the state would trivially "match" that listing forever and the
            // tag divergence would never be noticed by a later run. Carrying
            // the OLD (pre-retag) entry forward preserves the mismatch, so
            // the very next planRootSync recopies it once seen. For a PURE
            // move (no retag), the old entry's (mtime, size) already equal
            // the new listing's -- rename-only doesn't touch file bytes --
            // so carrying it forward is exactly as inert as re-deriving it
            // would have been, with no pointless recopy either way.
            final oldEntry = state.entries.remove(localRel);
            if (oldEntry != null) {
              state.entries[remoteRel] = oldEntry;
            } else {
              final rf = remoteFileByPath[remoteRel];
              if (rf != null) {
                state.entries[remoteRel] = core.SyncStateEntry(
                  mtimeMs: rf.mtimeMs,
                  size: rf.size,
                );
              }
            }
          } catch (e) {
            failures.add(
              SyncFailure(relPath: localRel, reason: 'rename failed: $e'),
            );
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
            final existed = await f.exists();
            if (existed) {
              await f.delete();
              deletedCount++;
            }
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
            expectedContentId: null, // not content-addressed -- size only
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

      // Sync-state records successes even when the root aborted mid-way, so
      // a re-run only re-plans what's actually missing.
      //
      // From here on, a failure is recorded as a SyncFailure rather than
      // left to reach the outer catch-all below: every counter above this
      // point reflects real, already-completed file-level work, and an
      // outer catch has no way to recover those values (it only knows how
      // to build a zeroed abort) -- so a bookkeeping error here (a full
      // disk on the state-file write, endManifestWrite() throwing while
      // draining a queued load()) must not discard a root that actually
      // succeeded into a false "aborted, nothing happened" report.
      try {
        await state.save(stateFile);
      } on Exception catch (e) {
        failures.add(
          SyncFailure(
            relPath: core.syncStateFileName,
            reason: 'state save failed: $e',
          ),
        );
      }

      if (!aborted) {
        try {
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
            } on Exception catch (e) {
              // The file sync work is done; only the manifest replacement
              // failed -- report it as a failure, not a whole-root abort.
              failures.add(
                SyncFailure(
                  relPath: core.manifestFileName,
                  reason: 'manifest adopt failed: $e',
                ),
              );
            } finally {
              await library.endManifestWrite();
            }
          }
        } on Exception catch (e) {
          // Covers _acquireManifestWrite() itself throwing, or
          // endManifestWrite() throwing from the finally above (reachable
          // if it drains a queued load() that fails) -- either way, the
          // real sync counts below must survive.
          failures.add(
            SyncFailure(
              relPath: core.manifestFileName,
              reason: 'manifest adopt failed: $e',
            ),
          );
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
    } on Exception catch (e) {
      // Last-resort net for anything not already turned into a per-file
      // SyncFailure or a specific early abort above -- a throwing listTree,
      // a syntactically-invalid local manifest with no usable .bak (the
      // shape-but-not-syntax corruption case is caught specifically at the
      // loadManifest call above, since it rethrows a TypeError, not an
      // Exception), an unexpected filesystem error during planning. This
      // root aborts; the run as a whole (and any other root in it) does not.
      //
      // Deliberately `on Exception`, not a bare `catch`: an `Error`
      // (TypeError, a null check, RangeError -- a genuine bug, not an
      // environmental failure like a dropped connection or a corrupt file)
      // must never be silently reported as just another "sync failed,
      // try again" abort. Letting it propagate is what makes it visible
      // enough to actually get fixed.
      //
      // This Error-vs-Exception policy is deliberately applied ONLY at this
      // outer boundary (and the loadManifest TypeError catch above, which
      // exists for the same "documented corruption signal, not a bug"
      // reason). The inner per-item catches throughout this method (rename,
      // delete, and the two inside _downloadAndVerify) stay bare `catch`
      // ON PURPOSE: those convert EVERYTHING -- Error included -- into a
      // per-file SyncFailure and keep going, because a single file's local
      // I/O quirk (a locked file, a transient rename race) must never take
      // the rest of the root down with it. Only this top-level boundary
      // (where the alternative is silently reporting a real bug as routine)
      // draws the Exception/Error line.
      final state = stateForRecovery;
      final stateFile = stateFileForRecovery;
      if (state != null && stateFile != null) {
        try {
          await state.save(stateFile);
        } on Exception catch (_) {
          // Truly nothing more to do -- the abort result below still
          // stands.
        }
      }
      return _abortedRoot(rootName, 'unexpected error: $e');
    }
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

      // Everything past this point is local filesystem work (stat, hash,
      // create-dir, delete, rename) -- the download itself already
      // succeeded, so nothing here should ever count toward "connection
      // lost". A verification mismatch is expected to be caught by the
      // explicit checks below; an unexpected local I/O error (a locked
      // file, a race, a disk error mid-rename) is caught here instead of
      // escaping this method entirely and taking the whole root down with
      // it -- treated exactly like a verification mismatch: retry once,
      // then record a per-file failure and move on.
      try {
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
      } catch (e) {
        failReason = 'verify/move failed: $e';
        await _deleteIfExists(tmpFile);
        continue;
      }
    }

    try {
      await _deleteIfExists(tmpFile);
    } catch (_) {
      // Best-effort cleanup only -- a leftover scratch file is swept up by
      // the next run's .sync_tmp cleanup regardless.
    }
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
