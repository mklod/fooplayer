// Cover-art embedding: the identity invariant above all else.
//
// Every test here ultimately asks one question -- did the CONTENT ID change?
// -- because a changed ID means the track looks like a brand-new file to the
// manifest and silently loses the "date downloaded" this whole project
// exists to protect. The ID is computed with fooplayer_core's real hashing,
// not a local re-implementation, so these tests fail if the core's audio
// range logic ever drifts away from what the embedder assumes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;

/// A believable MPEG frame: sync, then filler. Content is irrelevant -- what
/// matters is that these bytes survive untouched.
Uint8List _audio([int n = 4096]) {
  final b = Uint8List(n);
  b[0] = 0xFF;
  b[1] = 0xFB; // MPEG-1 Layer III
  b[2] = 0x90;
  b[3] = 0x00;
  for (var i = 4; i < n; i++) {
    b[i] = i % 251;
  }
  return b;
}

Uint8List _jpeg([int n = 512]) {
  final b = Uint8List(n);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  for (var i = 3; i < n; i++) {
    b[i] = (i * 7) % 253;
  }
  return b;
}

Uint8List _png() =>
    Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

/// A text frame body: encoding byte + latin1 text.
Uint8List _text(String s) => Uint8List.fromList([0x00, ...latin1.encode(s)]);

