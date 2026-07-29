// Proves a tag edit against REAL library bytes, on a copy.
//
// The unit tests build their own mp3s, which is the right way to test the
// parser but says nothing about the files this library actually holds --
// stacked v2.3+v2.4 tags, APEv2 trailers, junk between the tag and the first
// frame. This takes a real file, copies it, edits the copy, and checks the
// three things that matter: the content ID didn't move, the audio range is
// byte-identical, and the timestamps came back.
//
// Usage: dart run tool/verify_tag_write.dart <file.mp3> [<file.mp3> ...]

import 'dart:io';

import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;
import 'package:path/path.dart' as p;

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: verify_tag_write <file.mp3> ...');
    return 64;
  }
  final work = await Directory.systemTemp.createTemp('tagverify');
  var bad = 0;
  try {
    for (final path in args) {
      final source = File(path);
      final copy = File(p.join(work.path, p.basename(path)));
      await source.copy(copy.path);

      final originalTimes = (await source.stat()).modified;
      await copy.setLastModified(originalTimes);

      final before = await copy.readAsBytes();
      final idBefore = contentIdForBytes(p.basename(path), before);

      final report = await writeTags(
        copy,
        const TagEdits(
          artist: 'VERIFY Artist ünïcøde',
          album: 'VERIFY Album',
        ),
      );

      final after = await copy.readAsBytes();
      final idAfter = contentIdForBytes(p.basename(path), after);
      final mtimeAfter = await copy.lastModified();

      final idOk = idBefore == idAfter;
      final audioOk = audioBytesUnchanged(before, after);
      final dateOk = mtimeAfter == originalTimes;
      final tag = parseId3(after);
      final hasArt = tag.frames.any((f) => f.id == 'APIC');
      final hadArt = parseId3(before).frames.any((f) => f.id == 'APIC');

      final ok =
          report.outcome == EmbedOutcome.embedded &&
          idOk &&
          audioOk &&
          dateOk &&
          hasArt == hadArt;
      if (!ok) bad++;

      stdout.writeln('${ok ? "OK  " : "BAD "} ${p.basename(path)}');
      stdout.writeln('       outcome=${report.outcome.name} '
          '${report.reason.isEmpty ? "" : "(${report.reason})"}');
      stdout.writeln('       contentId ${idOk ? "unchanged" : "CHANGED"}  '
          'audio ${audioOk ? "identical" : "MOVED"}  '
          'date ${dateOk ? "restored" : "LOST"}  '
          'cover ${hadArt ? (hasArt ? "kept" : "LOST") : "n/a"}');
      stdout.writeln('       ${before.length} -> ${after.length} bytes');
    }
  } finally {
    await work.delete(recursive: true);
  }
  return bad == 0 ? 0 : 1;
}
