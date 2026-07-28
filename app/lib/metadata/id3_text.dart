// Reading ID3 text frames ourselves, because the upstream parser drops real
// tags on real files in this library.
//
// Three failures, all confirmed against actual albums:
//   * frames after a large picture are never reached -- "Lil Wayne - Tha
//     Carter III" keeps TPE1 *after* a 307 KB APIC, and the artist came back
//     null for all 18 tracks;
//   * ID3v2.2's 3-character frame IDs (TP1/TT2/TAL) aren't mapped at all --
//     Portishead's "Dummy", Sleigh Bells' "Treats" and Sneaker Pimps'
//     "Becoming X" are all fully tagged and all showed no artist;
//   * stacked tags (an ID3v2.3 immediately followed by an ID3v2.4, as on
//     "Tayyib Ali - Keystone State Of Mind") make it give up entirely.
//
// This walks every leading tag and every frame within it, whatever their
// size, and is only ever consulted to FILL GAPS the upstream parser left --
// it is not a replacement for it (that parser still handles FLAC, MP4, OGG,
// APE, and every text encoding subtlety we don't want to reimplement).
//
// Last modified: 2026-07-28--0030

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Upper bound on how much of a file's head is read looking for tags. Real
/// tags here run to ~440 KB (cover art inside the tag); beyond this a file is
/// pathological and not worth the network round trips.
const int kMaxId3ReadBytes = 3 * 1024 * 1024;

/// ID3v2.2's 3-character frame IDs, mapped to the v2.3/v2.4 names used as
/// keys in the returned map.
const Map<String, String> kId3v22Aliases = {
  'TT2': 'TIT2',
  'TP1': 'TPE1',
  'TP2': 'TPE2',
  'TAL': 'TALB',
  'TRK': 'TRCK',
  'TYE': 'TYER',
  'TCO': 'TCON',
  'TCM': 'TCOM',
  'TPA': 'TPOS',
};

/// Text frames we care about; anything else is skipped without decoding.
const Set<String> _wanted = {
  'TIT2',
  'TPE1',
  'TPE2',
  'TALB',
  'TCON',
  'TRCK',
  'TYER',
};

