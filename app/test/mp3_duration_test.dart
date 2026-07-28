// Unit tests for the mp3_duration.dart fallback estimator: verified against
// synthetic frame headers covering CBR at a couple of bitrates, MPEG2/2.5
// rates, a Xing and a VBRI VBR header, garbage input, and an ID3v2-prefixed
// stream -- plus an integration-style check against 3 real files from
// `L:\music (original structure)\monthly\2009-05\Eminem - Relapse` (the
// exact fixture this feature was built against: ID3v2.3 tags with large
// embedded cover art that pushes well past the estimator's 64KB head
// window). The real-file group skips gracefully when that path isn't
// present (e.g. on a machine without the NAS mounted).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/mp3_duration.dart';
import 'package:path/path.dart' as p;

/// Builds a 4-byte MPEG audio frame header. `versionBits`: 0=MPEG2.5,
/// 2=MPEG2, 3=MPEG1. `layerBits`: 1=Layer III (the only layer these tests
/// exercise, matching every real file in this library).
List<int> _frameHeader({
  required int versionBits,
  required int layerBits,
  required int bitrateIndex,
  required int sampleRateIndex,
  int padding = 0,
  int channelModeBits = 0, // 0 = stereo
}) {
  final b1 =
      0xE0 |
      (versionBits << 3) |
      (layerBits << 1) |
      0x1; // protection bit set (no CRC)
  final b2 = (bitrateIndex << 4) | (sampleRateIndex << 2) | (padding << 1);
  final b3 = channelModeBits << 6;
  return [0xFF, b1, b2, b3];
}

/// Builds [frameCount] back-to-back CBR frames sharing one header, each
/// [frameLengthBytes] long (header + zero-filled payload) -- exactly what a
/// real constant-bitrate MP3 stream looks like at the byte level, minus the
/// actual audio content (irrelevant to a duration estimate).
Uint8List _cbrStream(List<int> header, int frameLengthBytes, int frameCount) {
  final out = BytesBuilder();
  for (var i = 0; i < frameCount; i++) {
    out.add(header);
    out.add(List.filled(frameLengthBytes - header.length, 0x00));
  }
  return out.toBytes();
}

Uint8List _id3v2(int payloadSize, {int fill = 0x00}) {
  final size = payloadSize;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, 0x00, // version 3.0, no flags (no footer)
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...List.filled(size, fill),
  ]);
}

