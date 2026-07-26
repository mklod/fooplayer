// Last modified: 2026-07-25--2214
//
// Artwork sidecar storage (Plan 4, task A2).
//
// One `.artwork.json` per LIBRARY ROOT, with downloaded/chosen images in a
// `<root>/.artwork/` cache dir beside it, so the whole thing travels with
// the music folder and the `.library.json` manifest schema stays untouched.
// Never writes into album directories (v1 constraint: no `folder.jpg`
// injection), and never touches any user music file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'album_key.dart';

/// The per-root sidecar and its atomic-write companions -- same
/// tmp/`.bak` discipline (and the same names-next-to-each-other layout) as
/// `fooplayer_core`'s `saveManifest`.
const artworkSidecarName = '.artwork.json';
const artworkSidecarBakName = '.artwork.json.bak';
const artworkSidecarTmpName = '.artwork.json.tmp';

/// Image cache directory name, created directly under a library root (never
/// inside an album directory).
const artworkCacheDirName = '.artwork';

/// Sidecar schema version written by this build.
const artworkSidecarSchema = 1;

/// How long a *negative* lookup result (nothing good enough found online)
/// suppresses re-querying for that album. Long enough that a full library's
/// hopeless albums aren't re-queried on every launch, short enough that a
/// provider gaining the release eventually gets noticed.
const defaultArtworkNegativeTtl = Duration(days: 14);

/// Image file extensions we are willing to reuse for the cached copy. The
/// extension is cosmetic (`Image.memory` sniffs the real format), but keeping
/// a PNG named `.png` makes the `.artwork/` dir legible to a human.
const _knownImageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// Extension to store [urlOrPath]'s bytes under; `.jpg` when it isn't
/// obvious (every provider we use serves JPEG).
String artworkExtensionFor(String urlOrPath) {
  var s = urlOrPath;
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  final dot = s.lastIndexOf('.');
  if (dot < 0 || dot < s.length - 6) return '.jpg';
  final ext = s.substring(dot).toLowerCase();
  return _knownImageExtensions.contains(ext) ? ext : '.jpg';
}

/// One recorded artwork choice -- auto-applied best guess, or a user pick.
///
/// [file] is a path RELATIVE to the image cache directory (a bare filename
/// in practice), exactly as the plan specifies, so the sidecar stays
/// portable when the folder is copied to another machine/drive letter.
class ArtworkEntry {
  final String file;

  /// `itunes` | `deezer` | `caa` | `local` | `url` | `embedded`.
  final String source;
  final DateTime pickedAt;

  /// What was searched to find this (or the local path / URL the user gave)
  /// -- purely informational, surfaced by the picker.
  final String query;

  /// Where the image came from: the provider candidate's full-size URL, the
  /// URL the user pasted, or the absolute path of a file they chose.
  ///
  /// Additive to the plan's documented entry shape (like `external` and the
  /// top-level `misses` map) and tolerated by older readers, which simply
  /// ignore the key. It exists so the picker can mark the candidate that is
  /// *currently* applied: the grid identifies candidates by URL, and without
  /// this the sidecar records only the cached filename, which no candidate
  /// can be compared against.
  final String origin;

  /// True when the image lives in the app data dir instead of under the
  /// library root, because the root turned out not to be writable. The
  /// sidecar recording it is then also in the app data dir (see
  /// [ArtworkStore.external]).
  final bool external;

  const ArtworkEntry({
    required this.file,
    required this.source,
    required this.pickedAt,
    this.query = '',
    this.origin = '',
    this.external = false,
  });

  Map<String, dynamic> toJson() => {
        'file': file,
        'source': source,
        'pickedAt': pickedAt.toUtc().toIso8601String(),
        'query': query,
        if (origin.isNotEmpty) 'origin': origin,
        if (external) 'external': true,
      };

  /// Tolerant parse: a malformed/partial entry yields null rather than
  /// throwing, so one bad record can't take the whole sidecar down.
  static ArtworkEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final file = raw['file'];
    if (file is! String || file.isEmpty) return null;
    final source = raw['source'];
    final pickedAt = DateTime.tryParse(raw['pickedAt'] as String? ?? '');
    return ArtworkEntry(
      file: file,
      source: source is String && source.isNotEmpty ? source : 'unknown',
      pickedAt: (pickedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).toUtc(),
      query: raw['query'] is String ? raw['query'] as String : '',
      origin: raw['origin'] is String ? raw['origin'] as String : '',
      external: raw['external'] == true,
    );
  }
}

/// A recorded *negative* result: we looked and found nothing good enough.
/// Timestamped so it expires (see [defaultArtworkNegativeTtl]) and so a
/// manual "Search again" can be told apart from an automatic retry.
class ArtworkMiss {
  final DateTime at;
  final String query;
  const ArtworkMiss({required this.at, this.query = ''});

