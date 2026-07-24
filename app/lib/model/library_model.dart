import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;
import '../metadata/isolate_io.dart';
import '../metadata/meta_cache.dart';
import '../metadata/tags.dart';
import 'filtering.dart';
import 'manifest_io.dart';
import 'track.dart';

/// Cache-misses are enriched off the UI/platform thread in chunks this
/// large; each chunk's synchronous tag-reading runs inside its own isolate
/// (see [_readBatchIsolate]) so no single batch blocks the UI for too long
/// and progress can be reported between batches.
const _enrichBatchSize = 200;

/// How long a whole [_enrichBatchSize]-file batch is allowed to run before
/// it's treated as stuck and retried one file at a time (see
/// [_readBatchIsolate] and [_readBatchResilient]).
///
/// Some real-world files make `audio_metadata_reader`'s MP3 parser scan the
/// *entire* remainder of the file one byte at a time looking for a frame
/// sync it will never find (its `_findFirstMp3Frame` has no upper bound).
/// On local disk that is fast; over the SMB-mounted library share each byte
/// crossing the parser's 16KB read buffer is a network round trip, so one
/// such file can take minutes. 90s is comfortably above every batch
/// observed to be merely slow (not pathological) while still bounding the
/// worst case.
const _defaultBatchTimeout = Duration(seconds: 90);

/// Per-file budget used once a batch has already been flagged as stuck (see
/// [_defaultBatchTimeout]). Generous enough for any individually slow file,
/// short enough that a genuinely pathological file is skipped quickly
/// instead of blocking the rest of its batch.
const _defaultFileTimeout = Duration(seconds: 20);

/// The merged tag cache is flushed to disk after every this-many enrichment
/// batches (and unconditionally once enrichment finishes), so progress
/// survives an app restart partway through a large first-run scan instead
/// of only being saved after every last file has been read.
const _saveEveryNBatches = 5;

/// How long a single root's scan -> diff -> stamp -> save cycle (see
/// [LibraryModel.rescan] and [_rescanRootIsolateEntry]) is allowed to run
/// before it's abandoned and the next root is tried instead.
///
/// `scanLibrary` walks the whole root and stats every audio file, which --
/// like the tag-reading batches above -- is synchronous-heavy over the
/// SMB-mounted library share. A root with a lot of new/changed files (or
/// one that hits a slow-transport pathology of its own) could otherwise
/// stall the entire rescan indefinitely. 120s is generous: a normal
/// incremental rescan (the common case -- a handful of new files since the
/// last one) finishes in a couple of seconds.
const _defaultRescanRootTimeout = Duration(seconds: 120);

/// How long [LibraryModel.updateDuration] waits after the most recent
/// backfilled duration before persisting the batch to the on-disk tag cache
/// (see [LibraryModel.flushPendingDurationSaves]). Long enough to coalesce
/// a burst (e.g. skipping through several duration-less tracks) into one
/// cache write, short enough that a single played track's backfill isn't
/// lost to anything but an immediate app kill.
const _durationSaveDebounce = Duration(seconds: 2);

/// Sortable track-list columns (see the header row in `ui/track_list.dart`
/// and [LibraryModel.setSort]/[LibraryModel.visibleTracks]).
///
/// [trackNumber] backs the '#' column, which is only ever visible (see
/// `ui/track_list.dart`) when exactly one album is selected or a playlist
/// is active -- but it is still a selectable [setSort] target like any
/// other column, both because [setAlbums] switches to it automatically
/// (see its doc) and because that's what makes its header cell clickable
/// the same way every other visible header is.
enum SortColumn { title, artist, album, duration, dateAdded, trackNumber }

class LibraryModel extends ChangeNotifier {
  List<Track> allTracks = [];
  List<ManifestPlaylist> playlists = [];
  /// Configured roots that have no `.library.json` yet, as of the last
  /// [load] -- skipped (not fatal) so the rest of the library still loads.
  /// The settings dialog surfaces these with a "seed with foolib" note.
  List<String> rootsMissingManifest = [];

  /// Configured roots whose `.library.json` exists but failed to parse (as
  /// of the last [load]) -- e.g. truncated by a crash mid-write, or hand
  /// edited into invalid JSON/shape. Same treatment as
  /// [rootsMissingManifest]: skipped, not fatal, so the remaining roots
  /// still load; surfaced by the settings dialog via the same per-root note
  /// pathway, with its own "corrupt, reseed to repair" wording.
  List<String> rootsFailed = [];

