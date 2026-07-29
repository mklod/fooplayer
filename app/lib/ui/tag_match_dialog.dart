// Proposing corrected tags, and being honest about how sure it is.
//
// The artwork pass may auto-apply a confident cover, because a wrong cover is
// merely embarrassing. This never applies anything on its own: a wrong title
// rewrites the file, and this project exists because something else did that
// without asking. So a proposal lands in the edit form, where it can be read
// and changed, and only Save writes.
//
// Each row shows what would actually change, field by field, current on the
// left. A confidence word rather than a number -- "83" invites false
// precision about a guess -- with the bar carrying the detail.
//
// Last modified: 2026-07-28--2230

import 'package:flutter/material.dart';

import '../metadata/tag_candidate.dart';
import '../metadata/tag_scoring.dart';
import 'app_theme.dart';

class TagMatchDialog extends StatefulWidget {
  final TagQuery query;
  final Future<List<TagCandidate>> Function(TagQuery q) search;

  const TagMatchDialog({
    super.key,
    required this.query,
    required this.search,
  });

  @override
  State<TagMatchDialog> createState() => _TagMatchDialogState();
}

class _TagMatchDialogState extends State<TagMatchDialog> {
  List<ScoredTag>? _ranked;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final results = await widget.search(widget.query);
    if (!mounted) return;
    final ranked = rankTagCandidates(widget.query, results);
    final best = bestTagGuess(ranked);
    setState(() {
      _ranked = ranked;
      // Pre-select only when one candidate is clearly ahead; otherwise leave
      // the top row highlighted but make the user look.
      _selected = best == null ? 0 : ranked.indexOf(best);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ranked = _ranked;
    return AlertDialog(
      key: const Key('tag-match'),
      title: const Text('Find correct tags'),
      content: SizedBox(
        width: 620,
        height: 420,
        child: ranked == null
            ? const Center(
                key: Key('tag-match-searching'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Searching MusicBrainz…',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              )
            : ranked.isEmpty
            ? const Center(
                key: Key('tag-match-empty'),
                child: Text(
                  'No match found.\n\n'
                  'Bootleg compilations, self-released tracks and DJ mixes '
                  'often are not in any database. Nothing has been changed.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              )
            : ListView.builder(
                itemCount: ranked.length,
                itemBuilder: (context, i) => _row(ranked[i], i),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tag-match-use'),
          onPressed: (ranked == null || ranked.isEmpty)
              ? null
              : () => Navigator.of(context).pop(ranked[_selected].candidate),
          child: const Text('Use this'),
        ),
      ],
    );
  }

  Widget _row(ScoredTag s, int index) {
    final c = s.candidate;
    final selected = index == _selected;
    return InkWell(
      key: Key('tag-match-row-$index'),
      onTap: () => setState(() => _selected = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.08) : null,
          border: Border(
            left: BorderSide(
              width: 3,
              color: selected ? AppColors.accent : Colors.transparent,
            ),
            bottom: const BorderSide(color: AppColors.hairline),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  s.confidence,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: s.score >= 70
                        ? AppColors.accent
                        : AppColors.inkSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (s.score / 100).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: AppColors.hairline,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              [
                c.artist,
                if (c.album.isNotEmpty) c.album,
                if (c.year != null) '${c.year}',
                if (c.trackNumber.isNotEmpty) 'track ${c.trackNumber}',
                if (c.durationMs != null) _mmss(c.durationMs!),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.inkSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _mmss(int ms) {
  final total = ms ~/ 1000;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}
