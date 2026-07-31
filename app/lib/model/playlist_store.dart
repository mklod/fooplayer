// Last modified: 2026-07-31--1619
import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart' as core;

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

/// Playlist CRUD over the shared `.playlists/` sidecar (see
/// `package:fooplayer_core`'s `playlist_sidecar.dart`) -- one JSON file per
/// playlist under [LibraryModel.libraryHome], instead of the old per-root
/// `.library.json` `playlists` arrays.
///
/// Write path: every mutation resolves the target playlist's id from
/// [LibraryModel.playlists] (the last merged/display state), then loads
/// its sidecar file FRESH from disk -- never a cached copy, so an edit that
/// landed since the last [LibraryModel.reloadPlaylists] (another device's
/// sync, this app's own previous mutation, ...) is never clobbered --
/// mutates it, saves it back via [core.savePlaylistFile] (atomic
/// .tmp-then-rename), then asks [LibraryModel.reloadPlaylists] for a
/// lightweight merged-playlist refresh, and finally calls [onMutated] (the
/// Task 8 sync scheduler's "something changed, consider syncing soon"
/// hook).
///
/// Unlike the old per-root design, there is no "owning root" to route a
/// mutation to and no manifest busy-lock to acquire: the sidecar is a
/// single shared directory, and [core.savePlaylistFile] is itself a cheap,
/// atomic local write, so nothing here contends with [LibraryModel.rescan]
/// or [LibraryModel.persistDurationsToManifests] the way manifest writes
/// used to.
class PlaylistStore {
  final LibraryModel library;

  /// Who signs `modified_by` on every playlist file this store writes --
  /// see `library_home.dart`'s `deviceLabel`. Also what a future sync
  /// report ("kept tablet's version") reads back out of a playlist's
  /// `modified_by`.
  final String device;

  /// Called after every mutation that actually wrote to disk (create,
  /// delete, add/remove track(s)) -- the Task 8 sync scheduler's hook to
  /// consider syncing soon. Null (the default) is a legitimate choice for
  /// any caller that doesn't need it yet.
  final void Function()? onMutated;

  PlaylistStore({required this.library, required this.device, this.onMutated});

  /// Creates an empty playlist named [name] (trimmed) in the shared
  /// sidecar. Throws [PlaylistStoreException] if the name is empty or
  /// collides with ANY merged playlist name -- including a suffixed one
  /// like "mix (2)" that only exists as a merge artifact, since creating it
  /// for real would collide with that display name on the next merge -- or
  /// if [LibraryModel.libraryHome] is null (no library roots configured
  /// yet, so there's nowhere to put `.playlists/`).
  Future<void> createPlaylist(String name) async {
    final trimmed = name.trim();
    validateNewPlaylistName(trimmed);
    final home = library.libraryHome;
    if (home == null) {
      throw PlaylistStoreException(
        'No library home for playlists — configure library roots first.',
      );
    }
    final now = DateTime.now().toUtc();
    final file = core.PlaylistFile(
      id: core.newPlaylistId(),
      name: trimmed,
      trackIds: [],
      created: now,
      modified: now,
      modifiedBy: device,
    );
    await core.savePlaylistFile(Directory(home), file);
    library.reloadPlaylists();
    onMutated?.call();
  }

  /// Deletes the playlist shown as [name]: backs up its current content
  /// (see [core.backupPlaylistFile]), records a tombstone (what tells
  /// another device's sync "this was deleted, not just never seen" rather
  /// than resurrecting it), then removes the sidecar file itself.
  Future<void> deletePlaylist(String name) async {
    final entry = _resolveEntry(name);
    final home = library.libraryHome;
    if (home == null) {
      throw PlaylistStoreException(
        'No library home for playlists — configure library roots first.',
      );
    }
    final homeDir = Directory(home);
    final state = core.loadPlaylistsDir(homeDir);
    final id = entry.id;
    final p = id == null ? null : state.playlists[id];
    if (p == null) {
      throw PlaylistStoreException(
        'Playlist "$name" is no longer present — it may have been '
        'changed outside the app.',
      );
    }
    final now = DateTime.now().toUtc();
    await core.backupPlaylistFile(homeDir, p, now);
    final tombstones = Map<String, core.PlaylistTombstone>.of(
      state.tombstones,
    );
    tombstones[p.id] = core.PlaylistTombstone(deleted: now, name: p.name);
    await core.saveTombstones(homeDir, tombstones);
    await core.removePlaylistFile(homeDir, p.id);
    library.reloadPlaylists();
    onMutated?.call();
  }

