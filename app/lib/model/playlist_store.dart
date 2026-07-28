// Last modified: 2026-07-24
import 'dart:async';
import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;

import 'library_model.dart';
import 'manifest_io.dart';

/// Thrown by every [PlaylistStore] operation that can't proceed -- the
/// [message] is user-presentable (the UI surfaces it in a SnackBar /
/// dialog error line verbatim).
class PlaylistStoreException implements Exception {
  final String message;
  PlaylistStoreException(this.message);
  @override
  String toString() => message;
}

/// Playlist CRUD over the configured library roots' `.library.json` files.
///
/// Write path: every mutation loads the relevant root's manifest FRESH from
/// disk (`fooplayer_core`'s [core.loadManifest] -- never a cached copy, so a
/// rescan's own manifest save that landed since the app's last load is
/// preserved), mutates only the `playlists` section, saves via
/// [core.saveManifest] (atomic .tmp-rename with a `.bak` of the previous
/// version), then asks [LibraryModel.reloadPlaylists] for a lightweight
/// merged-playlist refresh -- no full library reload.
///
/// Rescan-writer guard -- documented choice: **brief retry, not a queue.**
/// [LibraryModel.rescan] saves a manifest file from inside an isolate while
/// holding [LibraryModel.busy]; a store write interleaving with that save
/// would lose one side's changes. Each mutation therefore acquires the
/// model's busy flag via [LibraryModel.tryBeginManifestWrite], retrying
/// every [busyRetryEvery] for up to [busyRetryFor] before giving up with a
/// clear "library is busy" [PlaylistStoreException]. A retry keeps the
/// failure mode explicit and bounded (the user re-clicks a second later)
/// instead of a silent queue that might apply a mutation long after the
/// click, against a library state the user no longer sees.
///
/// Ownership: LibraryModel merges playlists from every root, suffixing name
/// collisions (" (2)", ...) and stamping each merged entry with the root it
/// actually lives in ([ManifestPlaylist.rootPath]). **Edits go to the
/// owning root**: [addTrack]/[addTracks]/[removeTrack]/[removeTracks]/
/// [deletePlaylist] resolve that root (via [LibraryModel.rootWithPath]) and
/// load-mutate-save ITS manifest -- a playlist living in the third of four
/// configured roots is edited exactly as readily as one in the first.
/// [createPlaylist] is the one exception: a brand-new playlist has no
/// existing owner, so it always lands in the FIRST configured root (see its
/// own doc).
///
/// Caveat worth knowing (not a bug, just a consequence of per-root
/// manifests): a playlist in root D can end up referencing track IDs whose
/// files live under a DIFFERENT root -- e.g. the user adds a track from
/// root A to a playlist stored in root D. The merged in-app library (every
/// root's tracks combined) resolves that fine, but root D's `.library.json`
/// read in isolation is not a complete description of that playlist's
/// tracks -- another tool reading just that one file, or a future version
/// that drops multi-root merging, would see the playlist reference IDs it
/// can't find. No safeguard against this today; flagged here so it isn't a
/// surprise later.
class PlaylistStore {
  final LibraryModel library;

  /// See the class doc's rescan-writer guard. Overridable so tests don't
  /// wait wall-clock seconds.
  final Duration busyRetryEvery;
  final Duration busyRetryFor;

  PlaylistStore({
    required this.library,
    this.busyRetryEvery = const Duration(milliseconds: 100),
    this.busyRetryFor = const Duration(seconds: 5),
  });

  /// Creates an empty playlist named [name] (trimmed) in the FIRST
  /// configured root's manifest (see the class doc: unlike every other
  /// mutation here, a brand-new playlist has no existing owning root to
  /// route to). Throws [PlaylistStoreException] if the name is empty or
  /// collides with ANY merged playlist name -- including a suffixed one
  /// like "mix (2)" that only exists as a merge artifact, since creating
  /// it on disk would collide with that display name on the next merge.
  Future<void> createPlaylist(String name) async {
    final trimmed = name.trim();
    validateNewPlaylistName(trimmed);
    final first = library.firstRoot;
    if (first == null) {
      throw PlaylistStoreException('No library roots configured.');
    }
    await _withManifest(first, (manifest) {
      if (manifest.playlists.any((pl) => pl.name == trimmed)) {
        // Model state was stale (e.g. another process wrote the manifest);
        // re-check against the fresh manifest so we never write a dupe.
        throw PlaylistStoreException(
          'A playlist named "$trimmed" already exists.',
        );
      }
      manifest.playlists.add(core.Playlist(name: trimmed, trackIds: []));
    });
  }

