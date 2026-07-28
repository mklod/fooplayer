// Embedding cover art into the audio file's own tags (so every other player
// -- foobar2000, Kodi, Explorer thumbnails, a phone's stock app -- sees the
// artwork fooplayer found, without scattering folder.jpg files around).
//
// THE ONE INVARIANT THIS FILE EXISTS TO PROTECT: a track's content ID must
// not change. The ID is a SHA-256 over the file's AUDIO byte range only --
// `mp3AudioRange` skips a leading ID3v2 tag and any trailing ID3v1/APEv2
// block -- so rewriting the tag leaves the hashed bytes untouched *provided*
// every byte from the old audio start to EOF is copied through verbatim.
// That is exactly what [buildTaggedMp3] does, and [embedResultIsSafe] proves
// it per file rather than trusting the reasoning.
//
// Deliberately NOT handled here (the caller refuses these files instead of
// this code guessing):
//   - anything whose audio doesn't begin with an MPEG frame sync. A file
//     that is really MP4 or RIFF wearing an .mp3 name would be silently
//     corrupted by prepending an ID3 tag -- worse, that is precisely what
//     made "MrSuicideSheep - Best of 2025" unplayable.
//   - unsynchronised tags, extended headers and footers. None exist in this
//     library (surveyed 2026-07-27: 3779 v2.3, 1644 untagged, 47 v2.2,
//     40 v2.4, zero awkward flags), and supporting them unverified would be
//     writing code no file exercises.
//
// Last modified: 2026-07-27--1955

import 'dart:convert';
import 'dart:typed_data';

/// Picture type 3 -- "cover (front)". The only one written here.
const int kApicFrontCover = 0x03;

/// Zero bytes left after the frames so a later tag edit by another tool can
/// grow a little without rewriting the whole file. Conventional, cheap.
const int kTagPadding = 1024;

/// Why a file was refused. Every one of these means "left completely
/// untouched", never a partial write.
enum EmbedRefusal {
  /// Audio doesn't start with an MPEG frame sync -- not really an MP3.
  notMpeg,

  /// Tag uses unsynchronisation / an extended header / a footer.
  unsupportedTagFlags,

  /// The image bytes aren't a JPEG or PNG.
  unsupportedImage,

  /// Rebuilding would have changed the hashed audio range. Cannot happen by
  /// construction; checked anyway, because silently re-dating a track is a
  /// worse outcome than skipping it.
  audioRangeChanged,
}

class EmbedException implements Exception {
  final EmbedRefusal refusal;
  final String message;
  const EmbedException(this.refusal, this.message);
  @override
  String toString() => 'EmbedException(${refusal.name}): $message';
}

/// One parsed frame, kept as raw bytes: frames we don't understand are
/// copied through untouched rather than re-encoded.
class Id3Frame {
  final String id;
  final Uint8List data;
  const Id3Frame(this.id, this.data);
}

/// What a file's leading ID3v2 tag (if any) contains.
class Id3Tag {
  /// 2, 3 or 4 for ID3v2.2/2.3/2.4; 0 when the file has no tag at all.
  final int major;

  /// Bytes the tag occupies at the head of the file (0 when absent).
  final int size;

  final List<Id3Frame> frames;

  const Id3Tag({required this.major, required this.size, required this.frames});

