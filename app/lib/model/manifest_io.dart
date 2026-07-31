// Last modified: 2026-07-31--1619
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'track.dart';

class ManifestPlaylist {
  /// Merged/display name -- may carry LibraryModel's collision suffix
  /// (" (2)", " (3)", ...) when a same-named playlist collided with one
  /// already loaded, so it is NOT necessarily the name stored on disk. See
  /// [sourceName].
  final String name;
  final List<String> trackIds;

  /// The sidecar [PlaylistFile.id] this merged entry was built from (see
  /// `LibraryModel._sidecarPlaylists`) -- what [PlaylistStore] uses to
  /// address the exact file for a mutation, since [name] may be a
  /// collision-suffixed display name that exists nowhere on disk. Null only
  /// for hand-built fixtures that never went through the sidecar merge.
  final String? id;

  /// Formerly the library root whose `.library.json` this playlist lived
  /// in, back when playlists were merged per-root. Playlists now live in
  /// the single shared `.playlists/` sidecar (see [id]), so this is always
  /// null for real (merged) entries -- kept only so old hand-built fixtures
  /// still compile.
  final String? rootPath;

  /// The playlist's name as written on disk -- differs from [name] exactly
  /// when the merge had to suffix a collision. Null falls back to [name].
  final String? sourceName;

  /// Formerly this playlist's index within its owning manifest's
  /// `playlists` array. No sidecar equivalent (each playlist is its own
  /// file, addressed by [id]) -- kept only so old hand-built fixtures still
  /// compile.
  final int? sourceIndex;

  const ManifestPlaylist({
    required this.name,
    required this.trackIds,
    this.id,
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
  if (schema != 1) {
    throw FormatException('unsupported manifest schema: $schema');
  }
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
        // Straight into the first frame: a duration the manifest already
        // knows never waits on tag enrichment (see TrackEntry.durationMs).
        durationMs: (entry['duration_ms'] as num?)?.toInt(),
        title: p.basenameWithoutExtension(paths.first),
      ),
    );
  });
  final playlists = _playlistsFromJson(j);
  return ManifestData(tracks: tracks, playlists: playlists);
}

/// Parses ONLY the `playlists` section of a `.library.json` manifest --
/// shared by [loadManifestFile] above. Playlists now live in the shared
/// `.playlists/` sidecar (see `playlist_sidecar.dart`), not per-root
/// manifests, so this is purely a legacy-format reader: it still parses
/// whatever a manifest's `playlists` array happens to contain (old
/// manifests written before the sidecar migration, or hand-built fixtures).
List<ManifestPlaylist> _playlistsFromJson(Map<String, dynamic> j) =>
    (j['playlists'] as List)
        .map(
          (e) => ManifestPlaylist(
            name: (e as Map<String, dynamic>)['name'] as String,
            trackIds: (e['track_ids'] as List).cast<String>(),
          ),
        )
        .toList();
