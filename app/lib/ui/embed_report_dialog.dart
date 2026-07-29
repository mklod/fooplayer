// What the embed pass actually did, in a window that waits to be read.
//
// This used to be a six-second SnackBar at the end of a pass that runs for
// fifteen minutes over SMB. If you weren't watching the exact moment it
// landed, the entire outcome was gone -- which is how a run that skipped
// four thousand files for a mundane reason ("no artwork chosen for this
// album") came across as a run that had failed.
//
// Last modified: 2026-07-28--2015

import 'package:flutter/material.dart';

import '../artwork/artwork_embed_pass.dart';
import 'report_dialog.dart';

class EmbedReportDialog extends StatelessWidget {
  final EmbedPassReport report;

  const EmbedReportDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) => ReportDialog(
    reportKey: 'embed-report',
    title: 'Artwork embedding finished',
    children: [
      ReportTally(report.embedded, 'Covers written into files'),
      ReportTally(report.skipped, 'Left alone'),
      if (report.failed > 0) ReportTally(report.failed, 'Failed'),
      ReportNote('${report.considered} files considered.'),

      // The one outcome that would quietly damage the library, so it is
      // stated in full rather than folded into a count.
      if (report.datesDisturbed > 0) _datesWarning(),

      ReportReasons(
        heading: 'Why files were left alone',
        reasons: report.reasons,
      ),
    ],
  );

  Widget _datesWarning() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Container(
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
            '${report.datesDisturbed == 1 ? "" : "s"} came back with '
            'changed dates',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8B1A10),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'These are the download dates. Check them before anything else.',
            style: TextStyle(fontSize: 12, color: Color(0xFF8B1A10)),
          ),
          const SizedBox(height: 8),
          for (final path in report.disturbedPaths.take(10))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                path,
                style: const TextStyle(fontSize: 11, color: Color(0xFF8B1A10)),
              ),
            ),
          if (report.disturbedPaths.length > 10)
            Text(
              '…and ${report.disturbedPaths.length - 10} more',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B1A10)),
            ),
        ],
      ),
    ),
  );
}
