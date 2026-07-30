// Last modified: 2026-07-25--2214
//
// Plan 4 (Album Artwork Lookup) -- THE MERGE SEAM.
//
// A1 (providers + scoring), A2 (sidecar store + display resolution chain +
// background pass) and A3 (picker UI) were each built against injected
// function seams rather than against each other. This file is the one place
// those seams are joined into a working feature, so every adapter is small,
// visible and testable:
//
//   A1 `searchAll`   -> A2 `ArtworkSearch`      (background best-guess pass)
//   A1 `bestGuess`   -> A2 `ArtworkAutoPick`    (the >=75 / >=10 rule)
//   A1 `httpArtworkBytes` -> A2 `ArtworkDownloader`
//   A1 `ArtCandidate` -> A3 `PickerCandidate`   (grid view-model)
//   A2 store+resolver -> A3 `ArtworkServices`   (apply / remove / current)
//
// **Everything that touches the network is injected.** [ArtworkWiring] takes
// an [ArtFetch] (provider JSON) and an [ArtBytesFetch] (image bytes) whose
// defaults are the production HTTP implementations; every test constructs it
// with fakes, so the plan's "no test may hit the network" rule stays a
// property of the code rather than a promise.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../model/track.dart';
import 'artwork_backfill.dart';
import 'artwork_resolver.dart';
import 'artwork_store.dart';
import 'picker_seams.dart';
import 'providers.dart';
import 'scoring.dart';

/// Reads a local image the user picked with "Choose file...". Injected so
/// widget tests never touch the filesystem.
typedef ArtworkLocalReader = Future<List<int>?> Function(String path);

