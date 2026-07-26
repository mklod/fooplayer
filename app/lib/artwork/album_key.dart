// Last modified: 2026-07-25--2115
//
// Album-key normalization for the artwork subsystem (Plan 4, task A2).
//
// Deliberately dependency-free (no Flutter, no dart:io) so BOTH the pure
// scoring code (task A1) and the storage/resolution code (this task) can
// share exactly one normalizer -- the plan requires the album key to come
// "from the same normalizer the scorer uses". Keeping it in its own file
// means A1's `scoring.dart` can import it without dragging in the resolver,
// the store, or any widget code.

/// Bracketed suffixes/qualifiers that never belong in an album identity:
/// `(Deluxe Edition)`, `[Explicit]`, `{2011 Remaster}`, ... Any bracketed
/// run is dropped wholesale -- an album whose *real* title needs brackets is
/// vanishingly rare compared with the edition noise this removes, and the
/// key only has to be stable and collision-light, not reversible.
final RegExp _bracketed = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');

/// Trailing dash-qualifiers iTunes/Deezer routinely append to album titles
/// (`- EP`, `- Single`, `- Deluxe Edition`, `- 2011 Remaster`, ...).
/// Anchored at the end and applied repeatedly so `Foo - EP - Remastered`
/// collapses too.
final RegExp _trailingQualifier = RegExp(
  r'\s*[-–—]\s*('
  r'ep|single|deluxe(\s+edition)?|deluxe\s+version|special\s+edition|'
  r'expanded(\s+edition)?|anniversary\s+edition|'
  r'(\d{4}\s+)?remaster(ed)?(\s+version)?(\s+\d{4})?|'
  r'bonus\s+track\s+version|explicit(\s+version)?|clean(\s+version)?|'
  r'original\s+motion\s+picture\s+soundtrack'
  r')\s*$',
  caseSensitive: false,
);

/// Anything that isn't a letter, digit or whitespace, once diacritics are
/// folded. Punctuation differences ("Rock 'n' Roll" vs "Rock n Roll",
/// "Vol. 2" vs "Vol 2") must not split one album into two keys.
final RegExp _punctuation = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

final RegExp _whitespaceRun = RegExp(r'\s+');

/// Latin-1/Latin-Extended-A diacritic folding table. A lookup table rather
/// than Unicode NFD decomposition because Dart's core libraries ship no
/// normalizer, and the alternative (pulling in a package) is not worth it
/// for the handful of scripts a Western music library actually contains.
const Map<String, String> _foldings = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a', 'æ': 'ae',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ĉ': 'c', 'ċ': 'c',
  'ď': 'd', 'đ': 'd', 'ð': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e',
  'ę': 'e', 'ě': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g',
  'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i',
  'į': 'i', 'ı': 'i',
  'ĵ': 'j', 'ķ': 'k',
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ŏ': 'o', 'ő': 'o', 'œ': 'oe',
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r',
  'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ß': 'ss',
  'ţ': 't', 'ť': 't', 'ŧ': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
  'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
  'ź': 'z', 'ż': 'z', 'ž': 'z', 'þ': 'th',
};

String _foldDiacritics(String s) {
  final b = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    b.write(_foldings[ch] ?? ch);
  }
  return b.toString();
}

/// The shared normalizer: lowercase → fold diacritics → drop bracketed
/// suffixes → drop trailing dash-qualifiers → strip punctuation → collapse
/// whitespace → trim.
///
/// Pure and total: never throws, returns `''` for null-ish/blank input.
String normalizeArtworkText(String? input) {
  if (input == null) return '';
  var s = _foldDiacritics(input.toLowerCase());
  s = s.replaceAll(_bracketed, ' ');
  // Repeat: a title can carry more than one trailing qualifier.
  for (var i = 0; i < 3; i++) {
    final next = s.replaceFirst(_trailingQualifier, '');
    if (next == s) break;
    s = next;
  }
  s = s.replaceAll(_punctuation, ' ');
  return s.replaceAll(_whitespaceRun, ' ').trim();
}

/// The artwork album key: `normalizedArtist|normalizedAlbum`, so every track
/// of an album shares one artwork entry.
///
/// Per the plan, a track with an **empty album** falls back to
/// `normalizedArtist|normalizedTitle` -- a single-track key, so loose files
/// don't all collapse onto one shared `artist|` bucket and inherit each
/// other's covers.
String artworkAlbumKey({
  required String artist,
  required String album,
  String title = '',
}) {
  final a = normalizeArtworkText(artist);
  final al = normalizeArtworkText(album);
  if (al.isNotEmpty) return '$a|$al';
  return '$a|${normalizeArtworkText(title)}';
}

/// Stable 64-bit FNV-1a hash of [s], lowercase hex, zero-padded to 16 chars.
///
/// Used for on-disk names ( `<root>/.artwork/<hash>.jpg`, and the per-root
/// bucket under the app data dir) -- an album key can contain characters no
/// filesystem accepts, and must produce the SAME filename on every launch
/// and every machine that opens the folder. Deliberately hand-rolled rather
/// than `package:crypto`: the app package doesn't depend on crypto directly
/// (only transitively via fooplayer_core), and adding a dependency for a
/// non-cryptographic filename key isn't worth the pubspec churn. Collisions
/// over a library-sized key space (~1e4 keys in a 1.8e19 space) are ~1e-11.
String artworkHash(String s) {
  // 64-bit FNV-1a. Dart ints are 64-bit two's complement on the VM; the
  // multiply wraps, which is exactly what the algorithm wants. Rendered
  // unsigned via toRadixString on the two 32-bit halves so the result never
  // carries a '-' sign (invalid-ish in a filename and ugly).
  var hash = 0xcbf29ce484222325;
  for (final unit in s.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    // Mix the high byte of a multi-byte code unit too, so 'é' and 'e'
    // (already folded apart by the normalizer) can't alias.
    final high = (unit >> 8) & 0xff;
    if (high != 0) {
      hash ^= high;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
  }
  final hi = (hash >> 32) & 0xFFFFFFFF;
  final lo = hash & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