  /// The selected library root(s) ([Track.rootPath]), from the Folder
  /// filter panel (`ui/home_screen.dart`) -- occupies the same
  /// top-of-cascade position the old Genre filter used to (see
  /// [setFolders]): narrows [artists]/[albums]/[visibleTracks] and is
  /// itself cleared by [setPlaylist]. Empty means "every folder"; more than
  /// one value ORs together (standard foobar2000 Ctrl+click multi-select --
  /// see [setFolders]/`ui/filter_panel.dart`).
  Set<String> folderFilters = {};
  Set<String> artistFilters = {};
  Set<String> albumFilters = {};
  String search = '';
  String? activePlaylist;
  String status = 'idle';

  /// The single track currently selected in the track list (single-click;
  /// see `ui/track_list.dart`'s `_TrackRow`) -- visual-only for now (a
  /// `selectionFill` background), and the basis for a future multi-select.
  /// Distinct from the currently *playing* track ([PlayerService.current]):
  /// a row can be selected, playing, both, or neither, and each gets its
  /// own independent highlight treatment.
  String? selectedTrackId;

  /// The track-list column [visibleTracks] is currently sorted by, and its
  /// direction. Defaults to date-added, newest first -- matching the feed's
  /// pre-Task-6 behavior exactly. Playlist mode ignores both (playlist
  /// order is always preserved; see [visibleTracks]).
  SortColumn sortColumn = SortColumn.dateAdded;
  bool sortAscending = false;

  /// True while [load] or [rescan] is actively running. Surfaced so the UI
  /// (the Refresh button in the search row) can disable itself, and so
  /// [rescan] itself refuses to start a second overlapping run -- see the
  /// guard at the top of [rescan]. Enrichment (this file's Part B, and
  /// rescan's own post-merge enrichment) only ever runs while this is
  /// already `true`, so it and a fresh [rescan]/[load] call never race on
  /// the shared tag cache or a root's manifest file.
  ///
  /// [load] itself is guarded by the same flag (see [load]'s re-entrancy
  /// doc): a `load()` call that arrives while this is already `true` is
  /// queued (see [_pendingLoad]) rather than run concurrently, so a
  /// settings-triggered reload that arrives mid-enrichment can't clear this
  /// flag out from under a still-running earlier load/rescan (previously
  /// possible, since each call had its own independent `finally { _busy =
  /// false; }`).
  bool get busy => _busy;
  bool _busy = false;

  /// Set by [load] when a new load request arrives while [_busy] already
  /// holds (see [load]'s re-entrancy doc); re-issued by [_runPendingLoad]
  /// once the in-flight [load]/[rescan] releases [_busy]. Only ever holds
  /// the *latest* such request -- an intermediate request superseded by a
  /// newer one before the current operation finishes is simply dropped in
  /// favor of it, so "the latest request eventually wins" rather than every
  /// queued request running in turn.
  Future<void> Function()? _pendingLoad;

  // Remembered from the most recent [load] call so [rescan] -- which takes
  // no arguments of its own -- knows what to rescan. Empty/null until the
  // first [load] completes, at which point [rescan] is still a safe no-op
  // (nothing to do yet).
  List<Directory> _libraryRoots = [];
  File? _cacheFile;
  Duration _enrichBatchTimeout = _defaultBatchTimeout;
  Duration _enrichFileTimeout = _defaultFileTimeout;

  /// Durations backfilled by [updateDuration] since the last cache flush,
  /// keyed by contentId -- what [flushPendingDurationSaves] persists. Kept
  /// separate from the enrichment cache instance (which is local to each
  /// [load]) so a flush can merge into whatever the on-disk cache holds *at
  /// flush time* instead of racing enrichment's own saves with a stale
  /// full-map snapshot.
  final Map<String, int> _pendingDurationUpdates = {};
  Timer? _durationSaveTimer;

  /// Testing seam for [flushPendingDurationSaves]: when set, receives the
  /// pending `contentId -> durationMs` batch instead of the default
  /// merge-into-[_cacheFile] writer, so tests can observe exactly what
  /// would be persisted without touching real files.
  @visibleForTesting
  Future<void> Function(Map<String, int> pending)? durationCacheWriter;

  /// Loads (or reloads) the merged library from [libraryRoots].
  ///
  /// Re-entrancy: if [busy] is already `true` -- another [load] or a
  /// [rescan] is in flight -- this call does NOT run concurrently with it
  /// (which would race the in-flight one's tag-cache/manifest writes).
  /// Instead its arguments are remembered (see [_pendingLoad]) and the
  /// equivalent call is re-issued automatically the moment the current
  /// operation finishes, so e.g. a settings-dialog root add/remove that
  /// lands while the launch load is still enriching still eventually takes
  /// effect rather than being silently dropped or corrupting state -- it
  /// just waits its turn. If several `load()` calls stack up while busy,
  /// only the last one's arguments survive to actually run.
  Future<void> load({
    required List<Directory> libraryRoots,
    required File cacheFile,
    void Function(int done, int total)? onProgress,
    Duration batchTimeout = _defaultBatchTimeout,
    Duration fileTimeout = _defaultFileTimeout,
  }) async {
    if (_busy) {
      _pendingLoad = () => load(
            libraryRoots: libraryRoots,
            cacheFile: cacheFile,
            onProgress: onProgress,
            batchTimeout: batchTimeout,
            fileTimeout: fileTimeout,
          );
      return;
    }
    _libraryRoots = libraryRoots;
    _cacheFile = cacheFile;
    _enrichBatchTimeout = batchTimeout;
    _enrichFileTimeout = fileTimeout;
    _busy = true;
    try {
      await _loadBody(
        libraryRoots: libraryRoots,
        cacheFile: cacheFile,
        onProgress: onProgress,
        batchTimeout: batchTimeout,
        fileTimeout: fileTimeout,
      );
    } finally {
      _busy = false;
    }
    await _runPendingLoad();
  }

