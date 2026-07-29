// What the artwork enrichment found, in a window that waits to be read.
//
// Enrichment is two passes: adopt the covers already sitting in the folders,
// then ask three providers about whatever is still bare. Both used to end in
// a SnackBar, on a job that is throttled to about a request a second and runs
// for many minutes -- so "did the enrichment complete? there's no
// confirmation on it" was a fair question with no way to answer it.
//
// The albums-checked count matters as much as the found count: a pass that
// checked 119 compilations and found nothing has done its job, and says so,
// rather than looking like it did nothing.
//
// Last modified: 2026-07-28--2015

import 'package:flutter/material.dart';

import '../artwork/local_art_harvest.dart';
import 'report_dialog.dart';

class EnrichReportDialog extends StatelessWidget {
  /// Null when no sidecar store was wired, so no harvest ran.
  final HarvestReport? harvest;

  /// Covers the online lookup applied, and how many albums it examined.
  final int found;
  final int albumsChecked;

  const EnrichReportDialog({
    super.key,
    required this.harvest,
    required this.found,
    required this.albumsChecked,
  });

  @override
  Widget build(BuildContext context) {
    final h = harvest;
    return ReportDialog(
      reportKey: 'enrich-report',
      title: 'Artwork enrichment finished',
      children: [
        if (h != null) ...[
          ReportTally(h.adopted, 'Covers adopted from your folders'),
        ],
        ReportTally(found, 'Covers found online'),
        ReportNote('$albumsChecked albums checked.'),
        if (h != null)
          ReportReasons(
            heading: 'Albums with nothing to adopt locally',
            reasons: {
              if (h.skippedNoImage > 0)
                'no image file in the album folder': h.skippedNoImage,
              if (h.skippedTooSmall > 0)
                'only a thumbnail, too small to use': h.skippedTooSmall,
              if (h.failed > 0) 'could not be read': h.failed,
            },
          ),
        if (found == 0 && albumsChecked > 0)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'Nothing found online is a real answer, not a failure — '
              'bootleg compilations and self-released tracks often have no '
              'cover anywhere. They are remembered as checked, and skipped '
              'for two weeks.',
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }
}
