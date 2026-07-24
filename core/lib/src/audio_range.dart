import 'dart:typed_data';

/// Byte range [start, end) of the audio data within a file.
class AudioRange {
  final int start;
  final int end;
  const AudioRange(this.start, this.end);
}

int _syncsafe(Uint8List b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

AudioRange mp3AudioRange(Uint8List b) {
  var start = 0;
  var end = b.length;

  // ID3v2 at start: "ID3" <ver:2> <flags:1> <syncsafe size:4>
  if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    final size = _syncsafe(b, 6);
    final footer = (b[5] & 0x10) != 0 ? 10 : 0; // footer flag duplicates header at tag end
    start = (10 + size + footer).clamp(0, b.length);
  }

  // ID3v1: fixed 128-byte trailer starting "TAG".
  if (end - start >= 128 &&
      b[end - 128] == 0x54 &&
      b[end - 127] == 0x41 &&
      b[end - 126] == 0x47) {
    end -= 128;
  }

  // APEv2: 32-byte footer ending at `end`, magic "APETAGEX".
  // Footer's size field covers items + footer; a header (flag bit 31 of the
  // footer's flags at offset 20) adds another 32 bytes before that.
  const magic = [0x41, 0x50, 0x45, 0x54, 0x41, 0x47, 0x45, 0x58];
  if (end - start >= 32) {
    final f = end - 32;
    var isApe = true;
    for (var i = 0; i < 8; i++) {
      if (b[f + i] != magic[i]) {
        isApe = false;
        break;
      }
    }
    if (isApe) {
      final tagSize = _le32(b, f + 12);
      final flags = _le32(b, f + 20);
      final hasHeader = (flags & 0x80000000) != 0;
      final tagStart = end - tagSize - (hasHeader ? 32 : 0);
      if (tagStart >= start && tagStart < end) end = tagStart;
    }
  }

  if (start > end) start = end;
  return AudioRange(start, end);
}