Future<List<int>?> readLocalArtworkFile(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

/// A1's [ArtCandidate] as A3's grid view-model. Field names were chosen on
/// both sides to make this a straight copy -- no reshaping, no loss.
PickerCandidate toPickerCandidate(ArtCandidate c) => PickerCandidate(
  url: c.url,
  thumbUrl: c.thumbUrl,
  source: c.source.id,
  title: c.title,
  artist: c.artist,
  year: c.year,
  width: c.width,
);

/// Bounded, deduped, throttled image fetcher shared by the picker grid and
/// the "apply this candidate" path.
///
/// Three properties matter, all of them for manners rather than speed:
///  * **Cached** (LRU, [maxEntries]) -- reopening a picker, or a rebuild of
///    the grid, must not re-download anything.
///  * **Deduped** -- N tiles pointing at one URL make one request.
///  * **Throttled** ([maxConcurrent]) -- a 20-tile grid would otherwise open
///    20 sockets against a keyless public API in one frame.
class ArtworkImageCache {
  final ArtBytesFetch fetch;
  final int maxEntries;
  final int maxConcurrent;

  ArtworkImageCache({
    this.fetch = httpArtworkBytes,
    this.maxEntries = 48,
    this.maxConcurrent = 4,
  });

  final LinkedHashMap<String, Uint8List?> _cache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inFlight = {};
  final Queue<Completer<void>> _waiting = Queue();
  int _active = 0;

  int get cachedCount => _cache.length;

  /// Bytes for [url], or null when it can't be fetched. Never throws.
  Future<Uint8List?> bytes(String url) {
    if (url.isEmpty) return Future<Uint8List?>.value(null);
    if (_cache.containsKey(url)) {
      final v = _cache.remove(url);
      _cache[url] = v; // LRU touch
      return Future<Uint8List?>.value(v);
    }
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = _fetchGated(url).then((data) {
      _inFlight.remove(url);
      _cache[url] = data;
      while (_cache.length > maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return data;
    });
    _inFlight[url] = future;
    return future;
  }

  Future<Uint8List?> _fetchGated(String url) async {
    await _acquire();
    try {
      final raw = await fetch(url);
      if (raw == null || raw.isEmpty) return null;
      return raw is Uint8List ? raw : Uint8List.fromList(raw);
    } catch (_) {
      return null;
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _active--;
  }

  void clear() {
    _cache.clear();
  }
}

/// Small LRU of provider results, keyed by album key.
///
/// Reopening the picker for the same album (or opening it right after the
/// background pass looked the album up) reuses the candidate list instead of
/// re-querying three public APIs. "Search again" bypasses it -- that is what
/// makes the button meaningful.
class ArtworkCandidateCache {
  final int maxEntries;
  ArtworkCandidateCache({this.maxEntries = 24});

  final LinkedHashMap<String, List<ArtCandidate>> _cache = LinkedHashMap();

  List<ArtCandidate>? get(String albumKey) {
    if (!_cache.containsKey(albumKey)) return null;
    final v = _cache.remove(albumKey)!;
    _cache[albumKey] = v;
    return v;
  }

  void put(String albumKey, List<ArtCandidate> candidates) {
    _cache.remove(albumKey);
    _cache[albumKey] = candidates;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void clear() => _cache.clear();
}

/// Everything the artwork feature needs, wired together.
///
/// Construct ONE of these (production: in `main`), then hand
/// [ArtworkWiring.resolver] to the art surfaces, [ArtworkWiring.backfill] to
/// the load path, and [ArtworkWiring.services] to the two picker entry
/// points.
class ArtworkWiring {
  final ArtworkStoreRegistry stores;
  final ArtworkResolver resolver;
  final ArtworkImageCache images;
  final ArtworkCandidateCache candidates;
  final ArtworkLocalReader readLocal;

  /// Provider JSON transport (A1's seam). Injected; defaults to HTTP.
  final ArtFetch fetch;

  /// Rate limiter for the MusicBrainz-backed Cover Art Archive lookup that
  /// both the background pass and the picker's search share (adversarial
  /// review finding 2 -- see [RateLimitPriority]). Injected so a test can
  /// substitute an instant, private one instead of exercising the
  /// process-wide [musicBrainzLimiter] (shared global state every other
  /// caller in the same isolate would also see).
  final RateLimiter caaLimiter;

  late final ArtworkBackfill backfill;

  ArtworkWiring({
    required this.stores,
    required this.resolver,
    ArtworkImageCache? images,
    ArtworkCandidateCache? candidates,
    this.fetch = httpArtFetch,
    ArtBytesFetch imageFetch = httpArtworkBytes,
    this.readLocal = readLocalArtworkFile,
    RateLimiter? caaLimiter,
    bool backfillEnabled = true,
    int maxConcurrent = 3,
    Duration gap = defaultArtworkBackfillGap,
  }) : images = images ?? ArtworkImageCache(fetch: imageFetch),
       candidates = candidates ?? ArtworkCandidateCache(),
       caaLimiter = caaLimiter ?? musicBrainzLimiter {
    backfill = ArtworkBackfill(
      resolver: resolver,
      search: searchForBackfill,
      autoPick: autoPick,
      downloader: download,
      enabled: backfillEnabled,
      maxConcurrent: maxConcurrent,
      gap: gap,
    );
  }

  /// Builds the whole stack the normal way: one store registry rooted at the
  /// app data dir, one resolver, one wiring.
  ///
  /// `preferSidecar: true` is a deliberate, narrow deviation from the plan's
  /// literal chain order (`embedded -> sidecar -> sibling file`). The
  /// background pass only ever writes a sidecar entry for an album that
  /// [ArtworkResolver.hasArt] said had NONE, so an album that carries
  /// embedded art can only have a sidecar entry because the user explicitly
  /// picked one in the picker. Preferring the sidecar therefore changes
  /// exactly one thing: an explicit user choice wins over embedded tag art,
  /// instead of being silently ignored (which would make "Album artwork..."
  /// look broken on every album whose files are properly tagged). For every
  /// other album the two orders are indistinguishable.
  factory ArtworkWiring.production({
    required Directory appDataDir,
    bool backfillEnabled = true,
  }) {
    final stores = ArtworkStoreRegistry(appDataDir: appDataDir);
    return ArtworkWiring(
      stores: stores,
      resolver: ArtworkResolver(stores: stores, preferSidecar: true),
      backfillEnabled: backfillEnabled,
    );
  }

  // -------------------------------------------------------------------------
  // A1 -> A2 : the background best-guess pass
  // -------------------------------------------------------------------------

  /// A2's [ArtworkSearch] seam over A1's [searchAll]. Results are cached by
  /// album key so a picker opened right after the pass doesn't re-query.
  /// Never throws (A1 already guarantees `[]` over an exception; the
  /// try/catch is belt-and-braces because A2 treats a throw as
  /// `searchFailed`, which would silently skip the album).
  Future<List<dynamic>> searchForBackfill(ArtworkQuery query) =>
      searchCandidates(query.artist, query.album, albumKey: query.albumKey);

  /// Runs the three keyless providers for an album and caches the result.
  ///
  /// [priority] and [caaBudget] (adversarial review finding 2) are forwarded
  /// verbatim to [searchAll] -- see its doc. Every caller in this file other
  /// than [_pickerSearch] uses the defaults (background priority, no CAA
  /// budget), which is exactly the pre-fix behavior for the automatic pass.
  Future<List<ArtCandidate>> searchCandidates(
    String artist,
    String album, {
    String? albumKey,
    bool forceRefresh = false,
    RateLimitPriority priority = RateLimitPriority.background,
    Duration? caaBudget,
  }) async {
    final key =
        albumKey ?? artworkAlbumKey(artist: artist, album: album, title: album);
    if (!forceRefresh) {
      final hit = candidates.get(key);
      if (hit != null) return hit;
    }
    List<ArtCandidate> found;
    try {
      found = await searchAll(
        ArtQuery(artist: artist, album: album),
        fetch: fetch,
        limiter: caaLimiter,
        priority: priority,
        caaBudget: caaBudget,
      );
    } catch (_) {
      return const <ArtCandidate>[];
    }
    // Rank here, once: the picker grid wants best-first, and the scorer is
    // pure so doing it at the seam costs nothing and keeps both consumers
    // (grid order, auto-apply) reading from the same ordering.
    final ranked = [
      for (final s in rankCandidates(
        ArtQuery(artist: artist, album: album),
        found,
      ))
        s.candidate,
    ];
    candidates.put(key, ranked);
    return ranked;
  }

  /// A2's [ArtworkAutoPick] seam over A1's [bestGuess] -- i.e. the plan's
  /// "top score >= 75 AND >= 10 clear of the runner-up" rule, unmodified.
  ArtworkPick? autoPick(List<dynamic> found, ArtworkQuery query) {
    final typed = found.whereType<ArtCandidate>().toList();
    if (typed.isEmpty) return null;
    final best = bestGuess(
      ArtQuery(artist: query.artist, album: query.album),
      typed,
    );
    return best == null
        ? null
        : ArtworkPick(url: best.url, source: best.sourceId);
  }

  /// A2's [ArtworkDownloader] seam. A null result is "candidate rejected",
  /// which the background pass reports as `downloadFailed` -- deliberately
  /// NOT recorded as a negative result, since a Cover Art Archive URL is
  /// derived from a MusicBrainz id without checking an image was archived
  /// and may legitimately 404.
  Future<List<int>?> download(String url) => images.bytes(url);

  // -------------------------------------------------------------------------
  // A2 -> A3 : the picker's services
  // -------------------------------------------------------------------------

  /// The single [ArtworkServices] instance both picker entry points take.
  late final ArtworkServices services = ArtworkServices(
    search: _pickerSearch,
    apply: _pickerApply,
    remove: _pickerRemove,
    loadThumb: images.bytes,
    currentSelectionId: _currentSelectionId,
  );

  /// The picker's search -- ALWAYS [RateLimitPriority.interactive] (jumps
  /// any currently-queued background backfill lookups on the shared
  /// MusicBrainz limiter) and bounded by [kInteractiveCaaBudget] (proceeds
  /// with whatever iTunes/Deezer already found rather than making the
  /// picker's spinner wait on a slow Cover Art Archive). Adversarial review
  /// finding 2 -- see [RateLimitPriority] and [searchAll]'s doc.
  Future<List<PickerCandidate>> _pickerSearch(
    Track track,
    ArtworkQuery query, {
    bool forceRefresh = false,
  }) async {
    final req = ArtworkRequest.forTrack(track);
    final store = stores.forRoot(track.rootPath);
    // Loading here is what makes the synchronous [_currentSelectionId] read
    // correct: the grid is only built after this future completes.
    try {
      await store.ensureLoaded();
    } catch (_) {
      // A sidecar we can't read just means "nothing recorded".
    }
    if (forceRefresh) {
      // The plan's rule: a manual "Search again" bypasses the negative
      // cache -- and clears it, so the automatic pass isn't suppressed for
      // the next fortnight either.
      try {
        await store.clearMiss(req.albumKey);
      } catch (_) {}
    }
    final found = await searchCandidates(
      query.artist,
      query.album,
      albumKey: req.albumKey,
      forceRefresh: forceRefresh,
      priority: RateLimitPriority.interactive,
      caaBudget: kInteractiveCaaBudget,
    );
    return [for (final c in found) toPickerCandidate(c)];
  }

  Future<void> _pickerApply(
    Track track,
    String albumKey,
    ArtworkChoice choice,
  ) async {
    final req = ArtworkRequest.forTrack(track);
    final localPath = choice.localPath;
    final url = choice.url;
    final origin = localPath ?? url ?? '';
    List<int>? bytes;
    if (localPath != null && localPath.isNotEmpty) {
      bytes = await readLocal(localPath);
    } else if (url != null && url.isNotEmpty) {
      bytes = await images.bytes(url);
    }
    if (bytes == null || bytes.isEmpty) {
      // Surfaced by the picker as "Could not save that artwork." and it
      // stays open, which is the honest outcome: nothing was stored.
      throw const ArtworkApplyFailure();
    }
    final entry = await resolver.applyImage(
      req,
      bytes,
      source: choice.source,
      query: choice.query.isEmpty ? req.query.terms : choice.query,
      origin: origin,
      extension: artworkExtensionFor(origin),
      // A pick in the picker is a statement about THIS track and nothing
      // else. It used to write the album key too, so choosing a cover for one
      // mix silently replaced it on every track sharing that album label.
      scope: ArtworkApplyScope.track,
    );
    if (entry == null) throw const ArtworkApplyFailure();
  }

  Future<void> _pickerRemove(Track track, String albumKey) =>
      resolver.removeImage(ArtworkRequest.forTrack(track));

  /// The `origin` (candidate URL / pasted URL / chosen path) currently
  /// stored for this album, so the grid can mark the applied tile.
  /// Synchronous by contract; safe because the picker's search awaited
  /// `ensureLoaded()` before the grid was built.
  String? _currentSelectionId(Track track, String albumKey) {
    final store = stores.forRoot(track.rootPath);
    // The track's own pick is what the grid should mark, when it has one.
    final entry =
        store.entryFor(trackArtKey(track.contentId)) ?? store.entryFor(albumKey);
    final origin = entry?.origin ?? '';
    return origin.isEmpty ? null : origin;
  }
}

/// Thrown by the picker's apply path when nothing could be stored (the image
/// couldn't be fetched/read, or neither the root nor the app data dir was
/// writable). The picker catches it and keeps itself open with an inline
/// error rather than pretending the choice landed.
class ArtworkApplyFailure implements Exception {
  const ArtworkApplyFailure();
  @override
  String toString() => 'ArtworkApplyFailure: artwork could not be stored';
}
