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
/// hashes.
Future<EmbedReport> embedCover(File file, Uint8List image) {
  final isFlac = p.extension(file.path).toLowerCase() == '.flac';
  return _rewrite(
    file,
    isFlac: isFlac,
    build: (before) =>
        isFlac ? buildTaggedFlac(before, image) : buildTaggedMp3(before, image),
    outcome: EmbedOutcome.embedded,
  );
}

/// Applies [edits] to [file]'s text tags, leaving its cover and every other
/// frame alone.
///
/// The same rewrite as [embedCover] and therefore the same two guarantees:
/// the audio range is copied verbatim so the content ID cannot move, and the
/// file's dates are restored and read back. On this library those dates ARE
/// the download dates, so a retag that moved one would destroy the record
/// this whole project exists to keep.
///
/// FLAC is refused for now: its metadata is Vorbis comments, a different
/// format from ID3, and guessing at it unverified is how you corrupt the only
/// lossless files in the library.
Future<EmbedReport> writeTags(File file, TagEdits edits) {
  if (p.extension(file.path).toLowerCase() == '.flac') {
    return Future.value(
      EmbedReport(
        path: file.path,
        outcome: EmbedOutcome.refused,
        reason: 'FLAC tag editing is not implemented yet',
      ),
    );
  }
  return _rewrite(
    file,
    isFlac: false,
    build: (before) => buildRetaggedMp3(before, edits),
    outcome: EmbedOutcome.embedded,
  );
}

/// Read, rebuild, prove, write, restore.
///
/// One implementation for every kind of tag write, because the valuable part
/// is not the rebuild -- it is the proof that the hashed range didn't move
/// and the timestamps came back, and that reasoning must not exist twice.
Future<EmbedReport> _rewrite(
  File file, {
  required Uint8List Function(Uint8List before) build,
  required bool isFlac,
  required EmbedOutcome outcome,
}) async {
  final path = file.path;
  // Read the timestamps first: if they can't be read they can't be put back,
  // and finding that out after the write is too late.
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

  final Uint8List after;
  try {
    after = build(before);
  } on EmbedException catch (e) {
    return EmbedReport(
      path: path,
      outcome: EmbedOutcome.refused,
      reason: '${e.refusal.name}: ${e.message}',
      bytesBefore: before.length,
    );
  }

  // Nothing to do -- don't spend a write, and don't risk the dates for it.
  if (after.length == before.length && _identical(before, after)) {
    return EmbedReport(
      path: path,
      outcome: outcome,
      timesPreserved: true,
      bytesBefore: before.length,
      bytesAfter: after.length,
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
    outcome: outcome,
    timesPreserved: restored,
    bytesBefore: before.length,
    bytesAfter: after.length,
    reason: restored ? '' : 'TIMESTAMPS NOT RESTORED',
  );
}

bool _identical(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
