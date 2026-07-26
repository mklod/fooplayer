// Last modified: 2026-07-25--2214
//
// Display-side artwork resolution (Plan 4, task A2).
//
// ONE place decides what image a given track shows, so the desktop
// now-playing bar, the phone mini-player, the phone Now Playing page and
// any future album grid all agree and all share one cache:
//
//   embedded tag art -> sidecar choice (user pick / auto best guess)
//   -> folder.jpg / cover.jpg / front.jpg beside the audio file -> null
//
// Never blocks the caller: every step is async, results are cached in
// memory per album key, and concurrent requests for the same album share a
// single in-flight future.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../metadata/tags.dart' show readArtSafe;
import '../model/track.dart';
import 'album_key.dart';
import 'artwork_store.dart';

export 'album_key.dart' show ArtworkQuery, normalizeArtworkText, artworkAlbumKey;

/// Reads embedded cover art out of an audio file. Defaults to
/// [readArtSafe] -- the isolate-bounded, timeout-guarded reader; a
/// pathological file must never be able to stall art resolution.
typedef ArtworkEmbeddedLoader = Future<List<int>?> Function(File file);

/// Fetches image bytes for a URL. Injected (never constructed here) so no
/// test can hit the network: production wires an `http`-backed function,
/// tests wire a fake.
typedef ArtworkDownloader = Future<List<int>?> Function(String url);

// ---------------------------------------------------------------------------
// Provider seam
//
// A2 must not depend on A1's concrete provider/candidate API (the two were
// built in parallel), so the online-lookup side is expressed as two tiny
// function seams over `dynamic` candidates. The merge wires A1 in by
// adapting `searchAll` / `bestGuess` to these signatures; nothing in this
// file or the background pass ever inspects a candidate's fields.
// ---------------------------------------------------------------------------

// [ArtworkQuery] -- what an online lookup is asked for -- lives in
// album_key.dart, shared with the picker (A3). See the note on its
// declaration: one query type, one album-key spelling.

/// The one thing this half of the feature needs out of a candidate: where to
/// download it from and which provider it came from. A1's `ArtCandidate`
/// maps onto this in one line at merge time.
class ArtworkPick {
  final String url;

  /// `itunes` | `deezer` | `caa` | `local` | `url`.
  final String source;
  const ArtworkPick({required this.url, required this.source});
}

/// Runs the online providers for [query] and returns their candidates.
/// Deliberately `List<dynamic>`: the candidate type belongs to A1.
/// Implementations must degrade silently (return `[]`, never throw).
typedef ArtworkSearch = Future<List<dynamic>> Function(ArtworkQuery query);

/// Applies A1's deterministic scorer + auto-apply rule (top score >= 75 AND
/// >= 10 clear of the runner-up) to [candidates], returning the winner or
/// null when nothing is confident enough to apply automatically. Pure.
typedef ArtworkAutoPick = ArtworkPick? Function(
  List<dynamic> candidates,
  ArtworkQuery query,
);

/// Sibling image filenames checked beside the audio file, in order. Only
/// ever READ -- v1 never writes a `folder.jpg` into an album directory.
const artworkSiblingBaseNames = ['folder', 'cover', 'front'];
const artworkSiblingExtensions = ['.jpg', '.jpeg', '.png'];

/// Everything the resolver needs about one track.
@immutable
class ArtworkRequest {
  final String rootPath;
  final File file;
  final String artist;
  final String album;
  final String title;
  final String albumKey;

  ArtworkRequest({
    required this.rootPath,
    required this.file,
    this.artist = '',
    this.album = '',
    this.title = '',
  }) : albumKey = artworkAlbumKey(artist: artist, album: album, title: title);

  factory ArtworkRequest.forTrack(Track t) => ArtworkRequest(
        rootPath: t.rootPath,
        file: File(p.join(t.rootPath, t.relPath)),
        artist: t.artist,
        album: t.album,
        title: t.title,
      );

  ArtworkQuery get query =>
      ArtworkQuery(artist: artist, album: album, albumKey: albumKey);
}

