// A rescan requested while the library is BUSY must not be thrown away.
//
// Reported live (2026-09-18): a LAN sync said files had been copied, but
// nothing appeared at the top of the library for ~10 minutes -- then it
// did, with no further action. SyncEngine.run() ends with
// `library.rescan(quiet: true)`, which is what surfaces freshly synced
// files; rescan() used to return immediately when another load/rescan held
// the busy flag, dropping that request entirely. Nothing retried it, so
// the tracks stayed invisible until Android's next five-minute tick
// happened to catch them.
//
// load() has queued-behind-the-busy-flag behaviour for exactly this reason
// (see its re-entrancy doc); rescan() was the odd one out.
//
// Last modified: 2026-09-18--1420
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('requeue'));
  tearDown(() async => tmp.delete(recursive: true));

  test('a rescan requested while busy runs once the in-flight pass finishes',
      () async {
    final root = await Directory('${tmp.path}/lib').create();
    final cacheFile = File('${tmp.path}/meta_cache.json');

    final existing = File('${root.path}/Existing Song.mp3');
    await existing.writeAsBytes(List<int>.filled(64, 0x11));
    final existingId = await contentIdForFile(existing);
    final manifest = Manifest.empty();
    manifest.tracks[existingId] = TrackEntry(
      dateAdded: '2020-01-01T00:00:00.000Z',
      paths: const ['Existing Song.mp3'],
    );
    await saveManifest(manifest, root);

    final model = LibraryModel();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));
    expect(model.allTracks, hasLength(1));

    // A new file lands on disk -- the manifest does NOT know it, so only a
    // scan can surface it. (On the phone this is a synced track whose
    // manifest adopt has not landed yet.)
    final arrived = File('${root.path}/Slowburn - I Want You So Bad.mp3');
    await arrived.writeAsBytes(List<int>.filled(200, 0x22));
    final arrivedId = await contentIdForFile(arrived);

    // Something else takes the busy flag first. load() sets it
    // synchronously, before its first await, so by the time this returns
    // the model is genuinely busy -- the same collision a five-minute tick
    // makes with the end of a sync.
    final inFlight = model.load(libraryRoots: [root], cacheFile: cacheFile);

    // ...and the sync's post-copy rescan arrives mid-pass.
    await model.rescan().timeout(const Duration(seconds: 30));
    await inFlight.timeout(const Duration(seconds: 30));

    expect(
      model.allTracks.map((t) => t.contentId),
      contains(arrivedId),
      reason: 'the queued rescan must still run -- not be dropped until the '
          'next periodic tick',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a queued rescan still completes when the queued load ahead of it '
      'throws', () async {
    // The drain runs a queued load() first, then the queued rescan. If that
    // load throws and takes the drain down with it, the rescan's completer
    // is never completed -- and SyncEngine.run(), which awaits it, would
    // hang with its report undelivered.
    final root = await Directory('${tmp.path}/lib2').create();
    final cacheFile = File('${tmp.path}/meta_cache2.json');
    final model = _ThrowingReissuedLoad();
    await model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));

    // The error handler is attached AT CREATION: the queued load's failure
    // is delivered on this future (pre-existing _runPendingLoad
    // behaviour), and several awaits happen before we get back to it --
    // an unhandled async error in between would fail the test for the
    // wrong reason.
    Object? inFlightError;
    final inFlight = model
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .catchError((Object e) => inFlightError = e);
    expect(model.busy, isTrue);
    // Queued behind the in-flight load; it is the RE-ISSUE of this one,
    // out of the drain, that throws.
    unawaited(model.load(libraryRoots: [root], cacheFile: cacheFile));
    model.failOnNextIdleLoad = true;

    await model.rescan().timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('the queued rescan was stranded by the failed '
          'load ahead of it'),
    );
    await inFlight.timeout(const Duration(seconds: 30));
    expect(model.threw, isTrue, reason: 'the failing path must have run');
    expect(inFlightError, isA<Exception>());
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// Throws from the queued `load()` the drain re-issues once the busy flag
/// is free -- the one ordering that can strand a queued rescan.
class _ThrowingReissuedLoad extends LibraryModel {
  bool failOnNextIdleLoad = false;
  bool threw = false;

  @override
  Future<void> load({
    required List<Directory> libraryRoots,
    required File cacheFile,
    void Function(int done, int total)? onProgress,
    Duration batchTimeout = const Duration(seconds: 30),
    Duration fileTimeout = const Duration(seconds: 10),
    String? libraryHome,
  }) async {
    if (failOnNextIdleLoad && !busy) {
      failOnNextIdleLoad = false;
      threw = true;
      throw Exception('simulated load failure');
    }
    return super.load(
      libraryRoots: libraryRoots,
      cacheFile: cacheFile,
      onProgress: onProgress,
      batchTimeout: batchTimeout,
      fileTimeout: fileTimeout,
      libraryHome: libraryHome,
    );
  }
}