  /// Runs and clears [_pendingLoad], if any -- called once each of [load]
  /// and [rescan] releases [_busy], so a `load()` request that arrived
  /// mid-run still eventually takes effect (see [load]'s re-entrancy doc).
  /// No-op if nothing is pending.
  Future<void> _runPendingLoad() async {
    final pending = _pendingLoad;
    if (pending == null) return;
    _pendingLoad = null;
    await pending();
  }

  Future<void> _loadBody({
    required List<Directory> libraryRoots,
    required File cacheFile,
    void Function(int done, int total)? onProgress,
    required Duration batchTimeout,
    required Duration fileTimeout,
  }) async {
    try {
      status = 'loading manifest';
      notifyListeners();

      // Merge every root's manifest: tracks dedupe by contentId, first root
      // wins (so re-ordering roots in settings doesn't shuffle which copy
      // "owns" a track already known from an earlier root); playlists are
      // concatenated, with a same-name collision from a different root
      // suffixed " (2)", " (3)", ... so neither is silently shadowed.
      final mergedTracks = <String, Track>{};
      final mergedPlaylists = <ManifestPlaylist>[];
      final usedPlaylistNames = <String>{};
      final missingManifest = <String>[];
      final failedRoots = <String>[];

      for (final root in libraryRoots) {
        final manifest = File(p.join(root.path, '.library.json'));
        if (!manifest.existsSync()) {
          missingManifest.add(root.path);
          continue;
        }
        final ManifestData data;
        try {
          data = loadManifestFile(manifest, rootPath: root.path);
        } catch (e) {
          // A single root's corrupt/unreadable .library.json (invalid JSON,
          // wrong shape, an unsupported schema version, ...) must not take
          // the rest of a multi-root library down with it -- record it
          // (surfaced via [rootsFailed]) and move on to the remaining
          // roots, exactly like the no-manifest-yet case above.
          failedRoots.add(root.path);
          continue;
        }
        for (final t in data.tracks) {
          mergedTracks.putIfAbsent(t.contentId, () => t);
        }
        for (final pl in data.playlists) {
          mergedPlaylists.add(ManifestPlaylist(
            name: _uniquePlaylistName(pl.name, usedPlaylistNames),
            trackIds: pl.trackIds,
          ));
        }
      }

      rootsMissingManifest = missingManifest;
      rootsFailed = failedRoots;
      playlists = mergedPlaylists;

      if (mergedTracks.isEmpty) {
        allTracks = [];
        status = libraryRoots.isEmpty
            ? 'no library roots configured'
            : 'no .library.json found in any configured root';
        notifyListeners();
        return;
      }

      final cache = MetaCache.load(cacheFile);

      // Part A -- instant feed: apply any cached tags synchronously (cheap
      // map lookups) so the date-sorted view renders within ~2s of launch.
      // Tracks with no cached tags don't wait for background enrichment to
      // get real Title/Artist/Album columns: the manifest constructs every
      // track's `title` as the raw, unsplit filename (see
      // `manifest_io.dart`), so leaving that alone here would show e.g.
      // "RÜFÜS du Sol - The Life" as the Title with Artist/Album blank until
      // enrichment reaches that file, possibly minutes into a large scan.
      // [parseFromFilename] is pure string manipulation -- no file I/O --
      // so running it synchronously over every miss here (thousands of
      // tracks) is cheap and keeps the instant feed's columns properly
      // split from the very first frame. Real tag enrichment (Part B,
      // below) still upgrades these to on-disk tag data afterward.
      final tracks = mergedTracks.values.toList();
      final missing = <int>[]; // indices into `tracks` needing enrichment
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        final tags = cache.entries[t.contentId];
        if (tags == null) {
          final fb = parseFromFilename(t.relPath);
          tracks[i] = t.copyWith(
            title: fb.title,
            artist: fb.artist,
            album: fb.album,
            trackNumber: fb.trackNumber,
          );
          missing.add(i);
          continue;
        }
        tracks[i] = t.copyWith(
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          genre: tags.genre,
          durationMs: tags.durationMs,
          trackNumber: tags.trackNumber,
        );
      }
      allTracks = tracks;
      status = missing.isEmpty ? 'ready' : 'ready (reading tags in background)';
      notifyListeners();

      if (missing.isNotEmpty) {
        // Part B -- off-thread enrichment: read tags for cache misses in
        // batches, each batch's synchronous file I/O running inside its own
        // isolate so the UI/platform thread never blocks on it. Merge
        // results back in between batches so the list keeps updating.
        var done = 0;
        var batchesSinceSave = 0;
        for (var start = 0; start < missing.length; start += _enrichBatchSize) {
          final end = (start + _enrichBatchSize < missing.length)
              ? start + _enrichBatchSize
              : missing.length;
          final batch = missing.sublist(start, end);
          final records = [
            for (final i in batch)
              (
                tracks[i].contentId,
                p.join(tracks[i].rootPath, tracks[i].relPath),
                tracks[i].relPath,
              )
          ];

          Map<String, TrackTags> results;
          try {
            results =
                await _readBatchIsolate(records, timeout: batchTimeout);
          } on TimeoutException {
            // The whole-batch read didn't finish in time, which means at
            // least one file in it is pathologically slow (see
            // _defaultBatchTimeout). Fall back to resolving this batch one
            // file at a time -- each with its own bounded budget -- so the
            // other ~199 good files aren't held hostage by the bad one(s).
            results = await _readBatchResilient(records, timeout: fileTimeout);
          }

          for (final i in batch) {
            final t = tracks[i];
            final tags = results[t.contentId];
            if (tags == null) continue;
            cache.entries[t.contentId] = tags;
            tracks[i] = t.copyWith(
              title: tags.title,
              artist: tags.artist,
              album: tags.album,
              genre: tags.genre,
              durationMs: tags.durationMs,
              trackNumber: tags.trackNumber,
            );
          }
          done += batch.length;
          allTracks = List<Track>.of(tracks);
          status = 'reading tags $done/${missing.length}';
          onProgress?.call(done, missing.length);
          notifyListeners();

          if (++batchesSinceSave >= _saveEveryNBatches) {
            await cache.save(cacheFile);
            batchesSinceSave = 0;
          }
        }
        await cache.save(cacheFile);
      }
      status = 'ready';
    } catch (e) {
      status = 'error: $e';
    }
    notifyListeners();
  }

  /// Rescans every configured root for new files (added since the last
  /// [load] or [rescan]) and merges them into [allTracks], so files dropped
  /// into a watched folder while the app is running show up without a
  /// restart. See the class-level doc above [load]'s call sites in
  /// main.dart for the three triggers this feeds: launch (post-first-feed),
  /// the Refresh button, and a 5-minute periodic timer.
  ///
  /// No-ops (returns immediately) if [load] hasn't completed at least once
  /// yet (nothing to rescan against), or if a [load]/[rescan] is already in
  /// flight (see [busy]) -- this guard fires synchronously, before any
  /// `await`, so two back-to-back calls can never both proceed.
  ///
  /// Per root (skipping any with no `.library.json` yet -- same as [load],
  /// those need `foolib seed` first): the actual scan/diff/stamp/save cycle
  /// runs inside [Isolate.run] (bounded by [rootTimeout]; a root that blows
  /// its budget is skipped, not left to stall the rest of the rescan) since
  /// `scanLibrary` is synchronous-I/O-heavy over the SMB-mounted share --
  /// only plain sendable records cross back to this isolate. Newly found
  /// tracks are merged in immediately with filename-derived metadata (so
  /// they're visible right away), then upgraded via the same batched,
  /// timeout-guarded tag-reading machinery [load]'s Part B uses (see
  /// [_enrichNewTracks]).
  Future<void> rescan({Duration rootTimeout = _defaultRescanRootTimeout}) async {
    if (_busy) return;
    final roots = _libraryRoots;
    final cacheFile = _cacheFile;
    if (roots.isEmpty || cacheFile == null) return;

    _busy = true;
    try {
      final knownIds = {for (final t in allTracks) t.contentId};
      var tracks = List<Track>.of(allTracks);
      final newIndices = <int>[];
      var totalNew = 0;

      for (final root in roots) {
        final manifestFile = File(p.join(root.path, '.library.json'));
        if (!manifestFile.existsSync()) {
          continue; // no manifest yet -- settings dialog covers seeding it
        }

        final rootName = p.basename(root.path);
        status = 'scanning $rootName…';
        notifyListeners();

        List<(String, String, String)> newRecords;
        try {
          newRecords = await Isolate.run(() => _rescanRootIsolateEntry(root.path))
              .timeout(rootTimeout);
        } on TimeoutException {
          status = 'rescan of $rootName timed out';
          notifyListeners();
          continue;
        } catch (e) {
          status = 'rescan of $rootName failed: $e';
          notifyListeners();
          continue;
        }

        if (newRecords.isEmpty) continue;

        for (final (contentId, relPath, dateAddedIso) in newRecords) {
          // Defends against a track already known via another root (e.g.
          // the exact same file duplicated across two roots and newly added
          // to both since the last scan) -- first root in the list still
          // wins, same dedupe policy as load()'s merge.
          if (!knownIds.add(contentId)) continue;
          final fallback = parseFromFilename(relPath);
          tracks.add(Track(
            contentId: contentId,
            relPath: relPath,
            rootPath: root.path,
            dateAdded: DateTime.parse(dateAddedIso).toUtc(),
            title: fallback.title ?? p.basenameWithoutExtension(relPath),
            artist: fallback.artist ?? '',
            album: fallback.album ?? '',
            genre: fallback.genre ?? '',
            trackNumber: fallback.trackNumber,
          ));
          newIndices.add(tracks.length - 1);
          totalNew++;
        }
        allTracks = List<Track>.of(tracks);
        notifyListeners();
      }

      if (newIndices.isNotEmpty) {
        tracks = await _enrichNewTracks(tracks, newIndices, cacheFile);
        allTracks = tracks;
      }

      status = totalNew == 0 ? 'ready' : 'added $totalNew new tracks';
    } finally {
      _busy = false;
      notifyListeners();
      // A load() that arrived while this rescan held `_busy` is queued
      // (see [_pendingLoad]/[load]'s re-entrancy doc) rather than dropped
      // -- run it now that this rescan is done with the flag.
      await _runPendingLoad();
    }
  }

  /// Upgrades the freshly-merged tracks at [indices] within [tracks] from
  /// their filename-derived fallback tags to real ones, reusing exactly the
  /// batched-isolate-plus-timeout machinery [load]'s Part B enrichment uses
  /// ([_readBatchIsolate] / [_readBatchResilient]) -- so a rescan that
  /// happens to pick up a pathologically slow file is just as resilient as
  /// a full library load is. Reads/writes the same on-disk tag cache
  /// enrichment owns; safe because [rescan] only reaches here while [_busy]
  /// is held, so it can never interleave with [load]'s own cache writes.
  Future<List<Track>> _enrichNewTracks(
    List<Track> tracks,
    List<int> indices,
    File cacheFile,
  ) async {
    final cache = MetaCache.load(cacheFile);
    final out = List<Track>.of(tracks);
    for (var start = 0; start < indices.length; start += _enrichBatchSize) {
      final end = (start + _enrichBatchSize < indices.length)
          ? start + _enrichBatchSize
          : indices.length;
      final batch = indices.sublist(start, end);
      final records = [
        for (final i in batch)
          (
            out[i].contentId,
            p.join(out[i].rootPath, out[i].relPath),
            out[i].relPath,
          )
      ];

      Map<String, TrackTags> results;
      try {
        results = await _readBatchIsolate(records, timeout: _enrichBatchTimeout);
      } on TimeoutException {
        results = await _readBatchResilient(records, timeout: _enrichFileTimeout);
      }

      for (final i in batch) {
        final t = out[i];
        final tags = results[t.contentId];
        if (tags == null) continue;
        cache.entries[t.contentId] = tags;
        out[i] = t.copyWith(
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          genre: tags.genre,
          durationMs: tags.durationMs,
          trackNumber: tags.trackNumber,
        );
      }
      allTracks = List<Track>.of(out);
      notifyListeners();
    }
    await cache.save(cacheFile);
    return out;
  }

  List<Track> get _searched => applyFilters(allTracks, search: search);

  /// The Folder filter panel's values -- one entry per distinct
  /// [Track.rootPath] among the (search-filtered) tracks, i.e. the same
  /// cascade position/derivation the removed genre getter used to occupy. Each entry *is*
  /// the root path itself (what [setFolders] expects back, and what
  /// [folderFilters] is compared against) -- `ui/home_screen.dart` renders
  /// each one's basename via [FilterPanel.displayName] rather than this
  /// getter doing any display-string translation itself, so a root path
  /// round-trips through selection unchanged.
  List<String> get folderNames {
    final paths = distinctValues(_searched, (t) => t.rootPath);
    paths.sort((a, b) =>
        p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    return paths;
  }

  List<String> get artists => distinctValues(
      applyFilters(allTracks, rootPath: folderFilters, search: search),
      (t) => t.artist);
  List<String> get albums => distinctValues(
      applyFilters(allTracks,
          rootPath: folderFilters, artist: artistFilters, search: search),
      (t) => t.album);

  List<Track> get visibleTracks {
    if (activePlaylist != null) {
      // Playlist order is curator-defined, not date/name-derived -- never
      // resorted by column, regardless of [sortColumn]/[sortAscending].
      final matches = playlists.where((p) => p.name == activePlaylist);
      if (matches.isEmpty) return [];
      final pl = matches.first;
      final byId = {for (final t in allTracks) t.contentId: t};
      return [for (final id in pl.trackIds) if (byId[id] != null) byId[id]!];
    }
    final filtered = applyFilters(allTracks,
        rootPath: folderFilters,
        artist: artistFilters,
        album: albumFilters,
        search: search);
    return sortTracks(filtered, sortColumn, sortAscending);
  }

  /// Selects [column] as the track-list sort column: clicking the header of
  /// the already-active column toggles direction, clicking a different
  /// header switches to it ascending -- except date-added, which (matching
  /// the "newest first" default) starts descending on first click too.
  void setSort(SortColumn column) {
    if (column == sortColumn) {
      sortAscending = !sortAscending;
    } else {
      sortColumn = column;
      sortAscending = column != SortColumn.dateAdded;
    }
    notifyListeners();
  }

  /// Replaces the Folder filter selection with exactly [values] (each one
  /// of [folderNames]) -- empty clears it. Same cascade behavior
  /// [setArtists] has one rung down: clears any downstream artist/album
  /// selection (a folder switch invalidates whichever artist/album was
  /// showing under the old one) and reverts a stale trackNumber sort
  /// exactly like [setAlbums]/[setArtists] do -- see
  /// [_revertSortIfTrackNumber].
  ///
  /// [values] is the panel's *whole new selection*, not a single toggle --
  /// `ui/filter_panel.dart` computes the resulting set itself (plain click
  /// replaces it with one value, Ctrl+click toggles a value in/out of the
  /// existing set) and calls this with the result, so the cascade/sort
  /// side effects below only ever need to run once per user action.
  void setFolders(Set<String> values) {
    folderFilters = values;
    artistFilters = {};
    albumFilters = {};
    _revertSortIfTrackNumber();
    notifyListeners();
  }

  /// Replaces the Artist filter selection with exactly [values] -- see
  /// [setFolders]'s doc for the "whole new selection, not a toggle" contract
  /// this and [setAlbums] share.
  void setArtists(Set<String> values) {
    artistFilters = values;
    albumFilters = {};
    _revertSortIfTrackNumber();
    notifyListeners();
  }

  /// Replaces the Album filter selection with exactly [values] -- see
  /// [setFolders]'s doc for the "whole new selection, not a toggle"
  /// contract this shares.
  ///
  /// Also drives the track-list's default sort for the single-album view:
  /// selecting exactly one album switches to track-number order (ascending
  /// -- LP side one, track one, first), matching how a real album is
  /// listened to and making the now-visible '#' column (see
  /// `ui/track_list.dart`) meaningful; any other count -- none selected, or
  /// several at once (multiple albums' track numbers don't share one
  /// order) -- reverts to the library's normal newest-first order. This
  /// only sets the *default* -- [setSort] (a user's own header click) still
  /// always wins afterward, same as any other sort change.
  void setAlbums(Set<String> values) {
    albumFilters = values;
    if (values.length == 1) {
      sortColumn = SortColumn.trackNumber;
      sortAscending = true;
    } else {
      sortColumn = SortColumn.dateAdded;
      sortAscending = false;
    }
    notifyListeners();
  }

  void setSearch(String s) {
    search = s;
    notifyListeners();
  }

  /// Selects [id] as the single selected track (or clears the selection,
  /// when `null`). Selection is purely a UI highlight -- it never starts or
  /// affects playback (see [PlayerService.playFrom] for that).
  void selectTrack(String? id) {
    selectedTrackId = id;
    notifyListeners();
  }

  /// On-play duration backfill (see [PlayerService.onObservedDuration],
  /// which main.dart wires to this): records that the playback engine
  /// observed a real duration of [ms] milliseconds for the track with
  /// [contentId], so a track whose Time column was blank -- its cache entry
  /// persisted with `durationMs: null` because the tag parser couldn't
  /// derive one at scan time -- permanently gains its duration once played.
  ///
  /// Updates the in-memory [Track] immediately (and notifies, so the Time
  /// cell fills in while the track is still playing), then schedules a
  /// debounced merge into the on-disk tag cache (see
  /// [flushPendingDurationSaves] / [_durationSaveDebounce]) so the value
  /// survives restarts. No-ops on a non-positive [ms], an unknown
  /// [contentId], or a value the track already carries.
  void updateDuration(String contentId, int ms) {
    if (ms <= 0) return;
    final i = allTracks.indexWhere((t) => t.contentId == contentId);
    if (i < 0) return;
    if (allTracks[i].durationMs == ms) return;
    final tracks = List<Track>.of(allTracks);
    tracks[i] = tracks[i].copyWith(durationMs: ms);
    allTracks = tracks;
    _pendingDurationUpdates[contentId] = ms;
    _durationSaveTimer?.cancel();
    _durationSaveTimer = Timer(_durationSaveDebounce, () {
      flushPendingDurationSaves();
    });
    notifyListeners();
  }

  /// Persists every duration [updateDuration] has recorded since the last
  /// flush. Runs automatically [_durationSaveDebounce] after the most
  /// recent update; public so tests (and a future shutdown hook) can force
  /// the write instead of waiting out the debounce. No-op when nothing is
  /// pending.
  ///
  /// The default writer re-loads [_cacheFile] and merges the pending
  /// durations into whatever it holds *now* -- each entry keeps its
  /// existing tag fields (or falls back to the in-memory track's, for an
  /// entry the cache doesn't have yet) with only durationMs replaced --
  /// rather than saving a full cache snapshot taken earlier, so it can't
  /// resurrect stale entries over a concurrent enrichment save's newer
  /// ones. [durationCacheWriter], when set, replaces that default entirely
  /// (tests).
  Future<void> flushPendingDurationSaves() async {
    _durationSaveTimer?.cancel();
    _durationSaveTimer = null;
    if (_pendingDurationUpdates.isEmpty) return;
    final pending = Map<String, int>.of(_pendingDurationUpdates);
    _pendingDurationUpdates.clear();
    await (durationCacheWriter ?? _writeDurationsToCache)(pending);
  }

  Future<void> _writeDurationsToCache(Map<String, int> pending) async {
    final cacheFile = _cacheFile;
    if (cacheFile == null) return; // no load() yet -- nowhere to persist
    final cache = MetaCache.load(cacheFile);
    final byId = {for (final t in allTracks) t.contentId: t};
    for (final entry in pending.entries) {
      final old = cache.entries[entry.key];
      final t = byId[entry.key];
      if (old == null && t == null) continue; // gone from the library
      cache.entries[entry.key] = TrackTags(
        title: old?.title ?? t?.title,
        artist: old?.artist ?? t?.artist,
        album: old?.album ?? t?.album,
        genre: old?.genre ?? t?.genre,
        durationMs: entry.value,
        trackNumber: old?.trackNumber ?? t?.trackNumber,
      );
    }
    await cache.save(cacheFile);
  }

  @override
  void dispose() {
    _durationSaveTimer?.cancel();
    super.dispose();
  }

  void setPlaylist(String? name) {
    activePlaylist = name;
    folderFilters = {};
    artistFilters = {};
    albumFilters = {};
    search = '';
    notifyListeners();
  }

  /// Reverts sort to the default (dateAdded descending) when the album filter
  /// is cleared while [sortColumn] is [SortColumn.trackNumber].
  ///
  /// Track number sorting only makes sense in album view; when navigating away
  /// from an album via [setFolders]/[setArtists] (which clear [albumFilters]),
  /// a stale trackNumber sort would leave the '#' header hidden and no sort
  /// arrow visible, confusing the user. Mirrors [setAlbums]' not-exactly-one
  /// branch.
  void _revertSortIfTrackNumber() {
    if (sortColumn == SortColumn.trackNumber) {
      sortColumn = SortColumn.dateAdded;
      sortAscending = false;
    }
  }
}

