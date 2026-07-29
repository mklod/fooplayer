import 'dart:io';

import 'package:path/path.dart' as p;

import 'manifest.dart';
import 'scanner.dart';

class LibraryDiff {
  final List<ScannedTrack> newTracks; // content IDs not in manifest (one per ID)
  final Map<String, List<String>> movedOrRetagged; // id → new paths, when path set changed
  final List<String> missingTrackIds; // in manifest, no file on disk
  final Map<String, List<String>> duplicates; // id → paths, when a scan ID has >1 path
  LibraryDiff(this.newTracks, this.movedOrRetagged, this.missingTrackIds, this.duplicates);

  bool get isEmpty =>
      newTracks.isEmpty && movedOrRetagged.isEmpty && missingTrackIds.isEmpty;
}

Map<String, List<String>> _pathsById(List<ScannedTrack> scan) {
  final byId = <String, List<String>>{};
  for (final t in scan) {
    byId.putIfAbsent(t.contentId, () => []).add(t.relPath);
  }
  for (final paths in byId.values) {
    paths.sort();
  }
  return byId;
}

LibraryDiff diffAgainstManifest(Manifest m, List<ScannedTrack> scan) {
  final byId = _pathsById(scan);

  final newTracks = <ScannedTrack>[];
  final seenNew = <String>{};
  for (final t in scan) {
    if (!m.tracks.containsKey(t.contentId) && seenNew.add(t.contentId)) {
      newTracks.add(t);
    }
  }

  final moved = <String, List<String>>{};
  for (final e in m.tracks.entries) {
    final current = byId[e.key];
    if (current != null && current.join('\n') != (List.of(e.value.paths)..sort()).join('\n')) {
      moved[e.key] = current;
    }
  }

  final missing =
      m.tracks.keys.where((id) => !byId.containsKey(id)).toList()..sort();
  final duplicates = <String, List<String>>{
    for (final e in byId.entries)
      if (e.value.length > 1) e.key: e.value,
  };
  return LibraryDiff(newTracks, moved, missing, duplicates);
}

void applyDiff(
  Manifest m,
  LibraryDiff d,
  List<ScannedTrack> scan,
  DateTime Function() now,
) {
  final byId = _pathsById(scan);
  for (final t in d.newTracks) {
    m.tracks[t.contentId] = TrackEntry(
      dateAdded: now().toUtc().toIso8601String(),
      paths: byId[t.contentId]!,
    );
  }
  for (final id in d.movedOrRetagged.keys) {
    m.tracks[id]!.paths = byId[id]!;
  }
  // Missing entries: retained untouched — hidden by consumers, never deleted here.
}

/// Download dates already recorded by manifests living inside [root].
///
/// A file's own timestamps are not a source of truth for when it was
/// downloaded: copying a folder to a phone, restoring a backup, or unzipping
/// an archive stamps every file with today. The manifest is the only record
/// that survives that, which is why it travels with the music.
///
/// So seeding a folder that already contains `.library.json` files — a parent
/// placed above roots that were seeded separately, or a whole collection
/// copied to another device — has to take their dates instead of minting new
/// ones. Without this, "set up this folder" silently resets the entire
/// library to the day you set it up.
///
/// Keyed by content ID, so it holds across renames and retagging. When two
/// manifests disagree the EARLIEST date wins: a track owned since 2020 is not
/// newer because a later copy of it was catalogued in 2026. Durations are
/// carried too — they cost a slow tag read to recover and nothing to keep.
///
/// Unreadable folders and corrupt manifests are skipped, never fatal: the
/// worst case is the date this could not find, which is where seeding
/// started from anyway.
Map<String, TrackEntry> knownEntriesWithin(Directory root) {
  final known = <String, TrackEntry>{};
  for (final dir in _dirsHoldingAManifest(root)) {
    final Manifest m;
    try {
      m = loadManifest(dir);
    } catch (_) {
      continue; // corrupt beyond its own .bak — nothing to adopt here
    }
    for (final e in m.tracks.entries) {
      final existing = known[e.key];
      if (existing == null) {
        known[e.key] = TrackEntry(
          dateAdded: e.value.dateAdded,
          paths: const [],
          durationMs: e.value.durationMs,
        );
        continue;
      }
      if (e.value.dateAdded.compareTo(existing.dateAdded) < 0) {
        existing.dateAdded = e.value.dateAdded;
      }
      existing.durationMs ??= e.value.durationMs;
    }
  }
  return known;
}

Iterable<Directory> _dirsHoldingAManifest(Directory root) sync* {
  final stack = <Directory>[root];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue; // no permission, vanished mid-walk
    }
    var holds = false;
    for (final e in entries) {
      if (e is Directory) {
        stack.add(e);
        continue;
      }
      final name = p.basename(e.path);
      if (name == manifestFileName || name == manifestBakName) holds = true;
    }
    if (holds) yield dir;
  }
}

/// Replaces minted dates with ones [known] already had.
///
/// Applied after [applyDiff], so every track has an entry to correct. Only
/// the date and a missing duration are taken; paths belong to the manifest
/// being written, not to the one being adopted from.
///
/// [onlyIds] restricts it to specific tracks. A rescan passes the ones it
/// just minted a date for: the root manifest is the authority for everything
/// it already knew, and a background tick has no business rewriting dates
/// that were not in question.
void adoptKnownDates(
  Manifest m,
  Map<String, TrackEntry> known, {
  Iterable<String>? onlyIds,
}) {
  final ids = onlyIds == null ? m.tracks.keys.toList() : onlyIds.toList();
  for (final id in ids) {
    final entry = m.tracks[id];
    final was = known[id];
    if (entry == null || was == null) continue;
    entry.dateAdded = was.dateAdded;
    entry.durationMs ??= was.durationMs;
  }
}
