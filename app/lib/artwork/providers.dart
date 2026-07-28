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
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show HandshakeException, HttpClient, X509Certificate;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

import 'art_candidate.dart';
import 'image_sniff.dart';

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
typedef ArtFetch =
    Future<ArtHttpResponse> Function(Uri url, {Map<String, String>? headers});

/// Production [ArtFetch]: `package:http` GET with a timeout and the project
/// User-Agent. Never used by tests.
Future<ArtHttpResponse> httpArtFetch(
  Uri url, {
  Map<String, String>? headers,
}) async {
  final res = await http
      .get(
        url,
        headers: {
          'User-Agent': kArtworkUserAgent,
          'Accept': 'application/json',
          ...?headers,
        },
      )
      .timeout(kArtFetchTimeout);
  return ArtHttpResponse(statusCode: res.statusCode, body: res.body);
}

/// Fetches raw image bytes for [url]. See [httpArtworkBytes] for the
/// production implementation this typedef is injected with.
typedef ArtBytesFetch = Future<List<int>?> Function(String url);

/// Hard ceiling on a single downloaded image, in bytes. Artwork is a nicety
/// -- nothing in the app needs a multi-megabyte image, and "Paste URL..."
/// accepts arbitrary user input, so a URL serving something huge (by
/// accident or on purpose) must not be allowed to buffer unbounded memory
/// or spend unbounded bandwidth/time. 12 MB is comfortably above any real
/// album cover (even a lossless 3000x3000 PNG is a few MB) while still
/// catching a truly oversized response quickly.
const int kArtworkMaxBytes = 12 * 1024 * 1024;

/// Image hosts of the three built-in providers. A download from one of
/// these -- and ONLY these -- may retry with certificate-chain verification
/// relaxed; see [_fetchWithRelaxedTls].
///
/// Why this exists: Deezer's image CDN serves an INCOMPLETE certificate
/// chain (it omits the intermediate CA). Browsers paper over that by
/// fetching the missing certificate themselves; Dart does not, so every
/// Deezer cover download fails with a HandshakeException
/// (CERTIFICATE_VERIFY_FAILED) even though the same TLS stack talks to
/// Deezer's *API* and to iTunes/CAA without complaint. Verified on this
/// machine: 6/6 failures against cdn-images.dzcdn.net, 200 OK against
/// mzstatic.com in the same run.
///
/// The relaxation is deliberately narrow: it covers only these known
/// artwork hosts (never a user-pasted URL), only image bytes (never an API
/// call), no credentials or user data are ever sent, and the response is
/// still size-capped and magic-byte validated. The worst case a
/// man-in-the-middle buys is a different album cover.
const Set<String> kProviderImageHosts = {
  'cdn-images.dzcdn.net',
  'e-cdns-images.dzcdn.net',
  'is1-ssl.mzstatic.com',
  'is2-ssl.mzstatic.com',
  'is3-ssl.mzstatic.com',
  'is4-ssl.mzstatic.com',
  'is5-ssl.mzstatic.com',
  'coverartarchive.org',
  'ia800000.us.archive.org',
};

/// True when [host] belongs to a built-in provider's image CDN (exact match
/// or a subdomain of one), i.e. when the narrow TLS retry above is allowed.
bool isProviderImageHost(String host) {
  final h = host.toLowerCase();
  if (kProviderImageHosts.contains(h)) return true;
  return kProviderImageHosts.any((known) => h.endsWith('.$known')) ||
      h.endsWith('.dzcdn.net') ||
      h.endsWith('.mzstatic.com') ||
      h.endsWith('.archive.org');
}

