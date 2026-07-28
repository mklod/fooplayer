import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'track.dart';

class ManifestPlaylist {
  /// Merged/display name -- may carry LibraryModel's collision suffix
  /// (" (2)", " (3)", ...) when a same-named playlist was already taken by
  /// an earlier root, so it is NOT necessarily the name stored in any
  /// manifest file. See [sourceName].
  final String name;
  final List<String> trackIds;

  /// The library root whose `.library.json` this playlist actually lives in
  /// -- the merge step (LibraryModel `_loadBody`/`reloadPlaylists`) stamps
  /// it so PlaylistStore can tell first-root playlists (editable) apart
  /// from ones owned by another root (mutations blocked with a clear
  /// message). Null only for hand-built fixtures that never went through
  /// the merge.
  final String? rootPath;

  /// The playlist's name as written inside its owning manifest file --
  /// differs from [name] exactly when the merge had to suffix a collision.
  /// Null falls back to [name] (see PlaylistStore).
  final String? sourceName;

  /// Index of this playlist within its owning manifest's `playlists` array
  /// at merge time -- lets PlaylistStore address the exact entry even when
  /// one manifest holds several same-named playlists. Null for fixtures.
  final int? sourceIndex;

  const ManifestPlaylist({
    required this.name,
    required this.trackIds,
    this.rootPath,
    this.sourceName,
    this.sourceIndex,
  });
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
  if (schema != 1)
    throw FormatException('unsupported manifest schema: $schema');
  final tracks = <Track>[];
  (j['tracks'] as Map<String, dynamic>).forEach((id, v) {
    final entry = v as Map<String, dynamic>;
    final paths = (entry['paths'] as List).cast<String>();
    tracks.add(
      Track(
        contentId: id,
        relPath: paths.first,
        rootPath: rootPath,
        dateAdded: DateTime.parse(entry['date_added'] as String).toUtc(),
        title: p.basenameWithoutExtension(paths.first),
      ),
    );
  });
  final playlists = _playlistsFromJson(j);
  return ManifestData(tracks: tracks, playlists: playlists);
}

/// Parses ONLY the `playlists` section of a `.library.json` manifest --
/// the lightweight read [LibraryModel.reloadPlaylists] uses after a
/// PlaylistStore mutation, where re-materializing every [Track] (the
/// expensive part of [loadManifestFile] for a large library) would be
/// wasted work. Throws the same [FormatException]/[TypeError]s
/// [loadManifestFile] does on a corrupt/wrong-schema file.
List<ManifestPlaylist> loadManifestPlaylistsFile(File f) {
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final schema = j['schema'] as int;
  if (schema != 1)
    throw FormatException('unsupported manifest schema: $schema');
  return _playlistsFromJson(j);
}

List<ManifestPlaylist> _playlistsFromJson(Map<String, dynamic> j) =>
    (j['playlists'] as List)
        .map(
          (e) => ManifestPlaylist(
            name: (e as Map<String, dynamic>)['name'] as String,
            trackIds: (e['track_ids'] as List).cast<String>(),
          ),
        )
        .toList();
