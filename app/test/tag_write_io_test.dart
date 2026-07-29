// Editing tags on a real file, and putting its dates back.
//
// The engine tests prove the bytes are right. These prove the part that only
// shows up against a filesystem: the write lands, the audio range is
// untouched so the manifest still recognises the track, and the modified time
// comes back exactly as it was -- which since 2026-07-28 IS this library's
// "date downloaded".
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;
import 'package:path/path.dart' as p;

Uint8List _audio([int n = 4096]) {
  final b = Uint8List(n);
  b[0] = 0xFF;
  b[1] = 0xFB;
  b[2] = 0x90;
  for (var i = 3; i < n; i++) {
    b[i] = i % 251;
  }
  return b;
}

void _syncsafe(List<int> out, int v) =>
    out.addAll([(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f]);

/// An mp3 with a v2.3 tag carrying [title].
Uint8List _mp3({String title = 'Old Title'}) {
  final frameData = <int>[0x00, ...latin1.encode(title)];
  final body = <int>[
    ...latin1.encode('TIT2'),
    (frameData.length >> 24) & 0xff,
    (frameData.length >> 16) & 0xff,
    (frameData.length >> 8) & 0xff,
    frameData.length & 0xff,
    0, 0,
    ...frameData,
  ];
  final out = <int>[0x49, 0x44, 0x33, 3, 0x00, 0x00];
  _syncsafe(out, body.length);
  return Uint8List.fromList([...out, ...body, ..._audio()]);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('tagwrite'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> song({String name = 'song.mp3', String title = 'Old Title'}) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(_mp3(title: title));
    return f;
  }

  test('writes the new tag, keeps identity, and puts the date back', () async {
    final f = await song();
    final before = await f.readAsBytes();
    final wasId = contentIdForBytes('song.mp3', before);

    // Backdate it the way the library's real files are dated.
    final downloaded = DateTime(2009, 2, 14, 21, 30);
    await f.setLastModified(downloaded);

    final report = await writeTags(
      f,
      const TagEdits(title: 'Corrected Title', artist: 'Correct Artist'),
    );

    expect(report.outcome, EmbedOutcome.embedded);
    expect(report.timesPreserved, isTrue);

    final after = await f.readAsBytes();
    expect(
      contentIdForBytes('song.mp3', after),
      wasId,
      reason: 'a changed id would orphan the manifest entry and its date',
    );
    expect(audioBytesUnchanged(before, after), isTrue);
    expect(
      await f.lastModified(),
      downloaded,
      reason: 'the modified time IS the download date on this library',
    );
  });

  test('a no-op edit does not rewrite the file at all', () async {
    final f = await song();
    final downloaded = DateTime(2011, 6, 1, 12);
    await f.setLastModified(downloaded);
    final sizeBefore = await f.length();

    final report = await writeTags(f, const TagEdits());

    expect(report.outcome, EmbedOutcome.embedded);
    expect(report.timesPreserved, isTrue);
    expect(await f.length(), sizeBefore);
    expect(await f.lastModified(), downloaded);
  });

  test('a file that is not really an mp3 is refused, not mangled', () async {
    final f = File(p.join(tmp.path, 'liar.mp3'));
    final bytes = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x1c,
      ...latin1.encode('ftypisom'),
      ...List<int>.filled(2048, 0x41),
    ]);
    await f.writeAsBytes(bytes);

    final report = await writeTags(f, const TagEdits(title: 'Nope'));

    expect(report.outcome, EmbedOutcome.refused);
    expect(report.reason, contains('notMpeg'));
    expect(await f.readAsBytes(), bytes, reason: 'left exactly as it was');
  });

  test('FLAC is refused explicitly rather than half-attempted', () async {
    final f = File(p.join(tmp.path, 'song.flac'));
    await f.writeAsBytes([0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 34]);

    final report = await writeTags(f, const TagEdits(title: 'x'));

    expect(report.outcome, EmbedOutcome.refused);
    expect(report.reason, contains('FLAC'));
  });

  test('embedding a cover still works through the shared rewrite', () async {
    final f = await song();
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3, 4, 5]);
    final downloaded = DateTime(2007, 11, 11, 20);
    await f.setLastModified(downloaded);

    final report = await embedCover(f, jpeg);

    expect(report.outcome, EmbedOutcome.embedded);
    expect(report.timesPreserved, isTrue);
    expect(await f.lastModified(), downloaded);
    expect(parseId3(await f.readAsBytes()).frames.map((x) => x.id),
        contains('APIC'));
  });

  test('a cover survives a later text edit, and vice versa', () async {
    final f = await song();
    await embedCover(f, Uint8List.fromList([0xFF, 0xD8, 0xFF, 9, 9, 9]));
    await writeTags(f, const TagEdits(album: 'An Album'));

    final tag = parseId3(await f.readAsBytes());
    expect(tag.frames.where((x) => x.id == 'APIC'), hasLength(1));
    expect(tag.frames.where((x) => x.id == 'TALB'), hasLength(1));
  });
}