  Map<String, dynamic> toJson() =>
      {'at': at.toUtc().toIso8601String(), 'query': query};

  static ArtworkMiss? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    if (at == null) return null;
    return ArtworkMiss(
      at: at.toUtc(),
      query: raw['query'] is String ? raw['query'] as String : '',
    );
  }
}

/// Parsed `.artwork.json` contents.
class ArtworkSidecar {
  final int schema;
  final Map<String, ArtworkEntry> art;
  final Map<String, ArtworkMiss> misses;

  ArtworkSidecar({
    this.schema = artworkSidecarSchema,
    Map<String, ArtworkEntry>? art,
    Map<String, ArtworkMiss>? misses,
  })  : art = art ?? {},
        misses = misses ?? {};

  Map<String, dynamic> toJson() => {
        'schema': artworkSidecarSchema,
        'art': art.map((k, v) => MapEntry(k, v.toJson())),
        // Additive to the plan's documented shape; readers that don't know
        // about it simply ignore the key, and a sidecar written by an older
        // build (no `misses`) parses fine below.
        'misses': misses.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// Tolerant parse. Anything unrecognizable (wrong schema, non-object,
  /// junk entries) degrades to "no data" rather than throwing: a corrupt
  /// sidecar must never stop the app from showing music.
  static ArtworkSidecar parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return ArtworkSidecar();
      if (j['schema'] != artworkSidecarSchema) return ArtworkSidecar();
      final art = <String, ArtworkEntry>{};
      final rawArt = j['art'];
      if (rawArt is Map) {
        rawArt.forEach((k, v) {
          final e = ArtworkEntry.fromJson(v);
          if (k is String && e != null) art[k] = e;
        });
      }
      final misses = <String, ArtworkMiss>{};
      final rawMisses = j['misses'];
      if (rawMisses is Map) {
        rawMisses.forEach((k, v) {
          final m = ArtworkMiss.fromJson(v);
          if (k is String && m != null) misses[k] = m;
        });
      }
      return ArtworkSidecar(art: art, misses: misses);
    } catch (_) {
      return ArtworkSidecar();
    }
  }
}

/// Per-library-root artwork storage.
///
/// **Write location.** Normally `<root>/.artwork.json` plus
/// `<root>/.artwork/<hash>.jpg`. The first write probes the root for
/// writability; if it isn't writable (read-only share, permissions, a root
/// that no longer exists), everything falls back to
/// `<appDataDir>/artwork/<rootHash>/` and every entry written there is
/// flagged `external: true`, exactly as the plan requires. `<rootHash>`
/// keeps two different roots' external caches from colliding.
///
/// **Atomicity.** [save] writes `.artwork.json.tmp`, moves any existing
/// `.artwork.json` to `.artwork.json.bak`, then renames the tmp into place
/// -- byte-for-byte the discipline `saveManifest` uses, so a crash mid-write
/// leaves either the complete previous sidecar or the complete new one.
/// Saves are serialized through an internal chain so two concurrent
/// mutations can't interleave their renames. The sidecar is a DIFFERENT
/// file from `.library.json`, so it never interferes with a rescan's or
/// PlaylistStore's manifest write even though they share a directory.
class ArtworkStore {
  /// The library root this store serves. Only ever written at its top level
  /// (`.artwork.json`, `.artwork/`) -- never inside an album directory.
  final Directory root;

  /// App data dir (e.g. `%APPDATA%\fooplayer`) used for the read-only-root
  /// fallback. Nothing is created here unless the fallback actually fires.
  final Directory appDataDir;

  /// TTL for [isNegative]; see [defaultArtworkNegativeTtl].
  final Duration negativeTtl;

  /// Clock seam so tests can age a negative-cache entry without sleeping.
  final DateTime Function() now;