  /// Appends [contentId] to the playlist shown as [name] (no-op write if
  /// the track is already in it -- playlists here are sets-in-order, not
  /// multisets).
  Future<void> addTrack(String name, String contentId) async {
    await _withPlaylist(name, (p) {
      if (!p.trackIds.contains(contentId)) {
        p.trackIds.add(contentId);
      }
    });
  }

  /// Removes every occurrence of [contentId] from the playlist shown as
  /// [name].
  Future<void> removeTrack(String name, String contentId) async {
    await _withPlaylist(name, (p) {
      p.trackIds.removeWhere((id) => id == contentId);
    });
  }

  /// Batch form of [addTrack]: appends every id in [contentIds] to the
  /// playlist shown as [name] (skipping any already present -- same
  /// set-in-order semantics as [addTrack]), writing the sidecar file ONCE
  /// for the whole batch rather than once per track -- what the track
  /// list's multi-select "Add to playlist" context-menu action uses so
  /// selecting N tracks costs one disk write, not N. Returns the number of
  /// tracks actually appended (excludes ones already present), so the
  /// caller can report an accurate count. No-ops (no write, no reload) when
  /// [contentIds] is empty.
  Future<int> addTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    var added = 0;
    await _withPlaylist(name, (p) {
      for (final id in contentIds) {
        if (!p.trackIds.contains(id)) {
          p.trackIds.add(id);
          added++;
        }
      }
    });
    return added;
  }

  /// Batch form of [removeTrack]: removes every occurrence of every id in
  /// [contentIds] from the playlist shown as [name], writing the sidecar
  /// file ONCE for the whole batch -- the multi-select "Remove from
  /// playlist" counterpart to [addTracks]. Returns the number of playlist
  /// entries actually removed. No-ops when [contentIds] is empty.
  Future<int> removeTracks(String name, List<String> contentIds) async {
    if (contentIds.isEmpty) return 0;
    var removed = 0;
    await _withPlaylist(name, (p) {
      final idSet = contentIds.toSet();
      final before = p.trackIds.length;
      p.trackIds.removeWhere((id) => idSet.contains(id));
      removed = before - p.trackIds.length;
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

  /// Resolves the merged playlist entry for display-name [name].
  ManifestPlaylist _resolveEntry(String name) {
    final matches = library.playlists.where((pl) => pl.name == name);
    if (matches.isEmpty) {
      throw PlaylistStoreException('No playlist named "$name".');
    }
    return matches.first;
  }

  /// The shared load-mutate-save-refresh cycle every track-membership
  /// mutation runs through: resolves [displayName] to its sidecar id, loads
  /// that playlist's file FRESH (never a cached copy -- so a change that
  /// landed since the last reload, from another device's sync or this
  /// app's own previous mutation, is never overwritten), applies [mutate],
  /// and -- ONLY if [mutate] actually changed the name or membership --
  /// stamps `modified`/`modifiedBy`, saves, refreshes
  /// [LibraryModel.playlists], and calls [onMutated]. [mutate] may throw a
  /// [PlaylistStoreException] to abort -- nothing is saved in that case.
  ///
  /// The no-op check matters beyond "why write nothing": [addTrack] of an
  /// id already present, or [removeTrack]/[removeTracks] of one that was
  /// never there, leaves [core.PlaylistFile.trackIds] byte-for-byte
  /// unchanged. Stamping `modified` anyway would still be a NEWER
  /// timestamp than a real edit another device made to the same playlist,
  /// so the Task 2 reconciler's last-write-wins would wrongly prefer this
  /// no-op touch over that real edit -- or, worse, a no-op bump could
  /// out-date and resurrect a playlist another device just tombstoned.
  Future<void> _withPlaylist(
    String displayName,
    void Function(core.PlaylistFile p) mutate,
  ) async {
    final entry = _resolveEntry(displayName);
    final id = entry.id;
    final home = library.libraryHome;
    if (home == null) {
      throw PlaylistStoreException(
        'No library home for playlists — configure library roots first.',
      );
    }
    final homeDir = Directory(home);
    final state = core.loadPlaylistsDir(homeDir);
    final p = id == null ? null : state.playlists[id];
    if (p == null) {
      throw PlaylistStoreException(
        'Playlist "$displayName" is no longer present — it may have been '
        'changed outside the app.',
      );
    }
    final before = core.PlaylistFile(
      id: p.id,
      name: p.name,
      trackIds: List<String>.of(p.trackIds),
      created: p.created,
      modified: p.modified,
      modifiedBy: p.modifiedBy,
    );
    mutate(p);
    if (p.sameContentAs(before)) {
      return;
    }
    p.modified = DateTime.now().toUtc();
    p.modifiedBy = device;
    await core.savePlaylistFile(homeDir, p);
    library.reloadPlaylists();
    onMutated?.call();
  }
}
