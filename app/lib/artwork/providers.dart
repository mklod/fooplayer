// Keyless album-artwork providers: iTunes Search, Deezer, and Cover Art
// Archive (found via MusicBrainz).
//
// Three rules hold for everything in this file:
//   1. No API keys, no signup, no per-user quota to manage.
//   2. Every provider is error-isolated: network off, 404, HTML error page,
//      truncated/renamed JSON -- all of it degrades to an empty candidate
//      list. A provider never throws at the caller, so the UI can call this
//      without a try/catch and can never be broken by someone else's outage.
//   3. All IO goes through the injectable [ArtFetch] seam, so tests run
//      entirely off captured fixtures and never touch the network.
//
// Last modified: 2026-07-25--2113

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'art_candidate.dart';

export 'art_candidate.dart' show ArtQuery, ArtCandidate, ArtSource;

/// MusicBrainz *requires* a descriptive User-Agent that identifies the
/// application and gives them a way to contact us; anonymous or generic
/// agents get blocked. See https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
const String kArtworkUserAgent =
    'fooplayer/1.0 (https://github.com/mklod/fooplayer)';

/// MusicBrainz allows at most one request per second per client.
const Duration kMusicBrainzMinInterval = Duration(seconds: 1);

/// Hard ceiling on any single provider request. Deliberately short: artwork
/// is a nice-to-have, and a hung socket must never be able to keep a lookup
/// (or the background pass behind it) alive indefinitely.
const Duration kArtFetchTimeout = Duration(seconds: 10);

/// Minimal HTTP response the providers need. Keeping our own type (instead of
/// `http.Response`) means test fakes and future transports don't have to
/// depend on `package:http` at all.
class ArtHttpResponse {
  final int statusCode;
  final String body;

  const ArtHttpResponse({required this.statusCode, required this.body});

  bool get ok => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'ArtHttpResponse($statusCode, ${body.length} bytes)';
}

/// The single IO seam. Implementations must either return a response or
/// throw; providers translate both into candidates or `[]`.
typedef ArtFetch = Future<ArtHttpResponse> Function(
  Uri url, {
  Map<String, String>? headers,
});

/// Production [ArtFetch]: `package:http` GET with a timeout and the project
/// User-Agent. Never used by tests.
Future<ArtHttpResponse> httpArtFetch(
  Uri url, {
  Map<String, String>? headers,
}) async {
  final res = await http.get(
    url,
    headers: {
      'User-Agent': kArtworkUserAgent,
      'Accept': 'application/json',
      ...?headers,
    },
  ).timeout(kArtFetchTimeout);
  return ArtHttpResponse(statusCode: res.statusCode, body: res.body);
}

/// Fetches raw image bytes for [url].
///
/// Injected everywhere it is used (the background pass's downloader, the
/// picker's thumbnail loader) so **no test can reach the network**: this is
/// the only function in the artwork subsystem that downloads an image, and
/// nothing constructs it implicitly -- production wires it in `main.dart`.
///
/// Returns null for anything that isn't a usable image response (non-200,
/// empty body, timeout, transport failure). A null is "candidate rejected",
/// which matters for Cover Art Archive: its URLs are *derived* from a
/// MusicBrainz release-group id without verifying an image was ever
/// archived, so a 404 here is an expected outcome, not an error.
typedef ArtBytesFetch = Future<List<int>?> Function(String url);

