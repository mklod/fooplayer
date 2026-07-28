// Last modified: 2026-07-27--1605
//
// Self-contained MP3 duration estimator, used by `tags.dart`'s `readTags` as
// a FALLBACK whenever `audio_metadata_reader`'s own parser yields no
// duration for an .mp3 file (verified to happen for real files -- see the
// Eminem - Relapse fixtures this was built and tested against, all
// ID3v2.3-tagged with large embedded cover art).
//
// Two entry points:
//   - [estimateMp3Duration] -- pure, synchronous, operates on bytes already
//     in memory. Used directly by unit tests with synthetic frame data, and
//     internally represents "I have the whole file".
//   - [estimateMp3DurationForFile] -- the production entry point. Reads only
//     a bounded window of the file (not the whole thing), expanding that
//     window exactly once if a leading ID3v2 tag turns out to be bigger than
//     the first window (common: embedded cover art routinely pushes real
//     files' ID3v2 tags well past a naive "first 64 KB" guess).
//
// Both find the first *validated* MPEG audio frame header after any leading
// tag, then either read a Xing/Info/VBRI VBR header out of that frame (exact
// duration, independent of file size) or fall back to a CBR
// bytes-over-bitrate estimate. Never throws: any failure to parse yields
// null, exactly like "the tag parser found nothing".
import 'dart:io';
import 'dart:typed_data';

import 'package:fooplayer_core/fooplayer_core.dart';

/// Bytes read from the start of the file on the first pass. Comfortably
/// clears a typical ID3v2 tag (a handful of text frames) and lands well
/// inside the first audio frame for the common case. Some real-world files
/// carry large embedded cover art *inside* the leading ID3v2 tag -- e.g.
/// every track in `L:\music (original structure)\monthly\2009-05\Eminem -
/// Relapse` has an ID3v2 tag around 219 KB -- which blows past this window;
/// [estimateMp3DurationForFile] detects that case from just the tag's
/// 10-byte header (see [_id3v2TagEnd]) and issues one targeted follow-up
/// read instead of giving up.
const _headWindowBytes = 65536;

/// Bytes read on the follow-up pass, once the leading ID3v2 tag is known to
/// extend past [_headWindowBytes]. Enough to contain the first audio frame
/// header plus a Xing/Info/VBRI header sitting right after it.
const _tailWindowBytes = 65536;

/// Fields decoded from one MPEG audio frame header needed to compute a
/// duration, plus where (relative to the header's own first byte) a
/// Xing/Info VBR header would sit for this header's specific MPEG
/// version/channel-mode combination.
class _FrameHeader {
  final int bitrateKbps;
  final int sampleRate;
  final int frameLengthBytes;
  final int samplesPerFrame;
  final int xingOffset;
  const _FrameHeader({
    required this.bitrateKbps,
    required this.sampleRate,
    required this.frameLengthBytes,
    required this.samplesPerFrame,
    required this.xingOffset,
  });
}

// Bitrate tables in kbps, indexed 0..15. Index 0 ("free" format -- bitrate
// isn't fixed per-frame, would need scanning multiple frames to measure) and
// index 15 ("bad" -- reserved/invalid) are both represented as -1 so the
// `<= 0` check in [_parseFrameHeader] rejects them uniformly.
const _bitratesV1L1 = [
  -1,
  32,
  64,
  96,
  128,
  160,
  192,
  224,
  256,
  288,
  320,
  352,
  384,
  416,
  448,
  -1,
];
const _bitratesV1L2 = [
  -1,
  32,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  384,
  -1,
];
const _bitratesV1L3 = [
  -1,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  -1,
];
// MPEG2/2.5 Layer II and Layer III share one bitrate table.
const _bitratesV2L1 = [
  -1,
  32,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  176,
  192,
  224,
  256,
  -1,
];
const _bitratesV2L2L3 = [
  -1,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  -1,
];

