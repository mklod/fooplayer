// The phone's "here is what I am doing" strip.
//
// Phone equivalent of the desktop's persistent [ActivityBar] footer, but
// transient rather than permanent: the desktop bar stays up even idle
// because something else (the track count) always lives in that space, so
// hiding it would jump the layout every time a job started or finished.
// This strip has nothing else to hold that space steady, so it simply isn't
// there when idle -- SizedBox.shrink, not a hairline-bordered empty bar.
//
// Sits above the mini-player slot in [PhoneShell]'s bottomNavigationBar --
// this is part of what closed the gap reported live: a sync could be
// running (and dying the moment the phone was backgrounded) with nothing on
// the phone UI anywhere hinting it was in progress at all.
//
// Last modified: 2026-08-04--0131

import 'package:flutter/material.dart';

import '../../model/activity_model.dart';
import '../app_theme.dart';

/// One row per active [BackgroundActivity]: a small spinner + label, with a
/// full-width progress bar underneath once its extent is known.
class PhoneActivityStrip extends StatelessWidget {
  final ActivityModel activity;

  const PhoneActivityStrip({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: activity,
      builder: (context, _) {
        final jobs = activity.active;
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Material(
          key: const Key('phone-activity-strip'),
          color: Colors.white,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.hairline)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final job in jobs) _row(job)],
            ),
          ),
        );
      },
    );
  }

  Widget _row(BackgroundActivity job) {
    return Padding(
      key: Key('phone-activity-${job.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.ink),
                ),
              ),
            ],
          ),
          if (job.hasProgress) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: job.fraction,
                minHeight: 3,
                backgroundColor: AppColors.hairline,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
