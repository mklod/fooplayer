// What the embed pass actually did, in a window that waits to be read.
//
// This used to be a six-second SnackBar at the end of a pass that runs for
// fifteen minutes over SMB. If you weren't watching the exact moment it
// landed, the entire outcome was gone -- which is how a run that skipped
// two thousand files for a mundane reason ("no artwork chosen for this
// album") came across as a run that had failed.
//
// So: a dialog, dismissed by hand, listing every reason with its count. The
// numbers here are the only account of the pass that exists.
//
// Last modified: 2026-07-28--1745

import 'package:flutter/material.dart';

import '../artwork/artwork_embed_pass.dart';
import 'app_theme.dart';

class EmbedReportDialog extends StatelessWidget {
  final EmbedPassReport report;

  const EmbedReportDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    // Biggest reason first: the one explaining most of the skips is the one
    // that answers "why didn't it do more than that?".
    final reasons = report.reasons.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return AlertDialog(
      key: const Key('embed-report'),
      title: const Text('Artwork embedding finished'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _tally('Covers written into files', report.embedded),
              _tally('Left alone', report.skipped),
              if (report.failed > 0) _tally('Failed', report.failed),
              const SizedBox(height: 4),
              Text(
                '${report.considered} files considered.',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.inkSecondary,
                ),
              ),

              // The one outcome that would quietly damage the library, so it
              // is stated in full rather than folded into a count.
              if (report.datesDisturbed > 0) ...[
                const SizedBox(height: 16),
                Container(
                  key: const Key('embed-report-dates'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEA),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${report.datesDisturbed} file'
                        '${report.datesDisturbed == 1 ? "" : "s"} came back '
                        'with changed dates',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF8B1A10),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'These are the download dates. Check them before '
                        'anything else.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF8B1A10)),
                      ),
                      const SizedBox(height: 8),
                      for (final path in report.disturbedPaths.take(10))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            path,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF8B1A10),
                            ),
                          ),
                        ),
                      if (report.disturbedPaths.length > 10)
                        Text(
                          '…and ${report.disturbedPaths.length - 10} more',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8B1A10),
                          ),
                        ),
                    ],
                  ),
                ),
              ],

              if (reasons.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Why files were left alone',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                for (final reason in reasons)
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
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('embed-report-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _tally(String label, int count) => Padding(
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
