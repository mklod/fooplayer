// What a metadata lookup asks for, and what it gets back.
//
// Deliberately dependency-free so the scorer, the provider and the widget
// layer can all share it -- the same discipline `artwork/album_key.dart`
// keeps, and for the same reason: two spellings of "the same recording"
// travelling through one feature is how a picker comes to propose something
// the writer never applies.
//
// Last modified: 2026-07-28--2230

/// Where a proposal came from.
enum TagSource { musicbrainz }

/// The track as it is now -- what a proposal is scored against.
class TagQuery {
  final String title;
  final String artist;
  final String album;

  /// The one field a music database can check that a human can't eyeball.
  /// Two recordings named "Intro" by the same artist are told apart by their
  /// length, not their text.
  final int? durationMs;

  const TagQuery({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.durationMs,
  });

  /// The free-text search term, when a structured query isn't available.
  String get terms => [
    artist,
    title,
  ].map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');

  bool get isEmpty => title.trim().isEmpty && artist.trim().isEmpty;
}

/// One proposed set of tags.
class TagCandidate {
  final String title;
  final String artist;
  final String album;

  /// Position on its release, when the provider gives one.
  final String trackNumber;

  final int? year;
  final int? durationMs;
  final TagSource source;

  /// The provider's id for this recording. Not shown, but it makes a
  /// candidate identifiable in a list and dedupable.
  final String id;

  const TagCandidate({
    required this.title,
    required this.artist,
    this.album = '',
    this.trackNumber = '',
    this.year,
    this.durationMs,
    this.source = TagSource.musicbrainz,
    this.id = '',
  });

  @override
  String toString() =>
      'TagCandidate($artist — $title${album.isEmpty ? "" : " [$album]"})';
}
