import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'audio_range.dart';

AudioRange audioRangeFor(String filename, Uint8List bytes) {
  switch (p.extension(filename).toLowerCase()) {
    case '.mp3':
      return mp3AudioRange(bytes);
    case '.flac':
      return flacAudioRange(bytes);
    default:
      return AudioRange(0, bytes.length);
  }
}

/// Lowercase hex SHA-256 of the file's audio byte range.
String contentIdForBytes(String filename, Uint8List bytes) {
  final r = audioRangeFor(filename, bytes);
  return sha256.convert(Uint8List.sublistView(bytes, r.start, r.end)).toString();
}

Future<String> contentIdForFile(File file) async {
  final bytes = await file.readAsBytes();
  return contentIdForBytes(p.basename(file.path), bytes);
}
