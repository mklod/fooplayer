// Regression test for the commit-677d850 defect: background tag
// enrichment (LibraryModel.load's Part B) froze forever at a batch
// boundary ("reading tags 600/10604") with no error, and the tag cache was
// never saved.
//
// Root cause: `audio_metadata_reader`'s MP3Parser looks for the first
// MPEG frame sync after the ID3v2 tag by scanning one byte at a time
// (`_findFirstMp3Frame`) with no upper bound. For a file whose audio data
// never contains a byte sequence matching a valid frame sync, that scan
// runs to EOF. On local disk this is fast; over the SMB-mounted library
// share, each 16KB crossed by the scan is a network round trip, so a
// single such file can block `Isolate.run`'s Future for minutes -- and
// since nothing timed that out, `LibraryModel.load`'s
// `await Isolate.run(...)` (and therefore the whole enrichment pipeline,
// including the final cache save) simply never returned.
//
// The two tests below pin, without depending on real network latency
// (which can't be reproduced deterministically in a fast unit test):
//   1. the exact file shape that defeats the third-party frame-sync scan
//      (parses fine locally -- proving the scan itself never throws, only
//      runs unboundedly slowly over a slow transport), and
//   2. that LibraryModel.load's timeout/fallback machinery -- exercised
//      here via an artificially tiny timeout rather than a slow file, so
//      the test is fast and deterministic -- guarantees forward progress:
//      it always reaches 'ready' with filename-derived fallback tags
//      rather than hanging or reporting 'error: ...'.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';
import 'package:fooplayer_app/model/library_model.dart';

/// Builds a minimal ID3v2.3 MP3 file with a single TIT2 (title) frame,
/// followed by [payloadSize] zero bytes standing in for audio data that
/// never contains a valid MPEG frame sync (a real sync always starts with
/// byte 0xFF, which zero bytes never do) -- the same shape as the real
/// file that triggered the freeze.
Uint8List _buildMp3WithNoFrameSync({
  required String title,
  int payloadSize = 5000,
}) {
  final titleBytes = latin1.encode(title);
  final content = Uint8List(1 + titleBytes.length)
    ..[0] = 0x00 // ISO-8859-1 encoding
    ..setRange(1, 1 + titleBytes.length, titleBytes);

  final frameHeader = Uint8List(10);
  frameHeader.setRange(0, 4, ascii.encode('TIT2'));
  // Frame content size, big-endian (ID3v2.3 frame sizes are not syncsafe).
  frameHeader[4] = (content.length >> 24) & 0xFF;
  frameHeader[5] = (content.length >> 16) & 0xFF;
  frameHeader[6] = (content.length >> 8) & 0xFF;
  frameHeader[7] = content.length & 0xFF;
  // flags[8..9] left as 0.

  final tagBody = Uint8List.fromList([...frameHeader, ...content]);

  final header = Uint8List(10);
  header.setRange(0, 3, ascii.encode('ID3'));
  header[3] = 3; // major version 2.3
  header[4] = 0; // revision
  header[5] = 0; // flags
  // Syncsafe 28-bit tag body size across header[6..9].
  final size = tagBody.length;
  header[6] = (size >> 21) & 0x7F;
  header[7] = (size >> 14) & 0x7F;
  header[8] = (size >> 7) & 0x7F;
  header[9] = size & 0x7F;

  final payload = Uint8List(payloadSize); // all zero: never 0xFF-prefixed
  return Uint8List.fromList([...header, ...tagBody, ...payload]);
}

