import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'track.dart';

class ManifestPlaylist {
  final String name;
  final List<String> trackIds;
  const ManifestPlaylist({required this.name, required this.trackIds});
}

class ManifestData {
  final List<Track> tracks;
  final List<ManifestPlaylist> playlists;
  const ManifestData({required this.tracks, required this.playlists});
}

/// Parses a `.library.json` manifest, stamping every [Track] it produces
/// with [rootPath] -- the library root this particular manifest lives in --
/// so downstream path resolution (`p.join(track.rootPath, track.relPath)`)
/// works without a separately-threaded "which root was this from" value.
ManifestData loadManifestFile(File f, {required String rootPath}) {
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final schema = j['schema'] as int;
  if (schema != 1) throw FormatException('unsupported manifest schema: $schema');
  final tracks = <Track>[];
  (j['tracks'] as Map<String, dynamic>).forEach((id, v) {
    final entry = v as Map<String, dynamic>;
    final paths = (entry['paths'] as List).cast<String>();
    tracks.add(Track(
      contentId: id,
      relPath: paths.first,
      rootPath: rootPath,
      dateAdded: DateTime.parse(entry['date_added'] as String).toUtc(),
      title: p.basenameWithoutExtension(paths.first),
    ));
  });
  final playlists = (j['playlists'] as List)
      .map((e) => ManifestPlaylist(
            name: (e as Map<String, dynamic>)['name'] as String,
            trackIds: (e['track_ids'] as List).cast<String>(),
          ))
      .toList();
  return ManifestData(tracks: tracks, playlists: playlists);
}
