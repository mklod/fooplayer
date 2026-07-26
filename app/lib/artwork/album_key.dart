// Last modified: 2026-07-25--2214
//
// Album-key normalization for the artwork subsystem (Plan 4).
//
// **The single normalizer.** The plan requires the album key to come "from
// the same normalizer the scorer uses", so this file is the one and only
// implementation: `scoring.dart` (A1) re-exports it as `normalizeText`, and
// `picker_seams.dart` (A3) builds its track key from it. Two normalizers
// would let the picker file a cover under a key the background pass never
// looks at -- exactly the drift the plan forbids.
//
// Deliberately dependency-free (no Flutter, no dart:io) so the pure scoring
// code, the storage code and the widget layer can all share it.

/// Latin-1/Latin-Extended folding table. Deliberately explicit rather than
/// Unicode-NFD-based: Dart's core libraries ship no normalization form, and a
/// table keeps the transform auditable and identical on every platform.
const Map<String, String> _diacritics = {
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
  'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ș': 's',
  'ţ': 't', 'ť': 't', 'ŧ': 't', 'ț': 't', 'þ': 'th',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
  'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w',
  'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
  'ź': 'z', 'ż': 'z', 'ž': 'z',
  'ß': 'ss',
};

/// Words that carry no identity of their own in an album title. A trailing
/// `- <tail>` segment is dropped only when *every* token in the tail is one
/// of these (or a bare number, e.g. a remaster year) -- so `- EP` and
/// `- 2011 Remaster` go, while `Kid A - Part Two` survives intact.
const Set<String> _noiseWords = {
  'ep',
  'lp',
  'single',
  'singles',
  'deluxe',
  'edition',
  'editions',
  'expanded',
  'extended',
  'remaster',
  'remastered',
  'remastering',
  'remasters',
  'special',
  'anniversary',
  'explicit',
  'clean',
  'bonus',
  'track',
  'tracks',
  'version',
  'reissue',
  'mono',
  'stereo',
  'digital',
  'digipak',
  'import',
  'th',
  'nd',
  'rd',
  'st',
  'and',
};

final RegExp _bracketGroup = RegExp(r'\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}');
final RegExp _apostrophes = RegExp(r"['‘’ʼ`]");
final RegExp _unicodeDashes = RegExp('[‐-―−]');

/// Anything that isn't a letter, digit or whitespace. Unicode-aware on
/// purpose: a Cyrillic/CJK/Greek title must survive normalization as itself
/// rather than being erased down to `''` (which would collapse every such
/// album onto one shared key). Diacritics are folded *before* this runs, so
/// Latin text still converges on its ASCII spelling.
final RegExp _nonAlnum = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

final RegExp _whitespace = RegExp(r'\s+');
final RegExp _dashTail = RegExp(r'^(.*\S)\s+-\s+(\S.*)$');
final RegExp _digitsOnly = RegExp(r'^\d+$');

/// Folds a free-text artist/album string down to a comparable form:
/// lowercase, `&` -> `and`, bracketed groups removed (`(Deluxe Edition)`,
/// `[Explicit]`, `{...}`, including nested ones), noise-only `- ` tails
/// removed (`- EP`, `- 2011 Remaster`), diacritics folded, apostrophes
/// elided (`don't` -> `dont`), remaining punctuation collapsed to spaces.
///
/// Applied to BOTH sides of every comparison, and it is the same function
/// that builds the album key -- so a track and its artwork entry can never
/// disagree about what "the same album" means.
///
/// Pure, total and idempotent: never throws, returns `''` for null/blank.
String normalizeArtworkText(String? input) {
  var s = (input ?? '').toLowerCase();
  if (s.isEmpty) return '';

  s = s.replaceAll('&', ' and ');

  // Remove bracketed groups repeatedly so nesting collapses fully.
  while (true) {
    final next = s.replaceAll(_bracketGroup, ' ');
    if (next == s) break;
    s = next;
  }

  s = s.replaceAll(_apostrophes, '');

  // Fold diacritics before punctuation stripping (some fold to two letters).
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(_diacritics[ch] ?? ch);
  }
  s = buf.toString();

  // Unify dash variants, then drop noise-only ` - ` tails repeatedly
  // ("Album - EP", "Album - 2011 Remaster - Deluxe Edition"). This has to
  // happen BEFORE punctuation is flattened, or there is no dash left to
  // anchor the tail on.
  s = s.replaceAll(_unicodeDashes, '-');
  while (true) {
    final m = _dashTail.firstMatch(s);
    if (m == null) break;
    final tail = m
        .group(2)!
        .replaceAll(_nonAlnum, ' ')
        .split(' ')
        .where((t) => t.isNotEmpty);
    final allNoise = tail.isNotEmpty &&
        tail.every((t) => _noiseWords.contains(t) || _digitsOnly.hasMatch(t));
    if (!allNoise) break;
    s = m.group(1)!.trim();
  }

  return s.replaceAll(_nonAlnum, ' ').replaceAll(_whitespace, ' ').trim();
}

