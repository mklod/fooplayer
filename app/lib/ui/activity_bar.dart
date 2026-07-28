// The persistent "here is what I am doing" bar.
//
// Sits above the now-playing bar and stays for the whole duration of whatever
// is running -- the opposite of the three-second toast it replaces, which
// announced a twenty-minute job and then said nothing.
//
// Last modified: 2026-07-28--1730

import 'package:flutter/material.dart';

import '../model/activity_model.dart';
import 'app_theme.dart';

class ActivityBar extends StatelessWidget {
  final ActivityModel activity;

  const ActivityBar({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: activity,
      builder: (context, _) {
        final jobs = activity.active;
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Container(
          key: const Key('activity-bar'),
          decoration: const BoxDecoration(
            color: AppColors.panelBg,
            border: Border(top: BorderSide(color: AppColors.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final job in jobs) _row(job)],
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