/// Sorts [tracks] by [column] in [ascending] order (stable on ties, keeping
/// the input's relative order -- same technique as [sortByDateAddedDesc]).
///
/// Text columns (title/artist/album) compare case-insensitively. The
/// duration and trackNumber columns sort tracks with no known value
/// ([Track.durationMs]/[Track.trackNumber] null, e.g. not yet tag-enriched)
/// after every track with a known one, regardless of [ascending] -- "last"
/// always means the end of the list, not "first when descending".
List<Track> sortTracks(List<Track> tracks, SortColumn column, bool ascending) {
  int compareText(String a, String b) {
    final c = a.toLowerCase().compareTo(b.toLowerCase());
    return ascending ? c : -c;
  }

  int compareNullableInt(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1; // null always sorts last
    if (b == null) return -1;
    return ascending ? a.compareTo(b) : b.compareTo(a);
  }

  int compare(Track a, Track b) {
    switch (column) {
      case SortColumn.title:
        return compareText(a.title, b.title);
      case SortColumn.artist:
        return compareText(a.artist, b.artist);
      case SortColumn.album:
        return compareText(a.album, b.album);
      case SortColumn.duration:
        return compareNullableInt(a.durationMs, b.durationMs);
      case SortColumn.trackNumber:
        return compareNullableInt(a.trackNumber, b.trackNumber);
      case SortColumn.dateAdded:
        return ascending
            ? a.dateAdded.compareTo(b.dateAdded)
            : b.dateAdded.compareTo(a.dateAdded);
    }
  }

  final indexed = tracks.asMap().entries.toList();
  indexed.sort((x, y) {
    final byColumn = compare(x.value, y.value);
    return byColumn != 0 ? byColumn : x.key.compareTo(y.key); // stable
  });
  return indexed.map((e) => e.value).toList();
}