  bool get present => size > 0;
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _be24(List<int> b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];

void _writeSyncsafe(List<int> out, int v) {
  out.addAll([(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f]);
}

void _writeBe32(List<int> out, int v) {
  out.addAll([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
}

/// ID3v2.2's 3-character frame IDs mapped onto their v2.3 equivalents. Frame
/// *data* layout is unchanged for these (same text-encoding byte, same
/// terminator rules), so upgrading is a pure rename. Anything not listed is
/// dropped -- v2.2 is 47 files here, and an obscure frame is not worth
/// guessing at.
const Map<String, String> kV22ToV23 = {
  'TT2': 'TIT2', // title
  'TP1': 'TPE1', // lead artist
  'TP2': 'TPE2', // band / album artist
  'TAL': 'TALB', // album
  'TRK': 'TRCK', // track number
  'TYE': 'TYER', // year
  'TCO': 'TCON', // genre
  'TCM': 'TCOM', // composer
  'TPA': 'TPOS', // part of set
  'TEN': 'TENC', // encoded by
  'COM': 'COMM', // comment
  'ULT': 'USLT', // lyrics
  'PIC': 'APIC', // picture (dropped anyway -- we write our own)
};

/// The 128-byte ID3v1 trailer, or null when there isn't one.
///
/// This block is EXCLUDED from the hashed audio range and is preserved
/// verbatim by the rewrite -- reading it here is purely so its fields can be
/// promoted into the new ID3v2 tag (see [framesFromId3v1]).
Uint8List? id3v1TrailerOf(Uint8List b) {
  if (b.length < 128) return null;
  final o = b.length - 128;
  if (b[o] != 0x54 || b[o + 1] != 0x41 || b[o + 2] != 0x47) return null;
  return Uint8List.sublistView(b, o);
}

/// ID3v1's fixed genre table (Winamp's extensions included). Index 255 and
/// anything past the end means "unset".
const List<String> kId3v1Genres = [
  'Blues',
  'Classic Rock',
  'Country',
  'Dance',
  'Disco',
  'Funk',
  'Grunge',
  'Hip-Hop',
  'Jazz',
  'Metal',
  'New Age',
  'Oldies',
  'Other',
  'Pop',
  'R&B',
  'Rap',
  'Reggae',
  'Rock',
  'Techno',
  'Industrial',
  'Alternative',
  'Ska',
  'Death Metal',
  'Pranks',
  'Soundtrack',
  'Euro-Techno',
  'Ambient',
  'Trip-Hop',
  'Vocal',
  'Jazz+Funk',
  'Fusion',
  'Trance',
  'Classical',
  'Instrumental',
  'Acid',
  'House',
  'Game',
  'Sound Clip',
  'Gospel',
  'Noise',
  'Alternative Rock',
  'Bass',
  'Soul',
  'Punk',
  'Space',
  'Meditative',
  'Instrumental Pop',
  'Instrumental Rock',
  'Ethnic',
  'Gothic',
  'Darkwave',
  'Techno-Industrial',
  'Electronic',
  'Pop-Folk',
  'Eurodance',
  'Dream',
  'Southern Rock',
  'Comedy',
  'Cult',
  'Gangsta',
  'Top 40',
  'Christian Rap',
  'Pop/Funk',
  'Jungle',
  'Native US',
  'Cabaret',
  'New Wave',
  'Psychedelic',
  'Rave',
  'Showtunes',
  'Trailer',
  'Lo-Fi',
  'Tribal',
  'Acid Punk',
  'Acid Jazz',
  'Polka',
  'Retro',
  'Musical',
  'Rock & Roll',
  'Hard Rock',
];

String _v1Field(Uint8List v1, int start, int len) {
  var end = start + len;
  while (end > start && (v1[end - 1] == 0 || v1[end - 1] == 0x20)) {
    end--;
  }
  if (end <= start) return '';
  return latin1.decode(Uint8List.sublistView(v1, start, end));
}

/// Promotes an ID3v1 trailer's fields into ID3v2.3 text frames.
///
/// Needed because 1643 of this library's 1644 ID3v2-less MP3s carry an ID3v1
/// tag: give such a file a new ID3v2 tag containing only a picture and every
/// player that prefers v2 over v1 (foobar2000, Kodi, ...) would suddenly show
/// it as untitled. The v1 block itself stays in the file, so nothing is
/// moved -- only copied forward.
List<Id3Frame> framesFromId3v1(Uint8List v1) {
  Id3Frame? text(String id, String value) => value.isEmpty
      ? null
      : Id3Frame(id, Uint8List.fromList([0x00, ...latin1.encode(value)]));

  final frames = <Id3Frame?>[
    text('TIT2', _v1Field(v1, 3, 30)),
    text('TPE1', _v1Field(v1, 33, 30)),
    text('TALB', _v1Field(v1, 63, 30)),
    text('TYER', _v1Field(v1, 93, 4)),
  ];
  // ID3v1.1: a zero at byte 125 with a non-zero at 126 means the last
  // comment byte is really the track number.
  if (v1[125] == 0 && v1[126] != 0) {
    frames.add(text('TRCK', v1[126].toString()));
  }
  final g = v1[127];
  if (g < kId3v1Genres.length) frames.add(text('TCON', kId3v1Genres[g]));
  return [for (final f in frames) ?f];
}

/// True when [b] at [o] looks like an MPEG audio frame sync.
bool hasMpegSyncAt(Uint8List b, int o) =>
    o + 1 < b.length && b[o] == 0xFF && (b[o + 1] & 0xE0) == 0xE0;

/// Parses the leading ID3v2 tag. Returns an absent tag (size 0) when the
/// file has none. Throws [EmbedException] for the tag shapes this file
/// deliberately refuses.
Id3Tag parseId3(Uint8List b) {
  if (b.length < 10 || b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) {
    return const Id3Tag(major: 0, size: 0, frames: []);
  }
  final major = b[3];
  final flags = b[5];
  if (flags & 0x80 != 0) {
    throw const EmbedException(
      EmbedRefusal.unsupportedTagFlags,
      'unsynchronised tag',
    );
  }
  if (flags & 0x40 != 0) {
    throw const EmbedException(
      EmbedRefusal.unsupportedTagFlags,
      'extended header',
    );
  }
  if (flags & 0x10 != 0) {
    throw const EmbedException(EmbedRefusal.unsupportedTagFlags, 'tag footer');
  }
  if (major != 2 && major != 3 && major != 4) {
    throw EmbedException(
      EmbedRefusal.unsupportedTagFlags,
      'unknown ID3v2.$major',
    );
  }

  final bodySize = _syncsafe(b, 6);
  final tagSize = 10 + bodySize;
  final end = tagSize > b.length ? b.length : tagSize;

  final frames = <Id3Frame>[];
  var o = 10;
  final headerLen = major == 2 ? 6 : 10;
  while (o + headerLen <= end) {
    if (b[o] == 0) break; // padding begins
    final String id;
    final int size;
    if (major == 2) {
      id = latin1.decode(b.sublist(o, o + 3));
      size = _be24(b, o + 3);
    } else {
      id = latin1.decode(b.sublist(o, o + 4));
      // v2.4 sizes are syncsafe; v2.3's are plain big-endian.
      size = major == 4 ? _syncsafe(b, o + 4) : _be32(b, o + 4);
    }
    final dataStart = o + headerLen;
    if (size < 0 || dataStart + size > end) break; // truncated -- stop cleanly
    frames.add(
      Id3Frame(id, Uint8List.sublistView(b, dataStart, dataStart + size)),
    );
    o = dataStart + size;
  }
  return Id3Tag(major: major, size: tagSize, frames: frames);
}

/// The byte offset where audio begins: past any leading ID3v2 tag.
int audioStartOf(Uint8List b) => parseId3(b).size;

/// `image/jpeg` or `image/png` for [image], or null when it is neither.
String? imageMimeOf(Uint8List image) {
  if (image.length > 3 &&
      image[0] == 0xFF &&
      image[1] == 0xD8 &&
      image[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (image.length > 8 &&
      image[0] == 0x89 &&
      image[1] == 0x50 &&
      image[2] == 0x4E &&
      image[3] == 0x47) {
    return 'image/png';
  }
  return null;
}

/// Builds the APIC frame body (identical layout in v2.3 and v2.4):
/// encoding, MIME (latin1, NUL-terminated), picture type, description
/// (NUL-terminated), then the image.
Uint8List buildApicBody(Uint8List image, String mime) {
  final out = <int>[];
  out.add(0x00); // ISO-8859-1 -- the description is empty, so this is safe
  out.addAll(latin1.encode(mime));
  out.add(0x00);
  out.add(kApicFrontCover);
  out.add(0x00); // empty description
  out.addAll(image);
  return Uint8List.fromList(out);
}

/// Returns the complete new file: a rebuilt ID3v2 tag carrying [image] as
/// its front cover, followed by every original byte from the old audio start
/// to EOF -- untouched, trailing ID3v1/APEv2 blocks included.
///
/// The output tag keeps the input's ID3v2 version (v2.2 is upgraded to v2.3,
/// which is a pure frame-ID rename; a file with no tag gets a fresh v2.3),
/// so existing frames are copied byte-for-byte and no text ever gets
/// re-encoded behind the user's back.
Uint8List buildTaggedMp3(Uint8List original, Uint8List image) {
  final mime = imageMimeOf(image);
  if (mime == null) {
    throw const EmbedException(
      EmbedRefusal.unsupportedImage,
      'image is neither JPEG nor PNG',
    );
  }
  final tag = parseId3(original);
  final audioStart = tag.size;
  if (!hasMpegSyncAt(original, audioStart)) {
    throw const EmbedException(
      EmbedRefusal.notMpeg,
      'no MPEG frame sync where the audio should start',
    );
  }

  // v2.2 upgrades to v2.3; everything else keeps its version.
  final outMajor = tag.major == 2 ? 3 : (tag.major == 0 ? 3 : tag.major);

  final kept = <Id3Frame>[];
  for (final f in tag.frames) {
    var id = f.id;
    if (tag.major == 2) {
      final mapped = kV22ToV23[id];
      if (mapped == null) continue; // unknown v2.2 frame -- dropped
      id = mapped;
    }
    if (id == 'APIC' || id == 'PIC') continue; // replaced below
    if (f.data.isEmpty) continue;
    kept.add(Id3Frame(id, f.data));
  }
  // A file whose only metadata is an ID3v1 trailer would be left looking
  // untitled in any player that prefers ID3v2 once we add one, so carry the
  // v1 fields forward first (the v1 block itself is preserved regardless).
  if (kept.isEmpty) {
    final v1 = id3v1TrailerOf(original);
    if (v1 != null) kept.addAll(framesFromId3v1(v1));
  }
  kept.add(Id3Frame('APIC', buildApicBody(image, mime)));

  final body = <int>[];
  for (final f in kept) {
    body.addAll(latin1.encode(f.id.padRight(4).substring(0, 4)));
    if (outMajor == 4) {
      _writeSyncsafe(body, f.data.length);
    } else {
      _writeBe32(body, f.data.length);
    }
    body.addAll([0x00, 0x00]); // frame flags
    body.addAll(f.data);
  }
  body.addAll(List<int>.filled(kTagPadding, 0));

  final out = BytesBuilder(copy: false);
  final header = <int>[0x49, 0x44, 0x33, outMajor, 0x00, 0x00];
  _writeSyncsafe(header, body.length);
  out.add(header);
  out.add(body);
  out.add(Uint8List.sublistView(original, audioStart));
  return out.takeBytes();
}

/// Proves the rewrite preserved identity: the bytes `mp3AudioRange` would
/// hash are the same before and after. Compares the ranges directly instead
/// of hashing, so it costs nothing and can run on every file.
bool audioBytesUnchanged(Uint8List before, Uint8List after) {
  final a = Uint8List.sublistView(before, audioStartOf(before));
  final b = Uint8List.sublistView(after, audioStartOf(after));
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// FLAC
//
// FLAC needs no conversion to carry a cover: `flacAudioRange` skips the
// metadata blocks, so replacing/adding a PICTURE block leaves the hashed
// audio frames untouched -- the same identity guarantee MP3 gets, without
// re-encoding a lossless file into a lossy one.
// ---------------------------------------------------------------------------

/// FLAC metadata block type for an attached picture.
const int kFlacBlockPicture = 6;

/// FLAC metadata block type for padding.
const int kFlacBlockPadding = 1;

/// Picture dimensions parsed out of the image itself. The FLAC PICTURE block
/// carries width/height/depth inline; zeros are legal but make some taggers
/// show a cover as 0x0, so they're read properly rather than faked.
class ImageDims {
  final int width;
  final int height;
  final int depth;
  const ImageDims(this.width, this.height, this.depth);
}

/// Reads dimensions from a PNG header or a JPEG's first SOF marker.
/// Falls back to zeros (permitted by the spec) if the structure is unexpected.
ImageDims imageDimsOf(Uint8List b) {
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
    // PNG: IHDR width/height are big-endian at offsets 16 and 20.
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    final bitDepth = b[24];
    return ImageDims(w, h, bitDepth * 3);
  }
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var o = 2;
    while (o + 9 < b.length) {
      if (b[o] != 0xFF) {
        o++;
        continue;
      }
      final marker = b[o + 1];
      // SOF0..SOF15, excluding the non-frame markers DHT/JPG/DAC.
      final isSof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      final segLen = (b[o + 2] << 8) | b[o + 3];
      if (isSof) {
        final h = (b[o + 5] << 8) | b[o + 6];
        final w = (b[o + 7] << 8) | b[o + 8];
        final components = b[o + 9];
        return ImageDims(w, h, b[o + 4] * components);
      }
      o += 2 + segLen;
    }
  }
  return const ImageDims(0, 0, 0);
}

void _writeBe32At(List<int> out, int v) {
  out.addAll([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
}

/// The body of a FLAC METADATA_BLOCK_PICTURE (everything after the 4-byte
/// block header): type, MIME, description, dimensions, then the image.
Uint8List buildFlacPictureBlock(Uint8List image, String mime) {
  final dims = imageDimsOf(image);
  final out = <int>[];
  _writeBe32At(out, kApicFrontCover);
  final mimeBytes = latin1.encode(mime);
  _writeBe32At(out, mimeBytes.length);
  out.addAll(mimeBytes);
  _writeBe32At(out, 0); // empty description
  _writeBe32At(out, dims.width);
  _writeBe32At(out, dims.height);
  _writeBe32At(out, dims.depth);
  _writeBe32At(out, 0); // indexed-colour count; 0 for non-indexed
  _writeBe32At(out, image.length);
  out.addAll(image);
  return Uint8List.fromList(out);
}

/// Returns the complete new FLAC file carrying [image] as its front cover.
///
/// Every existing metadata block except PICTURE and PADDING is preserved in
/// order (STREAMINFO stays first, as the format requires), and the audio
/// frames after the metadata are copied verbatim -- so the content ID is
/// unchanged. Throws [EmbedException] if this isn't a FLAC stream.
Uint8List buildTaggedFlac(Uint8List original, Uint8List image) {
  final mime = imageMimeOf(image);
  if (mime == null) {
    throw const EmbedException(
      EmbedRefusal.unsupportedImage,
      'image is neither JPEG nor PNG',
    );
  }
  if (original.length < 8 ||
      original[0] != 0x66 ||
      original[1] != 0x4C ||
      original[2] != 0x61 ||
      original[3] != 0x43) {
    throw const EmbedException(
      EmbedRefusal.notMpeg,
      'not a FLAC stream (no fLaC marker at offset 0)',
    );
  }

  final kept = <(int, Uint8List)>[]; // (block type, block body)
  var o = 4;
  var sawLast = false;
  while (o + 4 <= original.length && !sawLast) {
    final header = original[o];
    sawLast = (header & 0x80) != 0;
    final type = header & 0x7f;
    final len =
        (original[o + 1] << 16) | (original[o + 2] << 8) | original[o + 3];
    final bodyStart = o + 4;
    if (bodyStart + len > original.length) {
      throw const EmbedException(
        EmbedRefusal.unsupportedTagFlags,
        'truncated FLAC metadata block',
      );
    }
    if (type != kFlacBlockPicture && type != kFlacBlockPadding) {
      kept.add((
        type,
        Uint8List.sublistView(original, bodyStart, bodyStart + len),
      ));
    }
    o = bodyStart + len;
  }
  final audioStart = o;

  kept.add((kFlacBlockPicture, buildFlacPictureBlock(image, mime)));

  final out = BytesBuilder(copy: false);
  out.add(Uint8List.fromList([0x66, 0x4C, 0x61, 0x43]));
  for (var i = 0; i < kept.length; i++) {
    final (type, body) = kept[i];
    final isLast = i == kept.length - 1;
    out.add(
      Uint8List.fromList([
        (isLast ? 0x80 : 0x00) | type,
        (body.length >> 16) & 0xff,
        (body.length >> 8) & 0xff,
        body.length & 0xff,
      ]),
    );
    out.add(body);
  }
  out.add(Uint8List.sublistView(original, audioStart));
  return out.takeBytes();
}

/// Offset where FLAC audio frames begin (past all metadata blocks).
int flacAudioStartOf(Uint8List b) {
  if (b.length < 8 ||
      b[0] != 0x66 ||
      b[1] != 0x4C ||
      b[2] != 0x61 ||
      b[3] != 0x43) {
    return 0;
  }
  var o = 4;
  var last = false;
  while (o + 4 <= b.length && !last) {
    last = (b[o] & 0x80) != 0;
    final len = (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    o += 4 + len;
  }
  return o > b.length ? b.length : o;
}

/// FLAC counterpart of [audioBytesUnchanged].
bool flacAudioBytesUnchanged(Uint8List before, Uint8List after) {
  final a = Uint8List.sublistView(before, flacAudioStartOf(before));
  final b = Uint8List.sublistView(after, flacAudioStartOf(after));
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
