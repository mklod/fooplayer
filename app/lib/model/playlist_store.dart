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

/// Playlist CRUD over the FIRST configured library root's `.library.json`.
///
/// Write path: every mutation loads that root's manifest FRESH from disk
/// (`fooplayer_core`'s [core.loadManifest] -- never a cached copy, so a
/// rescan's own manifest save that landed since the app's last load is
/// preserved), mutates only the `playlists` section, saves via
/// [core.saveManifest] (atomic .tmp-rename with a `.bak` of the previous
/// version), then asks [LibraryModel.reloadPlaylists] for a lightweight
/// merged-playlist refresh -- no full library reload.
///
/// Rescan-writer guard -- documented choice: **brief retry, not a queue.**
/// [LibraryModel.rescan] saves the same manifest file from inside an
/// isolate while holding [LibraryModel.busy]; a store write interleaving
/// with that save would lose one side's changes. Each mutation therefore
/// acquires the model's busy flag via [LibraryModel.tryBeginManifestWrite],
/// retrying every [busyRetryEvery] for up to [busyRetryFor] before giving
/// up with a clear "library is busy" [PlaylistStoreException]. A retry
/// keeps the failure mode explicit and bounded (the user re-clicks a
/// second later) instead of a silent queue that might apply a mutation
/// long after the click, against a library state the user no longer sees.
///
/// Ownership: LibraryModel merges playlists from every root, suffixing
/// name collisions (" (2)", ...). This store only ever writes the first
/// root's manifest, so a mutation aimed at a playlist that actually lives
/// in ANOTHER root's manifest (per the merge's ownership stamp, see
/// [ManifestPlaylist.rootPath]) is refused with a message naming the
/// owning root -- never a silent no-op.
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

  /// Creates an empty playlist named [name] (trimmed) in the first root's
  /// manifest. Throws [PlaylistStoreException] if the name is empty or
  /// collides with ANY merged playlist name -- including a suffixed one
  /// like "mix (2)" that only exists as a merge artifact, since creating
  /// it on disk would collide with that display name on the next merge.
  Future<void> createPlaylist(String name) async {
    final trimmed = name.trim();
    validateNewPlaylistName(trimmed);
    await _withFirstRootManifest((manifest, root) {
      if (manifest.playlists.any((pl) => pl.name == trimmed)) {
        // Model state was stale (e.g. another process wrote the manifest);
        // re-check against the fresh manifest so we never write a dupe.
        throw PlaylistStoreException(
            'A playlist named "$trimmed" already exists.');
      }
      manifest.playlists.add(core.Playlist(name: trimmed, trackIds: []));
    });
  }

  /// Deletes the playlist shown as [name]. Blocked (with the owning root
  /// named) when the playlist lives in a root other than the first -- see
  /// the class doc's ownership note.
  Future<void> deletePlaylist(String name) async {
    final entry = _ownedEntry(name);
    await _withFirstRootManifest((manifest, root) {
      manifest.playlists.removeAt(_manifestIndexOf(manifest, entry));
    });
  }

  /// Appends [contentId] to the playlist shown as [name] (no-op write if
  /// the track is already in it -- playlists here are sets-in-order, not
  /// multisets). Same ownership rules as [deletePlaylist].
  Future<void> addTrack(String name, String contentId) async {
    final entry = _ownedEntry(name);
    await _withFirstRootManifest((manifest, root) {
      final pl = manifest.playlists[_manifestIndexOf(manifest, entry)];
      if (!pl.trackIds.contains(contentId)) {
        pl.trackIds.add(contentId);
      }
    });
  }

  /// Removes every occurrence of [contentId] from the playlist shown as
  /// [name]. Same ownership rules as [deletePlaylist].
  Future<void> removeTrack(String name, String contentId) async {
    final entry = _ownedEntry(name);
    await _withFirstRootManifest((manifest, root) {
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
  /// acquisition) when [contentIds] is empty. Same ownership rules as
  /// [addTrack].
  Future<int> addTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    final entry = _ownedEntry(name);
    var added = 0;
    await _withFirstRootManifest((manifest, root) {
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
  /// actually removed. No-ops when [contentIds] is empty. Same ownership
  /// rules as [removeTrack].
  Future<int> removeTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    final entry = _ownedEntry(name);
    var removed = 0;
    await _withFirstRootManifest((manifest, root) {
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
          'A playlist named "${name.trim()}" already exists.');
    }
  }

  /// Resolves the merged playlist entry for display-name [name] and
  /// enforces first-root ownership -- see the class doc.
  ManifestPlaylist _ownedEntry(String name) {
    final matches = library.playlists.where((pl) => pl.name == name);
    if (matches.isEmpty) {
      throw PlaylistStoreException('No playlist named "$name".');
    }
    final entry = matches.first;
    final first = library.firstRoot;
    if (first == null) {
      throw PlaylistStoreException('No library roots configured.');
    }
    if (entry.rootPath != null && entry.rootPath != first.path) {
      throw PlaylistStoreException(
          'Playlist "$name" lives in another root\'s library '
          '(${entry.rootPath}) and can\'t be edited from here -- only '
          'playlists in the first library root (${first.path}) are '
          'editable.');
    }
    return entry;
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
          'manifest -- it may have been changed outside the app.');
    }
    return i;
  }

  /// The shared load-mutate-save-refresh cycle every mutation runs through
  /// (see the class doc for the write path and the busy-flag retry).
  /// [mutate] may throw a [PlaylistStoreException] to abort -- nothing is
  /// saved in that case.
  Future<void> _withFirstRootManifest(
      FutureOr<void> Function(core.Manifest manifest, Directory root)
          mutate) async {
    final root = library.firstRoot;
    if (root == null) {
      throw PlaylistStoreException('No library roots configured.');
    }
    final manifestFile = File(p.join(root.path, core.manifestFileName));
    if (!manifestFile.existsSync()) {
      // Refuse rather than letting loadManifest hand back Manifest.empty()
      // and saveManifest materialize a zero-track manifest: that would
      // make an unseeded root look seeded (and stop the settings dialog
      // reporting it as missing).
      throw PlaylistStoreException(
          'The first library root (${root.path}) has no .library.json yet '
          '-- seed it with foolib first.');
    }
    await _acquireBusy();
    try {
      final manifest = core.loadManifest(root);
      await mutate(manifest, root);
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
            'The library is busy (scanning) -- try again in a moment.');
      }
      await Future<void>.delayed(busyRetryEvery);
    }
  }
}
