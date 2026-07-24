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

  group('parseFromFilename date-like parent folder is not an album', () {
    test('a "YYYY-MM" parent directory (e.g. a dated export folder) yields no album', () {
      final t = parseFromFilename('Various Artists/2012-11/Track One.mp3');
      expect(t.album, isNull);
      expect(t.title, 'Track One');
    });

    test('a bare "YYYY" parent directory also yields no album', () {
      final t = parseFromFilename('Various Artists/1999/Track One.mp3');
      expect(t.album, isNull);
    });

    test('a parent directory that merely starts with a date but has more '
        'text is still treated as a real album', () {
      final t = parseFromFilename('Various Artists/2012-11 Tour Rehearsals/Track One.mp3');
      expect(t.album, '2012-11 Tour Rehearsals');
    });

    test('a top-level (no parent directory) file still has no album, same as before', () {
      final t = parseFromFilename('2012-11.mp3');
      expect(t.album, isNull);
    });
  });

  group('parseFromFilename track-number prefix', () {
    test('"NN Title.ext" -> trackNumber and a title with the prefix stripped', () {
      final t = parseFromFilename('03 You Love Me (Remix).mp3');
      expect(t.trackNumber, 3);
      expect(t.title, 'You Love Me (Remix)');
      expect(t.artist, isNull);
    });

    test('"Artist - Title.ext" with no leading number -> trackNumber null', () {
      final t = parseFromFilename('Artist - Title.mp3');
      expect(t.trackNumber, isNull);
      expect(t.artist, 'Artist');
      expect(t.title, 'Title');
    });

    test('"NN - Title.ext" -> trackNumber and the "NN - " prefix cleanly stripped', () {
      final t = parseFromFilename('07 - No One Gets Left Behind.mp3');
      expect(t.trackNumber, 7);
      expect(t.title, 'No One Gets Left Behind');
      expect(t.artist, isNull);
    });

    test('a leading four-digit year is not mistaken for a track number '
        '(falls through to the ordinary artist/title split instead)', () {
      final t = parseFromFilename('1999 - Live Forever.mp3');
      expect(t.trackNumber, isNull);
      expect(t.artist, '1999');
      expect(t.title, 'Live Forever');
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

    test('trackNumber round-trips through toJson/fromJson', () {
      const t = TrackTags(title: 'T', trackNumber: 7);
      final j = t.toJson();
      expect(j['trackNumber'], 7);
      expect(TrackTags.fromJson(j).trackNumber, 7);
    });

    test('a null trackNumber still serializes the key, with a null value', () {
      const t = TrackTags(title: 'T');
      final j = t.toJson();
      expect(j.containsKey('trackNumber'), isTrue);
      expect(j['trackNumber'], isNull);
      expect(TrackTags.fromJson(j).trackNumber, isNull);
    });
  });
}
