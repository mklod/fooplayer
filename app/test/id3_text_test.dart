// Our own ID3 text reader, against the exact shapes that defeated the
// upstream parser on real albums in Mike's library.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/id3_text.dart';

List<int> _syncsafe(int v) =>
    [(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f];

List<int> _be32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// Latin-1 text frame body.
Uint8List _text(String s) => Uint8List.fromList([0x00, ...latin1.encode(s)]);

/// UTF-16 (with BOM) text frame body, as real taggers write non-ASCII.
Uint8List _utf16(String s) {
  final out = <int>[0x01, 0xFF, 0xFE];
  for (final u in s.codeUnits) {
    out.addAll([u & 0xff, (u >> 8) & 0xff]);
  }
  return Uint8List.fromList(out);
}

/// One ID3v2 tag of the given major version.
List<int> _tag(int major, List<(String, Uint8List)> frames, {int padding = 0}) {
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
      body.addAll(major == 4 ? _syncsafe(data.length) : _be32(data.length));
      body.addAll([0, 0]);
    }
    body.addAll(data);
  }
  body.addAll(List<int>.filled(padding, 0));
  return [0x49, 0x44, 0x33, major, 0x00, 0x00, ..._syncsafe(body.length), ...body];
}

void main() {
  group('shapes the upstream parser got wrong', () {
    test('ID3v2.2 three-character frames (Portishead, Sleigh Bells, '
        'Sneaker Pimps)', () {
      final bytes = Uint8List.fromList(_tag(2, [
        ('TT2', _text('Mysterons')),
        ('TP1', _text('Portishead')),
        ('TAL', _text('Dummy')),
        ('TRK', _text('1')),
      ]));

      final f = parseId3TextFrames(bytes);
      expect(f['TIT2'], 'Mysterons');
      expect(f['TPE1'], 'Portishead');
      expect(f['TALB'], 'Dummy');
      expect(f['TRCK'], '1');
    });

    test('frames sitting AFTER a huge picture are still found (Lil Wayne — '
        'TPE1 came after a 307 KB APIC)', () {
      final hugePicture = Uint8List(300 * 1024);
      final bytes = Uint8List.fromList(_tag(3, [
        ('TIT2', _text('3 Peat')),
        ('APIC', hugePicture),
        ('TPE1', _text('Lil Wayne')),
        ('TALB', _text('2008 Tha Carter III [Cash Money]')),
      ]));

      final f = parseId3TextFrames(bytes);
      expect(f['TPE1'], 'Lil Wayne',
          reason: 'a picture in the middle must not end the frame walk');
      expect(f['TALB'], '2008 Tha Carter III [Cash Money]');
    });

    test('stacked tags: a v2.3 followed by a v2.4 (Tayyib Ali)', () {
      final bytes = Uint8List.fromList([
        ..._tag(3, [('TIT2', _text('Get Up'))], padding: 64),
        ..._tag(4, [
          ('TPE1', _text('Tayyib Ali')),
          ('TALB', _text('Keystone State Of Mind')),
        ]),
      ]);

      final f = parseId3TextFrames(bytes);
      expect(f['TIT2'], 'Get Up', reason: 'from the first tag');
      expect(f['TPE1'], 'Tayyib Ali', reason: 'from the SECOND tag');
      expect(f['TALB'], 'Keystone State Of Mind');
    });

    test('the first tag wins when both carry the same frame', () {
      final bytes = Uint8List.fromList([
        ..._tag(3, [('TPE1', _text('First'))]),
        ..._tag(4, [('TPE1', _text('Second'))]),
      ]);
      expect(parseId3TextFrames(bytes)['TPE1'], 'First');
    });
  });

  group('encodings and edge cases', () {
    test('UTF-16 with BOM decodes, and a NUL terminator is trimmed', () {
      final bytes = Uint8List.fromList(_tag(3, [
        ('TPE1', Uint8List.fromList([..._utf16('RÜFÜS du Sol'), 0x00, 0x00])),
      ]));
      expect(parseId3TextFrames(bytes)['TPE1'], 'RÜFÜS du Sol');
    });

    test('a v2.4 multi-value frame yields the first value', () {
      final joined = Uint8List.fromList(
          [0x03, ...utf8.encode('Bouga'), 0x00, ...utf8.encode('Various')]);
      final bytes = Uint8List.fromList(_tag(4, [('TPE1', joined)]));
      expect(parseId3TextFrames(bytes)['TPE1'], 'Bouga');
    });

    test('no ID3 tag, empty tag, and garbage all yield nothing (never throw)',
        () {
      expect(parseId3TextFrames(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00])),
          isEmpty);
      expect(parseId3TextFrames(Uint8List.fromList(_tag(3, []))), isEmpty);
      expect(parseId3TextFrames(Uint8List.fromList(List.filled(64, 0x49))),
          isEmpty);
    });

    test('a frame claiming a size past the end of the tag stops the walk '
        'instead of reading out of bounds', () {
      final t = _tag(3, [('TIT2', _text('ok'))]);
      // Corrupt the frame size to something absurd.
      final bytes = Uint8List.fromList(t);
      bytes[14] = 0x7f;
      bytes[15] = 0xff;
      expect(() => parseId3TextFrames(bytes), returnsNormally);
    });
  });

  group('reading from a file', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('id3text'));
    tearDown(() async => tmp.delete(recursive: true));

    test('reads past a large first tag to a stacked second one', () async {
      final f = File('${tmp.path}/stacked.mp3');
      await f.writeAsBytes([
        ..._tag(3, [
          ('TIT2', _text('Get Up')),
          ('APIC', Uint8List(120 * 1024)),
        ]),
        ..._tag(4, [('TPE1', _text('Tayyib Ali'))]),
        0xFF, 0xFB, 0x90, 0x00,
      ]);

      final frames = await readId3TextFramesFromFile(f);
      expect(frames['TIT2'], 'Get Up');
      expect(frames['TPE1'], 'Tayyib Ali');
    });

    test('a file with no tag returns empty rather than throwing', () async {
      final f = File('${tmp.path}/plain.mp3');
      await f.writeAsBytes([0xFF, 0xFB, 0x90, 0x00, 1, 2, 3]);
      expect(await readId3TextFramesFromFile(f), isEmpty);
    });

    test('a missing file returns empty rather than throwing', () async {
      expect(await readId3TextFramesFromFile(File('${tmp.path}/nope.mp3')),
          isEmpty);
    });
  });
}
