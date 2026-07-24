import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'content_id.dart';

const hashCacheName = '.hash_cache.json';
const audioExtensions = {'.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav'};

class ScannedTrack {
  final String relPath;
  final int size;
  final DateTime mtime;
  final String contentId;
  ScannedTrack(this.relPath, this.size, this.mtime, this.contentId);
}

Future<List<ScannedTrack>> scanLibrary(
  Directory root, {
  void Function(int done, int total)? onProgress,
}) async {
  final cacheFile = File('${root.path}/$hashCacheName');
  final cache = _loadCache(cacheFile);

  final files = <File>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (p.basename(e.path).startsWith('.')) continue;
    if (!audioExtensions.contains(p.extension(e.path).toLowerCase())) continue;
    files.add(e);
  }

  final tracks = <ScannedTrack>[];
  final newCache = <String, dynamic>{};
  var done = 0;
  for (final f in files) {
    final rel = p.relative(f.path, from: root.path).replaceAll('\\', '/');
    final stat = f.statSync();
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final cached = cache[rel];
    final String id;
    if (cached != null && _isCacheHit(cached, stat.size, mtimeMs)) {
      id = cached['id'] as String;
    } else {
      id = await contentIdForFile(f);
    }
    newCache[rel] = {'size': stat.size, 'mtimeMs': mtimeMs, 'id': id};
    tracks.add(ScannedTrack(rel, stat.size, stat.modified, id));
    onProgress?.call(++done, files.length);
  }

  cacheFile.writeAsStringSync(jsonEncode(newCache));
  tracks.sort((a, b) => a.relPath.compareTo(b.relPath));
  return tracks;
}

Map<String, dynamic> _loadCache(File cacheFile) {
  if (!cacheFile.existsSync()) {
    return <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(cacheFile.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (e) {
    // Corrupted or invalid JSON: treat as empty cache
  }
  return <String, dynamic>{};
}

bool _isCacheHit(dynamic cached, int fileSize, int mtimeMs) {
  if (cached is! Map<String, dynamic>) return false;
  return cached['size'] == fileSize &&
      cached['mtimeMs'] == mtimeMs &&
      cached['id'] is String;
}
