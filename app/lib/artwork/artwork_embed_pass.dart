// Writing the artwork fooplayer found into the files themselves, in bulk.
//
// Covers have lived in a per-root sidecar, which means nothing outside this
// app -- foobar2000, Kodi, Explorer thumbnails, a phone's stock player -- can
// see them. This pass copies each sidecar choice into its tracks' own tags
// (ID3v2 APIC for mp3, a PICTURE block for FLAC).
//
// THE TWO THINGS THIS MUST NEVER DO, both enforced per file by
// `tag_embed_io.dart` and re-checked here:
//
//   1. change a track's content ID -- that is the manifest key, and a changed
//      one silently resets the track's date-added;
//   2. change a file's modified/created dates -- as of 2026-07-28 those ARE
//      the "date downloaded", re-derived from the manifest across the whole
//      library.
//
// A file that can't satisfy both is left untouched, and [EmbedPassReport]
// says so rather than the pass quietly moving on.
//
// Last modified: 2026-07-28--0140

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../model/track.dart';
import 'album_key.dart';
import 'artwork_store.dart';
import 'tag_embed_io.dart';

/// What a pass did, in enough detail to explain any file it skipped.
class EmbedPassReport {
  /// Covers written into files.
  final int embedded;

  /// Files deliberately left alone (not mp3/flac, no art to write, already
  /// carrying that art, or refused by the safety checks).
  final int skipped;

  /// Files where writing was attempted and failed; the original is intact.
  final int failed;

  /// Files whose timestamps did NOT come back as they went in. Should always
  /// be zero -- it is called out separately because it is the one outcome
  /// that would quietly damage the library's dates.
  final int datesDisturbed;

  /// Reason -> count, for the skipped/failed files.
  final Map<String, int> reasons;

  /// Paths whose dates were disturbed, so the caller can name them.
  final List<String> disturbedPaths;

  /// Content IDs of the tracks actually written, so the caller can correct
  /// the cached "carries embedded art" flag without re-reading every file
  /// in the library to discover what this pass already knows.
  final List<String> embeddedIds;

  const EmbedPassReport({
    this.embedded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.datesDisturbed = 0,
    this.reasons = const {},
    this.disturbedPaths = const [],
    this.embeddedIds = const [],
  });

  int get considered => embedded + skipped + failed;

  /// One line for the UI.
  String get summary {
    final parts = <String>['$embedded embedded'];
    if (skipped > 0) parts.add('$skipped skipped');
    if (failed > 0) parts.add('$failed failed');
    if (datesDisturbed > 0) parts.add('$datesDisturbed WITH DATE CHANGES');
    return parts.join(', ');
  }
}

/// Formats supporting embedded cover art here. Anything else is skipped --
/// notably `.m4a`, whose content ID hashes the whole file, so embedding
/// anything into one would change its identity.
const Set<String> kEmbeddableExtensions = {'.mp3', '.flac'};

/// Runs the bulk embed. Construct one per pass; [run] is not re-entrant.
class ArtworkEmbedPass {
  final ArtworkStoreRegistry stores;

  /// Reads the cover chosen for an album key. Injected so tests never touch
  /// a real sidecar.
  final Future<List<int>?> Function(String rootPath, String albumKey)
  readAlbumImage;

  /// Writes one file. Injected for the same reason; production is
  /// [embedCover], which is where the identity and date guarantees live.
  final Future<EmbedReport> Function(File file, Uint8List image) embed;

  ArtworkEmbedPass({
    required this.stores,
    Future<List<int>?> Function(String rootPath, String albumKey)?
    readAlbumImage,
    Future<EmbedReport> Function(File file, Uint8List image)? embed,
  }) : readAlbumImage =
           readAlbumImage ??
           ((rootPath, albumKey) =>
               stores.forRoot(rootPath).readImage(albumKey)),
       embed = embed ?? embedCover;

  bool _cancelled = false;

  /// Asks the pass to stop after the file in flight.
  void cancel() => _cancelled = true;

  /// Embeds the sidecar's chosen cover into every track in [tracks] that can
  /// safely take it.
  ///
  /// [onProgress] is called with (done, total) as each file is finished.
  /// Album images are read once per album, not once per track.
  Future<EmbedPassReport> run(
    List<Track> tracks, {
    void Function(int done, int total)? onProgress,
  }) async {
    _cancelled = false;
    var embedded = 0, skipped = 0, failed = 0, datesDisturbed = 0;
    final reasons = <String, int>{};
    final disturbed = <String>[];
    final embeddedIds = <String>[];
    final imageCache = <String, List<int>?>{};

    void note(String reason) => reasons[reason] = (reasons[reason] ?? 0) + 1;

    var done = 0;
    for (final track in tracks) {
      if (_cancelled) {
        note('cancelled');
        break;
      }
      done++;
      onProgress?.call(done, tracks.length);

      if (!kEmbeddableExtensions.contains(
        p.extension(track.relPath).toLowerCase(),
      )) {
        skipped++;
        note('format cannot carry embedded art');
        continue;
      }

      final albumKey = artworkAlbumKey(
        artist: track.artist,
        album: track.album,
        title: track.title,
        rootPath: track.rootPath,
        relPath: track.relPath,
      );
      final cacheKey = '${track.rootPath}\x00$albumKey';
      final image = imageCache.containsKey(cacheKey)
          ? imageCache[cacheKey]
          : imageCache[cacheKey] = await _readImageSafe(
              track.rootPath,
              albumKey,
            );

      if (image == null || image.isEmpty) {
        skipped++;
        note('no artwork chosen for this album');
        continue;
      }

      final file = File(p.join(track.rootPath, track.relPath));
      final EmbedReport report;
      try {
        report = await embed(file, Uint8List.fromList(image));
      } catch (e) {
        failed++;
        note('write threw: $e');
        continue;
      }

      switch (report.outcome) {
        case EmbedOutcome.embedded:
          embedded++;
          embeddedIds.add(track.contentId);
          // The engine restores and re-reads all three timestamps; this is
          // the pass refusing to treat a date-losing write as a success.
          if (!report.timesPreserved) {
            datesDisturbed++;
            disturbed.add(file.path);
          }
        case EmbedOutcome.refused:
          skipped++;
          note(report.reason.isEmpty ? 'refused' : report.reason);
        case EmbedOutcome.failed:
          failed++;
          note(report.reason.isEmpty ? 'failed' : report.reason);
      }
    }

    return EmbedPassReport(
      embedded: embedded,
      skipped: skipped,
      failed: failed,
      datesDisturbed: datesDisturbed,
      reasons: reasons,
      disturbedPaths: disturbed,
      embeddedIds: embeddedIds,
    );
  }

  Future<List<int>?> _readImageSafe(String rootPath, String albumKey) async {
    try {
      return await readAlbumImage(rootPath, albumKey);
    } catch (_) {
      // An unreadable sidecar means "no art for this album", never a crash
      // mid-pass.
      return null;
    }
  }
}
