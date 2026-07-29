// Editing a FLAC's tags.
//
// Two of this library's three FLACs carry no artist or album at all -- they
// show up correctly in fooplayer only because it falls back to the filename.
// They are the files that most need this, and they are also the only lossless
// files here, so the bar is: rewrite the comments, touch nothing else, and
// leave the audio bit-identical.
//
// FLAC keeps its tags in a VORBIS_COMMENT metadata block whose lengths are
// LITTLE-endian, sitting inside block headers that are BIG-endian. That
// inconsistency is in the format, and getting it backwards makes a file that
// looks fine until something reads it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;

/// Audio frames: whatever bytes follow the metadata. Content is irrelevant --
/// what matters is that they come through untouched.
Uint8List _frames([int n = 2048]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 13) % 251]);

/// A FLAC with a STREAMINFO block, optionally a VORBIS_COMMENT and a PICTURE.
Uint8List _flac({List<String>? comments, String vendor = 'ref libFLAC 1.3.2',
    bool picture = false}) {
  final blocks = <(int, List<int>)>[
    (0, List<int>.filled(34, 0x11)), // STREAMINFO, fixed 34 bytes
    if (comments != null)
      (4, buildVorbisComment(vendor, comments)),
    if (picture) (6, buildFlacPictureBlock(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]), 'image/jpeg')),
  ];
  final out = <int>[0x66, 0x4C, 0x61, 0x43];
  for (var i = 0; i < blocks.length; i++) {
    final (type, body) = blocks[i];
    out.addAll([
      (i == blocks.length - 1 ? 0x80 : 0x00) | type,
      (body.length >> 16) & 0xff,
      (body.length >> 8) & 0xff,
      body.length & 0xff,
    ]);
    out.addAll(body);
  }
  out.addAll(_frames());
  return Uint8List.fromList(out);
}

/// The comments of the first VORBIS_COMMENT block, as FIELD=value strings.
({String vendor, List<String> comments}) _commentsOf(Uint8List flac) {
  final block = parseFlacBlocks(flac).blocks
      .where((b) => b.$1 == kFlacBlockVorbisComment)
      .first;
  return parseVorbisComment(block.$2);
}

void main() {
  test('a retag keeps the audio and the content ID', () {
    final before = _flac(comments: ['TITLE=Old', 'ARTIST=Someone']);
    final after = buildRetaggedFlac(
      before,
      const TagEdits(title: 'Destiny (Radio edit)', artist: 'Zero 7'),
    );

    expect(
      contentIdForBytes('x.flac', after),
      contentIdForBytes('x.flac', before),
    );
    expect(flacAudioBytesUnchanged(before, after), isTrue);

    final got = _commentsOf(after);
    expect(got.comments, contains('TITLE=Destiny (Radio edit)'));
    expect(got.comments, contains('ARTIST=Zero 7'));
    expect(got.comments.where((c) => c.startsWith('TITLE=')), hasLength(1));
  });

  test('a file with no comment block at all gains one', () {
    // This is the actual state of two of the three FLACs here.
    final before = _flac();
    final after = buildRetaggedFlac(
      before,
      const TagEdits(artist: 'Zero 7', album: 'Destiny CD Single'),
    );

    expect(
      contentIdForBytes('x.flac', after),
      contentIdForBytes('x.flac', before),
    );
    final got = _commentsOf(after);
    expect(got.comments, contains('ARTIST=Zero 7'));
    expect(got.comments, contains('ALBUM=Destiny CD Single'));
  });

  test('comments the edit does not name are preserved, vendor included', () {
    final before = _flac(
      vendor: 'reference libFLAC 1.2.1 20070917',
      comments: [
        'TITLE=Keep Me',
        'REPLAYGAIN_TRACK_GAIN=-3.21 dB',
        'MUSICBRAINZ_TRACKID=abc-123',
      ],
    );
    final after = buildRetaggedFlac(before, const TagEdits(artist: 'New'));
    final got = _commentsOf(after);

    expect(got.vendor, 'reference libFLAC 1.2.1 20070917');
    expect(got.comments, contains('TITLE=Keep Me'));
    expect(got.comments, contains('REPLAYGAIN_TRACK_GAIN=-3.21 dB'));
    expect(got.comments, contains('MUSICBRAINZ_TRACKID=abc-123'));
    expect(got.comments, contains('ARTIST=New'));
  });

  test('field names are matched case-insensitively', () {
    // Real files use every spelling; a lowercase `artist=` left in place
    // beside a new `ARTIST=` would make the file self-contradictory.
    final before = _flac(comments: ['artist=old spelling', 'Album=Mixed']);
    final after = buildRetaggedFlac(
      before,
      const TagEdits(artist: 'Correct', album: 'Also Correct'),
    );
    final got = _commentsOf(after);

    expect(got.comments.where((c) => c.toUpperCase().startsWith('ARTIST=')),
        hasLength(1));
    expect(got.comments, contains('ARTIST=Correct'));
    expect(got.comments.where((c) => c.toUpperCase().startsWith('ALBUM=')),
        hasLength(1));
  });

  test('an empty value removes the field', () {
    final before = _flac(comments: ['TITLE=Keep', 'ALBUM=2012-11']);
    final after = buildRetaggedFlac(before, const TagEdits(album: ''));
    final got = _commentsOf(after);

    expect(got.comments, contains('TITLE=Keep'));
    expect(got.comments.any((c) => c.toUpperCase().startsWith('ALBUM=')),
        isFalse);
  });

  test('the cover art survives a text edit', () {
    final before = _flac(comments: ['TITLE=x'], picture: true);
    final after = buildRetaggedFlac(before, const TagEdits(artist: 'y'));

    expect(
      parseFlacBlocks(after).blocks.where((b) => b.$1 == kFlacBlockPicture),
      hasLength(1),
    );
  });

  test('unicode round-trips as UTF-8', () {
    final before = _flac(comments: ['TITLE=x']);
    final after = buildRetaggedFlac(
      before,
      const TagEdits(artist: 'Sigur Rós', album: 'Ágætis byrjun'),
    );
    final got = _commentsOf(after);

    expect(got.comments, contains('ARTIST=Sigur Rós'));
    expect(got.comments, contains('ALBUM=Ágætis byrjun'));
  });

  test('an empty edit is a no-op', () {
    final before = _flac(comments: ['TITLE=x']);
    expect(buildRetaggedFlac(before, const TagEdits()), before);
  });

  test('something that is not a FLAC is refused', () {
    final notFlac = Uint8List.fromList([
      ...latin1.encode('RIFF'),
      ...List<int>.filled(64, 0),
    ]);
    expect(
      () => buildRetaggedFlac(notFlac, const TagEdits(title: 'x')),
      throwsA(isA<EmbedException>()),
    );
  });

  test('a truncated block is refused rather than half-read', () {
    final broken = Uint8List.fromList([
      0x66, 0x4C, 0x61, 0x43,
      0x80, 0xFF, 0xFF, 0xFF, // last block, absurd length
      1, 2, 3,
    ]);
    expect(
      () => buildRetaggedFlac(broken, const TagEdits(title: 'x')),
      throwsA(isA<EmbedException>()),
    );
  });
}