/// Returns [name] made unique against [used] (adding it to [used] as a side
/// effect) by suffixing " (2)", " (3)", ... on collision -- e.g. a
/// same-named playlist ("mix") loaded from a second, then third, library
/// root becomes "mix (2)", then "mix (3)".
String _uniquePlaylistName(String name, Set<String> used) {
  if (used.add(name)) return name;
  var n = 2;
  while (!used.add('$name ($n)')) {
    n++;
  }
  return '$name ($n)';
}

/// Runs one library root's whole rescan cycle -- `fooplayer_core`'s
/// `scanLibrary` (walk + stat + hash), `loadManifest`, `diffAgainstManifest`,
/// `applyDiff` (stamping any new tracks with `DateTime.now()`), then
/// `saveManifest` -- inside its own isolate (see [LibraryModel.rescan],
/// which runs this via `Isolate.run`).
///
/// [scanLibrary]'s directory walk and per-file `statSync` calls are
/// synchronous-heavy over the SMB-mounted library share, exactly like the
/// tag-reading batches below -- running this off the calling isolate keeps
/// it from blocking the UI/platform thread.
///
/// Takes and returns only plain, isolate-sendable values: the root's path
/// as a `String` in, and for every genuinely new track a `(contentId,
/// relPath, date_added ISO-8601 string)` record out -- never a `Manifest`
/// or `ScannedTrack` object graph. The caller (running on the main isolate)
/// reconstructs whatever [Track]s it needs from these records.
Future<List<(String, String, String)>> _rescanRootIsolateEntry(
    String rootPath) async {
  final root = Directory(rootPath);
  final scanned = await core.scanLibrary(root);
  final manifest = core.loadManifest(root);
  final diff = core.diffAgainstManifest(manifest, scanned);
  core.applyDiff(manifest, diff, scanned, DateTime.now);
  await core.saveManifest(manifest, root);
  return [
    for (final t in diff.newTracks)
      (
        t.contentId,
        manifest.tracks[t.contentId]!.paths.first,
        manifest.tracks[t.contentId]!.dateAdded,
      ),
  ];
}

