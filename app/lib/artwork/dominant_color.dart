// Last modified: 2026-08-02--2327
//
// Artwork -> muted background tint (Now Playing reskin).
//
// A pure HSV-bucket dominant-color extractor over raw RGBA bytes, followed
// by a deliberate "mute" step that clamps saturation and value into a
// narrow slate-like band. The point is that ANY artwork -- a neon album
// cover, a stark black-and-white photo, a scanned polaroid -- produces the
// same muted-slate feel as the reference design, and white foreground text
// stays readable no matter what's behind it.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, ImageByteFormat, instantiateImageCodec;

/// Number of 30-degree-wide hue buckets pixels are sorted into.
const int _hueBuckets = 12;

/// Pixels this near grey (very low saturation or very low brightness)
/// contribute nothing to any hue bucket -- a black band or a paper-white
/// mount would otherwise "win" a hue that isn't really there.
const double _greySaturationFloor = 0.12;
const double _greyValueFloor = 0.10;

/// If almost the whole image is that near-grey, there is no meaningful
/// dominant hue to extract (e.g. a monochrome cover) -- return null so the
/// caller falls back to its own default tint.
const double _greyMajorityThreshold = 0.92;

/// The muted output band: saturation and value are both clamped into these
/// ranges so the result always reads as a dark, muted slate -- never a
/// saturated poster color -- regardless of the source artwork.
const double _mutedSatMin = 0.22;
const double _mutedSatMax = 0.42;
const double _mutedValMin = 0.30;
const double _mutedValMax = 0.44;