  ArtworkStore({
    required this.root,
    required this.appDataDir,
    this.negativeTtl = defaultArtworkNegativeTtl,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  ArtworkSidecar _sidecar = ArtworkSidecar();
  bool _loaded = false;
  Future<void>? _loading;
  Directory? _writeDir;
  bool _external = false;
  Future<void> _writeChain = Future<void>.value();
  Future<void>? _pendingSave;

  /// True once a write has been attempted and the library root turned out
  /// not to be writable, so images + sidecar live under [appDataDir].
  bool get external => _external;

  /// The `<appDataDir>/artwork/<rootHash>/` bucket used by the read-only
  /// fallback. Computed, not created, until a fallback write happens.
  Directory get externalDir => Directory(
      p.join(appDataDir.path, 'artwork', artworkHash(_canonicalRootPath)));

  /// False for the placeholder empty root some test fixtures carry
  /// ([Track.rootPath] defaults to `''`). Without this guard an empty root
  /// would resolve `.artwork.json` / `.artwork/` RELATIVE to the process's
  /// working directory -- reading, and eventually creating, files wherever
  /// the app happens to have been launched from.
  bool get _hasRoot => root.path.trim().isNotEmpty;

  String get _canonicalRootPath {
    final normalized = p.normalize(root.path);
    // Windows paths are case-insensitive; fold so `L:\Music` and `l:\music`
    // share one external bucket instead of two.
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  File get _rootSidecarFile => File(p.join(root.path, artworkSidecarName));
  File get _externalSidecarFile =>
      File(p.join(externalDir.path, artworkSidecarName));

  /// Loads the sidecar (idempotent, deduped -- concurrent callers share one
  /// read). Both possible locations are read: the root's sidecar first,
  /// then the external one layered ON TOP, so a root that became read-only
  /// after some entries were already stored keeps showing both sets with
  /// the newer (external) records winning.
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final merged = ArtworkSidecar();
    final sources = [
      if (_hasRoot) _rootSidecarFile,
      _externalSidecarFile,
    ];
    for (final file in sources) {
      try {
        if (!await file.exists()) continue;
        final parsed = ArtworkSidecar.parse(await file.readAsString());
        merged.art.addAll(parsed.art);
        merged.misses.addAll(parsed.misses);
      } catch (_) {
        // Unreadable sidecar (permissions, disappeared mid-read, ...) is
        // treated exactly like "no sidecar": artwork is a nicety, never a
        // reason to fail a library load.
      }
    }
    _sidecar = merged;
    _loaded = true;
    _loading = null;
  }

  /// The in-memory sidecar. Empty (never null) before [ensureLoaded] runs,
  /// so synchronous callers see "nothing recorded yet" rather than an
  /// error; every mutator awaits [ensureLoaded] first, so a pre-load read
  /// can't cause a disk load to be skipped or a mutation to be lost.
  ArtworkSidecar get sidecar => _sidecar;

  /// The recorded choice for [albumKey], or null.
  ArtworkEntry? entryFor(String albumKey) => sidecar.art[albumKey];

  /// The on-disk image for [albumKey], or null when there's no entry.
  /// Existence is NOT checked here (that's an I/O call the caller is
  /// already doing when it reads the bytes).
  File? imageFileFor(String albumKey) {
    final e = entryFor(albumKey);
    if (e == null) return null;
    final dir = e.external
        ? externalDir
        : Directory(p.join(root.path, artworkCacheDirName));
    return File(p.join(dir.path, e.file));
  }

  /// Reads the bytes of [albumKey]'s recorded image, or null when there's
  /// no entry / the file vanished / it can't be read.
  Future<List<int>?> readImage(String albumKey) async {
    final f = imageFileFor(albumKey);
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Records [bytes] as [albumKey]'s artwork and persists the sidecar.
  ///
  /// Returns the written entry, or null when even the fallback location
  /// couldn't be written (no art recorded -- callers just keep showing the
  /// placeholder). Writing an entry clears any negative-cache record for
  /// the same key.
  Future<ArtworkEntry?> putImage(
    String albumKey,
    List<int> bytes, {
    required String source,
    String query = '',
    String origin = '',
    String extension = '.jpg',
  }) async {
    await ensureLoaded();
    final dir = _resolveWriteDir();
    if (dir == null) return null;
    final name = '${artworkHash(albumKey)}$extension';
    try {
      // tmp-then-rename for the image too: a half-written jpg that a later
      // launch happily "finds" would be worse than no art at all.
      final tmp = File(p.join(dir.path, '$name.tmp'));
      await tmp.writeAsBytes(bytes, flush: true);
      final target = File(p.join(dir.path, name));
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (_) {
      return null;
    }
    final entry = ArtworkEntry(
      file: name,
      source: source,
      pickedAt: now().toUtc(),
      query: query,
      origin: origin,
      external: _external,
    );
    sidecar.art[albumKey] = entry;
    sidecar.misses.remove(albumKey);
    await save();
    return entry;
  }

  /// Drops [albumKey]'s recorded choice (and its cached image file, best
  /// effort) and persists. Used by the picker's "Remove artwork".
  Future<void> remove(String albumKey) async {
    await ensureLoaded();
    final f = imageFileFor(albumKey);
    sidecar.art.remove(albumKey);
    if (f != null) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Leaving an orphan image behind is harmless; failing the removal
        // the user asked for is not.
      }
    }
    await save();
  }

  /// Records that a lookup for [albumKey] found nothing worth applying.
  Future<void> recordMiss(String albumKey, {String query = ''}) async {
    await ensureLoaded();
    sidecar.misses[albumKey] = ArtworkMiss(at: now().toUtc(), query: query);
    await save();
  }

  /// Forgets [albumKey]'s negative result -- what manual "Search again"
  /// calls so a user-initiated retry is never suppressed.
  Future<void> clearMiss(String albumKey) async {
    await ensureLoaded();
    if (sidecar.misses.remove(albumKey) == null) return;
    await save();
  }

  /// True when [albumKey] has a *fresh* negative result: an automatic
  /// lookup should be skipped. Expires after [negativeTtl].
  bool isNegative(String albumKey) {
    final m = sidecar.misses[albumKey];
    if (m == null) return false;
    return now().toUtc().difference(m.at) < negativeTtl;
  }

  /// Persists the sidecar atomically.
  ///
  /// **Serialized:** concurrent calls queue on [_writeChain] so two
  /// mutations can never interleave their renames.
  ///
  /// **Coalesced:** while a write is still *queued* (not yet started),
  /// further mutations join it instead of queueing their own -- the queued
  /// write serializes whatever the sidecar holds when it actually starts,
  /// so it already contains them. Without this, a background pass over a
  /// 10k-album library would rewrite a steadily-growing JSON file once per
  /// album (quadratic I/O on an SMB share). The returned future still only
  /// completes once a write that INCLUDES the caller's mutation has landed:
  /// [_pendingSave] is cleared synchronously just before [_saveNow]
  /// snapshots the sidecar, so a mutation made after that point always
  /// queues a fresh write.
  Future<void> save() {
    final pending = _pendingSave;
    if (pending != null) return pending;
    final next = _writeChain.then((_) {
      _pendingSave = null;
      return _saveNow();
    });
    _pendingSave = next;
    // Keep the chain alive even if one save fails, so a single transient
    // failure doesn't wedge every later write.
    _writeChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _saveNow() async {
    final dir = _resolveWriteDir();
    if (dir == null) return;
    final target = _external ? _externalSidecarFile : _rootSidecarFile;
    final json = const JsonEncoder.withIndent('  ').convert(sidecar.toJson());
    try {
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      if (await target.exists()) {
        final bak = File(p.join(target.parent.path, artworkSidecarBakName));
        if (await bak.exists()) await bak.delete();
        // renameSync does not overwrite on Windows -- delete first, exactly
        // like saveManifest / writeConfigFile.
        await target.rename(bak.path);
      }
      await tmp.rename(target.path);
    } catch (_) {
      // Best effort: a sidecar we couldn't persist just means the choice
      // doesn't survive restart. It must never surface as an exception to
      // the UI.
    }
  }

  /// Picks (and memoizes) the directory writes go to: `<root>/.artwork/`
  /// when the root is writable, else `<appDataDir>/artwork/<rootHash>/`.
  /// Returns null only when NEITHER is writable, in which case artwork is
  /// simply not persisted this session.
  Directory? _resolveWriteDir() {
    final cached = _writeDir;
    if (cached != null) return cached;
    if (!_hasRoot) return _resolveExternalWriteDir();
    final rootCache = Directory(p.join(root.path, artworkCacheDirName));
    try {
      rootCache.createSync(recursive: true);
      // createSync alone doesn't prove writability on a read-only share
      // that already has the dir -- probe with a real file.
      final probe = File(p.join(rootCache.path, '.probe'));
      probe.writeAsStringSync('');
      probe.deleteSync();
      _external = false;
      return _writeDir = rootCache;
    } catch (_) {
      // Falls through to the app-data fallback below.
    }
    return _resolveExternalWriteDir();
  }

  Directory? _resolveExternalWriteDir() {
    try {
      final ext = externalDir;
      ext.createSync(recursive: true);
      _external = true;
      return _writeDir = ext;
    } catch (_) {
      return null;
    }
  }
}

/// Memoizing per-root [ArtworkStore] factory.
///
/// Artwork is stored per library root, so a multi-root library gets one
/// store (and one sidecar) per root -- which is also what keeps album-key
/// collisions ACROSS roots from sharing a cache file: each root's images
/// live under its own `.artwork/`, and each root's external fallback lives
/// in its own path-hashed bucket.
class ArtworkStoreRegistry {
  final Directory appDataDir;
  final Duration negativeTtl;
  final DateTime Function()? now;

  ArtworkStoreRegistry({
    required this.appDataDir,
    this.negativeTtl = defaultArtworkNegativeTtl,
    this.now,
  });

  final Map<String, ArtworkStore> _stores = {};

  ArtworkStore forRoot(String rootPath) => _stores.putIfAbsent(
        Platform.isWindows ? rootPath.toLowerCase() : rootPath,
        () => ArtworkStore(
          root: Directory(rootPath),
          appDataDir: appDataDir,
          negativeTtl: negativeTtl,
          now: now,
        ),
      );

  Iterable<ArtworkStore> get stores => _stores.values;
}
