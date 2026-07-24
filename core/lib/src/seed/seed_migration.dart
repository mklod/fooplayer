import 'package:path/path.dart' as p;
import '../manifest.dart';
import '../scanner.dart';

class SeedResult {
  final Manifest manifest;
  final int fromMetadb;
  final int fromCtime;
  final int duplicateGroups;
  final List<String> report;
  SeedResult(this.manifest, this.fromMetadb, this.fromCtime, this.duplicateGroups,
      this.report);
}

SeedResult buildSeedManifest({
  required List<ScannedTrack> scan,
  required Map<String, DateTime> metadb,
  required DateTime Function(String relPath) ctimeOf,
}) {
  final m = Manifest.empty();
  var fromMetadb = 0;
  var fromCtime = 0;

  // Resolve a date per scanned file, then reduce per content ID (earliest wins).
  final dates = <String, DateTime>{}; // content ID → earliest date
  final paths = <String, List<String>>{};
  for (final t in scan) {
    final key = '${p.basename(t.relPath).toLowerCase()}|${t.size}';
    final DateTime date;
    if (metadb.containsKey(key)) {
      date = metadb[key]!;
      fromMetadb++;
    } else {
      date = ctimeOf(t.relPath).toUtc();
      fromCtime++;
    }
    final prev = dates[t.contentId];
    if (prev == null || date.isBefore(prev)) dates[t.contentId] = date;
    paths.putIfAbsent(t.contentId, () => []).add(t.relPath);
  }

  var duplicateGroups = 0;
  for (final id in dates.keys) {
    final ps = paths[id]!..sort();
    if (ps.length > 1) duplicateGroups++;
    m.tracks[id] = TrackEntry(dateAdded: dates[id]!.toIso8601String(), paths: ps);
  }

  final sorted = m.tracks.entries.toList()
    ..sort((a, b) => a.value.dateAdded.compareTo(b.value.dateAdded));
  String line(MapEntry<String, TrackEntry> e) =>
      '  ${e.value.dateAdded}  ${e.value.paths.first}';
  final report = <String>[
    'tracks: ${m.tracks.length}',
    'from metadb: $fromMetadb',
    'from ctime: $fromCtime',
    'duplicate groups: $duplicateGroups',
    'oldest:',
    ...sorted.take(10).map(line),
    'newest:',
    ...sorted.reversed.take(10).map(line),
  ];
  return SeedResult(m, fromMetadb, fromCtime, duplicateGroups, report);
}
