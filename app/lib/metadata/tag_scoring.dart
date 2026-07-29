// How confident we are that a proposal is the same recording.
//
// Pure, so the confidence bar in the picker and any future automatic pass
// can never disagree about what a number means. Reuses the artwork scorer's
// normalizer and similarity functions rather than growing a second set --
// two spellings of "how alike are these strings" is exactly the drift the
// artwork plan forbade, and the reasoning is identical here.
//
// The weights say what this is willing to be wrong about. Title and artist
// carry most of it because they are what the user is correcting. Duration is
// worth a fifth on its own: it is the only field a database can check that a
// human cannot eyeball, and two recordings called "Intro" by the same artist
// are told apart by their length or not at all. Album is worth least --
// singles, compilations and reissues legitimately disagree about it, which is
// half of why this library's tags are wrong in the first place.
//
// Last modified: 2026-07-28--2230

import '../artwork/scoring.dart' show textSimilarity;
import 'tag_candidate.dart';

const double kTagTitleWeight = 40;
const double kTagArtistWeight = 30;
const double kTagDurationWeight = 20;
const double kTagAlbumWeight = 10;

/// A duration this far out is treated as a different recording entirely.
/// Radio edits and album versions of the same song routinely differ by more.
const int kDurationToleranceMs = 5000;

/// Close enough that the difference is encoding, not arrangement.
const int kDurationExactMs = 1500;

/// How well two lengths agree, in `[0, 1]`. Returns 0.5 -- explicitly
/// neither evidence for nor against -- when either side has no duration,
/// rather than punishing a candidate for a fact we don't have.
double durationSimilarity(int? a, int? b) {
  if (a == null || b == null || a <= 0 || b <= 0) return 0.5;
  final delta = (a - b).abs();
  if (delta <= kDurationExactMs) return 1;
  if (delta >= kDurationToleranceMs) return 0;
  final span = kDurationToleranceMs - kDurationExactMs;
  return 1 - (delta - kDurationExactMs) / span;
}

/// A candidate with its score broken out, so the picker can explain a
/// ranking instead of showing a bare number.
class ScoredTag {
  final TagCandidate candidate;
  final double titleScore;
  final double artistScore;
  final double durationScore;
  final double albumScore;

  const ScoredTag({
    required this.candidate,
    required this.titleScore,
    required this.artistScore,
    required this.durationScore,
    required this.albumScore,
  });

  /// `[0, 100]`.
  double get score => titleScore + artistScore + durationScore + albumScore;

  /// What to call this level of confidence out loud. The picker shows the
  /// word, not the number: "83" invites false precision about a guess.
  String get confidence => switch (score) {
    >= 85 => 'Very likely',
    >= 70 => 'Likely',
    >= 50 => 'Possible',
    _ => 'Unlikely',
  };

  @override
  String toString() =>
      'ScoredTag(${score.toStringAsFixed(1)}: title '
      '${titleScore.toStringAsFixed(1)}, artist '
      '${artistScore.toStringAsFixed(1)}, duration '
      '${durationScore.toStringAsFixed(1)}, album '
      '${albumScore.toStringAsFixed(1)}) $candidate';
}

ScoredTag scoreTagCandidate(TagQuery q, TagCandidate c) => ScoredTag(
  candidate: c,
  titleScore: kTagTitleWeight * textSimilarity(q.title, c.title),
  artistScore: kTagArtistWeight * textSimilarity(q.artist, c.artist),
  durationScore:
      kTagDurationWeight * durationSimilarity(q.durationMs, c.durationMs),
  // An empty album on either side is not evidence of anything, so it neither
  // helps nor punishes -- the same reasoning as a missing duration.
  albumScore: (q.album.trim().isEmpty || c.album.trim().isEmpty)
      ? kTagAlbumWeight * 0.5
      : kTagAlbumWeight * textSimilarity(q.album, c.album),
);

/// Every candidate scored, best first. Ordering is total and reproducible:
/// ties fall back to the shorter title (an album version over a "(Remastered
/// 2011)" of it) and then the provider id.
List<ScoredTag> rankTagCandidates(
  TagQuery q,
  Iterable<TagCandidate> candidates,
) {
  final seen = <String>{};
  final scored = <ScoredTag>[];
  for (final c in candidates) {
    // The same recording comes back more than once when it appears on
    // several releases; keep the first, which is the provider's own best.
    final key = '${c.id}|${c.title.toLowerCase()}|${c.artist.toLowerCase()}'
        '|${c.album.toLowerCase()}';
    if (!seen.add(key)) continue;
    scored.add(scoreTagCandidate(q, c));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byTitle = a.candidate.title.length.compareTo(b.candidate.title.length);
    if (byTitle != 0) return byTitle;
    return a.candidate.id.compareTo(b.candidate.id);
  });
  return scored;
}

/// Score a proposal must reach before it is offered as the pre-selected one.
const double kTagAutoSelectScore = 75;

/// And how far clear of the runner-up, so an ambiguous pair is left for the
/// user rather than decided by a rounding error.
const double kTagAutoSelectMargin = 8;

/// The one candidate confident enough to pre-select, or null when the field
/// is too close to call.
///
/// Deliberately never applies anything by itself. The artwork pass can
/// auto-apply a cover because a wrong cover is embarrassing; a wrong title
/// rewrites the file's tags, and this library exists because something else
/// did that without asking.
ScoredTag? bestTagGuess(List<ScoredTag> ranked) {
  if (ranked.isEmpty) return null;
  final best = ranked.first;
  if (best.score < kTagAutoSelectScore) return null;
  if (ranked.length > 1 &&
      best.score - ranked[1].score < kTagAutoSelectMargin) {
    return null;
  }
  return best;
}