Future<List<int>?> httpArtworkBytes(String url) async {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  try {
    final res = await http.get(
      uri,
      headers: const {'User-Agent': kArtworkUserAgent, 'Accept': 'image/*'},
    ).timeout(kArtFetchTimeout);
    if (res.statusCode != 200) return null;
    final bytes = res.bodyBytes;
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

/// Serializes work and enforces a minimum gap between the *starts* of
/// consecutive actions.
///
/// The clock and the sleep are injected so tests can prove the spacing
/// without actually spending wall-clock seconds (see `providers_test.dart`).
class RateLimiter {
  final Duration minInterval;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  DateTime? _lastStart;
  Future<void> _chain = Future<void>.value();

  RateLimiter({
    required this.minInterval,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : _sleep = sleep ?? Future.delayed,
        _now = now ?? DateTime.now;

  /// Runs [action] no sooner than [minInterval] after the previous action
  /// started. Failures propagate to the caller but never poison the queue.
  Future<T> schedule<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      final last = _lastStart;
      if (last != null) {
        final wait = minInterval - _now().difference(last);
        if (wait > Duration.zero) await _sleep(wait);
      }
      _lastStart = _now();
      try {
        completer.complete(await action());
      } catch (e, st) {
        // Completed as an error for the caller; the chain itself stays
        // healthy so a single failed request can't wedge the limiter.
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

/// Process-wide MusicBrainz limiter. Every un-injected CAA lookup shares it,
/// which is the whole point: three albums looked up "concurrently" still hit
/// MusicBrainz one request per second.
final RateLimiter musicBrainzLimiter =
    RateLimiter(minInterval: kMusicBrainzMinInterval);

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

Future<List<ArtCandidate>> _guarded(
    Future<List<ArtCandidate>> Function() body) async {
  try {
    return await body();
  } catch (_) {
    // Rule 2: any failure is "no candidates", never an exception upward.
    return const <ArtCandidate>[];
  }
}

/// Decodes a JSON object body, or null for anything unusable (non-2xx,
/// empty, HTML error page, JSON array where an object was promised).
Map<String, dynamic>? _decodeObject(ArtHttpResponse res) {
  if (!res.ok) return null;
  if (res.body.trim().isEmpty) return null;
  final decoded = jsonDecode(res.body);
  return decoded is Map<String, dynamic> ? decoded : null;
}

List<Map<String, dynamic>> _objectList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map<String, dynamic>) e,
  ];
}

String _str(Map<String, dynamic> m, String key) {
  final v = m[key];
  return v is String ? v.trim() : '';
}

/// Year out of an ISO-ish date (`1997`, `1997-05-21`, `1973-03-01T08:00:00Z`).
/// Tolerant of the field being absent or the wrong type -- one odd field must
/// not cost us the whole response.
int? _yearFromDate(Object? date) {
  if (date is! String || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// Strips the characters that would break a quoted Lucene/Deezer term.
String _quoteSafe(String s) =>
    s.replaceAll('"', ' ').replaceAll('\\', ' ').trim();

// ---------------------------------------------------------------------------
// iTunes Search API
// ---------------------------------------------------------------------------

final RegExp _itunesSizeSegment = RegExp(r'/\d+x\d+bb');

/// Rewrites an iTunes artwork URL to a different square size. iTunes serves
/// any size from the same path by swapping the `NNNxNNNbb` segment -- that's
/// how we get 600px art out of a response that only advertises 100px.
String itunesArtworkAtSize(String url, int size) =>
    url.replaceAll(_itunesSizeSegment, '/${size}x${size}bb');

Uri itunesSearchUri(ArtQuery q, {int limit = 10}) =>
    Uri.https('itunes.apple.com', '/search', {
      'entity': 'album',
      'media': 'music',
      'limit': '$limit',
      'term': q.term,
    });

/// iTunes Search API. Keyless; returns album "collections".
Future<List<ArtCandidate>> searchItunes(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 10,
}) =>
    _guarded(() async {
      if (q.isEmpty) return const <ArtCandidate>[];
      final res = await fetch(itunesSearchUri(q, limit: limit));
      final json = _decodeObject(res);
      if (json == null) return const <ArtCandidate>[];

      final out = <ArtCandidate>[];
      for (final r in _objectList(json['results'])) {
        // `entity=album` should only ever return collections, but iTunes has
        // been known to mix in track rows; those carry the album's artwork
        // under a track title and would pollute the ranking.
        final wrapper = _str(r, 'wrapperType');
        if (wrapper.isNotEmpty && wrapper != 'collection') continue;
        final art = _str(r, 'artworkUrl100').isNotEmpty
            ? _str(r, 'artworkUrl100')
            : _str(r, 'artworkUrl60');
        if (art.isEmpty) continue;
        final title = _str(r, 'collectionName').isNotEmpty
            ? _str(r, 'collectionName')
            : _str(r, 'collectionCensoredName');
        if (title.isEmpty) continue;
        out.add(ArtCandidate(
          url: itunesArtworkAtSize(art, 600),
          thumbUrl: itunesArtworkAtSize(art, 200),
          source: ArtSource.itunes,
          title: title,
          artist: _str(r, 'artistName'),
          year: _yearFromDate(r['releaseDate']),
          width: 600,
        ));
      }
      return out;
    });

// ---------------------------------------------------------------------------
// Deezer
// ---------------------------------------------------------------------------

Uri deezerSearchUri(ArtQuery q, {int limit = 10}) {
  final artist = _quoteSafe(q.artist);
  final album = _quoteSafe(q.album);
  // Deezer's advanced syntax gives far better precision than a bag of words,
  // but only when we actually have both fields.
  final query = (artist.isNotEmpty && album.isNotEmpty)
      ? 'artist:"$artist" album:"$album"'
      : q.term;
  return Uri.https('api.deezer.com', '/search/album', {
    'q': query,
    'limit': '$limit',
  });
}

/// Deezer public search. Keyless. Note the API answers HTTP 200 with an
/// `{"error": {...}}` body on failures, which [_decodeObject] can't catch --
/// hence the explicit check.
Future<List<ArtCandidate>> searchDeezer(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 10,
}) =>
    _guarded(() async {
      if (q.isEmpty) return const <ArtCandidate>[];
      final res = await fetch(deezerSearchUri(q, limit: limit));
      final json = _decodeObject(res);
      if (json == null) return const <ArtCandidate>[];
      if (json['error'] != null) return const <ArtCandidate>[];

      final out = <ArtCandidate>[];
      for (final a in _objectList(json['data'])) {
        // Largest available first: xl is 1000px, big 500px, medium 250px;
        // the bare `cover` field has no documented size, so it gets no
        // resolution bonus rather than an invented one.
        final xl = _str(a, 'cover_xl');
        final big = _str(a, 'cover_big');
        final med = _str(a, 'cover_medium');
        final small = _str(a, 'cover_small');
        final base = _str(a, 'cover');
        String url;
        int? width;
        if (xl.isNotEmpty) {
          url = xl;
          width = 1000;
        } else if (big.isNotEmpty) {
          url = big;
          width = 500;
        } else if (med.isNotEmpty) {
          url = med;
          width = 250;
        } else {
          url = base;
          width = null;
        }
        if (url.isEmpty) continue;
        final title = _str(a, 'title');
        if (title.isEmpty) continue;
        final artistObj = a['artist'];
        final thumb = med.isNotEmpty ? med : (small.isNotEmpty ? small : url);
        out.add(ArtCandidate(
          url: url,
          thumbUrl: thumb,
          source: ArtSource.deezer,
          title: title,
          artist:
              artistObj is Map<String, dynamic> ? _str(artistObj, 'name') : '',
          year: _yearFromDate(a['release_date']),
          width: width,
        ));
      }
      return out;
    });

// ---------------------------------------------------------------------------
// MusicBrainz -> Cover Art Archive
// ---------------------------------------------------------------------------

Uri musicBrainzSearchUri(ArtQuery q, {int limit = 10}) {
  final artist = _quoteSafe(q.artist);
  final album = _quoteSafe(q.album);
  final lucene = [
    if (artist.isNotEmpty) 'artist:"$artist"',
    if (album.isNotEmpty) 'releasegroup:"$album"',
  ].join(' AND ');
  return Uri.https('musicbrainz.org', '/ws/2/release-group', {
    'query': lucene.isEmpty ? q.term : lucene,
    'fmt': 'json',
    'limit': '$limit',
  });
}

/// Cover Art Archive front-cover URL for a release-group MBID. CAA serves
/// these as redirects to the archived image; there is no separate lookup and
/// no key.
String coverArtArchiveFrontUrl(String mbid, {int size = 500}) =>
    'https://coverartarchive.org/release-group/$mbid/front-$size';

/// Joins a MusicBrainz `artist-credit` array into a display string,
/// honouring the join phrases ("Simon & Garfunkel", "X feat. Y").
String musicBrainzArtistCredit(Object? credit) {
  final parts = _objectList(credit);
  if (parts.isEmpty) return '';
  final buf = StringBuffer();
  for (final p in parts) {
    final artist = p['artist'];
    final name = _str(p, 'name').isNotEmpty
        ? _str(p, 'name')
        : (artist is Map<String, dynamic> ? _str(artist, 'name') : '');
    buf.write(name);
    // NOT trimmed: the join phrase carries its own spacing (" & ", " feat. ").
    final join = p['joinphrase'];
    if (join is String) buf.write(join);
  }
  return buf.toString().trim();
}

/// MusicBrainz release-group search, turned into Cover Art Archive URLs.
///
/// Rate-limited through [limiter] (defaults to the process-wide
/// [musicBrainzLimiter]) and always sends [kArtworkUserAgent] -- both are
/// conditions of MusicBrainz's terms of use, not optimizations.
Future<List<ArtCandidate>> searchCoverArtArchive(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 10,
  RateLimiter? limiter,
}) =>
    _guarded(() async {
      if (q.isEmpty) return const <ArtCandidate>[];
      final res = await (limiter ?? musicBrainzLimiter).schedule(
        () => fetch(
          musicBrainzSearchUri(q, limit: limit),
          headers: const {
            'User-Agent': kArtworkUserAgent,
            'Accept': 'application/json',
          },
        ),
      );
      final json = _decodeObject(res);
      if (json == null) return const <ArtCandidate>[];

      final out = <ArtCandidate>[];
      for (final g in _objectList(json['release-groups'])) {
        final mbid = _str(g, 'id');
        final title = _str(g, 'title');
        if (mbid.isEmpty || title.isEmpty) continue;
        out.add(ArtCandidate(
          url: coverArtArchiveFrontUrl(mbid, size: 500),
          thumbUrl: coverArtArchiveFrontUrl(mbid, size: 250),
          source: ArtSource.caa,
          title: title,
          artist: musicBrainzArtistCredit(g['artist-credit']),
          year: _yearFromDate(g['first-release-date']),
          width: 500,
        ));
      }
      return out;
    });

// ---------------------------------------------------------------------------
// All providers
// ---------------------------------------------------------------------------

/// Queries every provider and returns the union of their candidates, in
/// provider order (iTunes, Deezer, Cover Art Archive).
///
/// Concurrency is exactly the three providers -- the plan's "at most 3
/// concurrent provider fetches" ceiling -- and each one is independently
/// error-isolated, so one provider being down or slow costs nothing but its
/// own results. Ranking/deduping is `scoring.dart`'s job, not this one's.
Future<List<ArtCandidate>> searchAll(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limitPerProvider = 10,
  RateLimiter? limiter,
}) async {
  if (q.isEmpty) return const <ArtCandidate>[];
  final results = await Future.wait<List<ArtCandidate>>([
    _guarded(() => searchItunes(q, fetch: fetch, limit: limitPerProvider)),
    _guarded(() => searchDeezer(q, fetch: fetch, limit: limitPerProvider)),
    _guarded(() => searchCoverArtArchive(
          q,
          fetch: fetch,
          limit: limitPerProvider,
          limiter: limiter,
        )),
  ]);
  return [for (final r in results) ...r];
}
