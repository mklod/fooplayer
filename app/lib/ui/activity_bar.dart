// The persistent "here is what I am doing" bar.
//
// Sits above the now-playing bar and stays for the whole duration of whatever
// is running -- the opposite of the three-second toast it replaces, which
// announced a twenty-minute job and then said nothing.
//
// Last modified: 2026-07-28--1730

import 'package:flutter/material.dart';

import '../model/activity_model.dart';
import '../model/library_model.dart';
import 'app_theme.dart';

/// The window's persistent footer: what is running on the left, how many
/// tracks are in view on the right.
///
/// Always present, even idle -- the track count is a permanent readout, and a
/// strip that appears and disappears under the now-playing bar would jump the
/// layout every time a background job started.
class ActivityBar extends StatelessWidget {
  final ActivityModel activity;
  final LibraryModel library;

  const ActivityBar({super.key, required this.activity, required this.library});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([activity, library]),
      builder: (context, _) {
        final jobs = activity.active;
        return Container(
          key: const Key('activity-bar'),
          decoration: const BoxDecoration(
            color: AppColors.panelBg,
            border: Border(top: BorderSide(color: AppColors.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: jobs.isEmpty
                    ? const SizedBox(height: 18)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final job in jobs) _row(job)],
                      ),
              ),
              const SizedBox(width: 16),
              Text(
                '${_thousands(library.visibleTracks.length)} tracks',
                key: const Key('footer-track-count'),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.inkSecondary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BackgroundActivity job) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            job.text,
            key: Key('activity-${job.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.ink),
          ),
        ),
        if (job.hasProgress) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: job.fraction,
                minHeight: 4,
                backgroundColor: AppColors.hairline,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

String _thousands(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
