// Deterministic, pure, network-free scoring for album-artwork candidates.
//
// Everything in this file is a pure function of its arguments: no clock, no
// randomness, no IO. That is what makes the "auto-apply" decision safe to
// unit-test exhaustively, which matters because the cost of a wrong cover
// silently applied is much higher than the cost of no cover at all.
//
// Last modified: 2026-07-25--2214

import 'album_key.dart';
import 'art_candidate.dart';

export 'album_key.dart' show artworkAlbumKey, artworkHash, normalizeArtworkText;

// ---------------------------------------------------------------------------
// Normalization
//
// THE normalizer lives in album_key.dart -- one implementation shared by the
// scorer, the sidecar's album key and the picker (plan: the key must come
// "from the same normalizer the scorer uses"). The names below are the
// scorer-facing spellings; they are thin aliases, never a second algorithm.
// ---------------------------------------------------------------------------

/// Alias of [normalizeArtworkText] -- see album_key.dart for the algorithm.
String normalizeText(String? input) => normalizeArtworkText(input);

/// The library-wide identity of an album: `normalizedArtist|normalizedAlbum`.
///
/// Tracks with no album fall back to `normalizedArtist|normalizedTitle` so a
/// loose single still gets its own artwork slot instead of colliding with
/// every other album-less track by the same artist.
///
/// This is the key used by the `.artwork.json` sidecar and by the resolver's
/// in-memory cache; it delegates to [artworkAlbumKey] so it can never drift
/// from the normalizer the scorer uses.
String albumKey({String? artist, String? album, String? title}) =>
    artworkAlbumKey(
      artist: artist ?? '',
      album: album ?? '',
      title: title ?? '',
    );

/// Album key for a provider candidate (its own `artist`/`title` fields).
String candidateKey(ArtCandidate c) =>
    albumKey(artist: c.artist, album: c.title);

// ---------------------------------------------------------------------------
// String similarity
// ---------------------------------------------------------------------------

int _levenshtein(String a, String b) {
  if (identical(a, b) || a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  final cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    prev = List<int>.from(cur);
  }
  return prev[b.length];
}

/// Edit-distance similarity in `[0, 1]`. Two empty strings score 1.0 (they
/// are trivially equal); callers that must not reward "no evidence on both
/// sides" gate on emptiness themselves -- see [artistSimilarity].
double ratio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final longest = a.length > b.length ? a.length : b.length;
  if (longest == 0) return 1;
  return 1 - _levenshtein(a, b) / longest;
}

/// fuzzywuzzy-style token-set ratio in `[0, 1]`.
///
/// Compares the shared token set against each side's shared-plus-remainder
/// string, which makes the comparison order-insensitive and forgiving of one
/// side carrying extra words ("radiohead" vs "radiohead feat. someone",
/// "the beatles" vs "beatles" both score 1.0) without being forgiving of
/// genuinely different words.
double tokenSetRatio(String a, String b) {
  final ta = a.split(' ').where((t) => t.isNotEmpty).toSet();
  final tb = b.split(' ').where((t) => t.isNotEmpty).toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;

  final sect = (ta.intersection(tb).toList()..sort()).join(' ');
  final rest1 = (ta.difference(tb).toList()..sort()).join(' ');
  final rest2 = (tb.difference(ta).toList()..sort()).join(' ');
  final combined1 = sect.isEmpty ? rest1 : '$sect $rest1'.trim();
  final combined2 = sect.isEmpty ? rest2 : '$sect $rest2'.trim();

  final r1 = ratio(sect, combined1);
  final r2 = ratio(sect, combined2);
  final r3 = ratio(combined1, combined2);
  final best = r1 > r2 ? r1 : r2;
  return best > r3 ? best : r3;
}

