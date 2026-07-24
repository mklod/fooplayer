import 'dart:io';
import 'dart:isolate';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;
import 'isolate_io.dart';

class TrackTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  // Playback duration in whole milliseconds, when the format's parser
  // metadata exposed one (see the per-format dispatch in `_readRawTags`
  // below); null when the file's tags/stream headers didn't carry it.
  final int? durationMs;
  const TrackTags(
      {this.title, this.artist, this.album, this.genre, this.durationMs});

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (artist == null || artist!.isEmpty) &&
      (album == null || album!.isEmpty);

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'durationMs': durationMs,
      };
  factory TrackTags.fromJson(Map<String, dynamic> j) => TrackTags(
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        genre: j['genre'] as String?,
        durationMs: j['durationMs'] as int?,
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

/// Minimal metadata pulled out of a format-specific parser: just what
/// [TrackTags] and cover art need.
class _RawTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final int? durationMs;
  final List<Picture> pictures;
  const _RawTags({
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.durationMs,
    this.pictures = const [],
  });
}

/// Reads tag data for [audioFile] without ever going through
/// `audio_metadata_reader`'s top-level `readMetadata`.
///
/// `readMetadata` (package v1.6.0, `lib/src/parser.dart`) does
/// `track.openSync()` itself and never closes that `RandomAccessFile` when
/// no container parser's `canUserParser` matches -- it falls straight
/// through to `throw NoMetadataParserException(...)` with no `finally`
/// anywhere in the function. On Windows that leaves the audio file locked
/// for the rest of the process. This app scans ~10,000 files, so that is
/// disqualifying: locked library files plus handle exhaustion.
///
/// We open the file ourselves and own the handle end-to-end: opened here,
/// closed in `finally`. Dispatch mirrors `readMetadata`'s order and its
/// per-format field mapping into `AudioMetadata` (APEv2 is checked before
/// MP3 because APEv2 can coexist with a trailing ID3v1 tag and dedicated
/// APE metadata shouldn't be shadowed by that older tag) but only for the
/// formats the package exposes as exported parsers: [ApeParser],
/// [MP3Parser], [FlacParser], [MP4Parser], [OGGParser]. Formats without an
/// exported parser (e.g. `.wav`/RIFF -- `RiffParser` is not exported from
/// `audio_metadata_reader.dart`) fall through to `null`, same effective
/// outcome as `readMetadata` throwing `NoMetadataParserException`.
///
/// Note: several of the package's own container parsers already
/// `closeSync()` the reader internally on their happy/known-error paths
/// (`MP3Parser.parse` wraps everything in `try`/`finally`; `FlacParser`,
/// `MP4Parser`, `OGGParser` close it after their main parse loop returns;
/// `ApeParser` closes it before each of its early throws and again before
/// returning). So our own `finally` below is a backstop, not always the
/// first close -- it tolerates the "already closed" `FileSystemException`
/// that a redundant `closeSync()` raises, since the invariant we actually
/// need (closed by the time we return, however it got there) still holds.
/// It's the sole close for the cases those parsers don't already cover:
/// no `canUserParser` matches at all, or an uncaught exception occurs
/// mid-parse on a malformed/truncated file in a parser that (unlike
/// `MP3Parser`) doesn't wrap its whole body in `try`/`finally`.
_RawTags? _readRawTags(File audioFile, {required bool fetchImage}) {
  final reader = audioFile.openSync();
  try {
    if (ApeParser.canUserParser(reader)) {
      final m = ApeParser(fetchImage: fetchImage).parse(reader);
      return _RawTags(
        title: m.title,
        artist: m.artist,
        album: m.album,
        genre: m.genres.firstOrNull,
        durationMs: m.duration?.inMilliseconds,
        pictures: m.pictures,
      );
    }
    if (MP3Parser.canUserParser(reader)) {
      final m = MP3Parser(fetchImage: fetchImage).parse(reader);
      return _RawTags(
        title: m.songName,
        artist: m.bandOrOrchestra ?? m.leadPerformer ?? m.originalArtist,
        album: m.album,
        genre: m.genres.firstOrNull,
        durationMs: m.duration?.inMilliseconds,
        pictures: m.pictures,
      );
    }
    if (FlacParser.canUserParser(reader)) {
      final m = FlacParser(fetchImage: fetchImage).parse(reader);
      return _RawTags(
        title: m.title.firstOrNull,
        artist: m.artist.firstOrNull,
        album: m.album.firstOrNull,
        genre: m.genres.firstOrNull,
        durationMs: m.duration?.inMilliseconds,
        pictures: m.pictures,
      );
    }
    if (MP4Parser.canUserParser(reader)) {
      final m = MP4Parser(fetchImage: fetchImage).parse(reader);
      return _RawTags(
        title: m.title,
        artist: m.artist,
        album: m.album,
        genre: m.genre,
        durationMs: m.duration?.inMilliseconds,
        pictures: m.picture == null ? const [] : [m.picture!],
      );
    }
    if (OGGParser.canUserParser(reader)) {
      final m = OGGParser(fetchImage: fetchImage).parse(reader);
      return _RawTags(
        title: m.title.firstOrNull,
        artist: m.artist.firstOrNull,
        album: m.album.firstOrNull,
        genre: m.genres.firstOrNull,
        durationMs: m.duration?.inMilliseconds,
        pictures: m.pictures,
      );
    }
    return null;
  } finally {
    try {
      reader.closeSync();
    } on FileSystemException {
      // Already closed by the container parser's own parse() above; the
      // handle is closed either way, which is the only thing we need.
    }
  }
}

