// Last modified: 2026-07-31--1529
//
// The playlist sidecar: one JSON file per playlist in <library home>/.playlists/,
// membership by content ID. Tolerant parse (artwork-sidecar discipline, NOT the
// manifest's strict throw): a corrupt file degrades to "skipped + reported".
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const playlistsDirName = '.playlists';
const playlistTombstonesFileName = 'tombstones.json';
const playlistBackupDirName = 'backup';

class PlaylistFile {
  final String id;
  String name;
  List<String> trackIds;
  DateTime created;   // sidebar sort order: "the order I made them"
  DateTime modified;  // UTC; the LWW clock
  String modifiedBy;  // device label, for the report ("kept tablet's version")

  PlaylistFile({required this.id, required this.name, required this.trackIds,
      required this.created, required this.modified, required this.modifiedBy});

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'id': id,
        'name': name,
        'track_ids': trackIds,
        'created': created.toUtc().toIso8601String(),
        'modified': modified.toUtc().toIso8601String(),
        'modified_by': modifiedBy,
      };

  /// Tolerant: null on anything unusable. Unknown keys ignored; missing
  /// `created` falls back to `modified` (older writers).
  static PlaylistFile? fromJson(Map<String, dynamic> j) {
    final id = j['id'], name = j['name'], ids = j['track_ids'];
    if (id is! String || id.isEmpty || name is! String || ids is! List) {
      return null;
    }
    DateTime? parseTime(Object? v) {
      if (v is! String) return null;
      try {
        return DateTime.parse(v).toUtc();
      } catch (_) {
        return null;
      }
    }
    final modified = parseTime(j['modified']);
    if (modified == null) return null;
    return PlaylistFile(
      id: id,
      name: name,
      trackIds: ids.whereType<String>().toList(),
      created: parseTime(j['created']) ?? modified,
      modified: modified,
      modifiedBy: j['modified_by'] is String ? j['modified_by'] as String : '',
    );
  }

  /// Same user-visible content: name + ordered membership. Timestamps and
  /// authorship excluded — two devices writing the identical edit should
  /// reconcile to "nothing to do", not to a copy.
  bool sameContentAs(PlaylistFile other) {
    if (name != other.name || trackIds.length != other.trackIds.length) {
      return false;
    }
    for (var i = 0; i < trackIds.length; i++) {
      if (trackIds[i] != other.trackIds[i]) return false;
    }
    return true;
  }
}

class PlaylistTombstone {
  final DateTime deleted; // UTC
  final String name;      // for the report; the file is gone by then
  PlaylistTombstone({required this.deleted, required this.name});

  Map<String, dynamic> toJson() =>
      {'deleted': deleted.toUtc().toIso8601String(), 'name': name};

  static PlaylistTombstone? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final del = j['deleted'];
    if (del is! String) return null;
    final DateTime deleted;
    try {
      deleted = DateTime.parse(del).toUtc();
    } catch (_) {
      return null;
    }
    return PlaylistTombstone(deleted: deleted, name: name is String ? name : '');
  }
}

class PlaylistSidecarState {
  final Map<String, PlaylistFile> playlists;      // by id
  final Map<String, PlaylistTombstone> tombstones; // by id
  final List<String> corruptFiles;                 // basenames, for the report
  PlaylistSidecarState(this.playlists, this.tombstones, this.corruptFiles);
}

Directory _dirIn(Directory home) => Directory('${home.path}/$playlistsDirName');

/// Tolerant load of `<home>/.playlists/`: missing dir → empty state; a corrupt
/// playlist or tombstones file is skipped and listed in [corruptFiles].
PlaylistSidecarState loadPlaylistsDir(Directory home) {
  final dir = _dirIn(home);
  final playlists = <String, PlaylistFile>{};
  final corrupt = <String>[];
  var tombstones = <String, PlaylistTombstone>{};
  if (!dir.existsSync()) {
    return PlaylistSidecarState(playlists, tombstones, corrupt);
  }
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File || !e.path.endsWith('.json')) continue;
    final base = e.uri.pathSegments.last;
    if (base == playlistTombstonesFileName) {
      tombstones = _loadTombstones(e, corrupt);
      continue;
    }
    if (base.endsWith('.tmp')) continue;
    PlaylistFile? p;
    try {
      final j = jsonDecode(e.readAsStringSync());
      if (j is Map<String, dynamic>) p = PlaylistFile.fromJson(j);
    } catch (_) {}
    if (p == null) {
      corrupt.add(base);
    } else {
      playlists[p.id] = p;
    }
  }
  return PlaylistSidecarState(playlists, tombstones, corrupt);
}

Map<String, PlaylistTombstone> _loadTombstones(File f, List<String> corrupt) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    final raw = (j as Map<String, dynamic>)['tombstones'];
    if (raw is Map<String, dynamic>) {
      final out = <String, PlaylistTombstone>{};
      raw.forEach((id, v) {
        if (v is Map<String, dynamic>) {
          final t = PlaylistTombstone.fromJson(v);
          if (t != null) out[id] = t;
        }
      });
      return out;
    }
  } catch (_) {}
  corrupt.add(playlistTombstonesFileName);
  return {};
}

Future<void> _atomicWrite(File target, String content) async {
  target.parent.createSync(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(content);
  if (target.existsSync()) target.deleteSync(); // Windows rename won't overwrite
  tmp.renameSync(target.path);
}

Future<void> savePlaylistFile(Directory home, PlaylistFile p) => _atomicWrite(
    File('${_dirIn(home).path}/${p.id}.json'),
    const JsonEncoder.withIndent('  ').convert(p.toJson()));

Future<void> saveTombstones(
        Directory home, Map<String, PlaylistTombstone> t) =>
    _atomicWrite(
        File('${_dirIn(home).path}/$playlistTombstonesFileName'),
        const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'tombstones': t.map((k, v) => MapEntry(k, v.toJson())),
        }));

/// `backup/<id>--YYYYMMDD-HHMMSS.json` — the LWW loser / deleted playlist.
Future<void> backupPlaylistFile(
    Directory home, PlaylistFile p, DateTime now) async {
  final u = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${u.year}${two(u.month)}${two(u.day)}'
      '-${two(u.hour)}${two(u.minute)}${two(u.second)}';
  await _atomicWrite(
      File('${_dirIn(home).path}/$playlistBackupDirName/${p.id}--$stamp.json'),
      const JsonEncoder.withIndent('  ').convert(p.toJson()));
}

Future<void> removePlaylistFile(Directory home, String id) async {
  final f = File('${_dirIn(home).path}/$id.json');
  if (f.existsSync()) f.deleteSync();
}

String newPlaylistId([Random? rng]) {
  final r = rng ?? Random.secure();
  return 'p_${List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join()}';
}
