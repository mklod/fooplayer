import 'dart:convert';
import 'dart:io';

/// Parsed + migrated `config.json` contents (on-disk schema v2:
/// `{"libraryRoots": [...], "ui": {...}}`).
///
/// [raw] holds every key from the file verbatim -- including ones this
/// version of the app doesn't otherwise interpret (e.g. `"ui"`, or a future
/// key added by a newer build) -- so re-serializing via [toJson] never
/// silently drops data this function doesn't itself own.
class AppConfig {
  final List<String> libraryRoots;
  final Map<String, dynamic> raw;

  AppConfig({required this.libraryRoots, required this.raw});

  /// Serializes back to the v2 on-disk shape: [raw] (already carrying every
  /// preserved key, with `libraryRoots` set below) layered with the current
  /// `libraryRoots`.
  Map<String, dynamic> toJson() => {
        ...raw,
        'libraryRoots': libraryRoots,
      };
}

/// Reads and parses [file] as a JSON object.
///
/// - Missing file: returns `{}` (first run).
/// - Corrupt file (invalid JSON, or valid JSON that isn't a top-level
///   object): the broken contents are preserved by copying them to
///   `<file>.bad` next to it -- so a hand-edited or half-written
///   config.json is never silently discarded the next time the app writes
///   a fresh one -- and `{}` is returned so the app can start fresh in
///   memory instead of crashing.
Map<String, dynamic> readConfigFile(File file) {
  if (!file.existsSync()) return {};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {
    // Falls through to the backup-and-reset path below.
  }
  _backupCorrupt(file);
  return {};
}

void _backupCorrupt(File file) {
  try {
    file.copySync('${file.path}.bad');
  } catch (_) {
    // Best-effort: a failed backup still shouldn't crash the app over a
    // corrupt config file -- it just means this particular bad copy of it
    // isn't preserved.
  }
}

/// Migrates a raw config map (as returned by [readConfigFile]) to schema
/// v2's `"libraryRoots"` list:
///
/// - already-v2 (`"libraryRoots": [...]` non-empty) configs pass through
///   unchanged;
/// - v1's singular `"libraryRoot"` string is promoted to a one-element
///   list;
/// - a first-run/empty config defaults to `[defaultRoot]`.
///
/// The old singular `"libraryRoot"` key is dropped from the returned
/// [AppConfig.raw] and `"libraryRoots"` is (re)written into it; every other
/// key in [config] -- notably `"ui"` -- is carried over untouched, so a
/// caller that persists [AppConfig.toJson] afterward never loses data this
/// function doesn't itself own. [config] itself is not mutated.
AppConfig migrateConfig(Map<String, dynamic> config,
    {required String defaultRoot}) {
  final migrated = Map<String, dynamic>.of(config);

  List<String>? roots;
  final v2 = migrated['libraryRoots'];
  if (v2 is List) {
    final list = v2.whereType<String>().where((s) => s.isNotEmpty).toList();
    if (list.isNotEmpty) roots = list;
  }
  if (roots == null) {
    final singular = migrated['libraryRoot'];
    roots = (singular is String && singular.isNotEmpty)
        ? [singular]
        : [defaultRoot];
  }

  migrated.remove('libraryRoot');
  migrated['libraryRoots'] = roots;
  return AppConfig(libraryRoots: roots, raw: migrated);
}

/// True when [config] (the raw, pre-[migrateConfig] map) needs to be
/// written back to disk to persist the v1->v2 migration -- i.e. it either
/// had no `"libraryRoots"` yet, or it still carries the old singular
/// `"libraryRoot"` key that [migrateConfig] drops. Idempotent: an
/// already-v2 config with no leftover v1 key returns `false`, so a normal
/// launch doesn't rewrite config.json every time.
bool needsMigrationWrite(Map<String, dynamic> config) =>
    !config.containsKey('libraryRoots') || config.containsKey('libraryRoot');
