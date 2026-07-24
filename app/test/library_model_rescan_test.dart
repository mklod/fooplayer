// In-app library rescan (Plan 2a.2 Task 5): LibraryModel.rescan() finds
// files added to a configured root since the last load()/rescan(), merges
// them into allTracks with a freshly stamped dateAdded, and persists the
// change to that root's .library.json via fooplayer_core -- so new
// downloads show up without an app restart (launch/Refresh/5-minute-timer
// triggers are wired in main.dart, out of scope for this unit-level test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('rescan'));
  tearDown(() async => tmp.delete(recursive: true));

  test(
      'rescan finds a new file, merges it into allTracks with a fresh '
      'dateAdded, and the manifest on disk gains the entry', () async {
    final root = await Directory('${tmp.path}/lib').create();

    // Seed one pre-existing, already-known track via fooplayer_core's own
    // Manifest/saveManifest (the task's prescribed setup) -- backed by a
    // real file, since scanLibrary (which rescan() drives) walks the root
    // for real rather than trusting the manifest blindly.
    final existingFile = File('${root.path}/Existing Song.mp3');
    await existingFile.writeAsBytes(List<int>.filled(64, 0x11));
    final existingId = await contentIdForFile(existingFile);

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
    expect(model.status, 'ready');

    // Drop a genuinely new file into the root -- junk bytes, not real MP3
    // audio, so the merge step's filename-fallback metadata path (see
    // rescan()'s doc comment) is exercised end to end.
    await File('${root.path}/Artist - Junk File.mp3')
        .writeAsBytes(List<int>.filled(200, 0));

    final before = DateTime.now();
    await model.rescan().timeout(const Duration(seconds: 30));
    final after = DateTime.now();

    expect(model.status, 'added 1 new tracks');
    expect(model.busy, isFalse);
    expect(model.allTracks, hasLength(2));

    final added = model.allTracks
        .firstWhere((t) => t.relPath == 'Artist - Junk File.mp3');
    expect(added.rootPath, root.path);
    expect(added.title, 'Junk File'); // filename fallback: junk bytes, unparseable
    expect(added.artist, 'Artist');
    expect(
      added.dateAdded.isAfter(before.subtract(const Duration(seconds: 2))),
      isTrue,
      reason: 'the new track must be stamped with a dateAdded from this '
          'rescan, not some stale/default value',
    );
    expect(
      added.dateAdded.isBefore(after.add(const Duration(seconds: 2))),
      isTrue,
    );

    // The pre-existing track is untouched -- its original stamp survives.
    final existing =
        model.allTracks.firstWhere((t) => t.contentId == existingId);
    expect(existing.dateAdded, DateTime.utc(2020, 1, 1));

    // The manifest file on disk gained the new entry too, not just the
    // in-memory model -- rescan() must have actually called saveManifest.
    final onDisk = loadManifest(root);
    expect(onDisk.tracks, hasLength(2));
    expect(
      onDisk.tracks.values
          .any((e) => e.paths.contains('Artist - Junk File.mp3')),
      isTrue,
    );
  });

  test('rescan is a no-op while a rescan is already in flight', () async {
    final root = await Directory('${tmp.path}/lib').create();
    final existingFile = File('${root.path}/Existing Song.mp3');
    await existingFile.writeAsBytes(List<int>.filled(64, 0x22));
    final existingId = await contentIdForFile(existingFile);

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

    await File('${root.path}/Artist - New File.mp3')
        .writeAsBytes(List<int>.filled(200, 0));

    expect(model.busy, isFalse);
    final first = model.rescan().timeout(const Duration(seconds: 30));
    // rescan()'s busy guard is its very first line, with no `await` ahead
    // of it -- so by the time this call has returned control here (having
    // suspended at its own first `await`, deep inside the per-root loop),
    // `busy` is already true and won't flip back until `first` settles.
    expect(model.busy, isTrue);

    final statusBeforeSecondCall = model.status;
    final second = model.rescan().timeout(const Duration(seconds: 30));
    // A guarded call returns having touched nothing at all -- in
    // particular, without ever assigning `status` -- so it is unchanged
    // immediately after this synchronous call returns (still before either
    // Future has settled).
    expect(model.status, statusBeforeSecondCall);

    await Future.wait([first, second]);

    expect(model.busy, isFalse);
    expect(model.status, 'added 1 new tracks');
    expect(model.allTracks, hasLength(2)); // not duplicated by the no-op call
  });
}
