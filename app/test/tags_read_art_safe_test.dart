// Regression test for the readArt-hard-freezes-the-UI defect: AlbumArt's
// default loader used to call readArt directly on the UI isolate. readArt
// is `async` in name only -- there's no `await` before its call into the
// synchronous `_readRawTags(fetchImage: true)` parse, which (like the
// tag-enrichment side of this same bug, pinned in
// library_model_enrichment_resilience_test.dart) can scan byte-by-byte to
// EOF over SMB on a file that defeats the MP3 frame-sync search. That froze
// the whole window ("Not Responding") for as long as the scan took.
//
// readArtSafe fixes this by running the parse inside its own kill-capable,
// timeout-bounded isolate (metadata/isolate_io.dart's
// runIsolateWithTimeout) instead of directly on the caller's isolate. The
// key guarantee under test: a pathological file makes readArtSafe return
// null within its timeout budget, not hang.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';

import 'support/pathological_mp3.dart';

void main() {
  test(
      'readArtSafe: a synthetic pathological MP3 (the exact shape that '
      "defeats the third-party parser's unbounded frame-sync scan) "
      'resolves to null within a short timeout instead of hanging',
      () async {
    final tmp = await Directory.systemTemp.createTemp('art_safe_pathological');
    addTearDown(() => tmp.delete(recursive: true));
    final f = File('${tmp.path}/Artist - Weird Encode.mp3');
    await f.writeAsBytes(buildMp3WithNoFrameSync(title: 'Weird Encode'));

    // A short (2s) timeout with a wall-clock assertion budget just above it
    // (3s): this file has no embedded picture (only a TIT2 title frame),
    // so the correct result is null either way -- what this test actually
    // pins is that readArtSafe returns promptly through the full
    // isolate-spawn-parse-return pipeline instead of ever blocking the
    // calling isolate, which is the whole point of the fix.
    final art = await readArtSafe(f, timeout: const Duration(seconds: 2))
        .timeout(const Duration(seconds: 3));

    expect(art, isNull);
  });

  test('readArtSafe returns null (not a thrown error) for a nonexistent file',
      () async {
    final f = File(
        '${Directory.systemTemp.path}/fooplayer_readArtSafe_missing_${DateTime.now().microsecondsSinceEpoch}.mp3');
    expect(f.existsSync(), isFalse);

    final art = await readArtSafe(f, timeout: const Duration(seconds: 2))
        .timeout(const Duration(seconds: 3));

    expect(art, isNull);
  });

  test('readArtSafe returns null for an unparseable (garbage-bytes) file',
      () async {
    final tmp = await Directory.systemTemp.createTemp('art_safe_garbage');
    addTearDown(() => tmp.delete(recursive: true));
    final f = File('${tmp.path}/x.mp3');
    await f.writeAsBytes(List.filled(16, 0x01));

    final art = await readArtSafe(f, timeout: const Duration(seconds: 2))
        .timeout(const Duration(seconds: 3));

    expect(art, isNull);
  });
}
