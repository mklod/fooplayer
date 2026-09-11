// Regression: the last thing load() does must be to NOTIFY that it is no
// longer busy.
//
// main.dart mirrors library.busy into the activity strip, and it can only
// react to notifications it actually receives:
//
//   library.addListener(() {
//     if (!library.busy) { activity.finish(ActivityIds.library); return; }
//     ... else show "Loading library" / "Scanning ..." ...
//   });
//
// load() used to clear `_busy` in a finally WITHOUT notifying (rescan and
// the seed path both notify). The final notification therefore still said
// busy=true, so the strip kept showing "Loading library" forever -- on the
// phone and the desktop alike. Reported live: "it's just running like
// forever... feels like the app is never really going to load."
//
// Last modified: 2026-09-10--1810
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_core/fooplayer_core.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('busy'));
  tearDown(() async => tmp.delete(recursive: true));

  test('load() ends with a notification saying it is no longer busy',
      () async {
    final root = await Directory('${tmp.path}/lib').create();
    final f = File('${root.path}/Song.mp3');
    await f.writeAsBytes(List<int>.filled(64, 7));
    final id = await contentIdForFile(f);

    final manifest = Manifest.empty();
    manifest.tracks[id] = TrackEntry(
      dateAdded: '2024-01-01T00:00:00.000Z',
      paths: const ['Song.mp3'],
    );
    await saveManifest(manifest, root);

    final model = LibraryModel();
    // Exactly what main.dart's activity mirror observes.
    final busyAtEachNotification = <bool>[];
    model.addListener(() => busyAtEachNotification.add(model.busy));

    await model
        .load(
          libraryRoots: [root],
          cacheFile: File('${tmp.path}/meta_cache.json'),
        )
        .timeout(const Duration(seconds: 30));

    expect(model.busy, isFalse, reason: 'load finished');
    expect(
      busyAtEachNotification.last,
      isFalse,
      reason: 'the FINAL notification must report busy=false, or the '
          'activity strip never clears "Loading library"',
    );
  });
}