void _writeSyncsafe(List<int> out, int v) =>
    out.addAll([(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f]);

/// Builds a file with an ID3v2 tag of the given [major] version carrying
/// [frames], followed by [audio].
Uint8List _fileWithTag({
  required int major,
  required List<(String, Uint8List)> frames,
  required Uint8List audio,
  int padding = 0,
}) {
  final body = <int>[];
  for (final (id, data) in frames) {
    if (major == 2) {
      body.addAll(latin1.encode(id.substring(0, 3)));
      body.addAll([
        (data.length >> 16) & 0xff,
        (data.length >> 8) & 0xff,
        data.length & 0xff,
      ]);
    } else {
      body.addAll(latin1.encode(id.padRight(4).substring(0, 4)));
      if (major == 4) {
        _writeSyncsafe(body, data.length);
      } else {
        body.addAll([
          (data.length >> 24) & 0xff,
          (data.length >> 16) & 0xff,
          (data.length >> 8) & 0xff,
          data.length & 0xff,
        ]);
      }
      body.addAll([0, 0]);
    }
    body.addAll(data);
  }
  body.addAll(List<int>.filled(padding, 0));
  final out = <int>[0x49, 0x44, 0x33, major, 0x00, 0x00];
  _writeSyncsafe(out, body.length);
  out.addAll(body);
  out.addAll(audio);
  return Uint8List.fromList(out);
}

void main() {
  group('content ID survives embedding', () {
    test('file with no tag at all gains a cover, keeps its identity', () {
      final audio = _audio();
      final before = Uint8List.fromList(audio);
      final after = buildTaggedMp3(before, _jpeg());

      expect(contentIdForBytes('x.mp3', after),
          contentIdForBytes('x.mp3', before));
      expect(audioBytesUnchanged(before, after), isTrue);
      expect(after.length, greaterThan(before.length));
      expect(parseId3(after).major, 3, reason: 'fresh tags are written v2.3');
    });

    test('v2.3 tag without art: existing frames are preserved verbatim', () {
      final before = _fileWithTag(major: 3, frames: [
        ('TIT2', _text('Sorry, Blame It on Me')),
        ('TPE1', _text('Akon')),
        ('TALB', _text('2007-08')),
      ], audio: _audio());
      final after = buildTaggedMp3(before, _jpeg());

      expect(contentIdForBytes('a.mp3', after),
          contentIdForBytes('a.mp3', before));
      final frames = {for (final f in parseId3(after).frames) f.id: f.data};
      expect(latin1.decode(frames['TIT2']!.sublist(1)), 'Sorry, Blame It on Me');
      expect(latin1.decode(frames['TPE1']!.sublist(1)), 'Akon');
      expect(latin1.decode(frames['TALB']!.sublist(1)), '2007-08');
      expect(frames.containsKey('APIC'), isTrue);
    });

    test('v2.3 tag that already has art: the old picture is replaced, not '
        'duplicated', () {
      final oldArt = buildApicBody(_jpeg(2048), 'image/jpeg');
      final before = _fileWithTag(major: 3, frames: [
        ('TIT2', _text('Le missile est lance')),
        ('APIC', oldArt),
      ], audio: _audio());

      final newArt = _png();
      final after = buildTaggedMp3(before, newArt);

      expect(contentIdForBytes('k.mp3', after),
          contentIdForBytes('k.mp3', before));
      final apics =
          parseId3(after).frames.where((f) => f.id == 'APIC').toList();
      expect(apics, hasLength(1), reason: 'exactly one cover, never two');
      expect(apics.single.data.length, lessThan(oldArt.length),
          reason: 'the new (smaller) picture replaced the old one');
      // MIME is rewritten to match the new bytes, not inherited.
      expect(latin1.decode(apics.single.data.sublist(1, 10)), 'image/png');
    });

    test('v2.4 stays v2.4 (syncsafe frame sizes), v2.2 upgrades to v2.3', () {
      final v24 = _fileWithTag(
          major: 4, frames: [('TIT2', _text('Four'))], audio: _audio());
      final outV24 = buildTaggedMp3(v24, _jpeg());
      expect(parseId3(outV24).major, 4);
      expect(contentIdForBytes('v.mp3', outV24), contentIdForBytes('v.mp3', v24));
      final f24 = {for (final f in parseId3(outV24).frames) f.id: f.data};
      expect(latin1.decode(f24['TIT2']!.sublist(1)), 'Four');

      final v22 = _fileWithTag(major: 2, frames: [
        ('TT2', _text('Comfortable')),
        ('TP1', _text('Lil Wayne')),
      ], audio: _audio());
      final outV22 = buildTaggedMp3(v22, _jpeg());
      expect(parseId3(outV22).major, 3);
      expect(contentIdForBytes('w.mp3', outV22), contentIdForBytes('w.mp3', v22));
      final f22 = {for (final f in parseId3(outV22).frames) f.id: f.data};
      expect(latin1.decode(f22['TIT2']!.sublist(1)), 'Comfortable',
          reason: 'TT2 -> TIT2');
      expect(latin1.decode(f22['TPE1']!.sublist(1)), 'Lil Wayne',
          reason: 'TP1 -> TPE1');
    });

    test('a trailing ID3v1 block is carried through untouched', () {
      // ID3v1 sits in the last 128 bytes and is EXCLUDED from the hashed
      // range, so it must survive the rewrite or other tools lose data.
      final v1 = Uint8List(128);
      v1[0] = 0x54; // 'T'
      v1[1] = 0x41; // 'A'
      v1[2] = 0x47; // 'G'
      for (var i = 3; i < 128; i++) {
        v1[i] = i;
      }
      final before = Uint8List.fromList([..._audio(), ...v1]);
      final after = buildTaggedMp3(before, _jpeg());

      expect(contentIdForBytes('t.mp3', after),
          contentIdForBytes('t.mp3', before));
      expect(after.sublist(after.length - 128), v1);
    });

    test('embedding twice is idempotent in identity and cover count', () {
      final before = _fileWithTag(
          major: 3, frames: [('TIT2', _text('Twice'))], audio: _audio());
      final once = buildTaggedMp3(before, _jpeg());
      final twice = buildTaggedMp3(once, _jpeg(600));

      expect(contentIdForBytes('i.mp3', twice),
          contentIdForBytes('i.mp3', before));
      expect(parseId3(twice).frames.where((f) => f.id == 'APIC'), hasLength(1));
    });
  });

  group('refusals -- a file we cannot prove safe is left alone', () {
    test('MP4 wearing an .mp3 name is refused (the sheep pathology)', () {
      // ID3 tag, then 'ftyp' where MPEG frames should be. Prepending a tag
      // to this is exactly what made that file unplayable.
      final mp4ish = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x1c,
        ...latin1.encode('ftypisom'),
        ...List<int>.filled(2048, 0x41),
      ]);
      final before = _fileWithTag(
          major: 3, frames: [('TIT2', _text('Fake'))], audio: mp4ish);

      expect(
          () => buildTaggedMp3(before, _jpeg()),
          throwsA(isA<EmbedException>()
              .having((e) => e.refusal, 'refusal', EmbedRefusal.notMpeg)));
    });

    test('a non-image payload is refused', () {
      final before = Uint8List.fromList(_audio());
      expect(
          () => buildTaggedMp3(before, Uint8List.fromList(latin1.encode('<html>'))),
          throwsA(isA<EmbedException>().having(
              (e) => e.refusal, 'refusal', EmbedRefusal.unsupportedImage)));
    });

    test('unsynchronised / extended-header / footer tags are refused', () {
      for (final (flag, label) in [
        (0x80, 'unsync'),
        (0x40, 'extended header'),
        (0x10, 'footer'),
      ]) {
        final f = _fileWithTag(
            major: 3, frames: [('TIT2', _text('x'))], audio: _audio());
        f[5] = flag;
        expect(
            () => buildTaggedMp3(f, _jpeg()),
            throwsA(isA<EmbedException>().having((e) => e.refusal, 'refusal',
                EmbedRefusal.unsupportedTagFlags)),
            reason: label);
      }
    });
  });
}
