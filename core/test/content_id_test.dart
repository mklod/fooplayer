import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/audio_range.dart';
import 'package:fooplayer_core/src/content_id.dart';

Uint8List flacFile({required int vorbisSize, required List<int> audio}) {
  // "fLaC" + STREAMINFO block (34 bytes, not last) + VORBIS_COMMENT (last) + audio.
  final b = BytesBuilder();
  b.add([0x66, 0x4C, 0x61, 0x43]); // "fLaC"
  b.add([0x00, 0x00, 0x00, 34]); // type 0 (STREAMINFO), len 34, not last
  b.add(List.filled(34, 0x01));
  b.add([0x84, (vorbisSize >> 16) & 0xFF, (vorbisSize >> 8) & 0xFF, vorbisSize & 0xFF]); // 0x80|4: last, VORBIS_COMMENT
  b.add(List.filled(vorbisSize, 0x02));
  b.add(audio);
  return b.toBytes();
}

void main() {
  final audio = List<int>.filled(300, 0x77);

  test('flac range starts after last metadata block', () {
    final b = flacFile(vorbisSize: 50, audio: audio);
    final r = flacAudioRange(b);
    expect(r.start, 4 + 4 + 34 + 4 + 50);
    expect(r.end, b.length);
  });

  test('flac with different vorbis comment sizes → same content id', () {
    final a = flacFile(vorbisSize: 50, audio: audio);
    final b = flacFile(vorbisSize: 200, audio: audio);
    expect(contentIdForBytes('x.flac', a), contentIdForBytes('x.flac', b));
  });

  test('mp3 with different ID3v2 sizes → same content id', () {
    Uint8List mp3(int pad) => Uint8List.fromList([
          0x49, 0x44, 0x33, 3, 0, 0, 0, 0, (pad >> 7) & 0x7F, pad & 0x7F,
          ...List.filled(pad, 0xAA),
          ...audio,
        ]);
    expect(contentIdForBytes('x.mp3', mp3(20)), contentIdForBytes('x.mp3', mp3(90)));
  });

  test('unknown format hashes whole file', () {
    final a = Uint8List.fromList(audio);
    final b = Uint8List.fromList([...audio, 0x00]);
    expect(contentIdForBytes('x.m4a', a), isNot(contentIdForBytes('x.m4a', b)));
  });

  test('contentIdForFile matches contentIdForBytes', () async {
    final dir = await Directory.systemTemp.createTemp('cid');
    final f = File('${dir.path}/t.mp3');
    await f.writeAsBytes(audio);
    expect(await contentIdForFile(f), contentIdForBytes('t.mp3', Uint8List.fromList(audio)));
    await dir.delete(recursive: true);
  });
}