/// Resolves (and caches) the bytes each album's art should display.
///
/// **Album-keyed by design.** Cache *and* in-flight dedupe key on
/// `rootPath + albumKey`, so ten tracks of one album cause one resolution,
/// not ten -- the plan's "all tracks of an album share one artwork entry".
/// The consequence, documented deliberately: the first track of an album to
/// be resolved is the one whose embedded art the album shows. Tracks with
/// no album tag fall back to a single-track key (see [artworkAlbumKey]), so
/// loose files never pool.
///
/// **Bounded.** The byte cache is an LRU capped at [maxCachedAlbums]; art
/// blobs are hundreds of KB and a 10k-track library must not accumulate
/// them. The cached [Uint8List] instance is handed back unchanged on every
/// hit so `Image.memory` keeps hitting Flutter's image cache instead of
/// re-decoding (the invariant `AlbumArt` documents).
class ArtworkResolver extends ChangeNotifier {
  final ArtworkStoreRegistry stores;
  final ArtworkEmbeddedLoader embeddedLoader;

  /// When true, a recorded sidecar choice OUTRANKS embedded tag art.
  ///
  /// Default false = the plan's documented chain (embedded first). The knob
  /// exists because a user who explicitly picks a cover for an album whose
  /// files carry embedded art would otherwise see their pick ignored; the
  /// picker (A3) can flip this without touching the resolution logic.
  final bool preferSidecar;

  final int maxCachedAlbums;

  ArtworkResolver({
    required this.stores,
    this.embeddedLoader = readArtSafe,
    this.preferSidecar = false,
    this.maxCachedAlbums = 64,
  });

  /// LRU of resolved bytes. A present key with a null value means "resolved,
  /// and there is genuinely no art" -- cached so the chain isn't re-run on
  /// every rebuild.
  final LinkedHashMap<String, Uint8List?> _cache = LinkedHashMap();

  /// One future per in-flight cache key: concurrent `resolve` calls for the
  /// same album share it instead of each spawning their own tag-read
  /// isolate.
  final Map<String, Future<List<int>?>> _inFlight = {};

  /// Per-album-key generation counter. A resolution that finishes AFTER its
  /// album was invalidated must not write its now-stale bytes into the
  /// cache -- the same stale-request discipline `AlbumArt` uses for widgets,
  /// applied at the cache layer.
  final Map<String, int> _generation = {};

  int _revision = 0;
  bool _disposed = false;

  /// Bumped on every invalidation. Listeners (see `AlbumArt`) compare it to
  /// decide whether a re-resolve is warranted.
  int get revision => _revision;

  @visibleForTesting
  int get cachedAlbumCount => _cache.length;

  @visibleForTesting
  int get inFlightCount => _inFlight.length;

  /// Cache/dedupe key: root-qualified, so the same album key under two
  /// different library roots can neither share nor clobber the other's
  /// cached image. NUL-separated because NUL appears in neither a path nor
  /// a normalized album key, which makes [invalidate]'s `endsWith` exact.
  String _cacheKey(ArtworkRequest req) => '${req.rootPath}\u0000${req.albumKey}';