int _syncsafe(Uint8List b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

String _decode(Uint8List data) {
  if (data.isEmpty) return '';
  final enc = data[0];
  final raw = Uint8List.sublistView(data, 1);
  try {
    switch (enc) {
      case 0:
        return latin1.decode(raw, allowInvalid: true);
      case 1:
        return _decodeUtf16(raw);
      case 2:
        return _decodeUtf16(raw, bigEndian: true);
      case 3:
        return utf8.decode(raw, allowMalformed: true);
      default:
        return latin1.decode(raw, allowInvalid: true);
    }
  } catch (_) {
    return '';
  }
}

String _decodeUtf16(Uint8List raw, {bool bigEndian = false}) {
  var i = 0;
  var be = bigEndian;
  if (raw.length >= 2) {
    if (raw[0] == 0xFF && raw[1] == 0xFE) {
      be = false;
      i = 2;
    } else if (raw[0] == 0xFE && raw[1] == 0xFF) {
      be = true;
      i = 2;
    }
  }
  final units = <int>[];
  for (; i + 1 < raw.length; i += 2) {
    units.add(be ? (raw[i] << 8) | raw[i + 1] : raw[i] | (raw[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// Text frames from every leading ID3v2 tag in [bytes], keyed by their
/// v2.3/v2.4 frame ID. A value already found is not overwritten by a later
/// (stacked) tag, so the first tag wins -- matching what a player reading
/// only the first tag would show.
Map<String, String> parseId3TextFrames(Uint8List bytes) {
  final out = <String, String>{};
  var tagStart = 0;

  while (tagStart + 10 <= bytes.length &&
      bytes[tagStart] == 0x49 &&
      bytes[tagStart + 1] == 0x44 &&
      bytes[tagStart + 2] == 0x33) {
    final major = bytes[tagStart + 3];
    final flags = bytes[tagStart + 5];
    final bodySize = _syncsafe(bytes, tagStart + 6);
    final tagEnd = tagStart + 10 + bodySize + ((flags & 0x10) != 0 ? 10 : 0);
    if (bodySize <= 0) break;

    var o = tagStart + 10;
    // An extended header (rare) sits before the frames; skip it by its own
    // declared size rather than guessing.
    if ((flags & 0x40) != 0 && o + 4 <= bytes.length) {
      final extSize = major == 4
          ? _syncsafe(bytes, o)
          : (bytes[o] << 24) |
                (bytes[o + 1] << 16) |
                (bytes[o + 2] << 8) |
                bytes[o + 3];
      o += major == 4 ? extSize : extSize + 4;
    }

    final headerLen = major == 2 ? 6 : 10;
    final limit = tagEnd < bytes.length ? tagEnd : bytes.length;
    while (o + headerLen <= limit) {
      if (bytes[o] == 0) break; // padding
      final idLen = major == 2 ? 3 : 4;
      final id = latin1.decode(Uint8List.sublistView(bytes, o, o + idLen));
      final int size;
      if (major == 2) {
        size = (bytes[o + 3] << 16) | (bytes[o + 4] << 8) | bytes[o + 5];
      } else if (major == 4) {
        size = _syncsafe(bytes, o + 4);
      } else {
        size =
            (bytes[o + 4] << 24) |
            (bytes[o + 5] << 16) |
            (bytes[o + 6] << 8) |
            bytes[o + 7];
      }
      if (size <= 0 || o + headerLen + size > limit) break;

      final name = major == 2 ? (kId3v22Aliases[id] ?? id) : id;
      if (_wanted.contains(name) && !out.containsKey(name)) {
        final text = _decode(
          Uint8List.sublistView(bytes, o + headerLen, o + headerLen + size),
        );
        // Values are NUL-terminated, and v2.4 uses NUL as a multi-value
        // separator; the first value is what a player shows.
        final first = text
            .split('\x00')
            .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
        if (first.trim().isNotEmpty) out[name] = first.trim();
      }
      o += headerLen + size;
    }
    tagStart = tagEnd;
  }
  return out;
}

/// [parseId3TextFrames] over a file, reading only as much as the tags
/// declare. Returns an empty map for anything that isn't ID3-tagged, and
/// never throws.
Future<Map<String, String>> readId3TextFramesFromFile(File f) async {
  RandomAccessFile? handle;
  try {
    handle = await f.open();
    final head = await handle.read(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33) {
      return const {};
    }
    // Read generously past the first tag so a stacked second one is seen
    // too, but never more than the cap.
    final firstTagEnd =
        10 + _syncsafe(head, 6) + ((head[5] & 0x10) != 0 ? 10 : 0);
    var want = firstTagEnd + 4096;
    final len = await f.length();
    if (want > len) want = len;
    if (want > kMaxId3ReadBytes) want = kMaxId3ReadBytes;
    await handle.setPosition(0);
    final bytes = await handle.read(want);

    var frames = parseId3TextFrames(bytes);
    // A stacked tag can start right at the edge of what was read; if the
    // second tag is there but truncated, extend once.
    if (firstTagEnd + 10 <= bytes.length &&
        bytes[firstTagEnd] == 0x49 &&
        bytes[firstTagEnd + 1] == 0x44 &&
        bytes[firstTagEnd + 2] == 0x33) {
      final secondEnd = firstTagEnd + 10 + _syncsafe(bytes, firstTagEnd + 6);
      if (secondEnd > bytes.length) {
        var want2 = secondEnd + 16;
        if (want2 > len) want2 = len;
        if (want2 <= kMaxId3ReadBytes) {
          await handle.setPosition(0);
          frames = parseId3TextFrames(await handle.read(want2));
        }
      }
    }
    return frames;
  } catch (_) {
    return const {};
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
}

/// True when [bytes] carries an embedded picture: an ID3 APIC/PIC frame, or a
/// FLAC PICTURE metadata block. Header-only -- it never decodes the image.
bool bytesCarryEmbeddedArt(Uint8List bytes) {
  if (bytes.length > 4 &&
      bytes[0] == 0x66 &&
      bytes[1] == 0x4C &&
      bytes[2] == 0x61 &&
      bytes[3] == 0x43) {
    // FLAC: walk the metadata blocks looking for type 6 (PICTURE).
    var o = 4;
    var last = false;
    while (o + 4 <= bytes.length && !last) {
      last = (bytes[o] & 0x80) != 0;
      if ((bytes[o] & 0x7f) == 6) return true;
      o += 4 + ((bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]);
    }
    return false;
  }
  // ID3: scan the frame IDs rather than the whole tag, so a stray "APIC" in
  // lyrics or a comment can't produce a false positive.
  var tagStart = 0;
  while (tagStart + 10 <= bytes.length &&
      bytes[tagStart] == 0x49 &&
      bytes[tagStart + 1] == 0x44 &&
      bytes[tagStart + 2] == 0x33) {
    final major = bytes[tagStart + 3];
    final bodySize = _syncsafe(bytes, tagStart + 6);
    if (bodySize <= 0) break;
    final tagEnd = tagStart + 10 + bodySize;
    final headerLen = major == 2 ? 6 : 10;
    var o = tagStart + 10;
    final limit = tagEnd < bytes.length ? tagEnd : bytes.length;
    while (o + headerLen <= limit) {
      if (bytes[o] == 0) break;
      final idLen = major == 2 ? 3 : 4;
      final id = latin1.decode(Uint8List.sublistView(bytes, o, o + idLen));
      if (id == 'APIC' || id == 'PIC') return true;
      final int size;
      if (major == 2) {
        size = (bytes[o + 3] << 16) | (bytes[o + 4] << 8) | bytes[o + 5];
      } else if (major == 4) {
        size = _syncsafe(bytes, o + 4);
      } else {
        size =
            (bytes[o + 4] << 24) |
            (bytes[o + 5] << 16) |
            (bytes[o + 6] << 8) |
            bytes[o + 7];
      }
      if (size <= 0 || o + headerLen + size > limit) break;
      o += headerLen + size;
    }
    tagStart = tagEnd;
  }
  return false;
}

/// [bytesCarryEmbeddedArt] over a file, reading only the head. Never throws.
Future<bool> fileCarriesEmbeddedArt(File f) async {
  RandomAccessFile? handle;
  try {
    handle = await f.open();
    final head = await handle.read(10);
    if (head.length < 10) return false;
    var want = 64 * 1024;
    if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      want = 10 + _syncsafe(head, 6) + 4096;
    }
    final len = await f.length();
    if (want > len) want = len;
    if (want > kMaxId3ReadBytes) want = kMaxId3ReadBytes;
    await handle.setPosition(0);
    return bytesCarryEmbeddedArt(await handle.read(want));
  } catch (_) {
    return false;
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
}