/// Fetches raw image bytes for [url].
///
/// Injected everywhere it is used (the background pass's downloader, the
/// picker's thumbnail loader) so **no test can reach the network**: this is
/// the only function in the artwork subsystem that downloads an image, and
/// nothing constructs it implicitly -- production wires it in `main.dart`.
///
/// Returns null for anything that isn't a usable image response (non-200,
/// empty body, not a recognized image format, over [kArtworkMaxBytes],
/// timeout, transport failure). A null is "candidate rejected", which
/// matters for Cover Art Archive: its URLs are *derived* from a MusicBrainz
/// release-group id without verifying an image was ever archived, so a 404
/// here is an expected outcome, not an error.
///
/// **Streamed, not buffered whole.** Reads the response in chunks and
/// aborts (cancelling the connection) the instant the running total passes
/// [kArtworkMaxBytes], rather than the old `http.get()` convenience call
/// that always buffered the ENTIRE body into memory first and only checked
/// its size afterward -- against an arbitrary user-pasted URL, that meant an
/// oversized (or endless) response could exhaust memory before this
/// function ever got a chance to reject it.
///
/// **Magic-byte validated** (adversarial review finding 6): a 200 response
/// with a non-image body (an HTML error/redirect page is the common case
/// for a URL that isn't a direct image link) is rejected here rather than
/// stored as a "successful" pick that's never retried.
///
/// [clientFactory] builds the (single-use, closed at the end of this call)
/// [http.Client] -- defaults to a real one, injectable so tests can hand it
/// a `package:http/testing.dart` `MockClient` and exercise the streaming
/// cap/validation without a socket. Still satisfies the plain
/// `Future<List<int>?> Function(String)` shape [ArtBytesFetch] expects
/// (an optional named parameter doesn't change the call sites that omit
/// it), so production wiring in `artwork_wiring.dart` needs no changes.
Future<List<int>?> httpArtworkBytes(
  String url, {
  http.Client Function() clientFactory = http.Client.new,
}) async {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final strict = clientFactory();
  try {
    return await _readImage(strict, uri);
  } on HandshakeException {
    // Certificate-chain verification failed. For a KNOWN provider CDN only
    // (see kProviderImageHosts), retry once with verification relaxed --
    // some of them (Deezer's, today) serve an incomplete chain that Dart
    // can't complete on its own. Anything else -- notably a user-pasted
    // URL -- keeps strict verification and simply fails.
    if (!isProviderImageHost(uri.host)) return null;
    return _fetchWithRelaxedTls(uri);
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  } finally {
    strict.close();
  }
}

