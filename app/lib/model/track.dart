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

  /// Whether the file itself carries a cover -- drives the library view's
  /// "embedded" column. Filled from the tag cache, never probed per row.
  final bool hasEmbeddedArt;

  /// Whether this track belongs to a compilation -- many different artists
  /// filed under one album title.
  ///
  /// Not a tag: measured across this library 2026-07-28, 312 of 400 sampled
  /// compilation tracks carry no album-artist frame and NOT ONE carries the
  /// compilation flag, so the file cannot answer the question. It is inferred
  /// from the group instead (see `artwork/compilation.dart`) and stamped here
  /// so every consumer of a track agrees -- the picker, the resolver, the
  /// harvest and the embed pass must all file a cover under the same name or
  /// one of them looks up something another never wrote.
  final bool isCompilation;

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
    this.hasEmbeddedArt = false,
    this.isCompilation = false,
  });

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    String? genre,
    int? durationMs,
    int? trackNumber,
    bool? hasEmbeddedArt,
    bool? isCompilation,
  }) => Track(
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
    hasEmbeddedArt: hasEmbeddedArt ?? this.hasEmbeddedArt,
    isCompilation: isCompilation ?? this.isCompilation,
  );
}
