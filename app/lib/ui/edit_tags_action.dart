// Running a tag edit: show it immediately, write it in the background.
//
// The first version did the obvious thing -- write every file, then update
// the library -- and it was unusable. Pressing Save on one track sat there
// for about ten seconds before anything moved; a batch of ten took over a
// minute of staring at unchanged rows.
//
// Timing the parts showed the work itself is not slow: the tag rebuild is
// tens of milliseconds, the meta cache 53ms to load, the compilation pass
// 13-45ms, and a full read-rebuild-write over SMB 0.2-1.2s depending on file
// size. What made it feel broken is that all of it ran on the UI path, in
// series, behind whatever the background scan happened to be doing to the
// share at that moment.
//
// So: the library is updated the instant you press Save, before a single
// byte is written, and the writes go to the background with progress in the
// activity footer. If a file then refuses the edit, that track -- and only
// that track -- goes back to showing what it really contains.
//
// Kept out of the dialog and the context menu so the writing seam is
// injectable; no test may put a real file at risk.
//
// Last modified: 2026-07-29--0230

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../artwork/tag_embed.dart';
import '../artwork/tag_embed_io.dart';
import '../metadata/tag_providers.dart';
import '../model/activity_model.dart';
import '../model/library_model.dart';
import '../model/track.dart';
import 'edit_tags_dialog.dart';

/// How a tag write is performed. Production is [writeTags]; tests inject.
typedef TagWriter = Future<EmbedReport> Function(File file, TagEdits edits);

/// Files written at once. The share is the bottleneck and it is far happier
/// with a few requests in flight than with one; the same reasoning (and the
/// same number) as the tag-reading batches.
const int kTagWriteLanes = 4;

/// Opens the edit dialog for [tracks] and applies whatever comes back.
///
/// Returns once the dialog is closed and the library reflects the edit --
/// NOT once the files are written. The writing continues in the background.
Future<void> editTrackTags({
  required BuildContext context,
  required ScaffoldMessengerState messenger,
  required List<Track> tracks,
  required LibraryModel library,
  TagWriter writer = writeTags,
  TagSearch? search,
  ActivityModel? activity,
}) async {
  if (tracks.isEmpty) return;
  final edits = await showDialog<TagEdits>(
    context: context,
    builder: (_) => EditTagsDialog(tracks: tracks, search: search),
  );
  if (edits == null || edits.isEmpty) return;

  // Snapshot BEFORE the optimistic update, so a refused file can be put back.
  final before = {for (final t in tracks) t.contentId: t};

  // The whole point: the list changes now, not after the share answers.
  await library.applyTagEdits(before.keys, edits);

  unawaited(
    _writeInBackground(
      tracks: tracks,
      before: before,
      edits: edits,
      library: library,
      writer: writer,
      messenger: messenger,
      activity: activity,
    ),
  );
}

Future<void> _writeInBackground({
  required List<Track> tracks,
  required Map<String, Track> before,
  required TagEdits edits,
  required LibraryModel library,
  required TagWriter writer,
  required ScaffoldMessengerState messenger,
  ActivityModel? activity,
}) async {
  final label = tracks.length == 1
      ? 'Saving tags'
      : 'Saving tags to ${tracks.length} files';
  activity?.progress(ActivityIds.tagWrite, label, 0, tracks.length);

  final reverted = <Track>[];
  final trouble = <String>[];
  final datesDisturbed = <String>[];
  var done = 0;
  var written = 0;

  Future<void> writeOne(Track t) async {
    final file = File(p.join(t.rootPath, t.relPath));
    try {
      final report = await writer(file, edits);
      switch (report.outcome) {
        case EmbedOutcome.embedded:
          written++;
          if (!report.timesPreserved) datesDisturbed.add(file.path);
        case EmbedOutcome.refused:
          reverted.add(before[t.contentId]!);
          trouble.add('${p.basename(t.relPath)}: ${report.reason}');
        case EmbedOutcome.failed:
          reverted.add(before[t.contentId]!);
          trouble.add('${p.basename(t.relPath)}: ${report.reason}');
      }
    } catch (e) {
      reverted.add(before[t.contentId]!);
      trouble.add('${p.basename(t.relPath)}: $e');
    }
    done++;
    activity?.progress(ActivityIds.tagWrite, label, done, tracks.length);
  }

  try {
    for (var i = 0; i < tracks.length; i += kTagWriteLanes) {
      final end = (i + kTagWriteLanes).clamp(0, tracks.length);
      await Future.wait([for (var j = i; j < end; j++) writeOne(tracks[j])]);
    }
  } finally {
    activity?.finish(ActivityIds.tagWrite);
  }

  // Only what actually failed goes back; everything else keeps the edit it
  // has been showing all along.
  if (reverted.isNotEmpty) await library.restoreTracks(reverted);

  if (trouble.isEmpty && datesDisturbed.isEmpty) return; // silence is success
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        datesDisturbed.isNotEmpty
            ? 'Tags: $written saved — '
                  '${datesDisturbed.length} WITH DATE CHANGES'
            : 'Tags: $written saved, ${trouble.length} could not be '
                  'written — ${trouble.first}',
      ),
      duration: const Duration(seconds: 10),
    ),
  );
}