const _sampleRatesMpeg1 = [44100, 48000, 32000, -1];
const _sampleRatesMpeg2 = [22050, 24000, 16000, -1];
const _sampleRatesMpeg25 = [11025, 12000, 8000, -1];

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Parses the 4-byte MPEG audio frame header at `b[i..i+4)`. Returns null
/// for anything that isn't a fully valid header: bad sync, a reserved
/// version/layer/samplerate combination, or the "free"/"bad" bitrate
/// indices -- treating "free" (genuinely variable per-frame, would need a
/// different measurement strategy entirely) as unparseable is an accepted
/// simplification; it's rare in practice.
_FrameHeader? _parseFrameHeader(Uint8List b, int i) {
  if (i < 0 || i + 4 > b.length) return null;
  final b1 = b[i + 1], b2 = b[i + 2], b3 = b[i + 3];
  if (b[i] != 0xFF || (b1 & 0xE0) != 0xE0) return null;

  final versionBits = (b1 >> 3) & 0x3; // 0=MPEG2.5 1=reserved 2=MPEG2 3=MPEG1
  final layerBits =
      (b1 >> 1) & 0x3; // 0=reserved 1=Layer III 2=Layer II 3=Layer I
  if (versionBits == 1 || layerBits == 0) return null;

  final bitrateIndex = (b2 >> 4) & 0xF;
  final sampleRateIndex = (b2 >> 2) & 0x3;
  final padding = (b2 >> 1) & 0x1;
  if (sampleRateIndex == 3) return null;

  final mpeg1 = versionBits == 3;
  final mpeg25 = versionBits == 0;

  final List<int> bitrateTable;
  if (mpeg1) {
    bitrateTable = layerBits == 3
        ? _bitratesV1L1
        : (layerBits == 2 ? _bitratesV1L2 : _bitratesV1L3);
  } else {
    bitrateTable = layerBits == 3 ? _bitratesV2L1 : _bitratesV2L2L3;
  }
  final bitrateKbps = bitrateTable[bitrateIndex];
  if (bitrateKbps <= 0) return null;

  final sampleRateTable = mpeg1
      ? _sampleRatesMpeg1
      : (mpeg25 ? _sampleRatesMpeg25 : _sampleRatesMpeg2);
  final sampleRate = sampleRateTable[sampleRateIndex];
  if (sampleRate <= 0) return null;

  final int samplesPerFrame;
  if (layerBits == 3) {
    samplesPerFrame = 384; // Layer I, all versions
  } else if (layerBits == 2) {
    samplesPerFrame = 1152; // Layer II, all versions
  } else {
    samplesPerFrame = mpeg1 ? 1152 : 576; // Layer III
  }

  final bitrateBps = bitrateKbps * 1000;
  final int frameLengthBytes;
  if (layerBits == 3) {
    // Layer I: 4-byte slots.
    frameLengthBytes = ((12 * bitrateBps ~/ sampleRate) + padding) * 4;
  } else {
    // Layer II/III: 1-byte slots.
    frameLengthBytes = (144 * bitrateBps ~/ sampleRate) + padding;
  }
  if (frameLengthBytes < 4) return null;

  final mono = ((b3 >> 6) & 0x3) == 3;
  // Side-info size determines where a Xing/Info header sits (right after
  // it): MPEG1 stereo/joint/dual 32B, MPEG1 mono 17B; MPEG2/2.5
  // stereo/joint/dual 17B, MPEG2/2.5 mono 9B.
  final sideInfoBytes = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);

  return _FrameHeader(
    bitrateKbps: bitrateKbps,
    sampleRate: sampleRate,
    frameLengthBytes: frameLengthBytes,
    samplesPerFrame: samplesPerFrame,
    xingOffset: 4 + sideInfoBytes,
  );
}

/// Reads a Xing/Info VBR header's total frame count, if [buf] has one
/// starting at [off] that actually carries a frame-count field (flags bit
/// 0). "Info" is the same layout as "Xing", just LAME's naming for a
/// CBR-encoded stream that still carries this header. Returns null (not 0)
/// when nothing usable is present, so the caller falls through to CBR math.
int? _readXingFrameCount(Uint8List buf, int off) {
  if (off < 0 || off + 8 > buf.length) return null;
  final isXing =
      buf[off] == 0x58 &&
      buf[off + 1] == 0x69 &&
      buf[off + 2] == 0x6E &&
      buf[off + 3] == 0x67;
  final isInfo =
      buf[off] == 0x49 &&
      buf[off + 1] == 0x6E &&
      buf[off + 2] == 0x66 &&
      buf[off + 3] == 0x6F;
  if (!isXing && !isInfo) return null;
  final flags = _be32(buf, off + 4);
  if (flags & 0x1 == 0) return null; // frame-count field not present
  if (off + 12 > buf.length) return null;
  final frames = _be32(buf, off + 8);
  return frames > 0 ? frames : null;
}

