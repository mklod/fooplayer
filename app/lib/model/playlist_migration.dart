// Last modified: 2026-07-31--1558
//
// One-time move of playlists out of each root's .library.json into the
// shared .playlists/ sidecar. Idempotent: identical (name, trackIds) pairs
// already in the sidecar are skipped, so the second device to update (whose
// manifest copy still carries the array) migrates to a no-op.
import 'dart:io';
import 'dart:math';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;

Future<List<String>> migratePlaylistsToSidecar({
  required List<Directory> roots,
  required Directory home,
  required String device,
  DateTime Function()? now,
  Random? rng,
}) async {
  final clock = now ?? () => DateTime.now().toUtc();
  final notes = <String>[];
  var state = core.loadPlaylistsDir(home);

  bool alreadyThere(core.Playlist pl) => state.playlists.values.any((existing) {
        if (existing.name != pl.name ||
            existing.trackIds.length != pl.trackIds.length) {
          return false;
        }
        for (var i = 0; i < pl.trackIds.length; i++) {
          if (existing.trackIds[i] != pl.trackIds[i]) return false;
        }
        return true;
      });

  String freeName(String name) {
    final used = state.playlists.values.map((e) => e.name).toSet();
    if (!used.contains(name)) return name;
    var n = 2;
    while (used.contains('$name ($n)')) n++;
    return '$name ($n)';
  }

  for (final root in roots) {
    if (!File(p.join(root.path, core.manifestFileName)).existsSync()) continue;
    final core.Manifest manifest;
    try {
      manifest = core.loadManifest(root);
    } catch (_) {
      continue; // corrupt: load() reports it; migration must not crash startup
    }
    if (manifest.playlists.isEmpty) continue;

    for (final pl in manifest.playlists) {
      if (alreadyThere(pl)) {
        notes.add('"${pl.name}" already in the sidecar — skipped');
        continue;
      }
      final t = clock();
      // Ensure unique ID: regenerate if it collides with existing playlists
      var id = core.newPlaylistId(rng);
      while (state.playlists.containsKey(id)) {
        id = core.newPlaylistId(rng);
      }
      final file = core.PlaylistFile(
        id: id,
        name: freeName(pl.name),
        trackIds: List.of(pl.trackIds),
        created: t,
        modified: t,
        modifiedBy: device,
      );
      await core.savePlaylistFile(home, file);
      state = core.loadPlaylistsDir(home); // keep dedupe/name checks current
      notes.add('moved "${file.name}" (${file.trackIds.length} tracks) '
          'from ${p.basename(root.path)} into the sidecar');
    }
    manifest.playlists.clear();
    await core.saveManifest(manifest, root);
  }
  return notes;
}