void main() {
  test(
      'readTags: ID3v2 tag parses even when the audio data has no MPEG '
      'frame sync anywhere (the exact shape that defeats the third-party '
      "parser's unbounded byte-by-byte scan)", () async {
    final tmp = await Directory.systemTemp.createTemp('no_frame_sync');
    addTearDown(() => tmp.delete(recursive: true));
    // The filename-derived title ("Placeholder Name") deliberately differs
    // from the embedded ID3 title ("Real Tagged Title") so this test can
    // only pass if the embedded tag was genuinely parsed -- if tag parsing
    // silently failed and fell back to the filename (e.g. because
    // _readRawTags threw and readTags's catch(_) masked it), the title
    // would come back "Placeholder Name" instead and the assertion below
    // would catch that.
    final f = File('${tmp.path}/Artist - Placeholder Name.mp3');
    await f.writeAsBytes(_buildMp3WithNoFrameSync(title: 'Real Tagged Title'));

    // Must complete promptly on local disk: this documents that the parse
    // itself never throws and never hangs computationally -- the real
    // freeze is purely a function of per-byte network latency, which
    // load()'s timeout (tested below) is what actually guards against.
    final tags = await readTags(f).timeout(const Duration(seconds: 5));

    expect(tags.title, 'Real Tagged Title');
    expect(tags.title, isNot('Placeholder Name'));
  });

  test(
      'LibraryModel.load: a batch that blows its timeout budget falls back '
      'to filename-derived tags for every record instead of hanging or '
      'reporting an error', () async {
    final tmp = await Directory.systemTemp.createTemp('enrich_resilience');
    addTearDown(() => tmp.delete(recursive: true));
    final libRoot = await Directory('${tmp.path}/lib').create();

    // Deliberately not creating these files on disk: this test's only
    // concern is the timeout/fallback machinery itself (the exact file
    // shape that provokes the real slow scan is pinned separately, above).
    // Because Isolate.kill(priority: immediate) tears an isolate down
    // without running its Dart-level `finally` blocks, an isolate killed
    // mid-open would leave its file handle to close only whenever the VM
    // later collects it -- harmless for a real read-only library file, but
    // it would make this test's own temp-dir cleanup flaky on Windows.
    // Nonexistent paths exercise the identical timeout -> per-file-retry ->
    // fallback path (readTagsBatch falls back to parseFromFilename for any
    // missing file) without ever opening a file at all.
    final manifest = File('${libRoot.path}/.library.json');
    await manifest.writeAsString(jsonEncode({
      'schema': 1,
      'tracks': {
        'id-1': {
          'paths': ['Artist - Weird Encode.mp3'],
          'date_added': '2024-01-01T00:00:00Z',
        },
        'id-2': {
          'paths': ['Artist - Normal Song.mp3'],
          'date_added': '2024-01-02T00:00:00Z',
        },
      },
      'playlists': [],
    }));

    final cacheFile = File('${tmp.path}/meta_cache.json');
    final model = LibraryModel();

    // An artificially tiny budget forces every batch (and then every
    // per-file retry) to hit its timeout deterministically -- exercising
    // the same batch-timeout -> per-file-retry -> fallback path a real
    // pathologically slow file forces in production, without depending on
    // real file I/O or network latency.
    await model
        .load(
          libraryRoots: [libRoot],
          cacheFile: cacheFile,
          batchTimeout: const Duration(microseconds: 1),
          fileTimeout: const Duration(microseconds: 1),
        )
        .timeout(const Duration(seconds: 30));

    // The key guarantee under test: load() reaches 'ready' at all. Before
    // this fix, nothing bounded a stuck batch, so an equivalent real-world
    // case (see the shape pinned above) simply never got here.
    expect(model.status, 'ready');
    expect(model.allTracks, hasLength(2));
    final weird =
        model.allTracks.firstWhere((t) => t.contentId == 'id-1');
    expect(weird.artist, 'Artist');
    expect(weird.title, 'Weird Encode');
    final normalTrack =
        model.allTracks.firstWhere((t) => t.contentId == 'id-2');
    expect(normalTrack.artist, 'Artist');
    expect(normalTrack.title, 'Normal Song');

    // The cache was still written (final save always runs), so a restart
    // doesn't repeat this scan from scratch.
    expect(cacheFile.existsSync(), isTrue);
  });

  test(
      'LibraryModel.load: the merged cache is flushed to disk before '
      'enrichment finishes, not only at the very end', () async {
    final tmp = await Directory.systemTemp.createTemp('enrich_incremental');
    addTearDown(() => tmp.delete(recursive: true));
    final libRoot = await Directory('${tmp.path}/lib').create();
    final manifest = File('${libRoot.path}/.library.json');

    // 1200 tracks (6 enrichment batches of 200) pointing at files that
    // don't exist on disk, so each resolves via the cheap
    // parseFromFilename fallback with no real I/O -- keeping this test
    // fast while still driving enough batches to observe a mid-run save.
    final tracks = <String, Object?>{};
    for (var i = 0; i < 1200; i++) {
      tracks['id-$i'] = {
        'paths': ['Artist $i - Song $i.mp3'],
        'date_added': '2024-01-01T00:00:00Z',
      };
    }
    await manifest.writeAsString(
        jsonEncode({'schema': 1, 'tracks': tracks, 'playlists': []}));

    final cacheFile = File('${tmp.path}/meta_cache.json');
    var sawMidRunSave = false;
    final model = LibraryModel();

    await model
        .load(
          libraryRoots: [libRoot],
          cacheFile: cacheFile,
          onProgress: (done, total) {
            // Fires once per completed batch. By the time the 6th (final)
            // batch's progress callback runs, the save-every-5-batches
            // flush after batch 5 must already have happened -- before
            // load()'s own unconditional final save.
            if (done == 1200 && cacheFile.existsSync()) {
              final saved = jsonDecode(cacheFile.readAsStringSync()) as Map;
              if (saved.length == 1000) {
                sawMidRunSave = true;
              }
            }
          },
        )
        .timeout(const Duration(seconds: 30));

    expect(model.status, 'ready');
    expect(sawMidRunSave, isTrue,
        reason:
            'expected a 1000-entry cache on disk (5 batches x 200) before '
            'the 6th batch finished, proving the cache saves incrementally');
    final finalSaved = jsonDecode(cacheFile.readAsStringSync()) as Map;
    expect(finalSaved, hasLength(1200));
  });
}
