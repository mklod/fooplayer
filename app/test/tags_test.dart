import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';

void main() {
  group('parseFromFilename', () {
    test('artist - title with album from parent dir', () {
      final t = parseFromFilename('albums/Arctic Monkeys - Humbug/Arctic Monkeys - Crying Lightning.mp3');
      expect(t.artist, 'Arctic Monkeys');
      expect(t.title, 'Crying Lightning');
      expect(t.album, 'Arctic Monkeys - Humbug');
    });

    test('splits on first separator only', () {
      final t = parseFromFilename('x/A - B - C.mp3');
      expect(t.artist, 'A');
      expect(t.title, 'B - C');
    });

    test('no separator: title only, no artist', () {
      final t = parseFromFilename('track01.mp3');
      expect(t.artist, isNull);
      expect(t.title, 'track01');
      expect(t.album, isNull);
    });
  });

  test('readTags falls back to filename parse on unreadable file', () async {
    final tmp = await Directory.systemTemp.createTemp('tags');
    final f = File('${tmp.path}/Muse - New Born.mp3');
    await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
    final t = await readTags(f);
    expect(t.artist, 'Muse');
    expect(t.title, 'New Born');
    await tmp.delete(recursive: true);
  });

  test('readArt returns null on unreadable file', () async {
    final tmp = await Directory.systemTemp.createTemp('art');
    final f = File('${tmp.path}/x.mp3');
    await f.writeAsBytes(List.filled(16, 0x01));
    expect(await readArt(f), isNull);
    await tmp.delete(recursive: true);
  });

  test('readTags does not leak the file handle: file deletes immediately after', () async {
    final tmp = await Directory.systemTemp.createTemp('handle_leak');
    final f = File('${tmp.path}/Muse - New Born.mp3');
    await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
    await readTags(f);
    // On Windows, an open RandomAccessFile prevents deletion outright. If
    // readTags left the reader open, this throws (regression test for the
    // audio_metadata_reader handle leak worked around in tags.dart).
    expect(f.deleteSync, returnsNormally);
    await tmp.delete(recursive: true);
  });

  test('readTags on an unreadable/unparseable file yields durationMs null', () async {
    final tmp = await Directory.systemTemp.createTemp('tags_dur');
    final f = File('${tmp.path}/Muse - New Born.mp3');
    await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
    final t = await readTags(f);
    expect(t.durationMs, isNull);
    await tmp.delete(recursive: true);
  });

  group('TrackTags json round-trip', () {
    test('durationMs round-trips through toJson/fromJson', () {
      const t = TrackTags(
          title: 'T', artist: 'A', album: 'B', genre: 'G', durationMs: 245000);
      final j = t.toJson();
      expect(j['durationMs'], 245000);
      expect(TrackTags.fromJson(j).durationMs, 245000);
    });

    test('a null durationMs still serializes the key, with a null value', () {
      const t = TrackTags(title: 'T');
      final j = t.toJson();
      expect(j.containsKey('durationMs'), isTrue);
      expect(j['durationMs'], isNull);
      expect(TrackTags.fromJson(j).durationMs, isNull);
    });
  });
}
