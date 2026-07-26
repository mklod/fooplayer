// Last modified: 2026-07-25--2246
//
// Magic-byte sniffing for downloaded/stored artwork images (adversarial
// review finding 6).
//
// A 200 response is not proof of a usable image: a redirect landing page,
// an ad-blocker interstitial, or a plain error page can all be served with
// HTTP 200 and an HTML body -- common for URLs that aren't direct image
// links (exactly what the picker's "Paste URL..." accepts arbitrary user
// input for). Without a check, that HTML gets stored as a "successful"
// pick, is never retried (the sidecar has an entry, so nothing about it
// looks like a failure), and the art surfaces render Flutter's red error
// box instead of the placeholder when they eventually try to decode it.
//
// Checking the file's magic number is cheap, doesn't require decoding the
// whole image, and catches that failure mode before the bytes are ever
// written to disk or handed to a widget as a "successful" pick.
//
// Deliberately dependency-free (no Flutter, no dart:io, no package:http) so
// both the provider-facing downloader (providers.dart) and the sidecar
// store's write-time backstop (artwork_store.dart) can share ONE check
// without creating a dependency between those two independently-built
// halves of the feature (see artwork_wiring.dart's doc on that seam).

/// True when [bytes] starts with a recognized JPEG/PNG/GIF/WebP/BMP magic
/// number. NOT a full image decode -- just enough to reject an obviously
/// non-image response (an HTML error page, a truncated/empty body, a
/// renamed non-image file) before it's stored as a "successful" pick.
bool looksLikeImage(List<int> bytes) {
  // Every signature below is checked within the first 12 bytes, so
  // anything shorter than that can't possibly match one.
  if (bytes.length < 12) return false;

  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (_startsWith(bytes, const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ])) {
    return true;
  }

  // GIF: "GIF87a" or "GIF89a"
  if (_startsWith(bytes, const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      _startsWith(bytes, const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return true;
  }

  // WebP: "RIFF" <4-byte size> "WEBP"
  if (_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }

  // BMP: "BM"
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;

  return false;
}

bool _startsWith(List<int> bytes, List<int> signature) {
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}
