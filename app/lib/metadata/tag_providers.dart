// Asking MusicBrainz what a recording actually is.
//
// Recordings, not release-groups: the artwork lookup wants an album to fetch
// a cover for, this wants the track's own title, artist, length and where it
// sits on a release. Same host, same terms of use, so it goes through the
// SAME rate limiter and User-Agent the artwork providers use -- one request
// per second is a condition of using the service, not a tuning knob, and two
// independent limiters would quietly break it.
//
// Every failure degrades to "no proposals". A metadata lookup that throws
// into the UI would be worse than one that finds nothing.
//
// Last modified: 2026-07-28--2230

import 'dart:convert';

import '../artwork/providers.dart'
    show
        ArtFetch,
        ArtHttpResponse,
        RateLimitPriority,
        RateLimiter,
        httpArtFetch,
        kArtworkUserAgent,
        musicBrainzArtistCredit,
        musicBrainzLimiter;
import 'tag_candidate.dart';

/// Lucene special characters, escaped so a title containing them can't break
/// the query (or, worse, change what it means).
String _escapeLucene(String s) =>
    s.replaceAllMapped(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), (m) => '\\${m[0]}');

Uri musicBrainzRecordingUri(TagQuery q, {int limit = 12}) {
  final title = _escapeLucene(q.title.trim());
  final artist = _escapeLucene(q.artist.trim());
  final lucene = [
    if (title.isNotEmpty) 'recording:"$title"',
    if (artist.isNotEmpty) 'artist:"$artist"',
  ].join(' AND ');
  return Uri.https('musicbrainz.org', '/ws/2/recording', {
    'query': lucene.isEmpty ? q.terms : lucene,
    'fmt': 'json',
    'limit': '$limit',
  });
}

int? _year(Object? date) {
  if (date is! String || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// Turns one MusicBrainz recording into candidates -- one per release it
/// appears on, because the album and track number differ per release and
/// those are exactly the fields being corrected.
List<TagCandidate> _candidatesFrom(Map<String, dynamic> recording) {
  final id = recording['id'];
  final title = recording['title'];
  if (id is! String || title is! String || title.isEmpty) {
    return const <TagCandidate>[];
  }
  final artist = musicBrainzArtistCredit(recording['artist-credit']);
  final length = recording['length'];
  final durationMs = length is int ? length : null;

  final releases = recording['releases'];
  if (releases is! List || releases.isEmpty) {
    return [
      TagCandidate(
        id: id,
        title: title,
        artist: artist,
        durationMs: durationMs,
      ),
    ];
  }

  final out = <TagCandidate>[];
  for (final r in releases) {
    if (r is! Map<String, dynamic>) continue;
    var trackNumber = '';
    final media = r['media'];
    if (media is List && media.isNotEmpty) {
      final first = media.first;
      if (first is Map<String, dynamic>) {
        final tracks = first['track'];
        if (tracks is List && tracks.isNotEmpty) {
          final t = tracks.first;
          if (t is Map<String, dynamic> && t['number'] != null) {
            trackNumber = '${t['number']}';
          }
        }
      }
    }
    out.add(
      TagCandidate(
        id: id,
        title: title,
        artist: artist,
        album: r['title'] is String ? r['title'] as String : '',
        trackNumber: trackNumber,
        year: _year(r['date']),
        durationMs: durationMs,
      ),
    );
  }
  return out;
}

/// Searches MusicBrainz for recordings matching [q].
///
/// Returns `[]` on any failure -- a bad status, malformed JSON, a timeout, a
/// thrown socket. Nothing here is allowed to reach the UI as an exception.
Future<List<TagCandidate>> searchMusicBrainzRecordings(
  TagQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 12,
  RateLimiter? limiter,
  RateLimitPriority priority = RateLimitPriority.interactive,
}) async {
  if (q.isEmpty) return const <TagCandidate>[];
  try {
    final ArtHttpResponse res = await (limiter ?? musicBrainzLimiter).schedule(
      () => fetch(
        musicBrainzRecordingUri(q, limit: limit),
        headers: const {
          'User-Agent': kArtworkUserAgent,
          'Accept': 'application/json',
        },
      ),
      priority: priority,
    );
    if (!res.ok) return const <TagCandidate>[];
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return const <TagCandidate>[];
    final recordings = decoded['recordings'];
    if (recordings is! List) return const <TagCandidate>[];

    final out = <TagCandidate>[];
    for (final r in recordings) {
      if (r is Map<String, dynamic>) out.addAll(_candidatesFrom(r));
    }
    return out;
  } catch (_) {
    return const <TagCandidate>[];
  }
}

/// The seam the UI depends on, so no test ever opens a socket.
typedef TagSearch = Future<List<TagCandidate>> Function(TagQuery q);
