import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/audio_range.dart';

Uint8List id3v2(int payloadSize) {
  // "ID3" v2.3 header, syncsafe size (7 bits per byte).
  final h = BytesBuilder();
  h.add([0x49, 0x44, 0x33, 3, 0, 0]); // "ID3", version, flags
  h.add([
    (payloadSize >> 21) & 0x7F,
    (payloadSize >> 14) & 0x7F,
    (payloadSize >> 7) & 0x7F,
    payloadSize & 0x7F,
  ]);
  h.add(List.filled(payloadSize, 0xAA)); // tag payload
  return h.toBytes();
}

void main() {
  final audio = List<int>.filled(500, 0x55);

  test('plain file: whole range', () {
    final b = Uint8List.fromList(audio);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('skips ID3v2 header at start', () {
    final b = Uint8List.fromList([...id3v2(300), ...audio]);
    final r = mp3AudioRange(b);
    expect(r.start, 10 + 300);
    expect(r.end, b.length);
  });

  test('skips ID3v1 trailer', () {
    final v1 = [0x54, 0x41, 0x47, ...List.filled(125, 0)]; // "TAG" + 125 bytes
    final b = Uint8List.fromList([...audio, ...v1]);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('skips APEv2 tag (with header) before ID3v1', () {
    // APE tag: 32-byte header + 40 bytes of items + 32-byte footer.
    // APE "tag size" field = items + footer = 72.
    List<int> apeBlock(bool isHeader) => [
          0x41, 0x50, 0x45, 0x54, 0x41, 0x47, 0x45, 0x58, // "APETAGEX"
          0xD0, 0x07, 0x00, 0x00, // version 2000
          72, 0, 0, 0, // tag size (LE)
          1, 0, 0, 0, // item count
          0, 0, 0, isHeader ? 0xA0 : 0x80, // flags: has-header, (is-header)
          0, 0, 0, 0, 0, 0, 0, 0, // reserved
        ];
    final b = Uint8List.fromList([
      ...audio,
      ...apeBlock(true),
      ...List.filled(40, 0x11),
      ...apeBlock(false),
    ]);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('identical audio with different tags yields identical range content', () {
    final a = Uint8List.fromList([...id3v2(64), ...audio]);
    final b2 = Uint8List.fromList([...id3v2(999), ...audio]);
    final ra = mp3AudioRange(a);
    final rb = mp3AudioRange(b2);
    expect(a.sublist(ra.start, ra.end), b2.sublist(rb.start, rb.end));
  });
}