/// Reads a Fraunhofer VBRI header's total frame count. Unlike Xing/Info,
/// VBRI always sits at a fixed offset -- 36 bytes into the frame -- and
/// always carries a frame count directly (no flags field gating it).
int? _readVbriFrameCount(Uint8List buf, int frameStart) {
  final off = frameStart + 36;
  if (off < 0 || off + 18 > buf.length) return null;
  final isVbri =
      buf[off] == 0x56 &&
      buf[off + 1] == 0x42 &&
      buf[off + 2] == 0x52 &&
      buf[off + 3] == 0x49;
  if (!isVbri) return null;
  final frames = _be32(buf, off + 14);
  return frames > 0 ? frames : null;
}

Duration _secondsToDuration(double seconds) =>
    Duration(microseconds: (seconds * 1e6).round());

/// Scans `buf[scanStart..)` for the first validated MPEG audio frame header
/// and computes a duration from it. [audioEndAbsolute] is an absolute byte
/// offset into the real file marking where the audio stream ends -- used
/// for the CBR bytes-over-bitrate fallback when no VBR frame count is
/// found; [bufferFileOffset] is [buf]'s own absolute position within that
/// same file (0 unless this is a follow-up read partway through the file).
///
/// A candidate header is accepted once "corroborated": either there's no
/// room left in [buf] to check the next frame (accept as-is -- the common
/// case for a short synthetic test frame, or a frame near the end of a
/// bounded read), or the byte at this header's own `frameLengthBytes`
/// further on also starts with a valid frame sync. That second check is
/// what keeps a stray `0xFF` inside compressed audio or tag padding from
/// being mistaken for a frame header purely by chance.
Duration? _scanForDuration(
  Uint8List buf,
  int bufferFileOffset,
  int scanStart,
  int audioEndAbsolute,
) {
  final limit = buf.length - 4;
  var i = scanStart < 0 ? 0 : scanStart;
  while (i <= limit) {
    if (buf[i] == 0xFF && (buf[i + 1] & 0xE0) == 0xE0) {
      final hdr = _parseFrameHeader(buf, i);
      if (hdr != null) {
        final nextSync = i + hdr.frameLengthBytes;
        final corroborated =
            nextSync + 2 > buf.length ||
            (buf[nextSync] == 0xFF && (buf[nextSync + 1] & 0xE0) == 0xE0);
        if (corroborated) {
          final frameCount =
              _readXingFrameCount(buf, i + hdr.xingOffset) ??
              _readVbriFrameCount(buf, i);
          if (frameCount != null) {
            return _secondsToDuration(
              frameCount * hdr.samplesPerFrame / hdr.sampleRate,
            );
          }
          final audioBytes = audioEndAbsolute - (bufferFileOffset + i);
          if (audioBytes <= 0) return null;
          return _secondsToDuration(audioBytes * 8 / (hdr.bitrateKbps * 1000));
        }
      }
    }
    i++;
  }
  return null;
}

/// Estimates an MP3's playback duration directly from its own stream
/// headers. Pure and synchronous -- [bytes] is treated as the file's entire
/// content, so both the leading-tag skip and the trailing ID3v1/APEv2 trim
/// (via `fooplayer_core`'s [mp3AudioRange]) are fully accurate here. This is
/// the half exercised directly by synthetic-frame unit tests; production
/// code goes through [estimateMp3DurationForFile] instead, which never
/// loads a whole file into memory. Never throws: garbage input, a
/// corrupt/truncated file, or tags that consume the entire buffer all just
/// yield null.
Duration? estimateMp3Duration(Uint8List bytes) {
  try {
    final range = mp3AudioRange(bytes);
    if (range.start >= range.end) return null;
    return _scanForDuration(bytes, 0, range.start, range.end);
  } catch (_) {
    return null;
  }
}