/// Order-insensitive but length-sensitive similarity: compares the two token
/// sequences after sorting them alphabetically.
double tokenSortRatio(String a, String b) {
  final ta = (a.split(' ').where((t) => t.isNotEmpty).toList()..sort()).join(
    ' ',
  );
  final tb = (b.split(' ').where((t) => t.isNotEmpty).toList()..sort()).join(
    ' ',
  );
  if (ta.isEmpty || tb.isEmpty) return 0;
  return ratio(ta, tb);
}

/// Weights of the two ratios blended by [textSimilarity].
///
/// [tokenSetRatio] alone is far too forgiving here: it scores "OK Computer"
/// against "OK Computer OKNOTOK 1997 2017" as a perfect 1.0, which would put
/// a reissue box set in a dead heat with the album actually being looked up
/// and permanently trip the >=10-margin rule into "ask the user". Mixing in
/// [tokenSortRatio], which *does* pay for extra words, restores the gap while
/// still tolerating word-order differences and one-sided extras like
/// "The Beatles" vs "Beatles".
const double kTokenSortWeight = 0.6;
const double kTokenSetWeight = 0.4;

/// Normalized text similarity in `[0, 1]`. Returns 0 when either side is
/// blank after normalization: missing evidence is not a match.
double textSimilarity(String? a, String? b) {
  final na = normalizeText(a);
  final nb = normalizeText(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  return kTokenSortWeight * tokenSortRatio(na, nb) +
      kTokenSetWeight * tokenSetRatio(na, nb);
}

/// Normalized artist similarity.
double artistSimilarity(String? a, String? b) => textSimilarity(a, b);

/// Normalized album/title similarity.
double albumSimilarity(String? a, String? b) => textSimilarity(a, b);

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

/// Maximum weight of each component; sums to 100.
const double kArtistWeight = 50;
const double kAlbumWeight = 40;
const double kProviderWeightMax = 5;
const double kResolutionWeightMax = 5;

/// Minimum score for an automatic (un-prompted) artwork apply.
const double kAutoApplyMinScore = 75;

/// Minimum lead over the next *distinct* album for an automatic apply.
const double kAutoApplyMinMargin = 10;

/// Provider prior (0-5): how much we trust a source's metadata hygiene when
/// everything else ties. User-supplied sources rank at the top because the
/// user already made the decision.
double providerPrior(ArtSource source) => switch (source) {
  ArtSource.itunes => 5,
  ArtSource.deezer => 4,
  ArtSource.caa => 3,
  ArtSource.local => 5,
  ArtSource.url => 5,
  ArtSource.embedded => 5,
};

/// Resolution bonus (0-5) from the known pixel width. Unknown width scores 0
/// rather than guessing.
double resolutionBonus(int? width) {
  if (width == null || width <= 0) return 0;
  if (width >= 1000) return 5;
  if (width >= 600) return 4;
  if (width >= 500) return 3;
  if (width >= 300) return 2;
  return 1;
}

/// A candidate plus its score breakdown (kept so the picker can explain a
/// ranking and so tests assert on components, not just the total).
class ScoredCandidate {
  final ArtCandidate candidate;
  final double artistScore;
  final double albumScore;
  final double providerScore;
  final double resolutionScore;

  const ScoredCandidate({
    required this.candidate,
    required this.artistScore,
    required this.albumScore,
    required this.providerScore,
    required this.resolutionScore,
  });

  double get score =>
      artistScore + albumScore + providerScore + resolutionScore;

  @override
  String toString() =>
      'ScoredCandidate(${score.toStringAsFixed(1)}: '
      'artist ${artistScore.toStringAsFixed(1)}, '
      'album ${albumScore.toStringAsFixed(1)}, '
      'provider ${providerScore.toStringAsFixed(1)}, '
      'res ${resolutionScore.toStringAsFixed(1)}) $candidate';
}

/// Scores one candidate against the query. Pure; range `[0, 100]`.
ScoredCandidate scoreCandidate(ArtQuery q, ArtCandidate c) => ScoredCandidate(
  candidate: c,
  artistScore: kArtistWeight * artistSimilarity(q.artist, c.artist),
  albumScore: kAlbumWeight * albumSimilarity(q.album, c.title),
  providerScore: providerPrior(c.source),
  resolutionScore: resolutionBonus(c.width),
);

int _compareScored(ScoredCandidate a, ScoredCandidate b) {
  final byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  final byProvider = providerPrior(
    b.candidate.source,
  ).compareTo(providerPrior(a.candidate.source));
  if (byProvider != 0) return byProvider;
  final byWidth = (b.candidate.width ?? 0).compareTo(a.candidate.width ?? 0);
  if (byWidth != 0) return byWidth;
  // Prefer the plainer title: "Album" over "Album (Deluxe Edition)" when the
  // normalizer has already made them score identically.
  final byTitle = a.candidate.title.length.compareTo(b.candidate.title.length);
  if (byTitle != 0) return byTitle;
  // Final tiebreak on the URL so ordering is total and reproducible.
  return a.candidate.url.compareTo(b.candidate.url);
}

/// Drops literal duplicates -- the same image URL offered twice (iTunes
/// happily returns an album's artwork under several rows). Order of first
/// appearance is preserved.
///
/// Deliberately URL-only: two *different* images of the same album (an
/// original and its remaster, say) are different choices and both belong in
/// the picker. Collapsing them is the job of [rankDistinctAlbums], and only
/// for the auto-apply margin.
List<ArtCandidate> dedupeCandidates(Iterable<ArtCandidate> candidates) {
  final seenUrls = <String>{};
  final out = <ArtCandidate>[];
  for (final c in candidates) {
    if (!seenUrls.add(c.url)) continue;
    out.add(c);
  }
  return out;
}

/// Every candidate, deduped and ranked best-first. This is the picker grid's
/// order.
List<ScoredCandidate> rankCandidates(ArtQuery q, Iterable<ArtCandidate> cands) {
  final scored = dedupeCandidates(
    cands,
  ).map((c) => scoreCandidate(q, c)).toList();
  scored.sort(_compareScored);
  return scored;
}

/// One entry per *distinct album* (best-scoring representative of each
/// normalized `artist|title` group), ranked best-first.
///
/// The auto-apply margin is measured over THIS list, not [rankCandidates]:
/// three providers agreeing on the same album is corroboration, not a tie,
/// and must not be allowed to suppress the auto-apply. A real tie is two
/// *different* albums scoring alike -- exactly the ambiguity the picker
/// exists to resolve.
List<ScoredCandidate> rankDistinctAlbums(
  ArtQuery q,
  Iterable<ArtCandidate> cands,
) {
  final best = <String, ScoredCandidate>{};
  for (final s in rankCandidates(q, cands)) {
    final key = candidateKey(s.candidate);
    final existing = best[key];
    if (existing == null || _compareScored(s, existing) < 0) best[key] = s;
  }
  final out = best.values.toList();
  out.sort(_compareScored);
  return out;
}

/// The auto-apply decision, with its score, or null when we should stay out
/// of the way and let the picker decide.
///
/// Applies iff the top distinct album scores >= [kAutoApplyMinScore] AND
/// leads the runner-up by >= [kAutoApplyMinMargin].
ScoredCandidate? bestGuessScored(
  ArtQuery q,
  Iterable<ArtCandidate> candidates, {
  double minScore = kAutoApplyMinScore,
  double minMargin = kAutoApplyMinMargin,
}) {
  final ranked = rankDistinctAlbums(q, candidates);
  if (ranked.isEmpty) return null;
  final top = ranked.first;
  if (top.score < minScore) return null;
  if (ranked.length > 1 && top.score - ranked[1].score < minMargin) return null;
  return top;
}

/// [bestGuessScored] without the score breakdown.
ArtCandidate? bestGuess(
  ArtQuery q,
  Iterable<ArtCandidate> candidates, {
  double minScore = kAutoApplyMinScore,
  double minMargin = kAutoApplyMinMargin,
}) => bestGuessScored(
  q,
  candidates,
  minScore: minScore,
  minMargin: minMargin,
)?.candidate;