/// Resolves [records] one at a time, each bounded by [timeout], for use
/// once a whole-batch read (see [_readBatchIsolate]) has already timed out.
///
/// A record whose own read doesn't finish in time -- or fails for any other
/// reason -- keeps its filename-derived fallback tags (the same fallback
/// [readTags] itself uses for unparseable/missing files) instead of taking
/// the rest of the batch down with it. This is what makes enrichment
/// survive a single pathological file: it's skipped, counted (the caller's
/// `done` still advances for every record in the batch), and enrichment
/// moves on.
Future<Map<String, TrackTags>> _readBatchResilient(
  List<(String, String, String)> records, {
  required Duration timeout,
}) async {
  final out = <String, TrackTags>{};
  for (final record in records) {
    final (contentId, _, relPath) = record;
    try {
      final single = await _readBatchIsolate([record], timeout: timeout);
      out[contentId] = single[contentId] ?? parseFromFilename(relPath);
    } catch (_) {
      out[contentId] = parseFromFilename(relPath);
    }
  }
  return out;
}

/// Runs [readTagsBatch] for [records] inside its own isolate, bounded by
/// [timeout] -- see [runIsolateWithTimeout] (metadata/isolate_io.dart) for
/// the kill-on-timeout mechanics this delegates to; [_defaultBatchTimeout]'s
/// doc above explains why an unbounded batch read is dangerous in the first
/// place.
///
/// Any error [readTagsBatch] itself throws propagates normally (it is not
/// swallowed here), so a genuine failure still surfaces via the caller's
/// own error handling.
Future<Map<String, TrackTags>> _readBatchIsolate(
  List<(String, String, String)> records, {
  required Duration timeout,
}) {
  return runIsolateWithTimeout<Map<String, TrackTags>,
      List<(String, String, String)>>(
    _readBatchIsolateEntry,
    records,
    timeout: timeout,
  );
}

void _readBatchIsolateEntry(
    (List<(String, String, String)>, SendPort) args) async {
  final (records, resultPort) = args;
  Map<String, TrackTags> result;
  try {
    result = await readTagsBatch(records);
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
  Isolate.exit(resultPort, [result]);
}