Future<TrackTags> readTags(File audioFile, {String? relPath}) async {
  try {
    final raw = _readRawTags(audioFile, fetchImage: false);
    if (raw == null) return parseFromFilename(relPath ?? audioFile.path);
    final fromTags = TrackTags(
      title: _blankAsNull(raw.title),
      artist: _blankAsNull(raw.artist),
      album: _blankAsNull(raw.album),
      genre: _blankAsNull(raw.genre),
      durationMs: raw.durationMs,
    );
    if (fromTags.isEmpty) {
      // No usable title/artist/album tags, but the duration came from the
      // parsed stream headers, not the tag block -- still worth keeping
      // even though everything else falls back to the filename.
      final fb = parseFromFilename(relPath ?? audioFile.path);
      return TrackTags(
        title: fb.title,
        artist: fb.artist,
        album: fb.album,
        genre: fb.genre,
        durationMs: raw.durationMs,
      );
    }
    // Fill gaps (e.g. tagged title but no artist) from the filename.
    final fb = parseFromFilename(relPath ?? audioFile.path);
    return TrackTags(
      title: fromTags.title ?? fb.title,
      artist: fromTags.artist ?? fb.artist,
      album: fromTags.album ?? fb.album,
      genre: fromTags.genre,
      durationMs: fromTags.durationMs,
    );
  } catch (_) {
    return parseFromFilename(relPath ?? audioFile.path);
  }
}

Future<List<int>?> readArt(File audioFile) async {
  try {
    final raw = _readRawTags(audioFile, fetchImage: true);
    if (raw == null || raw.pictures.isEmpty) return null;
    return raw.pictures.first.bytes;
  } catch (_) {
    return null;
  }
}

/// Default budget for [readArtSafe] before it gives up on a single file's
/// cover art and returns null (the caller falls back to a placeholder)
/// instead of continuing to wait. Generous for any real embedded-art blob,
/// short enough that a pathological file can't reproduce the freeze this
/// function exists to prevent.
const _defaultArtTimeout = Duration(seconds: 20);

/// Isolate-safe, timeout-bounded wrapper around [readArt] -- this, not
/// [readArt] directly, is what production art loading goes through (see
/// `AlbumArt`'s default `loader` in `ui/now_playing_bar.dart`).
///
/// [readArt] is `async` in name only: there is no `await` before its call
/// into [_readRawTags], whose synchronous parse can scan byte-by-byte to
/// EOF on a file that defeats the MP3 frame-sync search (the same
/// pathology documented on `_defaultBatchTimeout` in
/// `model/library_model.dart`, for the tag-enrichment side of this same
/// bug) -- such files exist in this library. Calling [readArt] directly
/// from the UI isolate (as `AlbumArt` used to) therefore blocks the whole
/// window -- "Not Responding" -- for as long as that scan takes over the
/// SMB-mounted share: minutes, for a real file observed in production.
///
/// [readArtSafe] runs the same parse inside its own throwaway isolate via
/// [runIsolateWithTimeout] (metadata/isolate_io.dart -- the same
/// kill-capable-spawn-with-timeout machinery `LibraryModel`'s batched tag
/// enrichment uses), so a pathological file costs at most [timeout] and
/// never blocks the calling isolate at all. Returns null on timeout, on any
/// error propagated from the isolate, or when the file simply has no
/// embedded art -- callers can't tell these apart, which is fine: all three
/// mean "show the placeholder".
///
/// [relPath] is accepted for API symmetry with [readTags]/[readTagsBatch]
/// (useful to a future caller that wants it for logging) but isn't
/// otherwise used here: unlike tag reads, art has no filename-derived
/// fallback to fill in on failure.
///
/// [readArt] itself stays exported for direct use in tests (and is exactly
/// what runs inside the spawned isolate below) -- it's only *production*
/// art loading on a path that reaches the UI isolate that must go through
/// this wrapper instead.
Future<List<int>?> readArtSafe(
  File file, {
  String? relPath,
  Duration timeout = _defaultArtTimeout,
}) async {
  try {
    return await runIsolateWithTimeout<List<int>?, String>(
      _readArtIsolateEntry,
      file.path,
      timeout: timeout,
    );
  } catch (_) {
    // Timeout, isolate-spawn failure, or any error propagated from the
    // isolate -- all treated the same as readArt's own catch(_): no art,
    // fall back to the placeholder, never let a bad file surface as a
    // crash or (worse, the bug this function fixes) a UI-isolate hang.
    return null;
  }
}

void _readArtIsolateEntry((String, SendPort) args) async {
  final (path, resultPort) = args;
  List<int>? result;
  try {
    result = await readArt(File(path));
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
  Isolate.exit(resultPort, [result]);
}
