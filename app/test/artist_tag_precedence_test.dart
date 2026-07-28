// Which ID3 frame is "the artist".
//
// TPE1 is the lead performer -- the track artist every other player shows.
// TPE2 is the band/album artist, which on a compilation is usually "Various
// Artists". Reading TPE2 first (as this once did) mislabelled 359 files in
// Mike's library: "The Life" showed RÜFÜS instead of RÜFÜS du Sol, and
// compilation tracks showed "Various Artists" instead of the band that
// actually played them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';

/// A UTF-16 text frame body (encoding 0x01 + BOM), the way real taggers
/// write non-ASCII values -- "RÜFÜS" is exactly such a case.
Uint8List _utf16Frame(String text) {
  final out = <int>[0x01, 0xFF, 0xFE];
  for (final unit in text.codeUnits) {
    out.addAll([unit & 0xff, (unit >> 8) & 0xff]);
  }
  out.addAll([0x00, 0x00]);
  return Uint8List.fromList(out);
}

/// Writes a small but structurally valid MP3: an ID3v2.3 tag carrying
/// [frames], then a run of MPEG-1 Layer III frame headers.
File _mp3(Directory dir, String name, Map<String, Uint8List> frames) {
  final body = <int>[];
  frames.forEach((id, data) {
    body.addAll(latin1.encode(id));
    body.addAll([
      (data.length >> 24) & 0xff,
      (data.length >> 16) & 0xff,
      (data.length >> 8) & 0xff,
      data.length & 0xff,
    ]);
    body.addAll([0, 0]);
    body.addAll(data);
  });
  final header = <int>[0x49, 0x44, 0x33, 3, 0x00, 0x00];
  final n = body.length;
  header.addAll([
    (n >> 21) & 0x7f,
    (n >> 14) & 0x7f,
    (n >> 7) & 0x7f,
    n & 0x7f,
  ]);

  // 128 kbps, 44.1 kHz, mono -> 417-byte frames.
  final audio = <int>[];
  for (var i = 0; i < 12; i++) {
    audio.addAll([0xFF, 0xFB, 0x90, 0xC0]);
    audio.addAll(List<int>.filled(413, 0));
  }

  final f = File('${dir.path}/$name')
    ..writeAsBytesSync(Uint8List.fromList([...header, ...body, ...audio]));
  return f;
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('artisttag'));
  tearDown(() async => tmp.delete(recursive: true));

  test('TPE1 (lead performer) wins over TPE2 (band / album artist)', () async {
    final f = _mp3(tmp, 'the_life.mp3', {
      'TIT2': _utf16Frame('The Life'),
      'TPE1': _utf16Frame('RÜFÜS du Sol'),
      'TPE2': _utf16Frame('RÜFÜS'),
      'TALB': _utf16Frame('Inhale / Exhale'),
    });

    final tags = await readTags(f);
    expect(tags.artist, 'RÜFÜS du Sol',
        reason: 'the artist tag, not the album artist');
    expect(tags.title, 'The Life');
    expect(tags.album, 'Inhale / Exhale');
  });

  test('a compilation track shows the band, not "Various Artists"', () async {
    final f = _mp3(tmp, 'comp.mp3', {
      'TIT2': _utf16Frame('Belsunce Breakdown'),
      'TPE1': _utf16Frame('Bouga'),
      'TPE2': _utf16Frame('Various Artists'),
    });

    final tags = await readTags(f);
    expect(tags.artist, 'Bouga');
  });

  test('TPE2 is still used when there is no TPE1', () async {
    final f = _mp3(tmp, 'albumartist_only.mp3', {
      'TIT2': _utf16Frame('Untitled'),
      'TPE2': _utf16Frame('The Band'),
    });

    final tags = await readTags(f);
    expect(tags.artist, 'The Band',
        reason: 'falling back to album artist beats showing nothing');
  });
}
