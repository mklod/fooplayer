// Last modified: 2026-07-31--1719
//
// Pure per-root sync planner: diffs a remote root's manifest + directory
// listing against the local mirror's files + manifest + sync-state to
// produce a SyncPlan (what to copy/recopy/rename/delete/adopt). No dart:io
// anywhere in `planRootSync` -- SyncState.load/save are the only I/O, kept
// on their own class so the planner itself stays trivially fixture-testable.
import 'dart:convert';
import 'dart:io';

import 'manifest.dart';
import 'playlist_sidecar.dart' show playlistsDirName;
import 'scanner.dart' show audioExtensions, hashCacheName;

/// Per-root, device-local record of each synced file's NAS mtime+size at
/// last successful copy. Lives at `.sync_state.json`.
const syncStateFileName = '.sync_state.json';

/// Scratch directory for in-flight downloads (`<root>/.sync_tmp/`); never
/// listed, never copied, never deleted-as-content -- its contents are
/// discarded and re-planned on the next run.
const syncTmpDirName = '.sync_tmp';

/// One entry from a remote directory listing (or manifest-adjacent file).
/// [relPath] is forward-slash, relative to the sync root.
class RemoteFile {
  final String relPath;
  final int size;
  final int mtimeMs;
  RemoteFile({required this.relPath, required this.size, required this.mtimeMs});
}

/// What `.sync_state.json` records for one synced relPath: the remote
/// mtime+size it was copied *from*, so a later re-plan can tell a genuine
/// remote change from local file-attribute noise.
class SyncStateEntry {
  final int mtimeMs;
  final int size;
  SyncStateEntry({required this.mtimeMs, required this.size});

  Map<String, dynamic> toJson() => {'mtimeMs': mtimeMs, 'size': size};

  static SyncStateEntry? fromJson(Map<String, dynamic> j) {
    final mtime = j['mtimeMs'];
    final size = j['size'];
    if (mtime is! num || size is! num) return null;
    return SyncStateEntry(mtimeMs: mtime.toInt(), size: size.toInt());
  }
}

/// Per-root sync-state: `relPath -> SyncStateEntry`. Tolerant load (missing
/// or corrupt file -> empty state, mirroring `_loadCache` in scanner.dart);
/// atomic save (mirroring `_atomicWrite` in playlist_sidecar.dart).
class SyncState {
  final Map<String, SyncStateEntry> entries;
  SyncState(this.entries);

  /// Tolerance is per-entry as well as whole-file: an unparseable individual
  /// entry (wrong shape, non-numeric fields) is dropped silently and its
  /// well-formed siblings are still returned, rather than one bad entry
  /// discarding the entire state -- intentional, since a single corrupt
  /// record shouldn't force every other file back through a full recopy.
  static SyncState load(File f) {
    if (!f.existsSync()) return SyncState({});
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        final raw = decoded['entries'];
        if (raw is Map<String, dynamic>) {
          final out = <String, SyncStateEntry>{};
          raw.forEach((relPath, v) {
            if (v is Map<String, dynamic>) {
              final entry = SyncStateEntry.fromJson(v);
              if (entry != null) out[relPath] = entry;
            }
          });
          return SyncState(out);
        }
      }
    } catch (_) {
      // Corrupted or invalid JSON: treat as empty state.
    }
    return SyncState({});
  }

  Future<void> save(File f) async {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    final json = {
      'schema': 1,
      'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    };
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    if (f.existsSync()) f.deleteSync(); // Windows rename won't overwrite
    tmp.renameSync(f.path);
  }
}

/// The result of `planRootSync`: what the executor (a later task) should do
/// to bring the local mirror in line with the remote root.
class SyncPlan {
  final List<RemoteFile> copies;
  final List<RemoteFile> recopies;

  /// localRelPath -> remoteRelPath.
  final Map<String, String> renames;
  final List<String> deletes;
  final List<RemoteFile> sidecarCopies;