/// The artwork album key: `normalizedArtist|normalizedAlbum`, so every track
/// of an album shares one artwork entry.
///
/// Per the plan, a track with an **empty album** falls back to
/// `normalizedArtist|normalizedTitle` -- a single-track key, so loose files
/// don't all collapse onto one shared `artist|` bucket and inherit each
/// other's covers.
///
/// **Fully-untagged fallback.** When artist AND album are BOTH blank (a bare
/// filename rip like `01.mp3` with no tags at all), the title alone is not a
/// safe discriminator either: filename-derived fallback titles ("01", "02",
/// "Track 1", ...) repeat across every untagged album in the library, so
/// keying on title would collapse unrelated albums -- even unrelated
/// folders -- onto one shared artwork entry (adversarial review finding 7).
/// [rootPath]/[relPath] (when a caller has a real file to key off -- see
/// `ArtworkRequest` and `albumKeyForTrack`) make that case unique PER FILE
/// instead: every artist/album-less track gets its own artwork slot, same
/// as if it were tagged with a unique title. A caller with no file identity
/// at all (e.g. a bare artist/album/title lookup) keeps the old
/// `artist|title` fallback, which is the best available discriminator when
/// there is no file to fall back to.
String artworkAlbumKey({
  required String artist,
  required String album,
  String title = '',
  String rootPath = '',
  String relPath = '',
}) {
  final a = normalizeArtworkText(artist);
  final al = normalizeArtworkText(album);
  if (al.isNotEmpty) return '$a|$al';
  if (a.isNotEmpty) return '$a|${normalizeArtworkText(title)}';
  if (rootPath.isNotEmpty || relPath.isNotEmpty) {
    // '\x01' can never appear in a normalized artist/album/title string
    // (normalizeArtworkText strips every non-letter/digit/space character),
    // so this can't collide with a legitimate `artist|title` key -- it is
    // always recognizable as the fully-untagged, per-file fallback.
    return '|\x01$rootPath\x01$relPath';
  }
  return '$a|${normalizeArtworkText(title)}';
}

/// What one album's artwork lookup is asked for.
///
/// **One declaration, deliberately.** A2 (background pass) and A3 (picker)
/// each grew their own `ArtworkQuery` while building in parallel; they are
/// the same concept, and two of them would mean two spellings of the album
/// key travelling through the same feature. Both spellings of the search
/// term ([term] / [terms]) are kept so neither branch's call sites had to be
/// churned.
class ArtworkQuery {
  final String artist;
  final String album;

  /// Explicit album key, when the caller already computed one (A2 carries it
  /// on [ArtworkRequest] so nothing downstream has to re-derive it). Null
  /// means "derive it from artist/album", which is what the picker does.
  final String? albumKeyOverride;

  const ArtworkQuery({this.artist = '', this.album = '', String? albumKey})
      : albumKeyOverride = albumKey;

  /// The album key this query files its results under.
  ///
  /// The fallback passes [album] as the title too, so a query built for a
  /// track with no album tag (where the caller puts the *title* in [album],
  /// see `artworkQueryForTrack`) lands on the same `artist|title` key
  /// [artworkAlbumKey] would produce for that track.
  String get albumKey =>
      albumKeyOverride ??
      artworkAlbumKey(artist: artist, album: album, title: album);

  /// The single free-text term the keyless providers take (`?term=`/`?q=`),
  /// and what is recorded in the sidecar's `query` field.
  String get terms =>
      [artist, album].map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');

  /// A3's spelling of [terms].
  String get term => terms;

  bool get isEmpty => terms.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ArtworkQuery &&
      other.artist == artist &&
      other.album == album &&
      other.albumKeyOverride == albumKeyOverride;

  @override
  int get hashCode => Object.hash(artist, album, albumKeyOverride);

  @override
  String toString() => 'ArtworkQuery($terms)';
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
