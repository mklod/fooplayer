import 'dart:convert';
import 'dart:io';

const manifestFileName = '.library.json';
const manifestBakName = '.library.json.bak';

class TrackEntry {
  String dateAdded; // ISO 8601 UTC
  List<String> paths; // relative to library root, forward slashes
  TrackEntry({required this.dateAdded, required this.paths});

  Map<String, dynamic> toJson() => {'date_added': dateAdded, 'paths': paths};
  factory TrackEntry.fromJson(Map<String, dynamic> j) => TrackEntry(
        dateAdded: j['date_added'] as String,
        paths: (j['paths'] as List).cast<String>(),
      );
}

class Playlist {
  String name;
  List<String> trackIds;
  Playlist({required this.name, required this.trackIds});

  Map<String, dynamic> toJson() => {'name': name, 'track_ids': trackIds};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        name: j['name'] as String,
        trackIds: (j['track_ids'] as List).cast<String>(),
      );
}

class Manifest {
  int schema;
  Map<String, TrackEntry> tracks; // key: content ID
  List<Playlist> playlists;
  Manifest({required this.schema, required this.tracks, required this.playlists});

  Manifest.empty() : this(schema: 1, tracks: {}, playlists: []);

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
        'playlists': playlists.map((p) => p.toJson()).toList(),
      };

  factory Manifest.fromJson(Map<String, dynamic> j) {
    final schema = j['schema'] as int;
    if (schema != 1) throw FormatException('unsupported manifest schema: $schema');
    return Manifest(
      schema: schema,
      tracks: (j['tracks'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, TrackEntry.fromJson(v as Map<String, dynamic>))),
      playlists: (j['playlists'] as List)
          .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Atomic save: write .tmp, move current file to .bak, rename .tmp into place.
Future<void> saveManifest(Manifest m, Directory libraryRoot) async {
  final main = File('${libraryRoot.path}/$manifestFileName');
  final tmp = File('${libraryRoot.path}/$manifestFileName.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(m.toJson()));
  if (main.existsSync()) {
    final bak = File('${libraryRoot.path}/$manifestBakName');
    if (bak.existsSync()) bak.deleteSync();
    main.renameSync(bak.path);
  }
  tmp.renameSync(main.path);
}

Manifest _parse(File f) =>
    Manifest.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);

Manifest loadManifest(Directory libraryRoot) {
  final main = File('${libraryRoot.path}/$manifestFileName');
  final bak = File('${libraryRoot.path}/$manifestBakName');
  if (!main.existsSync() && !bak.existsSync()) return Manifest.empty();
  if (main.existsSync()) {
    try {
      return _parse(main);
    } on FormatException {
      if (!bak.existsSync()) rethrow;
    }
  }
  return _parse(bak);
}
