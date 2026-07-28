// Regression tests for a reviewer-found defect in Plan 2a.2 Task 5's rescan
// wiring: `load()` held `busy` for its *entire* duration (feed render AND
// background tag enrichment), but the launch-rescan hook used to fire from
// *inside* load() while that flag was still held -- so `rescan()`'s own
// "no-op while busy" guard silently swallowed the launch rescan on every
// single run. Fixed by making main.dart await load() to completion, THEN
// call rescan() -- see main.dart's reloadLibrary() -- rather than firing
// rescan from a callback load() invokes on its own way through.
//
// Also covers the accompanying re-entrancy gap this fix surfaced: two
// overlapping load() calls (e.g. a settings-triggered reload landing while
// the launch load is still enriching) each used to carry their own
// independent `finally { busy = false; }`, so the first one to finish would
// clear `busy` out from under the other -- letting a timer/Refresh rescan
// sneak in and race the still-running load's tag-cache writes. load() is
// now queued (not run concurrently) when busy, and re-issued once the
// in-flight operation releases the flag.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

Future<String> _seedRoot(
  Directory root,
  String existingFileName,
  List<int> existingBytes,
  String existingDateAdded,
) async {
  final existingFile = File('${root.path}/$existingFileName');
  await existingFile.writeAsBytes(existingBytes);
  final existingId = await contentIdForFile(existingFile);
  final manifest = Manifest.empty();
  manifest.tracks[existingId] = TrackEntry(
    dateAdded: existingDateAdded,
    paths: [existingFileName],
  );
  await saveManifest(manifest, root);
  return existingId;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('wiring'));
  tearDown(() async => tmp.delete(recursive: true));

  test(
    "mirrors main.dart's actual launch wiring end to end: await load() "
    'then call rescan() -- a file dropped in before launch is picked up',
    () async {
      final root = await Directory('${tmp.path}/lib').create();
      await _seedRoot(
        root,
        'Existing Song.mp3',
        List<int>.filled(64, 0x11),
        '2020-01-01T00:00:00.000Z',
      );

      // The "new" file already sits on disk BEFORE load() ever runs -- e.g.
      // dropped into a watched folder before the app was launched -- so only
      // rescan() (load() only reads the manifest) can find it.
      await File(
        '${root.path}/Artist - Launch Find.mp3',
      ).writeAsBytes(List<int>.filled(200, 0));

      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = LibraryModel();

      // This is main.dart's actual launch sequence, reproduced verbatim (see
      // reloadLibrary() there): await load() to completion, THEN call
      // rescan() -- not the removed onFirstFeedReady hook, which used to fire
      // rescan() from *inside* load() while `busy` was still held, silently
      // no-opping it every time (the bug this test pins).
      await model
          .load(libraryRoots: [root], cacheFile: cacheFile)
          .timeout(const Duration(seconds: 30));
      expect(
        model.busy,
        isFalse,
        reason:
            'load() must have released busy by the time it returns, or '
            'the following rescan() call would silently no-op',
      );
      expect(
        model.allTracks,
        hasLength(1),
        reason:
            'load() alone must not see the new file -- it only reads '
            'the manifest, not the filesystem',
      );

      await model.rescan().timeout(const Duration(seconds: 30));

      expect(model.status, 'added 1 new tracks');
      expect(model.allTracks, hasLength(2));
      expect(
        model.allTracks.any((t) => t.relPath == 'Artist - Launch Find.mp3'),
        isTrue,
        reason: 'the real launch wiring must have found and merged the file',
      );

      final onDisk = loadManifest(root);
      expect(onDisk.tracks, hasLength(2));
      expect(
        onDisk.tracks.values.any(
          (e) => e.paths.contains('Artist - Launch Find.mp3'),
        ),
        isTrue,
      );
    },
  );

  test('load() re-entrancy: a second load() that arrives while the first is '
      'still running is queued, not run concurrently, and still eventually '
      'reflects the latest requested roots', () async {
    final rootA = await Directory('${tmp.path}/rootA').create();
    // Unparseable bytes -> a cache miss -> Part B enrichment actually runs
    // for this track, giving onProgress a real callback to fire from.
    final idA1 = await _seedRoot(
      rootA,
      'A1.mp3',
      List<int>.filled(64, 1),
      '2020-01-01T00:00:00.000Z',
    );

    final rootB = await Directory('${tmp.path}/rootB').create();
    final idB1 = await _seedRoot(
      rootB,
      'B1.mp3',
      List<int>.filled(64, 2),
      '2021-01-01T00:00:00.000Z',
    );

    final cacheFile = File('${tmp.path}/meta_cache.json');
    final model = LibraryModel();

    Future<void>? overlapping;
    Set<String>? idsImmediatelyAfterOverlapCallReturns;
    final first = model.load(
      libraryRoots: [rootA],
      cacheFile: cacheFile,
      onProgress: (done, total) {
        // Fires mid-Part-B of the FIRST load, while `busy` is still held --
        // exactly the "settings reload arrives during initial enrichment"
        // scenario the re-entrancy guard exists for. Guard against firing
        // more than once (onProgress fires per completed batch).
        if (overlapping != null) return;
        overlapping = model.load(libraryRoots: [rootB], cacheFile: cacheFile);
        // Captured synchronously, in the very same callback, immediately
        // after the overlapping call above returns: this is what proves
        // the guard fires BEFORE the overlapping call touches any state,
        // rather than merely happening to resolve to the right answer
        // later by timing luck. Without the guard, load()'s Part A runs
        // fully synchronously (no `await` crossed) and would already have
        // overwritten allTracks with root B's track by this point.
        idsImmediatelyAfterOverlapCallReturns = model.allTracks
            .map((t) => t.contentId)
            .toSet();
      },
    );

    await first.timeout(const Duration(seconds: 30));
    await overlapping?.timeout(const Duration(seconds: 30));

    expect(
      overlapping,
      isNotNull,
      reason:
          'onProgress never fired -- the test setup did not actually '
          'exercise Part B enrichment',
    );
    expect(
      idsImmediatelyAfterOverlapCallReturns,
      {idA1},
      reason:
          'a second load() arriving while the first is still busy must '
          'be queued, not run concurrently -- allTracks must still be root '
          "A's data immediately after the (guarded) overlapping call "
          'returns, before the first load has released busy',
    );
    expect(model.busy, isFalse);

    // The LATEST request (rootB) eventually wins, once the first load
    // releases busy and the queued request is re-issued (see
    // LibraryModel.load's re-entrancy doc) -- not dropped, not corrupted by
    // running concurrently with the first.
    expect(model.allTracks, hasLength(1));
    expect(model.allTracks.single.contentId, idB1);
    expect(model.status, isNot(startsWith('error')));
  });
}
