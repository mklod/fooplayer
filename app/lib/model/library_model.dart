// Last modified: 2026-07-24--1807
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;
import '../metadata/isolate_io.dart';
import '../metadata/meta_cache.dart';
import '../metadata/id3_text.dart';
import '../metadata/mp3_duration.dart';
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

  /// The Folder pane's drill-down position: the folder currently "drilled
  /// into" whose immediate children [folderEntries] lists. Empty means the
  /// pane is at the top level (listing library roots, [folderNames]);
  /// otherwise element 0 is a [Track.rootPath] and any further elements are
  /// successive subdirectory names below it (relPath segments -- forward
  /// slashes, see [Track.relPath]).
  ///
  /// Occupies the same top-of-cascade position the old Genre filter used to
  /// (see [drillIntoFolder]): together with [folderSiblings] it narrows
  /// [artists]/[albums]/[visibleTracks], and it is cleared by [setPlaylist]
  /// and [clearFolderSelection].
  List<String> folderPath = [];

  /// Ctrl+click-selected sibling entries at the Folder pane's *current
  /// level* -- i.e. names from [folderEntries] (children of [folderPath];
  /// full root paths while [folderPath] is empty). Non-empty narrows the
  /// track filter to the union of these siblings INSTEAD of all of
  /// [folderPath]'s contents; empty means "everything under [folderPath]"
  /// (or no folder restriction at all when [folderPath] is empty too). See
  /// [setFolderSiblings].
  Set<String> folderSiblings = {};
  Set<String> artistFilters = {};
  Set<String> albumFilters = {};
  String search = '';
  String? activePlaylist;
  String status = 'idle';

  /// The tracks currently selected in the track list (see
  /// `ui/track_list.dart`'s per-row `onSelect`/`onPlay`, [selectTrackClick]
  /// and [selectTrack]) -- visual-only (the `selectionFill` background,
  /// applied per selected row), and the source selection for the row
  /// context menu's bulk playlist actions when the right-clicked row is
  /// part of it (see `ui/track_list.dart`'s `_showTrackContextMenu`).
  /// Distinct from the currently *playing* track ([PlayerService.current]):
  /// a row can be selected, playing, both, or neither, and each gets its
  /// own independent highlight treatment.
  Set<String> selectedTrackIds = {};

  /// The Shift+click range-selection anchor: the last row clicked WITHOUT
  /// Shift (a plain or Ctrl+click), or the row a Ctrl+click just toggled.
  /// Null once the selection has been cleared -- e.g. by one of the
  /// filter/search/playlist/folder cascade points (see [_clearSelection])
  /// -- and nothing has been clicked since. See [selectTrackClick].
  String? _selectionAnchor;

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

  /// True while a phase that actually reads or writes a root's
  /// `.library.json` is in flight: [load]'s manifest merge, [rescan]'s
  /// per-root scan/stamp/save, or an external [PlaylistStore] mutation.
  ///
  /// Deliberately NARROWER than [busy]. Playlist mutations used to gate on
  /// [_busy], which stays set for the whole of [load] -- including Part B's
  /// background tag enrichment, minutes of work on a large SMB-mounted
  /// library. The result was that "add to playlist" was refused for
  /// essentially the entire session on a real library (5k+ tracks), and
  /// since the refusal only surfaced after PlaylistStore's retry deadline,
  /// it read to the user as a silent failure. Enrichment writes only the
  /// AppData meta cache, never a manifest, so it has no business blocking
  /// manifest writes.
  bool _manifestIo = false;

  /// Bumped by every completed external manifest write ([endManifestWrite]).
  /// [load] samples it around its merge so a playlist write that lands
  /// mid-load can't be overwritten in the UI by the pre-write playlists this
  /// load already read.
  int _manifestWriteEpoch = 0;

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

      // Held across the merge below (manifest reads) and released before
      // Part B's enrichment, which touches only the meta cache. A playlist
      // write that refuses to come free in time doesn't block the load:
      // saveManifest is an atomic tmp-then-rename, so the worst case is
      // reading the pre-write copy -- which the epoch check below repairs.
      final epoch = _manifestWriteEpoch;
      final tookPhase = await _beginManifestPhase(const Duration(seconds: 5));
      try {
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
          for (var i = 0; i < data.playlists.length; i++) {
            final pl = data.playlists[i];
            mergedPlaylists.add(
              ManifestPlaylist(
                name: _uniquePlaylistName(pl.name, usedPlaylistNames),
                trackIds: pl.trackIds,
                rootPath: root.path,
                sourceName: pl.name,
                sourceIndex: i,
              ),
            );
          }
        }
      } finally {
        if (tookPhase) _endManifestPhase();
      }

      rootsMissingManifest = missingManifest;
      rootsFailed = failedRoots;
      playlists = mergedPlaylists;
      if (_manifestWriteEpoch != epoch) {
        // A playlist write landed while this load was merging, so
        // `mergedPlaylists` predates it -- re-read just the playlists rather
        // than leaving the UI showing the pre-write state.
        reloadPlaylists();
      }

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
          hasEmbeddedArt: tags.hasEmbeddedArt,
        );
        // A cache hit still worth a one-time re-read for a duration (see
        // `meta_cache.dart`'s `needsDurationProbe`) -- the already-good
        // cached title/artist/album applied just above are kept for the
        // instant feed; only queue it for Part B's background re-read
        // (below) when the file is actually still there, so a stale entry
        // for a since-removed file doesn't get downgraded to a
        // filename-derived placeholder by that re-read's own miss path.
        if (needsDurationProbe(tags, t.relPath) &&
            File(p.join(t.rootPath, t.relPath)).existsSync()) {
          missing.add(i);
        } else if (cache.staleIds.contains(t.contentId) &&
            File(p.join(t.rootPath, t.relPath)).existsSync()) {
          // Cached by an older tag-reading revision: the values above are
          // already on screen, and this queues a background re-read to
          // correct them in place. Nothing is blanked in the meantime.
          //
          // Gated on the file still existing, for the same reason the
          // duration probe above is: re-reading a file that has since moved
          // or gone offline yields filename-derived placeholders, and
          // trading perfectly good cached tags for those is a downgrade, not
          // a refresh.
          missing.add(i);
        }
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
              ),
          ];

          Map<String, TrackTags> results;
          try {
            results = await _readBatchIsolate(records, timeout: batchTimeout);
          } on TimeoutException {
            // The whole-batch read didn't finish in time, which means at
            // least one file in it is pathologically slow (see
            // _defaultBatchTimeout). Fall back to resolving this batch one
            // file at a time -- each with its own bounded budget -- so the
            // other ~199 good files aren't held hostage by the bad one(s).
            results = await _readBatchResilient(records, timeout: fileTimeout);
          }

          // A read that failed outright (parser pathology, timeout, a file
          // that went away mid-scan) contributes no result. Rather than
          // leave those tracks with a blank Time column AND no cache entry
          // -- which meant paying the same failed read again on every single
          // launch -- fall back to the header-only estimator, which costs
          // tens of milliseconds and gets a duration for most of them.
          // Only for tracks nothing is known about yet: a track that already
          // has cached tags keeps them.
          for (final i in batch) {
            final t = tracks[i];
            if (results.containsKey(t.contentId)) continue;
            final existing = cache.entries[t.contentId];
            final wasStale = cache.staleIds.contains(t.contentId);
            if (existing != null && !wasStale) continue;

            // Our own readers are bounded and fast (tens of ms) and handle
            // precisely the shapes that make the upstream parser hang -- a
            // 439 KB ID3v2.4 tag stacked behind a v2.3 one, on the Tayyib
            // Ali album, timed out on every pass and so was never corrected.
            // Freshly-read frames win over a stale entry's values; for a
            // never-seen track they simply fill in.
            final frames = await readId3TextFramesFromFile(
              File(p.join(t.rootPath, t.relPath)),
            );
            final ms = existing?.durationMs ?? await _estimateDurationMs(t);
            if (frames.isEmpty && ms == null) continue;

            final fb = parseFromFilename(t.relPath);
            String? pick(String frame, String? stale, String? fallback) =>
                blankAsNull(frames[frame]) ?? stale ?? fallback;
            final track = frames['TRCK'];
            cache.entries[t.contentId] = TrackTags(
              title:
                  pick('TIT2', existing?.title, fb.title) ??
                  p.basenameWithoutExtension(t.relPath),
              artist:
                  blankAsNull(frames['TPE1']) ??
                  blankAsNull(frames['TPE2']) ??
                  existing?.artist ??
                  fb.artist,
              album: pick('TALB', existing?.album, fb.album),
              genre: pick('TCON', existing?.genre, fb.genre),
              durationMs: ms,
              trackNumber:
                  (track == null
                      ? null
                      : int.tryParse(track.split('/').first)) ??
                  existing?.trackNumber ??
                  fb.trackNumber,
              // Probed: don't re-attempt this file forever.
              durationProbed: true,
            );
            // Recovered as far as we can, so stop treating it as stale --
            // otherwise the same timing-out file is retried every launch.
            cache.markRefreshed(t.contentId);
            final rec = cache.entries[t.contentId]!;
            tracks[i] = tracks[i].copyWith(
              title: rec.title,
              artist: rec.artist,
              album: rec.album,
              genre: rec.genre,
              durationMs: rec.durationMs,
              trackNumber: rec.trackNumber,
            );
          }

          for (final i in batch) {
            final t = tracks[i];
            final tags = results[t.contentId];
            if (tags == null) continue;
            cache.entries[t.contentId] = tags;
            // This entry has now genuinely been re-read at the current
            // revision; without this it stays flagged stale forever.
            cache.markRefreshed(t.contentId);
            tracks[i] = t.copyWith(
              title: tags.title,
              artist: tags.artist,
              album: tags.album,
              genre: tags.genre,
              durationMs: tags.durationMs,
              trackNumber: tags.trackNumber,
              hasEmbeddedArt: tags.hasEmbeddedArt,
            );
          }
          done += batch.length;
          allTracks = List<Track>.of(tracks);
          status = 'reading tags $done/${missing.length}';
          onProgress?.call(done, missing.length);
          notifyListeners();

          if (++batchesSinceSave >= _saveEveryNBatches) {
            _mergeKnownDurationsInto(cache);
            await cache.save(cacheFile);
            batchesSinceSave = 0;
          }
        }
        _mergeKnownDurationsInto(cache);
        await cache.save(cacheFile);
      }
      // Durations cost a full tag read per file over the share, so once
      // known they are written into the manifests as well -- see
      // TrackEntry.durationMs. From then on they load with the library
      // itself and survive anything that happens to the local cache.
      await persistDurationsToManifests();
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
  /// runs inside its own isolate via the kill-capable
  /// [runIsolateWithTimeout] (bounded by [rootTimeout]; a root that blows
  /// its budget has its isolate KILLED and is skipped, not left to stall
  /// the rest of the rescan -- or, worse, to survive as a zombie whose
  /// eventual `saveManifest` clobbers a later playlist write) since
  /// `scanLibrary` is synchronous-I/O-heavy over the SMB-mounted share --
  /// only plain sendable records cross back to this isolate. Newly found
  /// tracks are merged in immediately with filename-derived metadata (so
  /// they're visible right away), then upgraded via the same batched,
  /// timeout-guarded tag-reading machinery [load]'s Part B uses (see
  /// [_enrichNewTracks]).
  /// [quiet] suppresses the per-root progress chatter, for the periodic
  /// background rescan. Without it the status line flickered through five
  /// "scanning ..." messages and back to "ready" on every tick while the user
  /// was doing nothing at all -- a twitch carrying no information. A quiet
  /// pass still reports what it FINDS ("added N new tracks") and still
  /// reports failures; it just doesn't narrate a scan that found nothing.
  Future<void> rescan({
    Duration rootTimeout = _defaultRescanRootTimeout,
    bool quiet = false,
  }) async {
    if (_busy) return;
    final roots = _libraryRoots;
    final cacheFile = _cacheFile;
    if (roots.isEmpty || cacheFile == null) return;

    _busy = true;
    var holdsManifestPhase = false;
    try {
      // The per-root isolates below do a read-modify-write of each
      // `.library.json`, so they must not interleave with a PlaylistStore
      // mutation. Rescan is the one caller that can afford to give up: it
      // runs again on its 5-minute timer (and on the Refresh button).
      if (!await _beginManifestPhase(const Duration(seconds: 3))) {
        if (!quiet) {
          status = 'rescan skipped (a playlist write was in progress)';
        }
        return;
      }
      holdsManifestPhase = true;
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
        if (!quiet) {
          status = 'scanning $rootName…';
          notifyListeners();
        }

        List<(String, String, String)> newRecords;
        try {
          // MUST be the kill-capable runIsolateWithTimeout, never
          // `Isolate.run(...).timeout(...)`: Future.timeout does not cancel
          // the isolate, so a timed-out root's scan would keep running as a
          // zombie and call core.saveManifest at some arbitrary later time
          // -- AFTER this rescan's `finally` has released [_busy] -- racing
          // (and silently clobbering) a PlaylistStore mutation's own
          // manifest save made under tryBeginManifestWrite. Killing the
          // isolate at the deadline guarantees a timed-out root performs no
          // late manifest write.
          newRecords =
              await runIsolateWithTimeout<
                List<(String, String, String)>,
                String
              >(_rescanRootIsolateEntry, root.path, timeout: rootTimeout);
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
          tracks.add(
            Track(
              contentId: contentId,
              relPath: relPath,
              rootPath: root.path,
              dateAdded: DateTime.parse(dateAddedIso).toUtc(),
              title: fallback.title ?? p.basenameWithoutExtension(relPath),
              artist: fallback.artist ?? '',
              album: fallback.album ?? '',
              genre: fallback.genre ?? '',
              trackNumber: fallback.trackNumber,
            ),
          );
          newIndices.add(tracks.length - 1);
          totalNew++;
        }
        allTracks = List<Track>.of(tracks);
        notifyListeners();
      }

      // Every manifest write this rescan makes is done; enrichment below
      // only touches the meta cache, so playlist edits are free again.
      _endManifestPhase();
      holdsManifestPhase = false;

      if (newIndices.isNotEmpty) {
        tracks = await _enrichNewTracks(tracks, newIndices, cacheFile);
        allTracks = tracks;
      }

      // A quiet pass that found nothing leaves the status exactly as it was.
      if (totalNew > 0) {
        status = 'added $totalNew new tracks';
      } else if (!quiet) {
        status = 'ready';
      }
    } finally {
      _busy = false;
      // Belt and braces: the happy path released this above, but a throw
      // in between must not leave the flag stuck -- that would refuse every
      // later playlist write. Conditional because the give-up path never
      // held it, and clearing it there would release the OTHER writer's.
      if (holdsManifestPhase) _endManifestPhase();
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
          ),
      ];

      Map<String, TrackTags> results;
      try {
        results = await _readBatchIsolate(
          records,
          timeout: _enrichBatchTimeout,
        );
      } on TimeoutException {
        results = await _readBatchResilient(
          records,
          timeout: _enrichFileTimeout,
        );
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
          hasEmbeddedArt: tags.hasEmbeddedArt,
        );
      }
      allTracks = List<Track>.of(out);
      notifyListeners();
    }
    _mergeKnownDurationsInto(cache);
    await cache.save(cacheFile);
    return out;
  }

  /// Folds any duration already known in [allTracks] into [cache]'s
  /// in-memory entries wherever the entry itself still shows `durationMs`
  /// as null, so an enrichment [cache.save] mid-run can't clobber an
  /// on-play duration backfill (see [updateDuration]) with the stale
  /// null-duration snapshot [cache] was loaded with.
  ///
  /// [cache] is loaded once at the start of [_loadBody]/[_enrichNewTracks]
  /// and only has its cache-*miss* entries touched by the enrichment loop
  /// that owns it; a cache-*hit* track with a null-duration entry is never
  /// revisited there even if [flushPendingDurationSaves] concurrently wrote
  /// its backfilled duration to disk (or it's merely still pending, not
  /// yet flushed) -- so periodically overwriting the whole file from this
  /// map, unmerged, would silently erase that backfill. [allTracks] is
  /// updated synchronously by [updateDuration] regardless of flush state,
  /// so re-reading from it here covers both cases in one pass.
  void _mergeKnownDurationsInto(MetaCache cache) {
    final byId = {for (final t in allTracks) t.contentId: t};
    for (final id in cache.entries.keys.toList(growable: false)) {
      final entry = cache.entries[id]!;
      if (entry.durationMs != null) continue;
      final known = byId[id]?.durationMs;
      if (known == null) continue;
      cache.entries[id] = TrackTags(
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        genre: entry.genre,
        durationMs: known,
        trackNumber: entry.trackNumber,
        durationProbed: entry.durationProbed,
      );
    }
  }

  List<Track> get _searched => applyFilters(allTracks, search: search);

  /// The Folder pane's top-level values -- one entry per distinct
  /// [Track.rootPath] among the (search-filtered) tracks, i.e. the same
  /// cascade position/derivation the removed genre getter used to occupy.
  /// Each entry *is* the root path itself (what [drillIntoFolder]/
  /// [setFolderSiblings] expect back at this level) -- `ui/home_screen.dart`
  /// renders each one's basename via [FilterPanel.displayName] rather than
  /// this getter doing any display-string translation itself, so a root
  /// path round-trips through selection unchanged.
  List<String> get folderNames {
    final paths = distinctValues(_searched, (t) => t.rootPath);
    paths.sort(
      (a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return paths;
  }

  /// What the Folder pane currently lists: the library roots
  /// ([folderNames]) while at the top level, otherwise the immediate
  /// subdirectory names one level below [folderPath], derived from the
  /// (search-filtered) tracks' relPaths (see [subfolderNames] -- tracks
  /// sitting directly at [folderPath]'s level contribute no entries, so a
  /// leaf folder yields an empty list and only filters the track list).
  List<String> get folderEntries {
    if (folderPath.isEmpty) return folderNames;
    return subfolderNames(
      _searched,
      rootPath: folderPath.first,
      prefix: folderPath.skip(1).join('/'),
    );
  }

  /// The Folder pane's pinned-header breadcrumb, one display segment per
  /// drill-down step -- `['monthly', '2007-08']` -- or empty when nothing
  /// is selected (pane at the top level with no Ctrl-selected roots).
  ///
  /// Segment `i` (0-based) corresponds to [folderPath] element `i` (element
  /// 0 shown by basename, it's a whole root path); when [folderSiblings] is
  /// non-empty one *extra* trailing segment follows the path segments: the
  /// sole sibling's name, or `'N selected'` for a multi-selection. The UI
  /// (`ui/home_screen.dart`) prepends its own leading `'All'` segment, so a
  /// click on *UI* segment `i` maps straight to `popFolderTo(i)` -- path
  /// segment `i` here pops to depth `i + 1`, and the trailing sibling
  /// segment is the current (non-clickable) position.
  List<String> get folderBreadcrumbs {
    final parts = <String>[
      if (folderPath.isNotEmpty) p.basename(folderPath.first),
      ...folderPath.skip(1),
    ];
    if (folderSiblings.length > 1) {
      parts.add('${folderSiblings.length} selected');
    } else if (folderSiblings.length == 1) {
      parts.add(
        folderPath.isEmpty
            ? p.basename(folderSiblings.first)
            : folderSiblings.first,
      );
    }
    return parts;
  }

  /// The [FolderScope]s the current Folder-pane selection filters tracks
  /// down to (see [applyFilters]' `folders` parameter): one per
  /// Ctrl-selected sibling (their tracks OR together), just [folderPath]
  /// itself when no siblings are toggled, or empty (no restriction) when
  /// there is no folder selection at all.
  List<FolderScope> get folderScopes {
    if (folderPath.isEmpty) {
      // Top level: siblings are whole root paths.
      return [for (final r in folderSiblings) (root: r, sub: '')];
    }
    final root = folderPath.first;
    final base = folderPath.skip(1).toList();
    if (folderSiblings.isEmpty) return [(root: root, sub: base.join('/'))];
    return [
      for (final n in folderSiblings) (root: root, sub: [...base, n].join('/')),
    ];
  }

  List<String> get artists => distinctValues(
    applyFilters(allTracks, folders: folderScopes, search: search),
    (t) => t.artist,
  );
  List<String> get albums => distinctValues(
    applyFilters(
      allTracks,
      folders: folderScopes,
      artist: artistFilters,
      search: search,
    ),
    (t) => t.album,
  );

  /// Whether the current Folder-pane selection is a view of exactly one
  /// album: a single selected scope (one drilled folder, or exactly one
  /// Ctrl-selected sibling -- multi-sibling selections span folders and
  /// never qualify) whose (search-scoped) tracks all carry the same
  /// non-empty album, per [isSingleAlbum].
  ///
  /// This is what makes selecting an album *folder* under a library root
  /// (e.g. `albums/Alina Baraz & Galimatias - Urban Flora/01 Show Me.mp3`)
  /// behave like selecting that album in the Albums pane: the '#' column
  /// shows the tag track numbers (see `ui/track_list.dart`) and the default
  /// sort switches to track order (see [_onFolderSelectionChanged]).
  /// Without it, an album reached through the Folder pane -- the only way
  /// to reach it when the album lives as a folder under a whole-albums
  /// library root -- rendered with no '#' column at all, even though every
  /// track had a perfectly good tag/cache trackNumber.
  ///
  /// Deliberately keyed to an *explicit* single-folder selection, not to
  /// "the visible tracks happen to share one album": the full unfiltered
  /// library (or an artist filter) coincidentally containing one album must
  /// keep the column hidden, matching the long-standing library-mode
  /// behavior pinned by track_list_track_number_column_test.dart.
  bool get folderSelectionIsSingleAlbum {
    final scopes = folderScopes;
    if (scopes.length != 1) return false;
    return isSingleAlbum(
      applyFilters(allTracks, folders: scopes, search: search),
    );
  }

  List<Track> get visibleTracks {
    if (activePlaylist != null) {
      // Playlist order is curator-defined, not date/name-derived -- never
      // resorted by column, regardless of [sortColumn]/[sortAscending].
      final matches = playlists.where((p) => p.name == activePlaylist);
      if (matches.isEmpty) return [];
      final pl = matches.first;
      final byId = {for (final t in allTracks) t.contentId: t};
      return [
        for (final id in pl.trackIds)
          if (byId[id] != null) byId[id]!,
      ];
    }
    final filtered = applyFilters(
      allTracks,
      folders: folderScopes,
      artist: artistFilters,
      album: albumFilters,
      search: search,
    );
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

  /// Plain click in the Folder pane: selects [entry] (one of
  /// [folderEntries] -- a root path at the top level, a subdirectory name
  /// below that) AND drills into it, so the pane now lists ITS immediate
  /// subdirectories instead of the level [entry] was clicked at. Any
  /// Ctrl-selected siblings from the previous level are dropped ([entry] is
  /// the whole selection now).
  ///
  /// Same cascade behavior [setArtists] has one rung down: clears any
  /// downstream artist/album selection (a folder switch invalidates
  /// whichever artist/album was showing under the old one) and re-derives
  /// the default sort for the new selection -- track-number order when the
  /// selected folder is a single album's, otherwise reverting a stale
  /// trackNumber sort -- see [_onFolderSelectionChanged].
  void drillIntoFolder(String entry) {
    folderPath = [...folderPath, entry];
    folderSiblings = {};
    _onFolderSelectionChanged();
  }

  /// Ctrl+click in the Folder pane: replaces the Ctrl-selected sibling set
  /// at the pane's current level with exactly [values] (each one of
  /// [folderEntries]) WITHOUT drilling -- the pane keeps listing the same
  /// level, and the selected siblings' tracks OR together (see
  /// [folderScopes]). Empty reverts the filter to all of [folderPath].
  ///
  /// [values] is the panel's *whole new selection*, not a single toggle --
  /// `ui/filter_panel.dart` computes the resulting set itself (Ctrl+click
  /// toggles a value in/out of the existing set) and calls this with the
  /// result, so the cascade/sort side effects only ever run once per user
  /// action. Shares [drillIntoFolder]'s cascade/sort-revert side effects.
  ///
  /// No-ops (skips the cascade entirely) when [values] is exactly the
  /// current [folderSiblings] -- e.g. Ctrl-toggling a sibling off and back
  /// on, or a redundant call with the set unchanged -- so it doesn't wipe
  /// the user's artist/album picks for a folder scope that never actually
  /// changed.
  void setFolderSiblings(Set<String> values) {
    if (_setEquals(folderSiblings, values)) return;
    folderSiblings = values;
    _onFolderSelectionChanged();
  }

  /// Breadcrumb click in the Folder pane's pinned header: pops the
  /// drill-down back OUT to [depth] path segments (0 = the top-level root
  /// list -- equivalent to [clearFolderSelection]), dropping every deeper
  /// [folderPath] segment and any Ctrl-selected [folderSiblings] (they
  /// belonged to the deeper level being abandoned). [folderEntries] then
  /// lists the kept path's immediate children again, exactly as if the user
  /// had just drilled down to it. A [depth] at or beyond the current
  /// [folderPath] length keeps the whole path and only clears the sibling
  /// selection (that's the deepest clickable segment when a sibling
  /// selection is what the trailing breadcrumb segment shows).
  ///
  /// Shares [drillIntoFolder]'s cascade/sort-revert side effects (see
  /// [_onFolderSelectionChanged]); no-ops entirely -- preserving downstream
  /// artist/album picks, see [setFolderSiblings]'s doc for why -- when
  /// nothing would change (path already at most [depth] deep, no siblings).
  void popFolderTo(int depth) {
    if (depth < 0) depth = 0; // defensive: treat any underflow as "roots"
    if (depth >= folderPath.length && folderSiblings.isEmpty) return;
    if (depth < folderPath.length) {
      folderPath = folderPath.sublist(0, depth);
    }
    folderSiblings = {};
    _onFolderSelectionChanged();
  }

  /// The Folder pane's pinned ✕: fully clears the folder selection -- back
  /// to the top-level root list ([folderNames]) with no folder restriction
  /// on the track list. Shares [drillIntoFolder]'s cascade/sort-revert side
  /// effects (the artist/album lists rescope back to the whole library).
  ///
  /// No-ops when there is nothing to clear (both [folderPath] and
  /// [folderSiblings] already empty) -- see [setFolderSiblings]'s doc for
  /// why a no-op selection change must not still wipe artist/album filters.
  void clearFolderSelection() {
    if (folderPath.isEmpty && folderSiblings.isEmpty) return;
    folderPath = [];
    folderSiblings = {};
    _onFolderSelectionChanged();
  }

  /// Shared tail of every folder-selection mutation ([drillIntoFolder]/
  /// [setFolderSiblings]/[clearFolderSelection]): clears the downstream
  /// artist/album filter sets, then sets the sort to match what the new
  /// selection *is* -- mirroring [setAlbums]' two branches one pane up:
  ///
  /// - Selection resolves to a single album's folder
  ///   ([folderSelectionIsSingleAlbum]): default to track-number order
  ///   ascending, the same album-view default [setAlbums] applies when
  ///   exactly one album is picked in the Albums pane. (Before this branch
  ///   existed, an album opened via the Folder pane kept the newest-first
  ///   library sort, scrambling the album's track order.)
  /// - Anything else: revert a stale trackNumber sort (see
  ///   [_revertSortIfTrackNumber]).
  ///
  /// Either way this only sets the *default* -- a subsequent [setSort]
  /// (user's own header click) still wins, same as after [setAlbums].
  void _onFolderSelectionChanged() {
    artistFilters = {};
    albumFilters = {};
    _clearSelection();
    if (folderSelectionIsSingleAlbum) {
      sortColumn = SortColumn.trackNumber;
      sortAscending = true;
    } else {
      _revertSortIfTrackNumber();
    }
    notifyListeners();
  }

  /// Replaces the Artist filter selection with exactly [values] -- the
  /// panel's *whole new selection*, not a single toggle (see
  /// [setFolderSiblings]'s doc for the contract this and [setAlbums]
  /// share): `ui/filter_panel.dart` computes the resulting set itself
  /// (plain click replaces it with one value, Ctrl+click toggles a value
  /// in/out of the existing set) and calls this with the result, so the
  /// cascade/sort side effects below only ever need to run once per user
  /// action.
  void setArtists(Set<String> values) {
    artistFilters = values;
    albumFilters = {};
    _clearSelection();
    _revertSortIfTrackNumber();
    notifyListeners();
  }

  /// Replaces the Album filter selection with exactly [values] -- see
  /// [setArtists]'s doc for the "whole new selection, not a toggle"
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
    _clearSelection();
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
    _clearSelection();
    notifyListeners();
  }

  /// Selects exactly [id] (or clears the selection entirely when `null`),
  /// discarding any wider multi-selection and moving the range anchor to
  /// [id] -- used by double-click (selects the clicked row before playing
  /// it, see `ui/track_list.dart`'s `onPlay`) and by the row context menu's
  /// Explorer-style "right-click on an unselected row selects it first"
  /// behavior (`_showTrackContextMenu`). Selection is purely a UI
  /// highlight -- it never starts or affects playback (see
  /// [PlayerService.playFrom] for that).
  void selectTrack(String? id) {
    selectedTrackIds = id == null ? {} : {id};
    _selectionAnchor = id;
    notifyListeners();
  }

  /// Standard Explorer/foobar row-click selection semantics for the track
  /// list. `ui/track_list.dart`'s per-row `onSelect` supplies [ctrl]/[shift]
  /// from `HardwareKeyboard.instance` (the same real-time-modifier pattern
  /// [FilterPanel] already uses for its own Ctrl+click) and [visibleOrder]
  /// as [visibleTracks] at click time -- the order a Shift+click's range is
  /// walked in:
  ///
  /// - plain click: selects only [id], replacing the whole selection, and
  ///   moves the range anchor to it.
  /// - Ctrl+click: toggles [id] in/out of the existing selection, moving
  ///   the anchor to it.
  /// - Shift+click: replaces the selection with the contiguous range from
  ///   the anchor to [id] in [visibleOrder] -- the anchor itself is left
  ///   unchanged, so a further Shift+click re-ranges from the same start.
  /// - Ctrl+Shift+click: adds that anchor->[id] range to the existing
  ///   selection instead of replacing it (anchor unchanged) -- Explorer's
  ///   "extend" behavior.
  ///
  /// A Shift+click with no anchor yet, or whose anchor/[id] isn't present
  /// in [visibleOrder] (shouldn't normally happen -- see the cascade points
  /// that call [_clearSelection] whenever the visible set changes), falls
  /// back to plain/Ctrl+click handling on [id] alone.
  void selectTrackClick(
    String id, {
    required bool ctrl,
    required bool shift,
    required List<Track> visibleOrder,
  }) {
    final anchor = _selectionAnchor;
    if (shift && anchor != null) {
      final ids = [for (final t in visibleOrder) t.contentId];
      final anchorIndex = ids.indexOf(anchor);
      final clickIndex = ids.indexOf(id);
      if (anchorIndex >= 0 && clickIndex >= 0) {
        final lo = anchorIndex < clickIndex ? anchorIndex : clickIndex;
        final hi = anchorIndex < clickIndex ? clickIndex : anchorIndex;
        final range = ids.sublist(lo, hi + 1).toSet();
        selectedTrackIds = ctrl ? {...selectedTrackIds, ...range} : range;
        notifyListeners();
        return;
      }
      // Anchor/id not found in the current view -- fall through to
      // plain/Ctrl handling below as if Shift weren't held.
    }
    if (ctrl) {
      final next = Set<String>.of(selectedTrackIds);
      if (!next.remove(id)) next.add(id);
      selectedTrackIds = next;
    } else {
      selectedTrackIds = {id};
    }
    _selectionAnchor = id;
    notifyListeners();
  }

  /// Ctrl+A: selects every track currently in [visibleTracks]. No-ops on an
  /// empty visible list. Keeps the existing anchor when it's still part of
  /// the newly-selected set (so a further Shift+click ranges from where the
  /// user was), otherwise anchors on the first visible track.
  void selectAll() {
    final tracks = visibleTracks;
    if (tracks.isEmpty) return;
    selectedTrackIds = {for (final t in tracks) t.contentId};
    if (_selectionAnchor == null ||
        !selectedTrackIds.contains(_selectionAnchor)) {
      _selectionAnchor = tracks.first.contentId;
    }
    notifyListeners();
  }

  /// Clears the track-list selection and its range anchor -- called from
  /// every existing filter/search/playlist/folder cascade point
  /// ([setSearch], [setPlaylist], [setArtists], [setAlbums],
  /// [_onFolderSelectionChanged]) since a selection made against one
  /// visible set stops meaning anything once that set changes materially.
  /// Plain resorting ([setSort]) is deliberately NOT a cascade point here --
  /// the same rows stay visible, just reordered.
  void _clearSelection() {
    selectedTrackIds = {};
    _selectionAnchor = null;
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
  /// The default writer ([_writeDurationsToCache]) re-loads [_cacheFile] and
  /// merges the pending durations into whatever it holds *now* -- each
  /// entry keeps its existing tag fields with only durationMs replaced --
  /// rather than saving a full cache snapshot taken earlier, so it can't
  /// resurrect stale entries over a concurrent enrichment save's newer
  /// ones. A contentId with no existing cache entry yet (not yet enriched)
  /// is deliberately left pending rather than given a fabricated entry --
  /// see [_writeDurationsToCache]'s doc. [durationCacheWriter], when set,
  /// replaces that default entirely (tests).
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
      if (old == null) {
        // No enriched cache entry yet for this track (a first-scan cache
        // miss played before enrichment reached it). Fabricating one from
        // in-memory, filename-derived fields would carry both durationMs
        // and trackNumber keys and so pass MetaCache.load's staleness
        // filter -- permanently masquerading as a real, already-enriched
        // entry and excluding the track from ever getting its actual tags
        // (see the finding this guards against). Keep a still-known track
        // pending instead, so a later flush merges the duration into
        // whatever real entry enrichment eventually writes; a track no
        // longer in the library at all is simply dropped, as before.
        if (byId.containsKey(entry.key)) {
          _pendingDurationUpdates[entry.key] = entry.value;
        }
        continue;
      }
      cache.entries[entry.key] = TrackTags(
        title: old.title,
        artist: old.artist,
        album: old.album,
        genre: old.genre,
        durationMs: entry.value,
        trackNumber: old.trackNumber,
        durationProbed: old.durationProbed,
      );
    }
    await cache.save(cacheFile);
  }

  @override
  void dispose() {
    _durationSaveTimer?.cancel();
    super.dispose();
  }

  /// The first configured library root -- where [PlaylistStore.createPlaylist]
  /// always writes new playlists (see its class doc) -- or null before the
  /// first [load]. Kept in [load]'s remembered-arguments group
  /// ([_libraryRoots]).
  Directory? get firstRoot =>
      _libraryRoots.isEmpty ? null : _libraryRoots.first;

  /// Resolves a configured library root by its [Directory.path] -- what
  /// [PlaylistStore] uses to turn a merged [ManifestPlaylist.rootPath] back
  /// into the [Directory] it needs to load/save that root's manifest. Null
  /// if no currently-configured root matches (e.g. the roots were edited in
  /// Settings since the merge that produced the entry).
  Directory? rootWithPath(String path) {
    for (final r in _libraryRoots) {
      if (r.path == path) return r;
    }
    return null;
  }

  /// Writes every known track duration into its root's `.library.json`.
  ///
  /// Durations are expensive to obtain (a tag read per file, over SMB) and
  /// used to live only in the local tag cache, so any cache loss blanked the
  /// Time column for the whole library and forced another full re-read.
  /// Persisting them beside `date_added` makes them as durable -- and as
  /// portable -- as the dates themselves.
  ///
  /// Only writes a root whose manifest actually changed, takes the same
  /// manifest phase lock every other writer uses, and leaves the rest of the
  /// manifest (playlists included) untouched. Failures are swallowed: this
  /// is an optimisation, and a read-only or briefly-unreachable share must
  /// never take a load down with it.
  Future<void> persistDurationsToManifests() async {
    final byRoot = <String, Map<String, int>>{};
    for (final t in allTracks) {
      final ms = t.durationMs;
      if (ms == null || ms <= 0) continue;
      (byRoot[t.rootPath] ??= {})[t.contentId] = ms;
    }
    if (byRoot.isEmpty) return;

    if (!await _beginManifestPhase(const Duration(seconds: 5))) return;
    try {
      for (final entry in byRoot.entries) {
        final root = rootWithPath(entry.key);
        if (root == null) continue;
        if (!File(p.join(root.path, core.manifestFileName)).existsSync()) {
          continue;
        }
        try {
          final manifest = core.loadManifest(root);
          var changed = false;
          entry.value.forEach((id, ms) {
            final track = manifest.tracks[id];
            if (track != null && track.durationMs != ms) {
              track.durationMs = ms;
              changed = true;
            }
          });
          if (changed) await core.saveManifest(manifest, root);
        } catch (_) {
          // A single unreadable/unwritable root must not stop the others.
        }
      }
    } finally {
      _endManifestPhase();
    }
  }

  /// Tells listeners to repaint without changing any library state.
  ///
  /// Used when something the UI DERIVES from outside this model changes --
  /// specifically the artwork sidecars, which the library view's "Art" column
  /// reads synchronously. Loading a sidecar changes no track, but the column
  /// is wrong until the rows rebuild.
  void notifyDerivedChanged() => notifyListeners();

  /// Attempts to take the [busy] flag for a short external manifest write
  /// (PlaylistStore's load-mutate-save cycle on the first root's
  /// `.library.json`). Returns false -- caller should retry shortly -- when
  /// a [load]/[rescan] already holds it; those write the very same manifest
  /// file from inside their isolates, so interleaving would lose updates.
  ///
  /// While held, [rescan] no-ops and a concurrent [load] queues itself via
  /// [_pendingLoad] -- exactly the discipline the two of them already apply
  /// to each other. MUST be paired with [endManifestWrite] (in a
  /// `finally`).
  bool tryBeginManifestWrite() {
    if (_manifestIo) return false;
    _manifestIo = true;
    return true;
  }

  /// Takes [_manifestIo] for one of THIS model's own manifest-touching
  /// phases, waiting up to [wait] for an in-flight external write (a
  /// PlaylistStore mutation is a sub-second load-mutate-save, so the wait is
  /// short by design). Returns false if it never came free -- the caller
  /// decides whether to skip ([rescan], which runs again on its timer) or
  /// proceed anyway ([load], which must not be skipped and whose reads are
  /// safe against `saveManifest`'s atomic tmp-then-rename).
  Future<bool> _beginManifestPhase(Duration wait) async {
    final deadline = DateTime.now().add(wait);
    while (_manifestIo) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _manifestIo = true;
    return true;
  }

  void _endManifestPhase() {
    _manifestIo = false;
  }

  /// Releases the flag taken by [tryBeginManifestWrite], notifies (so a UI
  /// disabled on [busy] re-enables), and runs any [load] that queued up
  /// while the write held the flag.
  Future<void> endManifestWrite() async {
    _manifestIo = false;
    _manifestWriteEpoch++;
    notifyListeners();
    await _runPendingLoad();
  }

  /// Re-reads ONLY the playlists section of every root's manifest and
  /// rebuilds the merged [playlists] list (same first-root-first collision
  /// suffixing and ownership stamping as [load]'s merge) -- the lightweight
  /// refresh PlaylistStore asks for after each mutation, deliberately NOT a
  /// full [load] (no track re-merge, no tag enrichment, no [busy]
  /// involvement -- callable while PlaylistStore still holds the manifest
  /// write flag).
  ///
  /// Roots with a missing or unparseable manifest are skipped, mirroring
  /// [load]. If [activePlaylist] no longer exists afterward (it was just
  /// deleted), the selection falls back to the Library view.
  void reloadPlaylists() {
    final merged = <ManifestPlaylist>[];
    final used = <String>{};
    for (final root in _libraryRoots) {
      final manifest = File(p.join(root.path, '.library.json'));
      if (!manifest.existsSync()) continue;
      List<ManifestPlaylist> loaded;
      try {
        loaded = loadManifestPlaylistsFile(manifest);
      } catch (_) {
        continue; // corrupt manifest: skipped, same as load()
      }
      for (var i = 0; i < loaded.length; i++) {
        merged.add(
          ManifestPlaylist(
            name: _uniquePlaylistName(loaded[i].name, used),
            trackIds: loaded[i].trackIds,
            rootPath: root.path,
            sourceName: loaded[i].name,
            sourceIndex: i,
          ),
        );
      }
    }
    playlists = merged;
    if (activePlaylist != null &&
        !merged.any((pl) => pl.name == activePlaylist)) {
      activePlaylist = null;
    }
    notifyListeners();
  }

  void setPlaylist(String? name) {
    activePlaylist = name;
    folderPath = [];
    folderSiblings = {};
    artistFilters = {};
    albumFilters = {};
    search = '';
    _clearSelection();
    notifyListeners();
  }

  /// Reverts sort to the default (dateAdded descending) when the album filter
  /// is cleared while [sortColumn] is [SortColumn.trackNumber].
  ///
  /// Track number sorting only makes sense in album view; when navigating away
  /// from an album via a folder-selection change/[setArtists] (which clear
  /// [albumFilters]),
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

/// Whether [a] and [b] contain exactly the same elements, order irrelevant
/// -- used by [LibraryModel.setFolderSiblings] to detect a no-op selection
/// change (see its doc) without pulling in package:collection's SetEquality
/// for one call site.
bool _setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

/// Runs one library root's whole rescan cycle -- `fooplayer_core`'s
/// `scanLibrary` (walk + stat + hash), `loadManifest`, `diffAgainstManifest`,
/// `applyDiff` (stamping any new tracks with `DateTime.now()`), then
/// `saveManifest` -- inside its own isolate (see [LibraryModel.rescan],
/// which runs this via [runIsolateWithTimeout] so a root that blows its
/// timeout is KILLED, not left running as a zombie that could clobber a
/// later manifest write -- see the comment at rescan's call site).
///
/// [scanLibrary]'s directory walk and per-file `statSync` calls are
/// synchronous-heavy over the SMB-mounted library share, exactly like the
/// tag-reading batches below -- running this off the calling isolate keeps
/// it from blocking the UI/platform thread.
///
/// Takes and returns only plain, isolate-sendable values: the root's path
/// as a `String` in (plus the result [SendPort] the
/// [runIsolateWithTimeout] protocol requires), and for every genuinely new
/// track a `(contentId, relPath, date_added ISO-8601 string)` record out --
/// never a `Manifest` or `ScannedTrack` object graph. The caller (running
/// on the main isolate) reconstructs whatever [Track]s it needs from these
/// records.
void _rescanRootIsolateEntry((String, SendPort) args) async {
  final (rootPath, resultPort) = args;
  List<(String, String, String)> result;
  try {
    final root = Directory(rootPath);
    final scanned = await core.scanLibrary(root);
    final manifest = core.loadManifest(root);
    final diff = core.diffAgainstManifest(manifest, scanned);
    core.applyDiff(manifest, diff, scanned, DateTime.now);
    await core.saveManifest(manifest, root);
    result = [
      for (final t in diff.newTracks)
        (
          t.contentId,
          manifest.tracks[t.contentId]!.paths.first,
          manifest.tracks[t.contentId]!.dateAdded,
        ),
    ];
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
  Isolate.exit(resultPort, [result]);
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
  // Bounded concurrency, NOT one at a time. A batch that trips the
  // pathological-parser guard falls in here with all 200 of its files, and
  // serially at up to [timeout] each that is over an hour for a single
  // batch -- which is exactly what "stuck at 1400/5473" looked like. Eight
  // at a time keeps the worst case in minutes while staying polite to the
  // share.
  const lanes = 8;
  for (var start = 0; start < records.length; start += lanes) {
    final end = start + lanes < records.length ? start + lanes : records.length;
    await Future.wait([
      for (final record in records.sublist(start, end))
        _readOneResilient(record, timeout, out),
    ]);
  }
  return out;
}

/// One file's guarded read, writing into [out] on success. Never throws.
Future<void> _readOneResilient(
  (String, String, String) record,
  Duration timeout,
  Map<String, TrackTags> out,
) async {
  {
    final (contentId, _, _) = record;
    try {
      final single = await _readBatchIsolate([record], timeout: timeout);
      final tags = single[contentId];
      // A file that could not be read contributes NOTHING, rather than a
      // filename-derived stand-in. The caller skips absent results, which
      // leaves whatever is already known in place: the instant feed's own
      // filename parse for a never-seen track, or -- crucially -- the real
      // cached tags of a track being refreshed. Substituting a placeholder
      // here silently overwrote good data with a guess.
      if (tags != null) out[contentId] = tags;
    } catch (_) {
      // Same: skip, don't guess.
    }
  }
}

/// Header-only duration estimate for a track whose full tag read failed.
///
/// Reads frame headers rather than parsing tags, so it sidesteps the parser
/// pathology that made the read fail in the first place, and is bounded in
/// both work and time. Null for anything that isn't an mp3, or that it
/// can't measure.
Future<int?> _estimateDurationMs(Track t) async {
  if (!isMp3Path(t.relPath)) return null;
  try {
    final d = await estimateMp3DurationForFile(
      File(p.join(t.rootPath, t.relPath)),
    ).timeout(const Duration(seconds: 5));
    return d?.inMilliseconds;
  } catch (_) {
    return null;
  }
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
  return runIsolateWithTimeout<
    Map<String, TrackTags>,
    List<(String, String, String)>
  >(_readBatchIsolateEntry, records, timeout: timeout);
}

void _readBatchIsolateEntry(
  (List<(String, String, String)>, SendPort) args,
) async {
  final (records, resultPort) = args;
  Map<String, TrackTags> result;
  try {
    result = await readTagsBatch(records);
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
  Isolate.exit(resultPort, [result]);
}
