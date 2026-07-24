import 'dart:convert';
import 'dart:io';

/// Loads the JSON produced by tools/export_metadb.py.
/// Key: '<basename lowercase>|<size>'. Collisions keep the earliest date.
Map<String, DateTime> loadMetadbIndex(String jsonPath) {
  final j = jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, dynamic>;
  final idx = <String, DateTime>{};
  for (final r in (j['records'] as List).cast<Map<String, dynamic>>()) {
    final key = '${(r['basename'] as String).toLowerCase()}|${r['size']}';
    final created = DateTime.parse(r['created'] as String).toUtc();
    final existing = idx[key];
    if (existing == null || created.isBefore(existing)) idx[key] = created;
  }
  return idx;
}
