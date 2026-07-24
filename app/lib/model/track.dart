class Track {
  final String contentId;
  final String relPath; // forward slashes, relative to library root
  final DateTime dateAdded;
  final String title;
  final String artist;
  final String album;
  final String genre;

  const Track({
    required this.contentId,
    required this.relPath,
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
        dateAdded: dateAdded,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        genre: genre ?? this.genre,
      );
}
