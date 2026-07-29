// The shell every "that long job finished" report is built from.
//
// These passes run for minutes -- tag reading and artwork lookups over SMB,
// embedding covers into thousands of files. Each used to end in a SnackBar
// lasting a few seconds, so unless you happened to be looking at the window
// at that moment the entire outcome was gone, and a run that skipped
// thousands of files for a mundane reason was indistinguishable from one that
// had failed.
//
// So they end in something that waits to be dismissed, and they all look the
// same while doing it.
//
// Last modified: 2026-07-28--2015

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A dismissible end-of-pass report.
class ReportDialog extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// Key for the dialog itself and, suffixed `-close`, its button -- so each
  /// report stays addressable by name in tests.
  final String reportKey;

  const ReportDialog({
    super.key,
    required this.title,
    required this.reportKey,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: Key(reportKey),
    title: Text(title),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
    actions: [
      FilledButton(
        key: Key('$reportKey-close'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

/// A headline number and what it counted.
class ReportTally extends StatelessWidget {
  final String label;
  final int count;

  const ReportTally(this.count, this.label, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    ),
  );
}

/// A quieter line under the tallies.
class ReportNote extends StatelessWidget {
  final String text;

  const ReportNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
    ),
  );
}

/// Reasons with their counts, biggest first -- the one accounting for most of
/// the skips is the answer to "why didn't it do more than that?".
class ReportReasons extends StatelessWidget {
  final String heading;
  final Map<String, int> reasons;

  const ReportReasons({
    super.key,
    required this.heading,
    required this.reasons,
  });

  @override
  Widget build(BuildContext context) {
    if (reasons.isEmpty) return const SizedBox.shrink();
    final sorted = reasons.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          heading,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        for (final reason in sorted)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    '${reason.value}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    reason.key,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