double _clampD(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Extracts a muted "dominant color" tint from raw RGBA pixel bytes.
///
/// [rgba] is tightly packed 4-bytes-per-pixel (R, G, B, A) -- the layout
/// `Image.toByteData(format: ImageByteFormat.rawRgba)` produces; see
/// [dominantMutedColor], the decode-and-call wrapper.
///
/// Pure and synchronous by design: every pixel is converted to HSV and
/// bucketed into one of 12 hue wedges, weighted by `saturation * value` so
/// vivid, bright pixels outvote dull ones. Near-grey pixels (see
/// [_greySaturationFloor] / [_greyValueFloor]) are skipped entirely; if
/// almost every pixel was skipped that way, there is no real hue to report
/// and this returns null.
///
/// Otherwise the winning bucket's weighted-average hue/saturation/value is
/// taken and MUTED: hue is kept as-is, saturation is clamped into
/// [_mutedSatMin, _mutedSatMax], value into [_mutedValMin, _mutedValMax].
Color? mutedFromRgba(Uint8List rgba) {
  final bucketWeight = List<double>.filled(_hueBuckets, 0);
  final bucketSin = List<double>.filled(_hueBuckets, 0);
  final bucketCos = List<double>.filled(_hueBuckets, 0);
  final bucketSat = List<double>.filled(_hueBuckets, 0);
  final bucketVal = List<double>.filled(_hueBuckets, 0);

  var totalPixels = 0;
  var greyPixels = 0;

  final pixelCount = rgba.length ~/ 4;
  for (var i = 0; i < pixelCount; i++) {
    final o = i * 4;
    final a = rgba[o + 3] / 255.0;
    if (a <= 0.0) continue; // fully transparent pixels carry no color

    final r = rgba[o] / 255.0;
    final g = rgba[o + 1] / 255.0;
    final b = rgba[o + 2] / 255.0;
    totalPixels++;

    final hsv = _rgbToHsv(r, g, b);
    final h = hsv[0], s = hsv[1], v = hsv[2];

    if (s < _greySaturationFloor || v < _greyValueFloor) {
      greyPixels++;
      continue;
    }

    final weight = s * v;
    final bucket = (h / 30.0).floor() % _hueBuckets;
    final rad = h * math.pi / 180.0;
    bucketWeight[bucket] += weight;
    bucketSin[bucket] += math.sin(rad) * weight;
    bucketCos[bucket] += math.cos(rad) * weight;
    bucketSat[bucket] += s * weight;
    bucketVal[bucket] += v * weight;
  }

  if (totalPixels == 0) return null;
  if (greyPixels / totalPixels > _greyMajorityThreshold) return null;

  var winner = -1;
  var winnerWeight = 0.0;
  for (var i = 0; i < _hueBuckets; i++) {
    if (bucketWeight[i] > winnerWeight) {
      winnerWeight = bucketWeight[i];
      winner = i;
    }
  }
  if (winner == -1 || winnerWeight <= 0) return null;

  var hue = math.atan2(bucketSin[winner], bucketCos[winner]) * 180.0 / math.pi;
  hue %= 360.0;
  if (hue < 0) hue += 360.0;
  final avgSat = bucketSat[winner] / winnerWeight;
  final avgVal = bucketVal[winner] / winnerWeight;

  final mutedSat = _clampD(avgSat, _mutedSatMin, _mutedSatMax);
  final mutedVal = _clampD(avgVal, _mutedValMin, _mutedValMax);

  return _hsvToColor(hue, mutedSat, mutedVal);
}

/// Converts normalized (0-1) RGB to `[hue in 0..360, saturation, value]`.
List<double> _rgbToHsv(double r, double g, double b) {
  final maxc = math.max(r, math.max(g, b));
  final minc = math.min(r, math.min(g, b));
  final v = maxc;
  final delta = maxc - minc;
  final s = maxc == 0 ? 0.0 : delta / maxc;

  double h;
  if (delta == 0) {
    h = 0;
  } else if (maxc == r) {
    h = 60 * (((g - b) / delta) % 6);
  } else if (maxc == g) {
    h = 60 * (((b - r) / delta) + 2);
  } else {
    h = 60 * (((r - g) / delta) + 4);
  }
  if (h < 0) h += 360;
  return [h, s, v];
}

/// Converts HSV (hue 0..360, saturation/value 0..1) to an opaque [Color].
Color _hsvToColor(double h, double s, double v) {
  final c = v * s;
  final hh = h / 60.0;
  final x = c * (1 - ((hh % 2) - 1).abs());
  double r1, g1, b1;
  if (hh < 1) {
    r1 = c;
    g1 = x;
    b1 = 0;
  } else if (hh < 2) {
    r1 = x;
    g1 = c;
    b1 = 0;
  } else if (hh < 3) {
    r1 = 0;
    g1 = c;
    b1 = x;
  } else if (hh < 4) {
    r1 = 0;
    g1 = x;
    b1 = c;
  } else if (hh < 5) {
    r1 = x;
    g1 = 0;
    b1 = c;
  } else {
    r1 = c;
    g1 = 0;
    b1 = x;
  }
  final m = v - c;
  final r = (((r1 + m) * 255).round()).clamp(0, 255).toInt();
  final g = (((g1 + m) * 255).round()).clamp(0, 255).toInt();
  final b = (((b1 + m) * 255).round()).clamp(0, 255).toInt();
  return Color.fromARGB(255, r, g, b);
}

/// Decodes [imageBytes] and extracts its muted dominant-color tint (see
/// [mutedFromRgba]). Downsamples to 32px wide before analysis -- more than
/// enough signal for a background tint, and keeps every decode fast even
/// for a multi-megapixel embedded cover. Any decode failure (corrupt bytes,
/// unsupported format, zero-byte input) returns null rather than throwing:
/// artwork tinting is a nicety, never something that can crash the Now
/// Playing page.
Future<Color?> dominantMutedColor(Uint8List imageBytes) async {
  try {
    final codec = await instantiateImageCodec(imageBytes, targetWidth: 32);
    try {
      final frame = await codec.getNextFrame();
      try {
        final byteData = await frame.image.toByteData(
          format: ImageByteFormat.rawRgba,
        );
        if (byteData == null) return null;
        return mutedFromRgba(byteData.buffer.asUint8List());
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