  /// Deletes the playlist shown as [name] -- from whichever root actually
  /// owns it (see the class doc's ownership note).
  Future<void> deletePlaylist(String name) async {
    final entry = _resolveEntry(name);
    final root = _ownedRoot(entry);
    await _withManifest(root, (manifest) {
      manifest.playlists.removeAt(_manifestIndexOf(manifest, entry));
    });
  }

  /// Appends [contentId] to the playlist shown as [name] (no-op write if
  /// the track is already in it -- playlists here are sets-in-order, not
  /// multisets), writing to whichever root owns that playlist -- see the
  /// class doc's ownership note.
  Future<void> addTrack(String name, String contentId) async {
    final entry = _resolveEntry(name);
    final root = _ownedRoot(entry);
    await _withManifest(root, (manifest) {
      final pl = manifest.playlists[_manifestIndexOf(manifest, entry)];
      if (!pl.trackIds.contains(contentId)) {
        pl.trackIds.add(contentId);
      }
    });
  }

  /// Removes every occurrence of [contentId] from the playlist shown as
  /// [name]. Same owning-root routing as [addTrack].
  Future<void> removeTrack(String name, String contentId) async {
    final entry = _resolveEntry(name);
    final root = _ownedRoot(entry);
    await _withManifest(root, (manifest) {
      final pl = manifest.playlists[_manifestIndexOf(manifest, entry)];
      pl.trackIds.removeWhere((id) => id == contentId);
    });
  }