/// Retry path for a provider CDN whose certificate chain Dart can't verify.
/// Verification is disabled ONLY for [kProviderImageHosts] hosts; the
/// response is still size-capped and magic-byte validated by [_readImage].
Future<List<int>?> _fetchWithRelaxedTls(Uri uri) async {
  final httpClient = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) =>
        isProviderImageHost(host);
  final client = io_client.IOClient(httpClient);
  try {
    return await _readImage(client, uri);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Streams [uri] through [client], enforcing the size cap and image-format
/// validation. Throws transport errors to the caller (which decides whether
/// a retry is allowed); returns null for a response that is simply not a
/// usable image.
Future<List<int>?> _readImage(http.Client client, Uri uri) async {
  {
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = kArtworkUserAgent
      ..headers['Accept'] = 'image/*';
    final streamed = await client.send(request).timeout(kArtFetchTimeout);
    if (streamed.statusCode != 200) return null;
    // A declared size already over the cap: don't read a single byte.
    final declaredLength = streamed.contentLength;
    if (declaredLength != null && declaredLength > kArtworkMaxBytes) {
      return null;
    }

    final builder = BytesBuilder(copy: false);
    var oversize = false;
    await for (final chunk in streamed.stream.timeout(kArtFetchTimeout)) {
      builder.add(chunk);
      if (builder.length > kArtworkMaxBytes) {
        oversize = true;
        break; // cancels the stream subscription -- no more bytes read
      }
    }
    if (oversize) return null;

    final bytes = builder.takeBytes();
    if (bytes.isEmpty) return null;
    if (!looksLikeImage(bytes)) return null;
    return bytes;
  }
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

/// Where a [RateLimiter.schedule] request sits in the queue (adversarial
/// review finding 2).
///
/// The picker's search (and "Search again") and the background best-guess
/// pass share ONE process-wide MusicBrainz limiter -- that's the whole
/// point, since MusicBrainz's <=1 req/sec rule is per-CLIENT, not
/// per-caller. But a strict FIFO queue meant an interactive request that
/// landed behind a few hundred queued background lookups could sit in the
/// picker's spinner for minutes. [interactive] requests jump every
/// currently-queued [background] one (see [RateLimiter]'s doc for exactly
/// how); the overall pacing -- still at most one dispatch every
/// [RateLimiter.minInterval], no matter the mix -- is never relaxed for
/// either lane, so MusicBrainz's rate limit is honoured exactly as before.
enum RateLimitPriority { interactive, background }

/// Serializes work and enforces a minimum gap between the *starts* of
/// consecutive actions -- with a priority lane (adversarial review
/// finding 2): [RateLimitPriority.interactive] requests are always
/// dispatched before any currently-queued [RateLimitPriority.background]
/// one, without loosening [minInterval] for either.
///
/// **Where priority is decided.** [schedule] appends to one of two FIFO
/// queues by [RateLimitPriority]; the pump loop only picks WHICH queue's
/// head runs next AFTER waiting out the pacing gap (never before) -- so an
/// interactive request that arrives WHILE the limiter is already waiting on
/// the gap still gets to cut in front of every background request queued
/// before it. Within one priority tier, order is plain FIFO (unchanged from
/// before this queue existed).
///
/// The clock and the sleep are injected so tests can prove the spacing
/// without actually spending wall-clock seconds (see `providers_test.dart`).
class RateLimiter {
  final Duration minInterval;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  DateTime? _lastStart;
  final Queue<_LimiterTask> _interactive = Queue();
  final Queue<_LimiterTask> _background = Queue();
  bool _pumping = false;

  RateLimiter({
    required this.minInterval,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  }) : _sleep = sleep ?? Future.delayed,
       _now = now ?? DateTime.now;

  /// Runs [action] no sooner than [minInterval] after the previous action
  /// (of either priority) started. Failures propagate to the caller but
  /// never poison the queue -- a failed action doesn't stop later ones,
  /// queued or not-yet-arrived, from running on schedule.
  Future<T> schedule<T>(
    Future<T> Function() action, {
    RateLimitPriority priority = RateLimitPriority.background,
  }) {
    final completer = Completer<T>();
    final task = _LimiterTask(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    (priority == RateLimitPriority.interactive ? _interactive : _background)
        .add(task);
    _pump();
    return completer.future;
  }

  /// Drains both queues one task at a time. Idempotent to call while
  /// already running (guarded by [_pumping]) -- every [schedule] call
  /// invokes this, but only the first live one actually starts a loop; the
  /// rest just make sure their task is in a queue the running loop will see.
  void _pump() {
    if (_pumping) return;
    _pumping = true;
    () async {
      while (_interactive.isNotEmpty || _background.isNotEmpty) {
        final last = _lastStart;
        if (last != null) {
          final wait = minInterval - _now().difference(last);
          if (wait > Duration.zero) await _sleep(wait);
        }
        // Decided AFTER the wait, not before: an interactive request that
        // arrived during the wait above still wins over a background one
        // that was already queued -- see the class doc.
        final next = _interactive.isNotEmpty
            ? _interactive.removeFirst()
            : _background.removeFirst();
        _lastStart = _now();
        await next.run();
      }
      _pumping = false;
    }();
  }
}

class _LimiterTask {
  final Future<void> Function() run;
  _LimiterTask(this.run);
}

/// Process-wide MusicBrainz limiter. Every un-injected CAA lookup shares it,
/// which is the whole point: three albums looked up "concurrently" still hit
/// MusicBrainz one request per second -- across BOTH priority lanes (see
/// [RateLimitPriority]).
final RateLimiter musicBrainzLimiter = RateLimiter(
  minInterval: kMusicBrainzMinInterval,
);

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

Future<List<ArtCandidate>> _guarded(
  Future<List<ArtCandidate>> Function() body,
) async {
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

Uri itunesSearchUri(ArtQuery q, {int limit = 10}) => Uri.https(
  'itunes.apple.com',
  '/search',
  {'entity': 'album', 'media': 'music', 'limit': '$limit', 'term': q.term},
);

/// iTunes Search API. Keyless; returns album "collections".
Future<List<ArtCandidate>> searchItunes(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 10,
}) => _guarded(() async {
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
    out.add(
      ArtCandidate(
        url: itunesArtworkAtSize(art, 600),
        thumbUrl: itunesArtworkAtSize(art, 200),
        source: ArtSource.itunes,
        title: title,
        artist: _str(r, 'artistName'),
        year: _yearFromDate(r['releaseDate']),
        width: 600,
      ),
    );
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
}) => _guarded(() async {
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
    out.add(
      ArtCandidate(
        url: url,
        thumbUrl: thumb,
        source: ArtSource.deezer,
        title: title,
        artist: artistObj is Map<String, dynamic>
            ? _str(artistObj, 'name')
            : '',
        year: _yearFromDate(a['release_date']),
        width: width,
      ),
    );
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
/// conditions of MusicBrainz's terms of use, not optimizations. [priority]
/// (adversarial review finding 2) is forwarded verbatim to the limiter --
/// see [RateLimitPriority]'s doc.
Future<List<ArtCandidate>> searchCoverArtArchive(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limit = 10,
  RateLimiter? limiter,
  RateLimitPriority priority = RateLimitPriority.background,
}) => _guarded(() async {
  if (q.isEmpty) return const <ArtCandidate>[];
  final res = await (limiter ?? musicBrainzLimiter).schedule(
    () => fetch(
      musicBrainzSearchUri(q, limit: limit),
      headers: const {
        'User-Agent': kArtworkUserAgent,
        'Accept': 'application/json',
      },
    ),
    priority: priority,
  );
  final json = _decodeObject(res);
  if (json == null) return const <ArtCandidate>[];

  final out = <ArtCandidate>[];
  for (final g in _objectList(json['release-groups'])) {
    final mbid = _str(g, 'id');
    final title = _str(g, 'title');
    if (mbid.isEmpty || title.isEmpty) continue;
    out.add(
      ArtCandidate(
        url: coverArtArchiveFrontUrl(mbid, size: 500),
        thumbUrl: coverArtArchiveFrontUrl(mbid, size: 250),
        source: ArtSource.caa,
        title: title,
        artist: musicBrainzArtistCredit(g['artist-credit']),
        year: _yearFromDate(g['first-release-date']),
        width: 500,
      ),
    );
  }
  return out;
});

// ---------------------------------------------------------------------------
// All providers
// ---------------------------------------------------------------------------

/// How long [searchAll] waits on Cover Art Archive specifically before
/// proceeding without it, when a [searchAll] caller opts in via
/// [searchAll]'s `caaBudget` (adversarial review finding 2). iTunes and
/// Deezer typically answer in well under a second; MusicBrainz (behind CAA)
/// is the slowest and the only rate-limited leg of the three, so an
/// interactive caller that already has the other two providers' results in
/// hand must not sit spinning on it. Not applied unless a caller asks for
/// it -- the background pass has nobody waiting on it and always wants
/// CAA's answer if one is coming, however long that takes.
const Duration kInteractiveCaaBudget = Duration(seconds: 3);

/// Queries every provider and returns the union of their candidates, in
/// provider order (iTunes, Deezer, Cover Art Archive).
///
/// Concurrency is exactly the three providers -- the plan's "at most 3
/// concurrent provider fetches" ceiling -- and each one is independently
/// error-isolated, so one provider being down or slow costs nothing but its
/// own results. Ranking/deduping is `scoring.dart`'s job, not this one's.
///
/// [priority] is forwarded to the MusicBrainz [limiter] (see
/// [RateLimitPriority]). [caaBudget], when non-null, caps how long this call
/// waits on Cover Art Archive: past that budget CAA is treated exactly like
/// any other "no candidates" outcome (same as a provider that legitimately
/// returned nothing) -- iTunes/Deezer's results are returned regardless.
/// CAA's own request is NOT cancelled when the budget expires (it keeps its
/// place in the rate limiter and completes on its own schedule); its result
/// is simply not waited on by this call. Adversarial review finding 2.
Future<List<ArtCandidate>> searchAll(
  ArtQuery q, {
  ArtFetch fetch = httpArtFetch,
  int limitPerProvider = 10,
  RateLimiter? limiter,
  RateLimitPriority priority = RateLimitPriority.background,
  Duration? caaBudget,
}) async {
  if (q.isEmpty) return const <ArtCandidate>[];
  Future<List<ArtCandidate>> caa = _guarded(
    () => searchCoverArtArchive(
      q,
      fetch: fetch,
      limit: limitPerProvider,
      limiter: limiter,
      priority: priority,
    ),
  );
  if (caaBudget != null) {
    caa = caa.timeout(caaBudget, onTimeout: () => const <ArtCandidate>[]);
  }
  final results = await Future.wait<List<ArtCandidate>>([
    _guarded(() => searchItunes(q, fetch: fetch, limit: limitPerProvider)),
    _guarded(() => searchDeezer(q, fetch: fetch, limit: limitPerProvider)),
    caa,
  ]);
  return [for (final r in results) ...r];
}
