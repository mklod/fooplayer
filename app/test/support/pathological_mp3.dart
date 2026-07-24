// Shared test fixture builder: an MP3 shape that defeats
// `audio_metadata_reader`'s unbounded byte-by-byte MP3-frame-sync scan (see
// `_findFirstMp3Frame`) -- the exact pathology behind both the tag-enrichment
// freeze fixed in `library_model_enrichment_resilience_test.dart` and the
// UI-isolate art-loading freeze fixed by `readArtSafe`
// (`tags_read_art_safe_test.dart`). Both tests need the identical file
// shape, so it lives here once instead of being duplicated.
import 'dart:convert';
import 'dart:typed_data';

/// Builds a minimal ID3v2.3 MP3 file with a single TIT2 (title) frame,
/// followed by [payloadSize] zero bytes standing in for audio data that
/// never contains a valid MPEG frame sync (a real sync always starts with
/// byte 0xFF, which zero bytes never do) -- the same shape as the real file
/// that triggered the original freeze.
Uint8List buildMp3WithNoFrameSync({
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
