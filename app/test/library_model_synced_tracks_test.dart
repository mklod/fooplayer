// Regression: tracks that arrive ALREADY KNOWN TO THE MANIFEST must show up
// in the library without an app restart.
//
// This is exactly what a LAN sync produces on the phone: SyncEngine copies
// the audio files AND writes the NAS's manifest into the local root, then
// calls rescan(). Because the manifest already lists those tracks, the
// scan/manifest diff is EMPTY -- so the old rescan(), which only surfaced
// entries it had freshly minted, added nothing to allTracks and the feed
// looked identical to before the sync. Reported live: "I go back to library
// after the sync and I see nothing new at the top."
//
// load() never had the bug (it builds allTracks straight from the
// manifest), which is why restarting the app made the tracks appear.
//
// Last modified: 2026-09-10--1740
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('synced'));
  tearDown(() async => tmp.delete(recursive: true));

  test('rescan surfaces files whose manifest entry already exists '
      '(the post-sync case)', () async {
    final root = await Directory('${tmp.path}/lib').create();

    // One track the library already knows about.
    final existing = File('${root.path}/Existing Song.mp3');
    await existing.writeAsBytes(List<int>.filled(64, 0x11));
    final existingId = await contentIdForFile(existing);

    final manifest = Manifest.empty();
    manifest.tracks[existingId] = TrackEntry(
      dateAdded: '2020-01-01T00:00:00.000Z',
      paths: const ['Existing Song.mp3'],
    );
    await saveManifest(manifest, root);

    final cacheFile = File('${tmp.path}/meta_cache.json');
    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));
    expect(model.allTracks, hasLength(1));

    // --- simulate what SyncEngine does on the phone -------------------
    // 1. the audio file lands...
    final synced = File('${root.path}/Artist - Synced Track.mp3');
    await synced.writeAsBytes(List<int>.filled(200, 0x22));
    final syncedId = await contentIdForFile(synced);
    // 2. ...and the REMOTE manifest is written over the local one, so the
    //    entry (with the NAS's dateAdded) is already present.
    manifest.tracks[syncedId] = TrackEntry(
      dateAdded: '2026-09-09T12:00:00.000Z',
      paths: const ['Artist - Synced Track.mp3'],
    );
    await saveManifest(manifest, root);

    await model.rescan().timeout(const Duration(seconds: 30));

    expect(
      model.allTracks.map((t) => t.contentId),
      contains(syncedId),
      reason: 'a synced track must appear without restarting the app',
    );

    // And it must keep the NAS's dateAdded, NOT get re-stamped with now() --
    // that date is what the feed sorts by, and re-minting it would scramble
    // the phone's ordering relative to the desktop.
    final t = model.allTracks.firstWhere((t) => t.contentId == syncedId);
    expect(t.dateAdded, DateTime.utc(2026, 9, 9, 12));
  });
}
