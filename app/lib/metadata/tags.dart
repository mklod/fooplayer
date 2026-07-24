import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:path/path.dart' as p;

class TrackTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  const TrackTags({this.title, this.artist, this.album, this.genre});

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (artist == null || artist!.isEmpty) &&
      (album == null || album!.isEmpty);

  Map<String, dynamic> toJson() =>
      {'title': title, 'artist': artist, 'album': album, 'genre': genre};
  factory TrackTags.fromJson(Map<String, dynamic> j) => TrackTags(
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        genre: j['genre'] as String?,
      );
}

TrackTags parseFromFilename(String relPath) {
  final base = p.basenameWithoutExtension(relPath);
  final dir = p.dirname(relPath);
  final album = (dir == '.' || dir.isEmpty) ? null : p.basename(dir);
  final sep = base.indexOf(' - ');
  if (sep < 0) return TrackTags(title: base, album: album);
  return TrackTags(
    artist: base.substring(0, sep).trim(),
    title: base.substring(sep + 3).trim(),
    album: album,
  );
}

String? _blankAsNull(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

Future<TrackTags> readTags(File audioFile) async {
  try {
    final meta = amr.readMetadata(audioFile, getImage: false);
    final fromTags = TrackTags(
      title: _blankAsNull(meta.title),
      artist: _blankAsNull(meta.artist),
      album: _blankAsNull(meta.album),
      genre: _blankAsNull(meta.genres.isEmpty ? null : meta.genres.first),
    );
    if (fromTags.isEmpty) return parseFromFilename(audioFile.path);
    // Fill gaps (e.g. tagged title but no artist) from the filename.
    final fb = parseFromFilename(audioFile.path);
    return TrackTags(
      title: fromTags.title ?? fb.title,
      artist: fromTags.artist ?? fb.artist,
      album: fromTags.album ?? fb.album,
      genre: fromTags.genre,
    );
  } catch (_) {
    return parseFromFilename(audioFile.path);
  }
}

Future<List<int>?> readArt(File audioFile) async {
  try {
    final meta = amr.readMetadata(audioFile, getImage: true);
    if (meta.pictures.isEmpty) return null;
    return meta.pictures.first.bytes;
  } catch (_) {
    return null;
  }
}
