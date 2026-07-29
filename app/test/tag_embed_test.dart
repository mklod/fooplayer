// Cover-art embedding: the identity invariant above all else.
//
// Every test here ultimately asks one question -- did the CONTENT ID change?
// -- because a changed ID means the track looks like a brand-new file to the
// manifest and silently loses the "date downloaded" this whole project
// exists to protect. The ID is computed with fooplayer_core's real hashing,
// not a local re-implementation, so these tests fail if the core's audio
// range logic ever drifts away from what the embedder assumes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;

/// A believable MPEG frame: sync, then filler. Content is irrelevant -- what
/// matters is that these bytes survive untouched.
Uint8List _audio([int n = 4096]) {
  final b = Uint8List(n);
  b[0] = 0xFF;
  b[1] = 0xFB; // MPEG-1 Layer III
  b[2] = 0x90;
  b[3] = 0x00;
  for (var i = 4; i < n; i++) {
    b[i] = i % 251;
  }
  return b;
}

Uint8List _jpeg([int n = 512]) {
  final b = Uint8List(n);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  for (var i = 3; i < n; i++) {
    b[i] = (i * 7) % 253;
  }
  return b;
}

Uint8List _png() => Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
]);

/// A text frame body: encoding byte + latin1 text.
Uint8List _text(String s) => Uint8List.fromList([0x00, ...latin1.encode(s)]);