  /// Resolves [req]'s art. Never throws; returns null when the chain finds
  /// nothing (the caller shows its placeholder).
  Future<List<int>?> resolve(ArtworkRequest req) {
    if (_disposed) return Future<List<int>?>.value(null);
    final key = _cacheKey(req);
    if (_cache.containsKey(key)) {
      // LRU touch: re-insert so the most recently used entry is last.
      final v = _cache.remove(key);
      _cache[key] = v;
      return Future<List<int>?>.value(v);
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final gen = _generation[req.albumKey] ?? 0;
    final future = _safeResolve(req).then((bytes) {
      _inFlight.remove(key);
      if (_disposed) return bytes;
      // Only cache if nothing invalidated this album while we were working.
      if ((_generation[req.albumKey] ?? 0) == gen) {
        _cache[key] = bytes;
        _trim();
      }
      return bytes;
    });
    _inFlight[key] = future;
    return future;
  }

  /// True when [req]'s album already shows art via any link of the chain.
  ///
  /// Used by the background best-guess pass to decide whether an album
  /// needs an online lookup at all. Deliberately does NOT populate the byte
  /// cache: a sweep over thousands of albums would otherwise evict the one
  /// or two covers the UI is actually displaying. A cache HIT is still
  /// honored (free, and exactly right).
  Future<bool> hasArt(ArtworkRequest req) async {
    if (_disposed) return false;
    final key = _cacheKey(req);
    if (_cache.containsKey(key)) return _cache[key] != null;
    final bytes = await _resolveUncached(req);
    return bytes != null && bytes.isNotEmpty;
  }

  void _trim() {
    while (_cache.length > maxCachedAlbums) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// [_resolveUncached] already swallows every failure mode it knows about;
  /// this is the backstop that guarantees the `.then` in [resolve] runs no
  /// matter what, so a surprise throw can't leave a permanently-stuck entry
  /// in [_inFlight] (every later request for that album would hang forever
  /// on a future that never completes).
  Future<Uint8List?> _safeResolve(ArtworkRequest req) async {
    try {
      return await _resolveUncached(req);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _resolveUncached(ArtworkRequest req) async {
    final store = stores.forRoot(req.rootPath);
    try {
      await store.ensureLoaded();
    } catch (_) {
      // A sidecar we can't load just means "no recorded choice".
    }

    if (preferSidecar) {
      final chosen = await _sidecarBytes(store, req);
      if (chosen != null) return chosen;
    }

    try {
      final embedded = await embeddedLoader(req.file);
      if (embedded != null && embedded.isNotEmpty) return _bytes(embedded);
    } catch (_) {
      // readArtSafe already swallows everything; a custom loader might not.
    }

    if (!preferSidecar) {
      final chosen = await _sidecarBytes(store, req);
      if (chosen != null) return chosen;
    }

    return _siblingBytes(req);
  }

  Future<Uint8List?> _sidecarBytes(ArtworkStore store, ArtworkRequest req) async {
    try {
      final data = await store.readImage(req.albumKey);
      if (data != null && data.isNotEmpty) return _bytes(data);
    } catch (_) {
      // Missing/unreadable cached image: fall through to the next link.
    }
    return null;
  }

  /// `folder.jpg` / `cover.jpg` / `front.jpg` beside the audio file --
  /// checked asynchronously (an `existsSync` storm on an SMB share is
  /// exactly the kind of UI-thread stall this subsystem must not cause).
  Future<Uint8List?> _siblingBytes(ArtworkRequest req) async {
    final Directory dir;
    try {
      dir = req.file.parent;
    } catch (_) {
      return null;
    }
    for (final base in artworkSiblingBaseNames) {
      for (final ext in artworkSiblingExtensions) {
        final f = File(p.join(dir.path, '$base$ext'));
        try {
          if (await f.exists()) {
            final data = await f.readAsBytes();
            if (data.isNotEmpty) return data;
          }
        } catch (_) {
          // Unreadable candidate: try the next name.
        }
      }
    }
    return null;
  }

  Uint8List _bytes(List<int> data) =>
      data is Uint8List ? data : Uint8List.fromList(data);

  /// Drops every cached/in-flight result for [albumKey] (all roots) and
  /// notifies listeners so visible surfaces re-resolve. Called after a
  /// picker choice or a background best guess lands.
  void invalidate(String albumKey) {
    _generation[albumKey] = (_generation[albumKey] ?? 0) + 1;
    _cache.removeWhere((k, _) => k.endsWith('\u0000$albumKey'));
    _bumpRevision();
  }

  /// Drops the whole cache (e.g. library roots changed).
  void invalidateAll() {
    for (final key in _cache.keys.toList()) {
      final albumKey = key.substring(key.indexOf('\u0000') + 1);
      _generation[albumKey] = (_generation[albumKey] ?? 0) + 1;
    }
    _cache.clear();
    _bumpRevision();
  }

  void _bumpRevision() {
    _revision++;
    if (!_disposed) notifyListeners();
  }

  /// Records [bytes] as [req]'s album artwork and refreshes every surface.
  /// Returns the stored entry, or null when nothing could be persisted.
  Future<ArtworkEntry?> applyImage(
    ArtworkRequest req,
    List<int> bytes, {
    required String source,
    String query = '',
    String origin = '',
    String extension = '.jpg',
  }) async {
    final store = stores.forRoot(req.rootPath);
    final entry = await store.putImage(
      req.albumKey,
      bytes,
      source: source,
      query: query,
      origin: origin,
      extension: extension,
    );
    invalidate(req.albumKey);
    return entry;
  }

  /// Clears [req]'s recorded artwork ("Remove artwork" in the picker).
  Future<void> removeImage(ArtworkRequest req) async {
    await stores.forRoot(req.rootPath).remove(req.albumKey);
    invalidate(req.albumKey);
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    _inFlight.clear();
    _generation.clear();
    super.dispose();
  }
}
