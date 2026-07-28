// Album artwork candidate value type + the provenance vocabulary shared by
// the providers, the scorer and the `.artwork.json` sidecar.
//
// Last modified: 2026-07-25--2113

/// Where a piece of artwork came from.
///
/// [id] is the *wire* spelling used in the `.artwork.json` sidecar's
/// `"source"` field, so the sidecar stays human-readable and stable even if
/// this enum is reordered. Always serialise with [id] / deserialise with
/// [ArtSource.fromId] -- never `Enum.name`/`Enum.index`.
enum ArtSource {
  /// iTunes Search API (keyless).
  itunes('itunes'),

  /// Deezer public search API (keyless).
  deezer('deezer'),

  /// Cover Art Archive, found via a MusicBrainz release-group lookup.
  caa('caa'),

  /// A file the user picked off their own disk.
  local('local'),

  /// A URL the user pasted.
  url('url'),

  /// Art embedded in the audio file's own tags.
  embedded('embedded');

  const ArtSource(this.id);

  /// Stable wire spelling (see the enum doc).
  final String id;

  /// Parses a sidecar `"source"` value; returns null for anything unknown so
  /// a sidecar written by a future version degrades instead of throwing.
  static ArtSource? fromId(String? id) {
    for (final s in ArtSource.values) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Human-facing label for the picker's source chip.
  String get label => switch (this) {
    ArtSource.itunes => 'iTunes',
    ArtSource.deezer => 'Deezer',
    ArtSource.caa => 'Cover Art Archive',
    ArtSource.local => 'Local file',
    ArtSource.url => 'URL',
    ArtSource.embedded => 'Embedded',
  };
}

/// What we are looking artwork up for: one album, identified by whatever the
/// local tags say.
///
/// Lives beside [ArtCandidate] (rather than in `providers.dart`) so the pure
/// scorer can depend on it without dragging in the HTTP layer.
class ArtQuery {
  final String artist;
  final String album;

  const ArtQuery({this.artist = '', this.album = ''});

  /// Free-text search term for providers that take one ("artist album").
  String get term => '${artist.trim()} ${album.trim()}'.trim();

  /// Nothing to search on -- providers short-circuit to `[]`.
  bool get isEmpty => term.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ArtQuery && other.artist == artist && other.album == album;

  @override
  int get hashCode => Object.hash(artist, album);

  @override
  String toString() => 'ArtQuery("$artist" / "$album")';
}

/// One piece of candidate album art, normalized across providers.
///
/// [url] is the best (largest) image the provider offers; [thumbUrl] is a
/// small variant suitable for a picker grid (it falls back to [url] when a
/// provider has no separate thumbnail). Neither is fetched here -- these are
/// plain values, safe to send across an isolate boundary and cheap to cache.
class ArtCandidate {
  /// Full-size image URL.
  final String url;

  /// Small preview URL for grids; never null (defaults to [url]).
  final String thumbUrl;

  /// Which provider produced this candidate.
  final ArtSource source;

  /// Album/release title as reported by the provider (already trimmed, but
  /// NOT normalized -- normalization is the scorer's job so the picker can
  /// still show the provider's own spelling).
  final String title;

  /// Artist/credit as reported by the provider.
  final String artist;

  /// Release year when the provider exposed one.
  final int? year;

  /// Pixel width of the image at [url] when known (providers publish fixed
  /// sizes, so this is derived from the URL we build rather than measured).
  final int? width;

  const ArtCandidate({
    required this.url,
    required this.source,
    required this.title,
    required this.artist,
    String? thumbUrl,
    this.year,
    this.width,
  }) : thumbUrl = thumbUrl ?? url;

  /// Sidecar-facing spelling of [source]; convenience for storage code that
  /// would otherwise reach for `candidate.source.id`.
  String get sourceId => source.id;

  ArtCandidate copyWith({
    String? url,
    String? thumbUrl,
    ArtSource? source,
    String? title,
    String? artist,
    int? year,
    int? width,
  }) => ArtCandidate(
    url: url ?? this.url,
    thumbUrl: thumbUrl ?? this.thumbUrl,
    source: source ?? this.source,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    year: year ?? this.year,
    width: width ?? this.width,
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'thumbUrl': thumbUrl,
    'source': source.id,
    'title': title,
    'artist': artist,
    'year': year,
    'width': width,
  };

  /// Tolerant inverse of [toJson]; returns null when the payload is not a
  /// usable candidate (no URL, unknown source) so callers can just filter.
  static ArtCandidate? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    final source = ArtSource.fromId(json['source'] as String?);
    if (source == null) return null;
    final thumb = json['thumbUrl'];
    final year = json['year'];
    final width = json['width'];
    return ArtCandidate(
      url: url,
      thumbUrl: thumb is String && thumb.isNotEmpty ? thumb : url,
      source: source,
      title: json['title'] is String ? json['title'] as String : '',
      artist: json['artist'] is String ? json['artist'] as String : '',
      year: year is int ? year : null,
      width: width is int ? width : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ArtCandidate &&
      other.url == url &&
      other.thumbUrl == thumbUrl &&
      other.source == source &&
      other.title == title &&
      other.artist == artist &&
      other.year == year &&
      other.width == width;

  @override
  int get hashCode =>
      Object.hash(url, thumbUrl, source, title, artist, year, width);

  @override
  String toString() =>
      'ArtCandidate(${source.id}, "$artist" / "$title", ${width ?? '?'}px, $url)';
}
