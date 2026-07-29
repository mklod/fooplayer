// Running a tag edit: ask, write, tell the truth about what happened.
//
// Kept out of the dialog and out of the context menu so the writing seam is
// injectable -- no test may put a real file at risk, and the whole point of
// this feature is that it does not damage the files it touches.
//
// Last modified: 2026-07-28--2130

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../artwork/tag_embed.dart';
import '../artwork/tag_embed_io.dart';
import '../model/library_model.dart';
import '../model/track.dart';
import 'edit_tags_dialog.dart';

/// How a tag write is performed. Production is [writeTags]; tests inject.
typedef TagWriter = Future<EmbedReport> Function(File file, TagEdits edits);

/// Opens the edit dialog for [tracks] and applies whatever comes back.
///
/// Reports per outcome rather than claiming success: a file the engine
/// refuses (FLAC, or something that isn't really an mp3) is named, and a file
/// whose dates did NOT come back is called out on its own, because on this
/// library those dates are the download dates.
Future<void> editTrackTags({
  required BuildContext context,
  required ScaffoldMessengerState messenger,
  required List<Track> tracks,
  required LibraryModel library,
  TagWriter writer = writeTags,
}) async {
  if (tracks.isEmpty) return;
  final edits = await showDialog<TagEdits>(
    context: context,
    builder: (_) => EditTagsDialog(tracks: tracks),
  );
  if (edits == null || edits.isEmpty) return;

  final written = <String>[];
  final refused = <String>[];
  final failed = <String>[];
  final datesDisturbed = <String>[];

  for (final t in tracks) {
    final file = File(p.join(t.rootPath, t.relPath));
    EmbedReport report;
    try {
      report = await writer(file, edits);
    } catch (e) {
      failed.add('${p.basename(t.relPath)}: $e');
      continue;
    }
    switch (report.outcome) {
      case EmbedOutcome.embedded:
        written.add(t.contentId);
        if (!report.timesPreserved) datesDisturbed.add(file.path);
      case EmbedOutcome.refused:
        refused.add('${p.basename(t.relPath)}: ${report.reason}');
      case EmbedOutcome.failed:
        failed.add('${p.basename(t.relPath)}: ${report.reason}');
    }
  }

  // Only the files that actually took the edit get their cached tags
  // updated -- a refused file must keep showing what it really contains.
  await library.applyTagEdits(written, edits);

  final parts = <String>[
    if (written.isNotEmpty) '${written.length} updated',
    if (refused.isNotEmpty) '${refused.length} skipped',
    if (failed.isNotEmpty) '${failed.length} failed',
  ];
  final trouble = [...refused, ...failed];
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        datesDisturbed.isNotEmpty
            ? 'Tags: ${parts.join(', ')} — '
                  '${datesDisturbed.length} WITH DATE CHANGES'
            : 'Tags: ${parts.isEmpty ? "nothing to do" : parts.join(', ')}'
                  '${trouble.isEmpty ? "" : " — ${trouble.first}"}',
      ),
      duration: Duration(
        seconds: datesDisturbed.isNotEmpty || trouble.isNotEmpty ? 10 : 4,
      ),
    ),
  );
}
