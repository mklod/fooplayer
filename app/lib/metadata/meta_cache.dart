import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'tags.dart';

class MetaCache {
  final Map<String, TrackTags> entries;
  MetaCache._(this.entries);

  factory MetaCache.load(File f) {
    if (!f.existsSync()) return MetaCache._({});
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map<String, dynamic>) return MetaCache._({});
      return MetaCache._(j.map(
          (k, v) => MapEntry(k, TrackTags.fromJson(v as Map<String, dynamic>))));
    } catch (_) {
      return MetaCache._({});
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    await f.writeAsString(
        jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson()))));
  }
}

Future<List<Track>> fillMetadata(
  List<Track> tracks,
  Directory libraryRoot,
  MetaCache cache, {
  void Function(int done, int total)? onProgress,
}) async {
  final out = <Track>[];
  var done = 0;
  for (final t in tracks) {
    TrackTags? tags = cache.entries[t.contentId];
    if (tags == null) {
      final file = File(p.join(libraryRoot.path, t.relPath));
      tags = file.existsSync()
          ? await readTags(file, relPath: t.relPath)
          : parseFromFilename(t.relPath);
      cache.entries[t.contentId] = tags;
    }
    out.add(t.copyWith(
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      genre: tags.genre,
    ));
    onProgress?.call(++done, tracks.length);
  }
  return out;
}

/// Reads tags for a batch of tracks given as plain `(contentId, absPath,
/// relPath)` records rather than [Track]/[File]/[Directory] instances, so
/// the input is cheap to send across an isolate boundary.
///
/// This is what [LibraryModel.load]'s background enrichment runs inside
/// `Isolate.run` per batch: the synchronous, SMB-bound tag reading happens
/// off the calling isolate, and only the plain-value records go in and the
/// resulting `contentId -> TrackTags` map (a sendable value type) comes
/// back. It's also directly callable on the main isolate, e.g. in tests.
Future<Map<String, TrackTags>> readTagsBatch(
    List<(String, String, String)> records) async {
  final out = <String, TrackTags>{};
  for (final (contentId, absPath, relPath) in records) {
    final file = File(absPath);
    out[contentId] = file.existsSync()
        ? await readTags(file, relPath: relPath)
        : parseFromFilename(relPath);
  }
  return out;
}