  /// relPaths recorded into sync-state without copying (path present both
  /// sides, content IDs already match -- e.g. the tablet's hand-seeded
  /// library).
  final List<String> adoptions;

  /// Local audio files the local manifest doesn't know. Left alone,
  /// reported only -- the mirror never deletes what it never indexed.
  final List<String> unindexedLocal;

  SyncPlan({
    required this.copies,
    required this.recopies,
    required this.renames,
    required this.deletes,
    required this.sidecarCopies,
    required this.adoptions,
    required this.unindexedLocal,
  });

  int get totalBytes => [...copies, ...recopies, ...sidecarCopies]
      .fold(0, (sum, f) => sum + f.size);

  /// True when there is nothing left for the executor to do. Deliberately
  /// EXCLUDES [unindexedLocal]: those files are purely informational (left
  /// alone either way, never acted on), so a plan whose only non-empty list
  /// is "here's what's unindexed" still has nothing to execute.
  bool get isEmpty =>
      copies.isEmpty &&
      recopies.isEmpty &&
      renames.isEmpty &&
      deletes.isEmpty &&
      sidecarCopies.isEmpty &&
      adoptions.isEmpty;
}

bool _isExcluded(String relPath) {
  const exact = {
    hashCacheName,
    manifestFileName,
    manifestBakName,
    syncStateFileName,
  };
  if (exact.contains(relPath)) return true;
  if (relPath.startsWith('$syncTmpDirName/')) return true;
  if (relPath.startsWith('$playlistsDirName/')) return true;
  return false;
}

bool _isSidecar(String relPath) =>
    relPath == '.artwork.json' || relPath.startsWith('.artwork/');

String _lowerExtension(String relPath) {
  final slash = relPath.lastIndexOf('/');
  final name = slash >= 0 ? relPath.substring(slash + 1) : relPath;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '';
  return name.substring(dot).toLowerCase();
}

bool _isAudio(String relPath) =>
    audioExtensions.contains(_lowerExtension(relPath));