void main() {
  group('estimateMp3Duration: CBR', () {
    test('MPEG1 Layer III, 128 kbps, 44.1 kHz', () {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      final bytes = _cbrStream(header, 417, 50); // 20850 bytes @ 128kbps
      final d = estimateMp3Duration(bytes);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 1303125);
    });

    test('MPEG1 Layer III, 320 kbps, 44.1 kHz', () {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 14,
        sampleRateIndex: 0,
      );
      final bytes = _cbrStream(header, 1044, 10); // 10440 bytes @ 320kbps
      final d = estimateMp3Duration(bytes);
      expect(d, isNotNull);
      // 10440 * 8 / 320000 = 0.261 s
      expect(d!.inMicroseconds, 261000);
    });

    test('MPEG2 Layer III, 64 kbps, 22.05 kHz', () {
      final header = _frameHeader(
        versionBits: 2,
        layerBits: 1,
        bitrateIndex: 8,
        sampleRateIndex: 0,
      );
      final bytes = _cbrStream(header, 417, 30); // 12510 bytes @ 64kbps
      final d = estimateMp3Duration(bytes);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 1563750);
    });

    test('MPEG2.5 Layer III, 24 kbps, 11.025 kHz', () {
      final header = _frameHeader(
        versionBits: 0,
        layerBits: 1,
        bitrateIndex: 3,
        sampleRateIndex: 0,
      );
      final bytes = _cbrStream(header, 313, 20); // 6260 bytes @ 24kbps
      final d = estimateMp3Duration(bytes);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 2086667);
    });
  });

  group('estimateMp3Duration: VBR headers', () {
    test(
      'Xing header (frame-count flag set) drives duration, not file size',
      () {
        // Header frame: MPEG1 stereo Layer III 128kbps/44100 -> Xing offset 36
        // (4-byte header + 32-byte stereo side info).
        final header = _frameHeader(
          versionBits: 3,
          layerBits: 1,
          bitrateIndex: 9,
          sampleRateIndex: 0,
        );
        const frameCount = 5000;
        final out = BytesBuilder();
        out.add(header);
        out.add(
          List.filled(32, 0x00),
        ); // side info padding up to the Xing offset
        out.add('Xing'.codeUnits);
        out.add([0x00, 0x00, 0x00, 0x01]); // flags: frame-count field present
        out.add([
          (frameCount >> 24) & 0xFF,
          (frameCount >> 16) & 0xFF,
          (frameCount >> 8) & 0xFF,
          frameCount & 0xFF,
        ]);
        // The header frame itself is only ~40 bytes here (well short of its
        // real 417-byte frame length) -- fine, since there's no next frame in
        // this buffer for the corroboration check to look at.
        final d = estimateMp3Duration(out.toBytes());
        expect(d, isNotNull);
        // 5000 frames * 1152 samples/frame / 44100 Hz.
        expect(d!.inMicroseconds, 130612245);
      },
    );

    test(
      'Info header (LAME CBR-with-VBR-header variant) is read the same as Xing',
      () {
        final header = _frameHeader(
          versionBits: 3,
          layerBits: 1,
          bitrateIndex: 9,
          sampleRateIndex: 0,
        );
        const frameCount = 1000;
        final out = BytesBuilder();
        out.add(header);
        out.add(List.filled(32, 0x00));
        out.add('Info'.codeUnits);
        out.add([0x00, 0x00, 0x00, 0x01]);
        out.add([
          (frameCount >> 24) & 0xFF,
          (frameCount >> 16) & 0xFF,
          (frameCount >> 8) & 0xFF,
          frameCount & 0xFF,
        ]);
        final d = estimateMp3Duration(out.toBytes());
        expect(d, isNotNull);
        // 1000 frames * 1152 samples/frame / 44100 Hz = 26.122448979... s,
        // rounded (not floored) to the nearest microsecond by the estimator.
        expect(d!.inMicroseconds, 26122449);
      },
    );

    test('VBRI header (fixed offset 36, no flags gate) drives duration', () {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      const frameCount = 6000;
      final out = BytesBuilder();
      out.add(header); // 4 bytes
      out.add(List.filled(32, 0x00)); // pad to offset 36
      out.add('VBRI'.codeUnits); // offset 36
      out.add([0x00, 0x01]); // version
      out.add([0x00, 0x00]); // delay
      out.add([0x00, 0x64]); // quality
      out.add([
        0x00,
        0x00,
        0x00,
        0x00,
      ]); // total bytes (unused by the estimator)
      out.add([
        (frameCount >> 24) & 0xFF,
        (frameCount >> 16) & 0xFF,
        (frameCount >> 8) & 0xFF,
        frameCount & 0xFF,
      ]); // offset 46: total frames
      final d = estimateMp3Duration(out.toBytes());
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 156734694);
    });

    test(
      'Xing header with the frame-count flag unset falls back to CBR math',
      () {
        final header = _frameHeader(
          versionBits: 3,
          layerBits: 1,
          bitrateIndex: 9,
          sampleRateIndex: 0,
        );
        // Two full 417-byte CBR frames, first one carrying a Xing tag whose
        // flags claim NO frame-count field -- must be ignored, not read as 0.
        final out = BytesBuilder();
        out.add(header);
        out.add(List.filled(32, 0x00));
        out.add('Xing'.codeUnits);
        out.add([0x00, 0x00, 0x00, 0x00]); // flags: nothing present
        out.add(List.filled(417 - 4 - 32 - 8, 0x00));
        out.add(header);
        out.add(List.filled(417 - 4, 0x00));
        final d = estimateMp3Duration(out.toBytes());
        expect(d, isNotNull);
        // 2 frames * 417 bytes * 8 / 128000 bps.
        expect(d!.inMicroseconds, (2 * 417 * 8 * 1000000) ~/ 128000);
      },
    );
  });

  group('estimateMp3Duration: robustness', () {
    test('garbage input (no frame sync anywhere) yields null, not a throw', () {
      final bytes = Uint8List.fromList(List.filled(500, 0x00));
      expect(estimateMp3Duration(bytes), isNull);
    });

    test(
      'random-looking bytes with stray 0xFF but no valid header yield null',
      () {
        final bytes = Uint8List.fromList(
          List.generate(500, (i) => i.isEven ? 0xFF : 0x00),
        ); // 0xFF,0x00 alternating: never (b1&0xE0)==0xE0
        expect(estimateMp3Duration(bytes), isNull);
      },
    );

    test('too short to contain a header yields null', () {
      expect(estimateMp3Duration(Uint8List.fromList([0xFF, 0xFB])), isNull);
    });

    test('empty input yields null', () {
      expect(estimateMp3Duration(Uint8List(0)), isNull);
    });

    test('ID3v2-prefixed stream: the tag is skipped and the trailing CBR '
        'audio is measured correctly', () {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      final audio = _cbrStream(
        header,
        417,
        50,
      ); // matches the plain CBR case above
      final withTag = Uint8List.fromList([
        ..._id3v2(300, fill: 0xAA),
        ...audio,
      ]);
      final d = estimateMp3Duration(withTag);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 1303125);
    });

    test('ID3v2 tag whose payload is all 0xFF bytes (worst case for a naive '
        'sync scan) is still skipped correctly, not mistaken for audio', () {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      final audio = _cbrStream(header, 417, 10);
      final withTag = Uint8List.fromList([
        ..._id3v2(2000, fill: 0xFF),
        ...audio,
      ]);
      final d = estimateMp3Duration(withTag);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, (10 * 417 * 8 * 1000000) ~/ 128000);
    });
  });

  group('estimateMp3DurationForFile', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('mp3dur'));
    tearDown(() async => tmp.delete(recursive: true));

    test('small file (fits in one read): ID3v2 tag + CBR audio', () async {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      final audio = _cbrStream(header, 417, 50);
      final bytes = Uint8List.fromList([..._id3v2(500, fill: 0xAA), ...audio]);
      final f = File(p.join(tmp.path, 'small.mp3'));
      await f.writeAsBytes(bytes);

      final d = await estimateMp3DurationForFile(f);
      expect(d, isNotNull);
      expect(d!.inMicroseconds, 1303125);
    });

    test('ID3v2 tag bigger than the 64KB head window (large embedded cover '
        'art, matching the real Eminem - Relapse fixture) still resolves '
        'via the follow-up read', () async {
      final header = _frameHeader(
        versionBits: 3,
        layerBits: 1,
        bitrateIndex: 9,
        sampleRateIndex: 0,
      );
      final audio = _cbrStream(header, 417, 200); // 83400 bytes @ 128kbps
      // 100000-byte tag payload, deliberately filled with 0xFF so a naive
      // scan across the whole file would trip over "frame syncs" throughout
      // the tag if the ID3v2 skip weren't correctly bypassing it.
      final bytes = Uint8List.fromList([
        ..._id3v2(100000, fill: 0xFF),
        ...audio,
      ]);
      expect(bytes.length, greaterThan(65536));
      final f = File(p.join(tmp.path, 'big_tag.mp3'));
      await f.writeAsBytes(bytes);

      final d = await estimateMp3DurationForFile(f);
      expect(d, isNotNull);
      // 200 * 417 * 8 / 128000
      expect(d!.inMicroseconds, (200 * 417 * 8 * 1000000) ~/ 128000);
    });

    test(
      'a Xing VBR header is still found after a large leading tag',
      () async {
        final header = _frameHeader(
          versionBits: 3,
          layerBits: 1,
          bitrateIndex: 9,
          sampleRateIndex: 0,
        );
        const frameCount = 3430; // same as the real "Dr. West (Skit)" fixture
        final frame = BytesBuilder();
        frame.add(header);
        frame.add(List.filled(32, 0x00));
        frame.add('Xing'.codeUnits);
        frame.add([0x00, 0x00, 0x00, 0x01]);
        frame.add([
          (frameCount >> 24) & 0xFF,
          (frameCount >> 16) & 0xFF,
          (frameCount >> 8) & 0xFF,
          frameCount & 0xFF,
        ]);
        final bytes = Uint8List.fromList([
          ..._id3v2(100000, fill: 0xFF),
          ...frame.toBytes(),
        ]);
        final f = File(p.join(tmp.path, 'big_tag_xing.mp3'));
        await f.writeAsBytes(bytes);

        final d = await estimateMp3DurationForFile(f);
        expect(d, isNotNull);
        expect(
          d!.inMicroseconds,
          89600000,
        ); // matches the real file's own duration
      },
    );

    test('garbage file yields null, not a throw', () async {
      final f = File(p.join(tmp.path, 'garbage.mp3'));
      await f.writeAsBytes(List.filled(200, 0x00));
      expect(await estimateMp3DurationForFile(f), isNull);
    });

    test('too-short file yields null', () async {
      final f = File(p.join(tmp.path, 'tiny.mp3'));
      await f.writeAsBytes([0xFF, 0xFB]);
      expect(await estimateMp3DurationForFile(f), isNull);
    });

    test('nonexistent file yields null, not a throw', () async {
      final f = File(p.join(tmp.path, 'does_not_exist.mp3'));
      expect(await estimateMp3DurationForFile(f), isNull);
    });
  });

  group('real files (read-only fixture: Eminem - Relapse)', () {
    // Skips gracefully on a machine without this NAS path mounted.
    const relapseDir =
        r'L:\music (original structure)\monthly\2009-05\Eminem - Relapse';
    const cases = [
      '01-eminem-dr._west_(skit)_(produced_by_dr._dre_and_eminem).mp3',
      '06-eminem-hello_(produced_by_dr._dre_and_mark_batson).mp3',
      '16-eminem-deja_vu_(produced_by_dr._dre).mp3',
    ];

    for (final name in cases) {
      test('estimates a plausible duration for $name', () async {
        final f = File(p.join(relapseDir, name));
        if (!f.existsSync()) {
          markTestSkipped('fixture not present on this machine: $relapseDir');
          return;
        }
        final d = await estimateMp3DurationForFile(f);
        expect(
          d,
          isNotNull,
          reason: 'expected a computable duration for $name',
        );
        expect(
          d!.inSeconds,
          greaterThan(60),
          reason: 'implausibly short for a real album track: $d',
        );
        expect(
          d.inSeconds,
          lessThan(12 * 60),
          reason: 'implausibly long for a real album track: $d',
        );
        // ignore: avoid_print
        print(
          '$name -> ${d.inMilliseconds}ms '
          '(${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')})',
        );
      });
    }
  });
}
