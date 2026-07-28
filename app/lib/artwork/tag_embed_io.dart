// The filesystem half of cover embedding: read, rebuild, write, restore
// timestamps -- and refuse loudly rather than half-do any of it.
//
// Write strategy is tmp-then-rename (same discipline as the manifest and the
// artwork sidecar) so a crash mid-write can never leave a truncated music
// file. The rename is followed by restoring all three Windows timestamps, so
// "date modified" and "date created" read exactly as they did before.
//
// Last modified: 2026-07-27--2010

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../util/win_file_times.dart';
import 'tag_embed.dart';

enum EmbedOutcome {
  /// Cover written; identity and timestamps verified unchanged.
  embedded,

  /// File deliberately left untouched (see [EmbedReport.reason]).
  refused,

  /// Something failed mid-flight; the original is intact.
  failed,
}

class EmbedReport {
  final String path;
  final EmbedOutcome outcome;
  final String reason;

  /// True when the timestamps came back exactly as they went in. Reported
  /// separately from [outcome] so a date-losing write is never mistaken for
  /// a clean one.
  final bool timesPreserved;

  final int bytesBefore;
  final int bytesAfter;

  const EmbedReport({
    required this.path,
    required this.outcome,
    this.reason = '',
    this.timesPreserved = false,
    this.bytesBefore = 0,
    this.bytesAfter = 0,
  });

  @override
  String toString() =>
      '${outcome.name.padRight(8)} ${timesPreserved ? "dates-ok" : "DATES!"} '
      '$path${reason.isEmpty ? "" : "  ($reason)"}';
}

/// Embeds [image] as [file]'s front cover.
///
/// Refuses (leaving the file untouched) when the audio isn't MPEG, the tag
/// shape is unsupported, the image isn't JPEG/PNG, or -- the check that
/// matters most -- the rebuild would have altered the bytes the content ID
/// hashes. Also refuses up front if the current timestamps can't be read,
/// since they could then not be restored.
Future<EmbedReport> embedCover(File file, Uint8List image) async {
  final path = file.path;
  final times = getFileTimes(path);
  if (times == null && Platform.isWindows) {
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.refused,
      reason: 'could not read timestamps -- refusing to write',
    );
  }

  final Uint8List before;
  try {
    before = await file.readAsBytes();
  } catch (e) {
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.failed,
      reason: 'read failed: $e',
    );
  }

  // Dispatch on format: MP3 gets an ID3v2 APIC frame, FLAC a PICTURE
  // metadata block. Both leave their hashed audio range untouched, which is
  // why FLAC needs no conversion to carry a cover.
  final isFlac = p.extension(path).toLowerCase() == '.flac';
  final Uint8List after;
  try {
    after = isFlac
        ? buildTaggedFlac(before, image)
        : buildTaggedMp3(before, image);
  } on EmbedException catch (e) {
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.refused,
      reason: '${e.refusal.name}: ${e.message}',
      bytesBefore: before.length,
    );
  }

  // Belt and braces: prove the hashed range is untouched before anything is
  // written, not after.
  final unchanged = isFlac
      ? flacAudioBytesUnchanged(before, after)
      : audioBytesUnchanged(before, after);
  if (!unchanged) {
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.refused,
      reason: 'audio range would have changed -- identity at risk',
      bytesBefore: before.length,
    );
  }

  final tmp = File('$path.embed-tmp');
  try {
    await tmp.writeAsBytes(after, flush: true);
    await tmp.rename(path);
  } catch (e) {
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.failed,
      reason: 'write failed: $e',
    );
  }

  var restored = true;
  if (times != null) {
    restored = setFileTimes(path, times);
    final now = getFileTimes(path);
    restored =
        restored &&
        now != null &&
        now.lastWrite == times.lastWrite &&
        now.creation == times.creation;
  }

  return EmbedReport(
    path: path,
    outcome: EmbedOutcome.embedded,
    timesPreserved: restored,
    bytesBefore: before.length,
    bytesAfter: after.length,
    reason: restored ? '' : 'TIMESTAMPS NOT RESTORED',
  );
}