/// Pure per-root sync planner. See the "Music sync" section of the Plan 3
/// design spec for the full rule set; summarized:
///
/// - Remote truth = directory listing joined with the remote manifest (a
///   listed audio file the manifest doesn't know yet is skipped, not
///   copied, not an error).
/// - A remote path new to the local mirror is a **copy**, unless its
///   content ID maps to a local path that used to exist remotely and no
///   longer does -- then it's a **rename**, not a copy+delete.
/// - A path present on both sides with no sync-state entry is an
///   **adoption** (record state, no transfer) when the local and remote
///   manifests agree on its content ID; otherwise (ID mismatch, or the
///   local manifest doesn't know the path at all) it's a **recopy**. A path
///   present both sides WITH a state entry recopies only when that entry's
///   recorded (mtime, size) differs from the remote listing's -- keyed off
///   the recorded values, not current local file attributes, so an ID3
///   retag that leaves size unchanged still triggers a recopy.
/// - A local audio path whose content ID has no existing path in the
///   remote listing/manifest join is a **delete**. A local audio path the
///   local manifest doesn't know is **unindexedLocal** (never deleted).
/// - Sidecar files (`.artwork.json`, `.artwork/...`) are copied whenever
///   they're new or their sync-state entry differs -- no manifest/ID
///   involvement, since they're not content-addressed.
SyncPlan planRootSync({
  required Manifest remoteManifest,
  required List<RemoteFile> remoteListing,
  required Manifest localManifest,
  required Set<String> localFiles,
  required SyncState state,
}) {
  final remotePathToId = <String, String>{};
  remoteManifest.tracks.forEach((id, entry) {
    for (final path in entry.paths) {
      remotePathToId[path] = id;
    }
  });
  final localPathToId = <String, String>{};
  localManifest.tracks.forEach((id, entry) {
    for (final path in entry.paths) {
      localPathToId[path] = id;
    }
  });

  // Classify the remote listing, dropping explicitly-excluded entries.
  final remoteAudioPaths = <String>{};
  final remoteFileByPath = <String, RemoteFile>{};
  final sidecarFiles = <RemoteFile>[];
  for (final rf in remoteListing) {
    final path = rf.relPath;
    if (_isExcluded(path)) continue;
    remoteFileByPath[path] = rf;
    if (_isAudio(path)) {
      remoteAudioPaths.add(path);
    } else if (_isSidecar(path)) {
      sidecarFiles.add(rf);
    }
    // Anything else (neither audio, sidecar, nor excluded) is ignored --
    // the engine's listing is only ever supposed to cover those two kinds.
  }

  // "Remote truth": listing ∩ manifest. Preserves remoteListing's order.
  final remoteTruthPaths = <String>[
    for (final path in remoteAudioPaths)
      if (remotePathToId.containsKey(path)) path,
  ];
  final remoteTruthPathSet = remoteTruthPaths.toSet();
  final remoteTruthIds =
      remoteTruthPaths.map((path) => remotePathToId[path]!).toSet();

  final copies = <RemoteFile>[];
  final recopies = <RemoteFile>[];
  final renames = <String, String>{};
  final adoptions = <String>[];

  // A local rename source can only satisfy ONE remote target. When duplicate
  // content sits at multiple remote-truth paths (same ID, both absent
  // locally), only the first (by remoteListing order) claims the shared
  // local file as its rename source; every later remote path with the same
  // ID falls through to a fresh copy instead of silently vanishing from the
  // plan.
  final claimedRenameSources = <String>{};

  for (final path in remoteTruthPaths) {
    final id = remotePathToId[path]!;
    final remote = remoteFileByPath[path]!;

    if (localFiles.contains(path)) {
      // Present on both sides under the same path.
      final entry = state.entries[path];
      if (entry == null) {
        if (localPathToId[path] == id) {
          adoptions.add(path);
        } else {
          recopies.add(remote);
        }
      } else if (entry.mtimeMs != remote.mtimeMs || entry.size != remote.size) {
        recopies.add(remote);
      }
      // else: state matches the remote listing exactly -- already synced.
      continue;
    }

    // Not present locally under this exact path: either a fresh copy, or a
    // rename of a local file whose old path has fallen out of the remote
    // listing.
    String? renameSource;
    final localPathsForId = localManifest.tracks[id]?.paths;
    if (localPathsForId != null) {
      for (final lp in localPathsForId) {
        if (localFiles.contains(lp) &&
            !remoteAudioPaths.contains(lp) &&
            !claimedRenameSources.contains(lp)) {
          renameSource = lp;
          break;
        }
      }
    }
    if (renameSource != null) {
      renames[renameSource] = path;
      claimedRenameSources.add(renameSource);
    } else {
      copies.add(remote);
    }
  }

  final deletes = <String>[];
  final unindexedLocal = <String>[];
  for (final lp in localFiles) {
    if (!_isAudio(lp)) continue;
    if (renames.containsKey(lp)) continue; // handled as a rename above
    if (remoteTruthPathSet.contains(lp)) continue; // handled above already

    final id = localPathToId[lp];
    if (id == null) {
      unindexedLocal.add(lp);
    } else if (!remoteTruthIds.contains(id)) {
      deletes.add(lp);
    }
    // else: this content ID has an existing remote path (just under a
    // different local name, e.g. a duplicate copy) -- leave it alone.
  }

  final sidecarCopies = <RemoteFile>[];
  for (final rf in sidecarFiles) {
    final entry = state.entries[rf.relPath];
    if (entry == null || entry.mtimeMs != rf.mtimeMs || entry.size != rf.size) {
      sidecarCopies.add(rf);
    }
  }

  return SyncPlan(
    copies: copies,
    recopies: recopies,
    renames: renames,
    deletes: deletes,
    sidecarCopies: sidecarCopies,
    adoptions: adoptions,
    unindexedLocal: unindexedLocal,
  );
}