void _writeSyncsafe(List<int> out, int v) =>
    out.addAll([(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f]);

/// Builds a file with an ID3v2 tag of the given [major] version carrying
/// [frames], followed by [audio].
Uint8List _fileWithTag({
  required int major,
  required List<(String, Uint8List)> frames,
  required Uint8List audio,
  int padding = 0,
}) {
  final body = <int>[];
  for (final (id, data) in frames) {
    if (major == 2) {
      body.addAll(latin1.encode(id.substring(0, 3)));
      body.addAll([
        (data.length >> 16) & 0xff,
        (data.length >> 8) & 0xff,
        data.length & 0xff,
      ]);
    } else {
      body.addAll(latin1.encode(id.padRight(4).substring(0, 4)));
      if (major == 4) {
        _writeSyncsafe(body, data.length);
      } else {
        body.addAll([
          (data.length >> 24) & 0xff,
          (data.length >> 16) & 0xff,
          (data.length >> 8) & 0xff,
          data.length & 0xff,
        ]);
      }
      body.addAll([0, 0]);
    }
    body.addAll(data);
  }
  body.addAll(List<int>.filled(padding, 0));
  final out = <int>[0x49, 0x44, 0x33, major, 0x00, 0x00];
  _writeSyncsafe(out, body.length);
  out.addAll(body);
  out.addAll(audio);
  return Uint8List.fromList(out);
}

void main() {
  group('content ID survives embedding', () {
    test('file with no tag at all gains a cover, keeps its identity', () {
      final audio = _audio();
      final before = Uint8List.fromList(audio);
      final after = buildTaggedMp3(before, _jpeg());

      expect(
        contentIdForBytes('x.mp3', after),
        contentIdForBytes('x.mp3', before),
      );
      expect(audioBytesUnchanged(before, after), isTrue);
      expect(after.length, greaterThan(before.length));
      expect(parseId3(after).major, 3, reason: 'fresh tags are written v2.3');
    });

    test('v2.3 tag without art: existing frames are preserved verbatim', () {
      final before = _fileWithTag(
        major: 3,
        frames: [
          ('TIT2', _text('Sorry, Blame It on Me')),
          ('TPE1', _text('Akon')),
          ('TALB', _text('2007-08')),
        ],
        audio: _audio(),
      );
      final after = buildTaggedMp3(before, _jpeg());

      expect(
        contentIdForBytes('a.mp3', after),
        contentIdForBytes('a.mp3', before),
      );
      final frames = {for (final f in parseId3(after).frames) f.id: f.data};
      expect(
        latin1.decode(frames['TIT2']!.sublist(1)),
        'Sorry, Blame It on Me',
      );
      expect(latin1.decode(frames['TPE1']!.sublist(1)), 'Akon');
      expect(latin1.decode(frames['TALB']!.sublist(1)), '2007-08');
      expect(frames.containsKey('APIC'), isTrue);
    });

    test('v2.3 tag that already has art: the old picture is replaced, not '
        'duplicated', () {
      final oldArt = buildApicBody(_jpeg(2048), 'image/jpeg');
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Le missile est lance')), ('APIC', oldArt)],
        audio: _audio(),
      );

      final newArt = _png();
      final after = buildTaggedMp3(before, newArt);

      expect(
        contentIdForBytes('k.mp3', after),
        contentIdForBytes('k.mp3', before),
      );
      final apics = parseId3(
        after,
      ).frames.where((f) => f.id == 'APIC').toList();
      expect(apics, hasLength(1), reason: 'exactly one cover, never two');
      expect(
        apics.single.data.length,
        lessThan(oldArt.length),
        reason: 'the new (smaller) picture replaced the old one',
      );
      // MIME is rewritten to match the new bytes, not inherited.
      expect(latin1.decode(apics.single.data.sublist(1, 10)), 'image/png');
    });

    test('v2.4 stays v2.4 (syncsafe frame sizes), v2.2 upgrades to v2.3', () {
      final v24 = _fileWithTag(
        major: 4,
        frames: [('TIT2', _text('Four'))],
        audio: _audio(),
      );
      final outV24 = buildTaggedMp3(v24, _jpeg());
      expect(parseId3(outV24).major, 4);
      expect(
        contentIdForBytes('v.mp3', outV24),
        contentIdForBytes('v.mp3', v24),
      );
      final f24 = {for (final f in parseId3(outV24).frames) f.id: f.data};
      expect(latin1.decode(f24['TIT2']!.sublist(1)), 'Four');

      final v22 = _fileWithTag(
        major: 2,
        frames: [('TT2', _text('Comfortable')), ('TP1', _text('Lil Wayne'))],
        audio: _audio(),
      );
      final outV22 = buildTaggedMp3(v22, _jpeg());
      expect(parseId3(outV22).major, 3);
      expect(
        contentIdForBytes('w.mp3', outV22),
        contentIdForBytes('w.mp3', v22),
      );
      final f22 = {for (final f in parseId3(outV22).frames) f.id: f.data};
      expect(
        latin1.decode(f22['TIT2']!.sublist(1)),
        'Comfortable',
        reason: 'TT2 -> TIT2',
      );
      expect(
        latin1.decode(f22['TPE1']!.sublist(1)),
        'Lil Wayne',
        reason: 'TP1 -> TPE1',
      );
    });

    test('a trailing ID3v1 block is carried through untouched', () {
      // ID3v1 sits in the last 128 bytes and is EXCLUDED from the hashed
      // range, so it must survive the rewrite or other tools lose data.
      final v1 = Uint8List(128);
      v1[0] = 0x54; // 'T'
      v1[1] = 0x41; // 'A'
      v1[2] = 0x47; // 'G'
      for (var i = 3; i < 128; i++) {
        v1[i] = i;
      }
      final before = Uint8List.fromList([..._audio(), ...v1]);
      final after = buildTaggedMp3(before, _jpeg());

      expect(
        contentIdForBytes('t.mp3', after),
        contentIdForBytes('t.mp3', before),
      );
      expect(after.sublist(after.length - 128), v1);
    });

    test('embedding twice is idempotent in identity and cover count', () {
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Twice'))],
        audio: _audio(),
      );
      final once = buildTaggedMp3(before, _jpeg());
      final twice = buildTaggedMp3(once, _jpeg(600));

      expect(
        contentIdForBytes('i.mp3', twice),
        contentIdForBytes('i.mp3', before),
      );
      expect(parseId3(twice).frames.where((f) => f.id == 'APIC'), hasLength(1));
    });
  });

  group('junk between the tag and the first frame', () {
    // 28 files in Mike's library (the Passafire album, the Streets EP, three
    // Gym Class Heroes singles, a few others) put 42-1,035 bytes of neither
    // audio nor zero padding after their tag's declared end. Players resync
    // past it; the embedder used to stop at the first non-zero byte and
    // refuse the file, which is 20 of the "not MPEG" skips in the pass.
    test('a real tag followed by junk then audio embeds, identity intact', () {
      final junk = Uint8List.fromList([
        for (var i = 0; i < 626; i++) (i % 251) + 1, // never zero
      ]);
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Divide'))],
        audio: Uint8List.fromList([...junk, ..._audio()]),
      );

      final after = buildTaggedMp3(before, _jpeg());
      expect(
        contentIdForBytes('x.mp3', after),
        contentIdForBytes('x.mp3', before),
        reason: 'the junk is inside the hashed range and must survive',
      );
      expect(audioBytesUnchanged(before, after), isTrue);
      expect(parseId3(after).frames.where((f) => f.id == 'APIC'), hasLength(1));
    });

    test('junk carrying a bare sync but no decodable header is refused', () {
      // 0xFF 0xE0 matches the eleven sync bits, but its version/layer/bitrate
      // fields are all reserved -- no decoder would accept it. Scanning
      // forward on that alone would eventually "find" audio in any container.
      final junk = Uint8List.fromList([
        for (var i = 0; i < 40; i++) 0x41,
        0xFF, 0xE0, 0x00, 0x00,
        for (var i = 0; i < 40; i++) 0x41,
      ]);
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Not audio'))],
        audio: junk,
      );

      expect(
        () => buildTaggedMp3(before, _jpeg()),
        throwsA(
          isA<EmbedException>().having(
            (e) => e.refusal,
            'refusal',
            EmbedRefusal.notMpeg,
          ),
        ),
      );
    });

    test('a file with NO leading tag gets no junk tolerance at all', () {
      // The gate that keeps the sheep pathology refused: without a tag of its
      // own, "a frame header turns up a few hundred bytes in" is a
      // coincidence, and prepending a tag would corrupt whatever this is.
      final before = Uint8List.fromList([
        ...latin1.encode('....ftypisom'),
        for (var i = 0; i < 200; i++) 0x41,
        ..._audio(),
      ]);

      expect(
        () => buildTaggedMp3(before, _jpeg()),
        throwsA(
          isA<EmbedException>().having(
            (e) => e.refusal,
            'refusal',
            EmbedRefusal.notMpeg,
          ),
        ),
      );
    });

    test('junk longer than the window is refused', () {
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Miles of junk'))],
        audio: Uint8List.fromList([
          for (var i = 0; i < kJunkGapWindow + 64; i++) (i % 251) + 1,
          ..._audio(),
        ]),
      );

      expect(
        () => buildTaggedMp3(before, _jpeg()),
        throwsA(isA<EmbedException>()),
      );
    });

    test('looksLikeMpegFrameHeader rejects every reserved field', () {
      Uint8List h(int b1, int b2) => Uint8List.fromList([0xFF, b1, b2, 0x00]);
      expect(looksLikeMpegFrameHeader(h(0xFB, 0x90), 0), isTrue);
      expect(
        looksLikeMpegFrameHeader(h(0xEB, 0x90), 0),
        isFalse,
        reason: 'reserved MPEG version',
      );
      expect(
        looksLikeMpegFrameHeader(h(0xF9, 0x90), 0),
        isFalse,
        reason: 'reserved layer',
      );
      expect(
        looksLikeMpegFrameHeader(h(0xFB, 0xF0), 0),
        isFalse,
        reason: 'bad bitrate index',
      );
      expect(
        looksLikeMpegFrameHeader(h(0xFB, 0x9C), 0),
        isFalse,
        reason: 'reserved sample rate',
      );
    });
  });

  group('refusals -- a file we cannot prove safe is left alone', () {
    test('MP4 wearing an .mp3 name is refused (the sheep pathology)', () {
      // ID3 tag, then 'ftyp' where MPEG frames should be. Prepending a tag
      // to this is exactly what made that file unplayable.
      final mp4ish = Uint8List.fromList([
        0x00,
        0x00,
        0x00,
        0x1c,
        ...latin1.encode('ftypisom'),
        ...List<int>.filled(2048, 0x41),
      ]);
      final before = _fileWithTag(
        major: 3,
        frames: [('TIT2', _text('Fake'))],
        audio: mp4ish,
      );

      expect(
        () => buildTaggedMp3(before, _jpeg()),
        throwsA(
          isA<EmbedException>().having(
            (e) => e.refusal,
            'refusal',
            EmbedRefusal.notMpeg,
          ),
        ),
      );
    });

    test('a non-image payload is refused', () {
      final before = Uint8List.fromList(_audio());
      expect(
        () =>
            buildTaggedMp3(before, Uint8List.fromList(latin1.encode('<html>'))),
        throwsA(
          isA<EmbedException>().having(
            (e) => e.refusal,
            'refusal',
            EmbedRefusal.unsupportedImage,
          ),
        ),
      );
    });

    test('unsynchronised / extended-header / footer tags are refused', () {
      for (final (flag, label) in [
        (0x80, 'unsync'),
        (0x40, 'extended header'),
        (0x10, 'footer'),
      ]) {
        final f = _fileWithTag(
          major: 3,
          frames: [('TIT2', _text('x'))],
          audio: _audio(),
        );
        f[5] = flag;
        expect(
          () => buildTaggedMp3(f, _jpeg()),
          throwsA(
            isA<EmbedException>().having(
              (e) => e.refusal,
              'refusal',
              EmbedRefusal.unsupportedTagFlags,
            ),
          ),
          reason: label,
        );
      }
    });
  });

  group('FLAC keeps its identity too (no conversion needed)', () {
    /// A minimal but structurally real FLAC: fLaC, a 34-byte STREAMINFO, a
    /// VORBIS_COMMENT, then "audio".
    Uint8List flac({bool withPicture = false, int padding = 0}) {
      List<int> block(int type, List<int> body, bool last) => [
        (last ? 0x80 : 0x00) | type,
        (body.length >> 16) & 0xff,
        (body.length >> 8) & 0xff,
        body.length & 0xff,
        ...body,
      ];
      final streaminfo = List<int>.filled(34, 0x11);
      final comment = latin1.encode('reference libFLAC').toList();
      final blocks = <int>[
        ...block(0, streaminfo, false),
        ...block(4, comment, !withPicture && padding == 0),
      ];
      if (withPicture) {
        blocks.addAll(
          block(
            6,
            buildFlacPictureBlock(_jpeg(4096), 'image/jpeg').toList(),
            padding == 0,
          ),
        );
      }
      if (padding > 0) {
        blocks.addAll(block(1, List<int>.filled(padding, 0), true));
      }
      return Uint8List.fromList([
        0x66, 0x4C, 0x61, 0x43,
        ...blocks,
        ...List<int>.generate(2048, (i) => (i * 13) % 251), // frames
      ]);
    }

    test('a cover is added without disturbing the audio frames', () {
      final before = flac();
      final after = buildTaggedFlac(before, _jpeg());

      expect(
        contentIdForBytes('z.flac', after),
        contentIdForBytes('z.flac', before),
        reason: 'flacAudioRange skips metadata, so identity must hold',
      );
      expect(flacAudioBytesUnchanged(before, after), isTrue);
    });

    test('an existing picture is replaced, and padding is dropped', () {
      final before = flac(withPicture: true, padding: 512);
      final after = buildTaggedFlac(before, _png());

      expect(
        contentIdForBytes('z.flac', after),
        contentIdForBytes('z.flac', before),
      );
      // Walk the rebuilt block list: exactly one PICTURE, no PADDING, and
      // STREAMINFO still first (the format requires it).
      var o = 4, pictures = 0, paddings = 0;
      final types = <int>[];
      var last = false;
      while (o + 4 <= after.length && !last) {
        last = (after[o] & 0x80) != 0;
        final type = after[o] & 0x7f;
        types.add(type);
        if (type == kFlacBlockPicture) pictures++;
        if (type == kFlacBlockPadding) paddings++;
        o += 4 + ((after[o + 1] << 16) | (after[o + 2] << 8) | after[o + 3]);
      }
      expect(types.first, 0, reason: 'STREAMINFO stays first');
      expect(pictures, 1);
      expect(paddings, 0);
      expect(types, contains(4), reason: 'VORBIS_COMMENT preserved');
    });

    test('the picture block records real dimensions', () {
      // 1x1 PNG: IHDR says 1x1, and the block must say so too rather than 0x0.
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
      ]);
      final dims = imageDimsOf(png);
      expect(dims.width, 1);
      expect(dims.height, 1);

      final block = buildFlacPictureBlock(png, 'image/png');
      // width sits after: type(4) + mimeLen(4) + mime + descLen(4)
      final o = 4 + 4 + 'image/png'.length + 4;
      final w =
          (block[o] << 24) |
          (block[o + 1] << 16) |
          (block[o + 2] << 8) |
          block[o + 3];
      expect(w, 1);
    });

    test('a non-FLAC payload is refused', () {
      expect(
        () => buildTaggedFlac(_audio(), _jpeg()),
        throwsA(isA<EmbedException>()),
      );
    });
  });
}
