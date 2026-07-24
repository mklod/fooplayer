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
