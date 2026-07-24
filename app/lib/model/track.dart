class Track {
  final String contentId;
  final String relPath; // forward slashes, relative to rootPath
  // The library root this track was loaded from. All on-disk path
  // resolution app-wide is `p.join(track.rootPath, track.relPath)` -- this
  // is what makes multi-root libraries (Task 4) work: two tracks with the
  // same relPath under different roots don't collide, and nothing needs a
  // separately-threaded "which root is this?" parameter once it has a
  // Track in hand. Defaults to '' so fixtures/tests that don't care about
  // real file resolution (most of them) don't need to set it.
  final String rootPath;
  final DateTime dateAdded;
  final String title;
  final String artist;
  final String album;
  final String genre;
  // Playback duration in whole milliseconds, from TrackTags.durationMs (see
  // metadata/tags.dart); null when the file's tags/stream headers didn't
  // carry a duration, or before enrichment has read the file yet.
  final int? durationMs;
  // 1-based position within its album, from TrackTags.trackNumber (see
  // metadata/tags.dart); null when neither the file's tags nor its filename
  // carried one, or before enrichment/instant-feed parsing has run yet.
  final int? trackNumber;

  const Track({
    required this.contentId,
    required this.relPath,
    this.rootPath = '',
    required this.dateAdded,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
    this.durationMs,
    this.trackNumber,
  });

  Track copyWith(
          {String? title,
          String? artist,
          String? album,
          String? genre,
          int? durationMs,
          int? trackNumber}) =>
      Track(
        contentId: contentId,
        relPath: relPath,
        rootPath: rootPath,
        dateAdded: dateAdded,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        genre: genre ?? this.genre,
        durationMs: durationMs ?? this.durationMs,
        trackNumber: trackNumber ?? this.trackNumber,
      );
}
