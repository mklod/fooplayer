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

  const Track({
    required this.contentId,
    required this.relPath,
    this.rootPath = '',
    required this.dateAdded,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
  });

  Track copyWith({String? title, String? artist, String? album, String? genre}) =>
      Track(
        contentId: contentId,
        relPath: relPath,
        rootPath: rootPath,
        dateAdded: dateAdded,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        genre: genre ?? this.genre,
      );
}
