// Last modified: 2026-07-25--2208
//
// Background best-guess artwork pass (Plan 4, task A2).
//
// Runs AFTER the library has settled, over albums that still show no art,
// and auto-applies a provider best guess when -- and only when -- A1's
// scorer says it's confident enough (top score >= 75 AND >= 10 clear of the
// runner-up; that rule lives entirely behind the injected [ArtworkAutoPick]
// seam, so this file never second-guesses it).
//
// Manners, per the plan: off the UI path (every step async), at most
// [ArtworkBackfill.maxConcurrent] lookups in flight, a throttle gap between
// lookups, a per-album guard so one album is looked up once per pass,
// negative results cached with a timestamp so the same hopeless album isn't
// re-queried every launch, and cancellable at any point. It NEVER touches
// `LibraryModel.status` -- the status line belongs to scanning/enrichment
// and stays exactly as it was.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../model/track.dart';
import 'artwork_resolver.dart';
import 'artwork_store.dart';

/// Default pause between consecutive lookups started by one worker. With
/// [ArtworkBackfill.maxConcurrent] = 3 this keeps the aggregate request rate
/// civil for keyless public APIs (the MusicBrainz <=1 req/sec rule is
/// enforced inside A1's provider, which is where it belongs).
const defaultArtworkBackfillGap = Duration(milliseconds: 400);

/// Outcome of one album's lookup -- returned by [ArtworkBackfill.lookupOne]
/// so the picker (A3) can report "nothing found" vs "applied" without
/// re-deriving it.
enum ArtworkLookupResult {
  /// Album already had art (embedded / sidecar / sibling file).
  alreadyHadArt,

  /// Skipped because a fresh negative result was recorded.
  suppressedByNegativeCache,

  /// Providers returned nothing, or nothing scored high enough to
  /// auto-apply. A negative result was recorded.
  noConfidentMatch,

  /// A provider layer threw despite its "degrade silently" contract. NOT
  /// recorded as a negative result: the failure says nothing about whether
  /// art exists.
  searchFailed,

  /// A candidate was chosen but its bytes couldn't be downloaded/stored.
  downloadFailed,

  /// Art was downloaded, stored in the sidecar and applied.
  applied,

  /// The pass was cancelled (or superseded) before this album finished.
  cancelled,
}

/// The throttled background best-guess pass.
///
/// Construct once (production: alongside the resolver in `main`), then call
/// [run] with one request per album whenever the library settles. [run] is
/// fire-and-forget: nothing on the UI path awaits it.
///
/// **Cancellation is generational.** Every [run] takes the next generation
/// number and every step checks that it is still the current one; [cancel]
/// simply bumps the counter. So a new pass (or a shutdown) supersedes the
/// old one immediately -- no waiting on in-flight network I/O -- and runs
/// are serialized through an internal chain so two passes can never overlap
/// and hammer the providers.
class ArtworkBackfill {
  final ArtworkResolver resolver;

  /// Provider search seam -- A1's `searchAll`, adapted. See
  /// [ArtworkSearch]; expected to degrade silently, but a throw is caught
  /// here anyway.
  final ArtworkSearch search;

  /// Scorer + auto-apply-threshold seam -- A1's `bestGuess`, adapted. See
  /// [ArtworkAutoPick]; returns null when nothing is confident enough.
  final ArtworkAutoPick autoPick;

  /// Image fetch seam. Injected so no test touches the network.
  final ArtworkDownloader downloader;

  final int maxConcurrent;
  final Duration gap;

  /// Master switch for the automatic pass. When false, [run] does nothing
  /// at all (and [lookupOne] -- the picker's manual path -- is unaffected).
  ///
  /// It exists for two reasons. The immediate one: while the provider seams
  /// are still stubs (before task A1 is merged), every album would come
  /// back "no confident match" and earn a 14-day negative-cache record,
  /// poisoning the sidecar before the real providers ever ran. The lasting
  /// one: this is where a user-facing "look up artwork online" preference
  /// plugs in.
  final bool enabled;

  ArtworkBackfill({
    required this.resolver,
    required this.search,
    required this.autoPick,
    required this.downloader,
    this.maxConcurrent = 3,
    this.gap = defaultArtworkBackfillGap,
    this.enabled = true,
  });

