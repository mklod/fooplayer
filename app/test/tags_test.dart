import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';

void main() {
  group('parseFromFilename', () {
    test('artist - title with album from parent dir', () {
      final t = parseFromFilename(
        'albums/Arctic Monkeys - Humbug/Arctic Monkeys - Crying Lightning.mp3',
      );
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
    test(
      'a "YYYY-MM" parent directory (e.g. a dated export folder) yields no album',
      () {
        final t = parseFromFilename('Various Artists/2012-11/Track One.mp3');
        expect(t.album, isNull);
        expect(t.title, 'Track One');
      },
    );

    test('a bare "YYYY" parent directory also yields no album', () {
      final t = parseFromFilename('Various Artists/1999/Track One.mp3');
      expect(t.album, isNull);
    });

    test('a parent directory that merely starts with a date but has more '
        'text is still treated as a real album', () {
      final t = parseFromFilename(
        'Various Artists/2012-11 Tour Rehearsals/Track One.mp3',
      );
      expect(t.album, '2012-11 Tour Rehearsals');
    });

    test(
      'a top-level (no parent directory) file still has no album, same as before',
      () {
        final t = parseFromFilename('2012-11.mp3');
        expect(t.album, isNull);
      },
    );
  });

  group('parseFromFilename track-number prefix', () {
    test(
      '"NN Title.ext" -> trackNumber and a title with the prefix stripped',
      () {
        final t = parseFromFilename('03 You Love Me (Remix).mp3');
        expect(t.trackNumber, 3);
        expect(t.title, 'You Love Me (Remix)');
        expect(t.artist, isNull);
      },
    );

    test('"Artist - Title.ext" with no leading number -> trackNumber null', () {
      final t = parseFromFilename('Artist - Title.mp3');
      expect(t.trackNumber, isNull);
      expect(t.artist, 'Artist');
      expect(t.title, 'Title');
    });

    test(
      '"NN - Title.ext" -> trackNumber and the "NN - " prefix cleanly stripped',
      () {
        final t = parseFromFilename('07 - No One Gets Left Behind.mp3');
        expect(t.trackNumber, 7);
        expect(t.title, 'No One Gets Left Behind');
        expect(t.artist, isNull);
      },
    );

    test('a leading four-digit year is not mistaken for a track number '
        '(falls through to the ordinary artist/title split instead)', () {
      final t = parseFromFilename('1999 - Live Forever.mp3');
      expect(t.trackNumber, isNull);
      expect(t.artist, '1999');
      expect(t.title, 'Live Forever');
    });
  });

  group('readTags: ID3v2 TRCK track-number shapes (probe for #27)', () {
    // Builds a minimal-but-real ID3v2.3 tag: 10-byte header ('ID3', version
    // 3.0, no flags, sync-safe size) followed by v2.3 text frames (4-byte
    // id, 4-byte big-endian size, 2 flag bytes, then an encoding byte 0x00
    // + latin-1 text). No MP3 audio frames follow -- MP3Parser's
    // _parseAudioFrames tolerates that (no frame sync found -> duration
    // simply stays null), so readTags exercises the exact ID3v2 tag path
    // real library files take.
    List<int> id3v2(Map<String, String> frames) {
      final frameBytes = <int>[];
      for (final e in frames.entries) {
        final text = [
          0x00,
          ...e.value.codeUnits,
        ]; // latin-1 encoding byte + text
        frameBytes.addAll(e.key.codeUnits); // 4-char frame id
        final size = text.length;
        frameBytes.addAll([
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ]);
        frameBytes.addAll([0x00, 0x00]); // flags
        frameBytes.addAll(text);
      }
      final total = frameBytes.length;
      return [
        ...'ID3'.codeUnits,
        0x03, 0x00, 0x00, // v2.3.0, no flags
        // sync-safe size (7 bits per byte)
        (total >> 21) & 0x7F,
        (total >> 14) & 0x7F,
        (total >> 7) & 0x7F,
        total & 0x7F,
        ...frameBytes,
      ];
    }

    test('TRCK "3/12" (track-of-total STRING, the common MP3 shape) parses '
        'to trackNumber 3', () async {
      final tmp = await Directory.systemTemp.createTemp('trck');
      // No numeric filename prefix: the number can ONLY come from the tag.
      final f = File('${tmp.path}/Can I.mp3');
      await f.writeAsBytes(
        id3v2({'TIT2': 'Can I', 'TALB': 'Urban Flora', 'TRCK': '3/12'}),
      );
      final t = await readTags(f);
      expect(t.title, 'Can I');
      expect(t.album, 'Urban Flora');
      expect(t.trackNumber, 3);
      await tmp.delete(recursive: true);
    });

    test('plain TRCK "7" parses to trackNumber 7', () async {
      final tmp = await Directory.systemTemp.createTemp('trck');
      final f = File('${tmp.path}/Pretty Thoughts.mp3');
      await f.writeAsBytes(id3v2({'TRCK': '7'}));
      final t = await readTags(f);
      expect(t.trackNumber, 7);
      await tmp.delete(recursive: true);
    });

    test('no TRCK frame at all: trackNumber falls back to the "01 " '
        'filename prefix', () async {
      final tmp = await Directory.systemTemp.createTemp('trck');
      final f = File('${tmp.path}/01 Show Me.mp3');
      await f.writeAsBytes(id3v2({'TIT2': 'Show Me'}));
      final t = await readTags(f);
      expect(t.trackNumber, 1);
      await tmp.delete(recursive: true);
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

  test(
    'readTags does not leak the file handle: file deletes immediately after',
    () async {
      final tmp = await Directory.systemTemp.createTemp('handle_leak');
      final f = File('${tmp.path}/Muse - New Born.mp3');
      await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
      await readTags(f);
      // On Windows, an open RandomAccessFile prevents deletion outright. If
      // readTags left the reader open, this throws (regression test for the
      // audio_metadata_reader handle leak worked around in tags.dart).
      expect(f.deleteSync, returnsNormally);
      await tmp.delete(recursive: true);
    },
  );

  test(
    'readTags on an unreadable/unparseable file yields durationMs null',
    () async {
      final tmp = await Directory.systemTemp.createTemp('tags_dur');
      final f = File('${tmp.path}/Muse - New Born.mp3');
      await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
      final t = await readTags(f);
      expect(t.durationMs, isNull, reason: '64 zero bytes have no frames');
      // The estimator IS attempted here, and that matters: this test used to
      // assert the opposite -- that the fallback only runs once a parser has
      // matched -- and that assumption is exactly what left five real files
      // (Tiesto's "The Business", "AB2G Cygnus" and others) with a blank
      // Time column despite ffprobe reading them fine. No parser matching
      // says nothing about whether the frame headers are readable.
      // `durationProbed` records that the attempt happened, so a file that
      // genuinely cannot be measured is not retried on every launch.
      expect(t.durationProbed, isTrue);
      await tmp.delete(recursive: true);
    },
  );

  group('isMp3Path', () {
    test('matches .mp3 case-insensitively, not other extensions', () {
      expect(isMp3Path('song.mp3'), isTrue);
      expect(isMp3Path('Album/Song.MP3'), isTrue);
      expect(isMp3Path('Album/Song.Mp3'), isTrue);
      expect(isMp3Path('song.flac'), isFalse);
      expect(isMp3Path('song.m4a'), isFalse);
      expect(isMp3Path('song.mp3.bak'), isFalse);
      expect(isMp3Path('song'), isFalse);
    });
  });

  group('readTags: mp3 duration fallback wiring (mp3_duration.dart)', () {
    // A deterministic, machine-independent way to make `audio_metadata_reader`
    // itself yield a null duration (as opposed to relying on the exact
    // real-world condition seen in the Eminem - Relapse fixture, which isn't
    // reproducible from small synthetic bytes): its MP3Parser has no
    // MPEG2.5 branch in either `_getBitrate` or `_getSamplePerFrame` (see
    // audio_metadata_reader 1.6.0's `mp3.dart`), so for *any* MPEG2.5 file
    // it can never compute a duration via either its Xing-header path (needs
    // samplesPerFrame > 0) or its CBR-bytes-over-bitrate fallback (needs a
    // non-null bitrate) -- both silently no-op. This estimator's own
    // MPEG2.5 support (exercised directly in mp3_duration_test.dart) is what
    // fills the gap.
    List<int> id3v2Frames(Map<String, String> frames) {
      final frameBytes = <int>[];
      for (final e in frames.entries) {
        final text = [0x00, ...e.value.codeUnits];
        frameBytes.addAll(e.key.codeUnits);
        final size = text.length;
        frameBytes.addAll([
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ]);
        frameBytes.addAll([0x00, 0x00]);
        frameBytes.addAll(text);
      }
      final total = frameBytes.length;
      return [
        ...'ID3'.codeUnits,
        0x03,
        0x00,
        0x00,
        (total >> 21) & 0x7F,
        (total >> 14) & 0x7F,
        (total >> 7) & 0x7F,
        total & 0x7F,
        ...frameBytes,
      ];
    }

    /// MPEG2.5 Layer III, 24 kbps @ 11025 Hz CBR frames (frame length 313
    /// bytes -- matches the value independently verified in
    /// mp3_duration_test.dart's own MPEG2.5 case).
    List<int> mpeg25Frames(int frameCount) {
      const frameLen = 313;
      final header = [
        0xFF,
        0xE3,
        0x30,
        0x00,
      ]; // versionBits=0, layerBits=1(III), bitrateIndex=3, sampleRateIndex=0
      final out = <int>[];
      for (var i = 0; i < frameCount; i++) {
        out.addAll(header);
        out.addAll(List.filled(frameLen - header.length, 0x00));
      }
      return out;
    }

    test('a null-duration mp3 (per the tag parser) gets a duration from the '
        'stream-header fallback, and is marked durationProbed', () async {
      final tmp = await Directory.systemTemp.createTemp('mp3_fallback');
      final f = File('${tmp.path}/Some Artist - Some Title.mp3');
      await f.writeAsBytes([
        ...id3v2Frames({
          'TIT2': 'Some Title',
          'TPE1': 'Some Artist',
          'TALB': 'Some Album',
        }),
        ...mpeg25Frames(
          20,
        ), // 6260 bytes @ 24kbps -> 2086667us, see mp3_duration_test.dart
      ]);

      final t = await readTags(f);
      expect(t.title, 'Some Title');
      expect(t.artist, 'Some Artist');
      expect(t.album, 'Some Album');
      expect(t.durationMs, 2086); // 2086667us truncated to whole ms
      expect(t.durationProbed, isTrue);
      await tmp.delete(recursive: true);
    });

    test('a non-mp3 filename never reaches the fallback, even with the same '
        'MPEG2.5 bytes the .mp3 case above uses', () async {
      final tmp = await Directory.systemTemp.createTemp('mp3_fallback_ext');
      // audio_metadata_reader's MP3Parser is chosen purely by ID3 tag
      // presence, not extension -- so this still gets parsed as an mp3
      // container, but readTags's own extension gate (see [isMp3Path]) must
      // still refuse to run the fallback because the *file* isn't `.mp3`.
      final f = File('${tmp.path}/Some Artist - Some Title.wav');
      await f.writeAsBytes([
        ...id3v2Frames({'TIT2': 'Some Title', 'TPE1': 'Some Artist'}),
        ...mpeg25Frames(20),
      ]);

      final t = await readTags(f);
      expect(t.title, 'Some Title');
      expect(t.durationMs, isNull);
      expect(t.durationProbed, isFalse);
      await tmp.delete(recursive: true);
    });

    test('an mp3 whose tag parser DID find a duration is left alone -- no '
        'fallback attempted, durationProbed stays false', () async {
      final tmp = await Directory.systemTemp.createTemp('mp3_fallback_skip');
      // Plain MPEG1 CBR audio with a trailing ID3v1 tag (no ID3v2 -- MP3Parser
      // dispatches on hasID3v1Tag instead, then runs its own audio-frame
      // scan): audio_metadata_reader's own CBR bytes-over-bitrate fallback
      // (mp3.dart, `_parseAudioFrames`'s final `else if`) *does* compute a
      // duration for this shape (no Xing header, a directly-tabulated
      // MPEG1/LayerIII bitrate), so ours must not override it.
      const frameLen =
          417; // MPEG1 L3 128kbps/44100 -- see mp3_duration_test.dart
      final header = [0xFF, 0xFB, 0x90, 0x00];
      final f = File('${tmp.path}/track.mp3');
      final bytes = <int>[];
      for (var i = 0; i < 50; i++) {
        bytes.addAll(header);
        bytes.addAll(List.filled(frameLen - header.length, 0x00));
      }
      bytes.addAll([
        0x54,
        0x41,
        0x47,
        ...List.filled(125, 0x00),
      ]); // ID3v1 "TAG" trailer
      await f.writeAsBytes(bytes);

      final t = await readTags(f);
      expect(t.durationMs, isNotNull);
      expect(
        t.durationProbed,
        isFalse,
        reason:
            'the tag parser already produced a duration; the '
            'estimator must not have been invoked at all',
      );
      await tmp.delete(recursive: true);
    });
  });

  group('TrackTags json round-trip', () {
    test('durationMs round-trips through toJson/fromJson', () {
      const t = TrackTags(
        title: 'T',
        artist: 'A',
        album: 'B',
        genre: 'G',
        durationMs: 245000,
      );
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
