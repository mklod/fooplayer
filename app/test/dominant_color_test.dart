// Last modified: 2026-08-02--2327
//
// Unit tests for mutedFromRgba -- the pure HSV-bucket dominant-color
// extractor behind the Now Playing artwork tint (see dominant_color.dart).
// Deliberately hand-builds raw RGBA byte arrays rather than decoding real
// images: mutedFromRgba is pure and synchronous, so no image codec / Flutter
// binding is needed to exercise it directly.
import 'dart:typed_data';

import 'package:flutter/material.dart' show HSVColor;
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/dominant_color.dart';

/// Builds a tightly-packed RGBA byte buffer of [count] pixels, all set to
/// the given channel values (0-255).
Uint8List _solid(int r, int g, int b, int count, {int a = 255}) {
  final bytes = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    final o = i * 4;
    bytes[o] = r;
    bytes[o + 1] = g;
    bytes[o + 2] = b;
    bytes[o + 3] = a;
  }
  return bytes;
}

/// Concatenates several pixel blocks into one RGBA buffer.
Uint8List _mix(List<Uint8List> blocks) {
  final total = blocks.fold<int>(0, (n, b) => n + b.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final block in blocks) {
    out.setRange(offset, offset + block.length, block);
    offset += block.length;
  }
  return out;
}

/// Shortest signed distance in degrees between two hues on the 360-degree
/// circle -- e.g. dist(350, 5) == 15, not 345.
double _hueDist(double a, double b) {
  var d = (a - b) % 360.0;
  if (d < 0) d += 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

void main() {
  group('mutedFromRgba', () {
    test('solid saturated red -> hue near 0, muted saturation/value', () {
      final rgba = _solid(255, 0, 0, 64);
      final color = mutedFromRgba(rgba);

      expect(color, isNotNull);
      final hsv = HSVColor.fromColor(color!);
      expect(_hueDist(hsv.hue, 0), lessThanOrEqualTo(15));
      expect(hsv.saturation, inInclusiveRange(0.22, 0.42));
      expect(hsv.value, inInclusiveRange(0.30, 0.44));
    });

    test('solid grey -> null (no meaningful hue to extract)', () {
      final rgba = _solid(128, 128, 128, 64);
      expect(mutedFromRgba(rgba), isNull);
    });

    test('solid near-black -> null (below the value floor, reads as grey)', () {
      final rgba = _solid(4, 4, 6, 64);
      expect(mutedFromRgba(rgba), isNull);
    });

    test('70% blue + 30% grey mix -> blue-family hue', () {
      final rgba = _mix([_solid(0, 0, 255, 70), _solid(128, 128, 128, 30)]);
      final color = mutedFromRgba(rgba);

      expect(color, isNotNull);
      final hsv = HSVColor.fromColor(color!);
      expect(_hueDist(hsv.hue, 240), lessThanOrEqualTo(20));
      expect(hsv.saturation, inInclusiveRange(0.22, 0.42));
      expect(hsv.value, inInclusiveRange(0.30, 0.44));
    });

    test('tiny 1px input works without crashing', () {
      final rgba = _solid(20, 200, 40, 1);
      final color = mutedFromRgba(rgba);

      expect(color, isNotNull);
      final hsv = HSVColor.fromColor(color!);
      expect(_hueDist(hsv.hue, 135), lessThanOrEqualTo(20));
      expect(hsv.saturation, inInclusiveRange(0.22, 0.42));
      expect(hsv.value, inInclusiveRange(0.30, 0.44));
    });

    test('fully transparent pixels contribute nothing (all-alpha-0 -> null)',
        () {
      final rgba = _solid(255, 0, 0, 32, a: 0);
      expect(mutedFromRgba(rgba), isNull);
    });
  });
}
