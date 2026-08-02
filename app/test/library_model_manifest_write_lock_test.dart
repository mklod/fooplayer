// LibraryModel.tryBeginManifestWrite / endManifestWrite (Plan 3 Task 5
// reviewer finding #3): this pair used to be exercised only indirectly, via
// the old PlaylistStore's busy-retry tests -- which were deleted when
// PlaylistStore moved off the manifest lock entirely (see
// playlist_store_test.dart's header comment). That left the pair with zero
// direct coverage even though it has zero production callers right now:
// Task 9's SyncEngine is the next writer expected to take this lock for its
// own external `.library.json` touches, so the acquire/release/drain
// contract needs to keep working even while nothing in this app calls it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';

void main() {
  late Directory tmp;
  setUp(
    () async => tmp = await Directory.systemTemp.createTemp('manifestlock'),
  );
  tearDown(() async => tmp.delete(recursive: true));

  test(
    'tryBeginManifestWrite acquires once, refuses a second holder, and '
    'endManifestWrite releases it for the next one',
    () async {
      final model = LibraryModel();

      expect(model.tryBeginManifestWrite(), isTrue);
      expect(
        model.tryBeginManifestWrite(),
        isFalse,
        reason: 'already held -- a second acquire must be refused',
      );

      await model.endManifestWrite();

      expect(
        model.tryBeginManifestWrite(),
        isTrue,
        reason: 'released, so a fresh acquire succeeds again',
      );
    },
  );

  test(
    'endManifestWrite drains a load() that queued while the flag was held',
    () async {
      // rootA and rootB each get no `.library.json` of their own, so
      // whichever one actually ran is unambiguous from
      // LibraryModel.rootsMissingManifest afterward.
      final rootA = await Directory('${tmp.path}/rootA').create();
      final rootB = await Directory('${tmp.path}/rootB').create();
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = LibraryModel();

      // Hold the flag as an external writer would.
      expect(model.tryBeginManifestWrite(), isTrue);

      // load() sets `busy` SYNCHRONOUSLY (before its first `await`), and its
      // own track merge waits on the very same flag via
      // `_beginManifestPhase` -- so it stays `busy`, blocked on that wait,
      // for as long as the flag is held. No phantom-track timing tricks
      // needed to get a reliable window.
      final firstLoad = model.load(
        libraryRoots: [rootA],
        cacheFile: cacheFile,
      );
      expect(model.busy, isTrue);

      // A second load() arriving now must queue (LibraryModel.load's
      // re-entrancy contract) rather than run concurrently -- its early
      // return completes immediately, but the deferred reload it queued has
      // not run yet.
      final secondLoad = model.load(
        libraryRoots: [rootB],
        cacheFile: cacheFile,
      );
      await secondLoad;
      expect(
        model.rootsMissingManifest,
        isEmpty,
        reason: 'neither the first (still blocked) nor the queued second '
            'load has reached the point of recording a missing manifest yet',
      );

      await model.endManifestWrite();
      await firstLoad.timeout(const Duration(seconds: 30));

      // The queued load's arguments -- rootB, not rootA -- describe the
      // model's final state: the drain ran it, it didn't just vanish.
      expect(model.rootsMissingManifest, [rootB.path]);
    },
  );
}