  /// Batch form of [addTrack]: appends every id in [contentIds] to the
  /// playlist shown as [name] (skipping any already present -- same
  /// set-in-order semantics as [addTrack]), writing the manifest ONCE for
  /// the whole batch rather than once per track -- what the track list's
  /// multi-select "Add to playlist" context-menu action uses so selecting
  /// N tracks costs one disk write, not N. Returns the number of tracks
  /// actually appended (excludes ones already present), so the caller can
  /// report an accurate count. No-ops (no manifest write, no busy
  /// acquisition) when [contentIds] is empty. Same owning-root routing as
  /// [addTrack].
  Future<int> addTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    final entry = _resolveEntry(name);
    final root = _ownedRoot(entry);
    var added = 0;
    await _withManifest(root, (manifest) {
      final pl = manifest.playlists[_manifestIndexOf(manifest, entry)];
      for (final id in contentIds) {
        if (!pl.trackIds.contains(id)) {
          pl.trackIds.add(id);
          added++;
        }
      }
    });
    return added;
  }

  /// Batch form of [removeTrack]: removes every occurrence of every id in
  /// [contentIds] from the playlist shown as [name], writing the manifest
  /// ONCE for the whole batch -- the multi-select "Remove from playlist"
  /// counterpart to [addTracks]. Returns the number of playlist entries
  /// actually removed. No-ops when [contentIds] is empty. Same owning-root
  /// routing as [removeTrack].
  Future<int> removeTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    final entry = _resolveEntry(name);
    final root = _ownedRoot(entry);
    var removed = 0;
    await _withManifest(root, (manifest) {
      final pl = manifest.playlists[_manifestIndexOf(manifest, entry)];
      final idSet = contentIds.toSet();
      final before = pl.trackIds.length;
      pl.trackIds.removeWhere((id) => idSet.contains(id));
      removed = before - pl.trackIds.length;
    });
    return removed;
  }

  /// Throws [PlaylistStoreException] unless [name] (already trimmed) is a
  /// usable NEW playlist name: non-empty and not colliding with any merged
  /// playlist name (suffixed merge artifacts included). Public so the
  /// create dialog can validate as the user types, with the same rules the
  /// eventual [createPlaylist] enforces.
  void validateNewPlaylistName(String name) {
    if (name.trim().isEmpty) {
      throw PlaylistStoreException('Playlist name cannot be empty.');
    }
    if (library.playlists.any((pl) => pl.name == name.trim())) {
      throw PlaylistStoreException(
        'A playlist named "${name.trim()}" already exists.',
      );
    }
  }

  /// Resolves the merged playlist entry for display-name [name]. No
  /// ownership decisions here -- see [_ownedRoot] for where a mutation's
  /// target root is actually chosen.
  ManifestPlaylist _resolveEntry(String name) {
    final matches = library.playlists.where((pl) => pl.name == name);
    if (matches.isEmpty) {
      throw PlaylistStoreException('No playlist named "$name".');
    }
    return matches.first;
  }

  /// The [Directory] a mutation against [entry] must load-mutate-save --
  /// [ManifestPlaylist.rootPath] (LibraryModel's merge-time ownership stamp)
  /// resolved back to a currently-configured root via
  /// [LibraryModel.rootWithPath]. Null [rootPath] only happens for
  /// hand-built fixtures that skipped the merge (tests); those fall back to
  /// the first root, matching this store's historical behavior for them. A
  /// non-null [rootPath] that no longer matches any configured root (the
  /// roots were edited in Settings since the merge ran) is a clear refusal,
  /// not a silent fallback to the wrong root.
  Directory _ownedRoot(ManifestPlaylist entry) {
    final path = entry.rootPath;
    if (path == null) {
      final first = library.firstRoot;
      if (first == null) {
        throw PlaylistStoreException('No library roots configured.');
      }
      return first;
    }
    final root = library.rootWithPath(path);
    if (root == null) {
      throw PlaylistStoreException(
        'Playlist "${entry.name}" lives in a root ($path) that is no '
        'longer configured.',
      );
    }
    return root;
  }

  /// Finds [entry]'s index in the freshly-loaded [manifest]'s playlists:
  /// prefer the merge-time [ManifestPlaylist.sourceIndex] when the name at
  /// that position still matches (this is what disambiguates two
  /// same-named playlists within one manifest), otherwise fall back to the
  /// first name match; throws if the playlist vanished from the manifest
  /// since the merge (e.g. an external edit).
  int _manifestIndexOf(core.Manifest manifest, ManifestPlaylist entry) {
    final sourceName = entry.sourceName ?? entry.name;
    final si = entry.sourceIndex;
    if (si != null &&
        si >= 0 &&
        si < manifest.playlists.length &&
        manifest.playlists[si].name == sourceName) {
      return si;
    }
    final i = manifest.playlists.indexWhere((pl) => pl.name == sourceName);
    if (i < 0) {
      throw PlaylistStoreException(
        'Playlist "${entry.name}" is no longer present in the library '
        'manifest -- it may have been changed outside the app.',
      );
    }
    return i;
  }

  /// The shared load-mutate-save-refresh cycle every mutation runs through
  /// (see the class doc for the write path and the busy-flag retry) against
  /// [root] -- the first root for [createPlaylist], the resolved owning
  /// root (see [_ownedRoot]) for everything else. [mutate] may throw a
  /// [PlaylistStoreException] to abort -- nothing is saved in that case.
  Future<void> _withManifest(
    Directory root,
    FutureOr<void> Function(core.Manifest manifest) mutate,
  ) async {
    final manifestFile = File(p.join(root.path, core.manifestFileName));
    if (!manifestFile.existsSync()) {
      // Refuse rather than letting loadManifest hand back Manifest.empty()
      // and saveManifest materialize a zero-track manifest: that would
      // make an unseeded root look seeded (and stop the settings dialog
      // reporting it as missing).
      throw PlaylistStoreException(
        'The library root (${root.path}) has no .library.json yet -- '
        'seed it with foolib first.',
      );
    }
    await _acquireBusy();
    try {
      final manifest = core.loadManifest(root);
      await mutate(manifest);
      await core.saveManifest(manifest, root);
      library.reloadPlaylists();
    } finally {
      await library.endManifestWrite();
    }
  }

  Future<void> _acquireBusy() async {
    final deadline = DateTime.now().add(busyRetryFor);
    while (!library.tryBeginManifestWrite()) {
      if (DateTime.now().isAfter(deadline)) {
        throw PlaylistStoreException(
          'The library is busy (scanning) -- try again in a moment.',
        );
      }
      await Future<void>.delayed(busyRetryEvery);
    }
  }
}