  int _generation = 0;
  Future<void>? _chain;
  bool _running = false;
  int _considered = 0;
  int _applied = 0;

  bool get running => _running;

  @visibleForTesting
  int get consideredCount => _considered;

  @visibleForTesting
  int get appliedCount => _applied;

  /// Cancels the in-flight (or queued) pass. Safe at any time, never waits
  /// on anything, and leaves nothing half-written: an album is either fully
  /// applied (sidecar saved) or untouched.
  void cancel() => _generation++;

  /// Runs the pass over [requests] -- ideally one per album; duplicates by
  /// album key are collapsed.
  ///
  /// Supersedes any earlier pass (see the class doc). The returned future
  /// completes when this pass finishes, is cancelled, or is superseded.
  Future<void> run(
    List<ArtworkRequest> requests, {
    bool bypassNegativeCache = false,
  }) {
    if (!enabled) return Future<void>.value();
    final gen = ++_generation;
    final next = (_chain ?? Future<void>.value()).then(
      (_) => _runBody(gen, requests, bypassNegativeCache),
    );
    // Keep the chain alive past a failure so one bad pass can't wedge every
    // later one.
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _runBody(
    int gen,
    List<ArtworkRequest> requests,
    bool bypassNegativeCache,
  ) async {
    if (gen != _generation) return; // superseded before we even started
    _running = true;
    _considered = 0;
    _applied = 0;
    try {
      final seen = <String>{};
      final queue = Queue<ArtworkRequest>();
      for (final r in requests) {
        // ROOT-QUALIFIED, exactly like [artworkBackfillRequests], the
        // resolver's cache key and the store registry. Deduping on the album
        // key alone would give a multi-root library (e.g. `L:\music` plus a
        // reorganized copy of the same albums) ONE lookup for an album that
        // exists under two roots: the second root's `.artwork.json` would
        // never get an entry, its tracks would show the placeholder forever,
        // and -- because no miss is recorded either -- nothing would ever
        // mark it unresolved.
        if (seen.add('${r.rootPath}\u0000${r.albumKey}')) queue.add(r);
      }
      final workers = queue.length < maxConcurrent
          ? queue.length
          : maxConcurrent;
      await Future.wait([
        for (var i = 0; i < workers; i++)
          _worker(gen, queue, bypassNegativeCache),
      ]);
    } finally {
      _running = false;
    }
  }

  Future<void> _worker(
    int gen,
    Queue<ArtworkRequest> queue,
    bool bypassNegativeCache,
  ) async {
    while (gen == _generation && queue.isNotEmpty) {
      final req = queue.removeFirst();
      _considered++;
      await _lookup(req, gen, bypassNegativeCache);
      if (gen != _generation) return;
      if (gap > Duration.zero) await Future<void>.delayed(gap);
    }
  }

  /// Looks up (and, if confident, applies) artwork for ONE album.
  ///
  /// Also the entry point for the picker's manual "Search again":
  /// [bypassNegativeCache] `true` ignores a recorded miss AND clears it, so
  /// a user-initiated retry is never silently suppressed.
  Future<ArtworkLookupResult> lookupOne(
    ArtworkRequest req, {
    bool bypassNegativeCache = false,
  }) => _lookup(req, _generation, bypassNegativeCache);

  Future<ArtworkLookupResult> _lookup(
    ArtworkRequest req,
    int gen,
    bool bypassNegativeCache,
  ) async {
    if (gen != _generation) return ArtworkLookupResult.cancelled;
    final store = resolver.stores.forRoot(req.rootPath);
    await store.ensureLoaded();

    if (bypassNegativeCache) {
      await store.clearMiss(req.albumKey);
    } else if (store.isNegative(req.albumKey)) {
      return ArtworkLookupResult.suppressedByNegativeCache;
    }

    // Deliberately NOT resolver.resolve(): a sweep over thousands of albums
    // must not evict the one or two covers the UI is actually showing from
    // the resolver's bounded LRU.
    if (await resolver.hasArt(req)) return ArtworkLookupResult.alreadyHadArt;
    if (gen != _generation) return ArtworkLookupResult.cancelled;

    final query = req.query;
    List<dynamic> candidates;
    try {
      candidates = await search(query);
    } catch (_) {
      return ArtworkLookupResult.searchFailed;
    }
    if (gen != _generation) return ArtworkLookupResult.cancelled;

    ArtworkPick? pick;
    try {
      pick = autoPick(candidates, query);
    } catch (_) {
      pick = null;
    }
    if (pick == null) {
      // The plan's rule: a wrong cover silently applied is worse than none.
      await store.recordMiss(req.albumKey, query: query.terms);
      return ArtworkLookupResult.noConfidentMatch;
    }

    List<int>? bytes;
    try {
      bytes = await downloader(pick.url);
    } catch (_) {
      bytes = null;
    }
    if (gen != _generation) return ArtworkLookupResult.cancelled;
    if (bytes == null || bytes.isEmpty) {
      return ArtworkLookupResult.downloadFailed;
    }

    final ArtworkEntry? entry = await resolver.applyImage(
      req,
      bytes,
      source: pick.source,
      query: query.terms,
      // Recording the winning candidate's URL is what lets the picker mark
      // the auto-applied cover as the current selection when the user opens
      // it later.
      origin: pick.url,
      extension: artworkExtensionFor(pick.url),
    );
    if (entry == null) return ArtworkLookupResult.downloadFailed;
    _applied++;
    return ArtworkLookupResult.applied;
  }
}

/// Rescans (via [rescan]) then queues a background best-guess backfill pass
/// over whatever [tracks] returns afterward.
///
/// Shared by every trigger that calls `LibraryModel.rescan` -- app launch's
/// post-load rescan, main.dart's periodic timer, and the Refresh button in
/// `ui/home_screen.dart` -- so an album added to a watched folder after
/// launch, or one that missed the launch-time pass to a transient network
/// failure, still gets automatic artwork on the very next rescan instead of
/// only on an app restart.
///
/// [rescan] and [tracks] are function seams rather than a `LibraryModel`
/// parameter, so this file keeps its existing "no dependency on the rest of
/// the app" shape (see the file doc) and this helper stays unit-testable
/// with plain fakes. [tracks] is deliberately called only AFTER [rescan]
/// completes, so a rescan that discovers new tracks queues a backfill pass
/// that actually covers them.
///
/// Fire-and-forget by every caller (never awaited on a UI path) -- the
/// returned future exists so a caller that DOES want to know when the whole
/// thing (rescan + backfill pass) has settled -- e.g. a test -- can await
/// it.
Future<void> rescanThenBackfill({
  required Future<void> Function() rescan,
  required ArtworkBackfill backfill,
  required List<Track> Function() tracks,
  bool yieldToRunningPass = false,
}) async {
  await rescan();
  // A pass already working through the library must not be restarted by a
  // timer tick. [ArtworkBackfill.run] supersedes: it bumps the generation and
  // the in-flight workers exit at their next check. On this library the rescan
  // timer fires every 5 minutes and lookups are throttled to roughly one a
  // second, so an enrichment could never get further than one timer window --
  // measured 2026-07-28, a manual pass over 101 compilation volumes managed 33
  // before the tick cut it off, then began again from the top. It converged
  // only because the negative cache made the redone albums cheap.
  //
  // Set by the periodic caller, not the manual one: pressing "Enrich artwork"
  // deliberately supersedes whatever is running, because it is a request to
  // start now.
  if (yieldToRunningPass && backfill.running) return;
  await backfill.run(artworkBackfillRequests(tracks()));
}

/// One [ArtworkRequest] per album across [tracks] -- what [ArtworkBackfill.run]
/// wants. First track of each album key wins (that's the file whose embedded
/// art / sibling folder image gets checked).
List<ArtworkRequest> artworkBackfillRequests(Iterable<Track> tracks) {
  final seen = <String>{};
  final out = <ArtworkRequest>[];
  for (final t in tracks) {
    final req = ArtworkRequest.forTrack(t);
    if (seen.add('${t.rootPath}\u0000${req.albumKey}')) out.add(req);
  }
  return out;
}
