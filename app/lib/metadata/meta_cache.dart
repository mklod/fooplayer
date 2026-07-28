import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'tags.dart';

/// Bumped whenever `readTags` changes what it EXTRACTS from a file, as
/// opposed to gaining a new field (that case is handled by the missing-key
/// eviction in [MetaCache.load]). Entries written by an older revision are
/// dropped on load so every affected track is re-read once.
///
/// rev 2 (2026-07-27): artist now reads TPE1 (lead performer) before TPE2
/// (band/album artist). 359 files in this library had them differ -- mostly
/// compilation tracks cached as "Various Artists" -- and those cached values
/// would otherwise survive the fix indefinitely.
const int kMetaCacheRevision = 2;

class MetaCache {
  final Map<String, TrackTags> entries;
  MetaCache._(this.entries);

  factory MetaCache.load(File f) {
    if (!f.existsSync()) return MetaCache._({});
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map<String, dynamic>) return MetaCache._({});
      final entries = <String, TrackTags>{};
      for (final entry in j.entries) {
        final v = entry.value;
        if (v is! Map<String, dynamic>) continue;
        // Entries written before durationMs (or, later, trackNumber)
        // existed lack the key entirely (as opposed to carrying it with a
        // null value, which means a format whose parser genuinely found
        // none). Those pre-existing entries are deliberately left out of
        // the loaded cache so every caller's normal cache-miss path
        // (`cache.entries[id] == null`) re-reads the file and backfills the
        // new field -- instead of needing its own separate staleness check.
        if (!v.containsKey('durationMs')) continue;
        if (!v.containsKey('trackNumber')) continue;
        // Same idea as the missing-key checks above, but for a change in how
        // an EXISTING field is read -- see [kMetaCacheRevision].
        if (v['rev'] != kMetaCacheRevision) continue;
        entries[entry.key] = TrackTags.fromJson(v);
      }
      return MetaCache._(entries);
    } catch (_) {
      return MetaCache._({});
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode(
        entries.map(
          (k, v) => MapEntry(k, {...v.toJson(), 'rev': kMetaCacheRevision}),
        ),
      ),
    );
  }
}

/// True when [tags] -- an existing cache *hit* for a track at [relPath] --
/// still deserves one more look for a duration, because it was cached
/// before `readTags` grew the `mp3_duration.dart` stream-header fallback
/// (or by a path that never needed it, e.g. a non-mp3 format). Re-reading
/// such an entry is a one-time cost: [readTags] always sets
/// [TrackTags.durationProbed] to true after attempting the fallback,
/// whether or not it actually found a duration, so a file whose audio
/// stream genuinely can't be measured doesn't get re-probed on every future
/// load forever -- only once, right after upgrading to this feature (or
/// after a scan that, for whatever reason, produced a still-probed-false
/// null-duration mp3 entry).
///
/// Deliberately narrower than the durationMs/trackNumber staleness checks
/// in [MetaCache.load] (which evict *any* entry missing those keys
/// entirely): gating on [tags.durationMs] being null here means a healthy
/// majority of a real library -- every non-mp3 track, and every mp3 whose
/// duration the tag parser already found directly -- is completely
/// unaffected by this rollout, rather than the whole cache invalidating in
/// one shot.
bool needsDurationProbe(TrackTags tags, String relPath) =>
    tags.durationMs == null && !tags.durationProbed && isMp3Path(relPath);

/// Resolves each track's file via its own [Track.rootPath] (multi-root
/// libraries can mix tracks from different roots in a single list), rather
/// than a single library-wide root directory.
Future<List<Track>> fillMetadata(
  List<Track> tracks,
  MetaCache cache, {
  void Function(int done, int total)? onProgress,
}) async {
  final out = <Track>[];
  var done = 0;
  for (final t in tracks) {
    TrackTags? tags = cache.entries[t.contentId];
    if (tags == null) {
      final file = File(p.join(t.rootPath, t.relPath));
      tags = file.existsSync()
          ? await readTags(file, relPath: t.relPath)
          : parseFromFilename(t.relPath);
      cache.entries[t.contentId] = tags;
    } else if (needsDurationProbe(tags, t.relPath)) {
      // A cache hit, but one worth a one-time re-read for a duration (see
      // [needsDurationProbe]). Only actually re-reads when the file is
      // still there -- otherwise there's nothing to probe, and keeping the
      // existing (already-enriched) cached tags beats discarding real
      // title/artist/album for a filename-derived placeholder.
      final file = File(p.join(t.rootPath, t.relPath));
      if (file.existsSync()) {
        tags = await readTags(file, relPath: t.relPath);
        cache.entries[t.contentId] = tags;
      }
    }
    out.add(
      t.copyWith(
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        genre: tags.genre,
        durationMs: tags.durationMs,
        trackNumber: tags.trackNumber,
      ),
    );
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
  List<(String, String, String)> records,
) async {
  final out = <String, TrackTags>{};
  for (final (contentId, absPath, relPath) in records) {
    final file = File(absPath);
    out[contentId] = file.existsSync()
        ? await readTags(file, relPath: relPath)
        : parseFromFilename(relPath);
  }
  return out;
}