/// Returns the absolute byte offset where a leading ID3v2 tag ends, reading
/// only its fixed 10-byte header (magic + version + flags + syncsafe size)
/// -- never its payload. Returns 0 when [head] doesn't start with one.
///
/// This duplicates the handful of lines `fooplayer_core`'s [mp3AudioRange]
/// uses for that same 10-byte header rather than calling it directly,
/// because [mp3AudioRange] clamps its returned `start` to `bytes.length` --
/// exactly right when `bytes` is the whole file (a corrupt tag claiming a
/// size past EOF can't push `start` out of bounds), but wrong for
/// [estimateMp3DurationForFile]'s bounded head-window read: `head` there is
/// deliberately just the first [_headWindowBytes] of a possibly much larger
/// file, so a real (non-corrupt) tag bigger than the window would have its
/// true end silently clamped down to `head.length` -- landing *inside* the
/// tag's own payload (frequently embedded cover art, itself full of
/// incidental `0xFF` bytes from JPEG markers) instead of at the real audio
/// start. Using this instead lets [estimateMp3DurationForFile] detect that
/// oversized-tag case correctly and follow up with a second, targeted read.
int _id3v2TagEnd(Uint8List head) {
  if (head.length < 10 ||
      head[0] != 0x49 ||
      head[1] != 0x44 ||
      head[2] != 0x33) {
    return 0;
  }
  final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
  final footer = (head[5] & 0x10) != 0 ? 10 : 0;
  return 10 + size + footer;
}

/// File-based wrapper around the same estimator that reads only what it
/// needs rather than slurping the whole file:
///
/// 1. Reads the first [_headWindowBytes] (or the whole file, if smaller).
/// 2. Finds where any leading ID3v2 tag ends via [_id3v2TagEnd] -- correct
///    even when the tag's payload extends past what was read.
/// 3. If that end lands past the buffer (large embedded cover art routinely
///    pushes real files' ID3v2 tags well past 64 KB -- see this file's
///    top-of-file doc), issues one targeted follow-up read starting at the
///    tag's real end, so the frame search isn't abandoned just because the
///    first window undershot.
/// 4. Searches for the first frame header and, when present, a Xing/Info/
///    VBRI VBR header, exactly like [estimateMp3Duration].
///
/// Trailing tags (ID3v1/APEv2) are deliberately **not** probed for here --
/// doing so would cost a second seek+read on every single file just to trim
/// at most a couple hundred bytes off a CBR estimate. It doesn't matter at
/// all for a VBR file (a Xing/Info/VBRI frame count found): duration then
/// comes entirely from that frame count, independent of file length. For a
/// CBR file, the file's total length is used as the audio end as-is; on any
/// real music file (typically several MB) a ~100-500 byte trailing tag is a
/// well under 0.01% error -- not audible, not visible in a rendered mm:ss
/// Time column.
Future<Duration?> estimateMp3DurationForFile(File f) async {
  RandomAccessFile? raf;
  try {
    final length = await f.length();
    if (length < 4) return null;
    raf = await f.open();

    final firstReadLen = length < _headWindowBytes ? length : _headWindowBytes;
    var buf = await raf.read(firstReadLen);
    var bufferFileOffset = 0;
    var scanStart = _id3v2TagEnd(buf);
    // range.end is only trustworthy when `buf` happens to be the *whole*
    // file (see the class doc) -- otherwise fall back to the real length,
    // deliberately ignoring any trailing ID3v1/APEv2 tag (see doc above).
    var audioEndAbsolute = (buf.length == length)
        ? mp3AudioRange(buf).end
        : length;

    if (scanStart >= length) return null; // tag (claimed) consumes the file

    if (scanStart + 64 > buf.length && buf.length < length) {
      final remaining = length - scanStart;
      final secondReadLen = remaining < _tailWindowBytes
          ? remaining
          : _tailWindowBytes;
      await raf.setPosition(scanStart);
      buf = await raf.read(secondReadLen);
      bufferFileOffset = scanStart;
      scanStart = 0;
      audioEndAbsolute = length;
    }

    return _scanForDuration(buf, bufferFileOffset, scanStart, audioEndAbsolute);
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {
      // Already closed, or never successfully opened -- either way there's
      // nothing left to clean up.
    }
  }
}
