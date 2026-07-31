// Last modified: 2026-07-31--1535
//
// Pure whole-playlist LWW between two sidecar states. Produces actions; the
// app-side executor does the I/O. Never touches disk itself.
import 'playlist_sidecar.dart';

enum PlaylistSyncOp {
  copyToLocal, copyToRemote,
  deleteLocal, deleteRemote,
  tombstoneToLocal, tombstoneToRemote,
}

class PlaylistSyncAction {
  final PlaylistSyncOp op;
  final String id;
  /// Snapshot the about-to-be-overwritten/deleted side to backup/ first.
  final bool backupFirst;
  /// Human-readable report line ("kept tablet's version of roadtrip ...").
  final String note;
  PlaylistSyncAction(this.op, this.id,
      {this.backupFirst = false, this.note = ''});
}

List<PlaylistSyncAction> reconcilePlaylists(
  PlaylistSidecarState local,
  PlaylistSidecarState remote, {
  required String localLabel,
  required String remoteLabel,
}) {
  final actions = <PlaylistSyncAction>[];
  final ids = <String>{
    ...local.playlists.keys, ...remote.playlists.keys,
    ...local.tombstones.keys, ...remote.tombstones.keys,
  };
  for (final id in ids) {
    final lp = local.playlists[id], rp = remote.playlists[id];
    final lt = local.tombstones[id], rt = remote.tombstones[id];
    // A tombstone only counts against a playlist it postdates; an older
    // tombstone under a re-edited playlist is stale and ignored.
    final localDead = lp == null
        ? lt != null
        : (lt != null && !lt.deleted.isBefore(lp.modified));
    final remoteDead = rp == null
        ? rt != null
        : (rt != null && !rt.deleted.isBefore(rp.modified));

    if (!localDead && lp != null && !remoteDead && rp != null) {
      if (lp.sameContentAs(rp)) continue; // converged, however it happened
      if (lp.modified.isAfter(rp.modified)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToRemote, id,
            backupFirst: true,
            note: 'kept $localLabel\'s version of "${lp.name}"; '
                '$remoteLabel\'s is in backup'));
      } else if (rp.modified.isAfter(lp.modified)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            backupFirst: true,
            note: 'kept $remoteLabel\'s version of "${rp.name}"; '
                '$localLabel\'s is in backup'));
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            backupFirst: true,
            note: 'same timestamp, different content for "${rp.name}" — '
                '$remoteLabel wins (deterministic); $localLabel\'s is in backup'));
      }
      continue;
    }

    if (!localDead && lp != null) {
      // Live locally; remote is dead or absent.
      final tomb = rt ?? lt;
      if (tomb != null && !lp.modified.isAfter(tomb.deleted)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.deleteLocal, id,
            backupFirst: true,
            note: 'deleted "${lp.name}" (removed on $remoteLabel); '
                'copy kept in backup'));
        if (rt != null && (lt == null || rt.deleted.isAfter(lt.deleted))) {
          actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToLocal, id));
        }
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToRemote, id,
            note: tomb == null
                ? 'new playlist "${lp.name}" from $localLabel'
                : 'restored "${lp.name}" — edited on $localLabel after deletion'));
      }
      continue;
    }

    if (!remoteDead && rp != null) {
      final tomb = lt ?? rt;
      if (tomb != null && !rp.modified.isAfter(tomb.deleted)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.deleteRemote, id,
            backupFirst: true,
            note: 'deleted "${rp.name}" on $remoteLabel (removed on $localLabel); '
                'copy kept in backup'));
        if (lt != null && (rt == null || lt.deleted.isAfter(rt.deleted))) {
          actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToRemote, id));
        }
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            note: tomb == null
                ? 'new playlist "${rp.name}" from $remoteLabel'
                : 'restored "${rp.name}" — edited on $remoteLabel after deletion'));
      }
      continue;
    }

    // Dead (or tombstone-only) on both sides: converge tombstones newest-first.
    if (lt != null && (rt == null || lt.deleted.isAfter(rt.deleted))) {
      actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToRemote, id));
    } else if (rt != null && (lt == null || rt.deleted.isAfter(lt.deleted))) {
      actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToLocal, id));
    }
  }
  return actions;
}
