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
import 'dart:typed_data';

import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_app/metadata/tags.dart';
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
      final audioOk = p.extension(path).toLowerCase() == '.flac'
          ? flacAudioBytesUnchanged(before, after)
          : audioBytesUnchanged(before, after);
      final dateOk = mtimeAfter == originalTimes;
      final isFlac = p.extension(path).toLowerCase() == '.flac';
      bool art(List<int> bytes) => isFlac
          ? parseFlacBlocks(Uint8List.fromList(bytes))
                .blocks
                .any((b) => b.$1 == kFlacBlockPicture)
          : parseId3(Uint8List.fromList(bytes)).frames.any((f) => f.id == 'APIC');
      final hasArt = art(after);
      final hadArt = art(before);
      final tags = isFlac
          ? parseVorbisComment(parseFlacBlocks(after)
                  .blocks
                  .firstWhere((b) => b.$1 == kFlacBlockVorbisComment)
                  .$2)
              .comments
              .where((c) => c.toUpperCase().startsWith('ARTIST=') ||
                  c.toUpperCase().startsWith('ALBUM='))
              .toList()
          : <String>[];

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
      // Round-trip through the app's OWN reader, not just the writer's
      // idea of what it wrote -- that is the pair that has to agree.
      final readBack = await readTags(copy);
      final readOk = readBack.artist == 'VERIFY Artist ünïcøde' &&
          readBack.album == 'VERIFY Album';
      if (!readOk) bad++;
      stdout.writeln('       reader sees artist=${readBack.artist} '
          'album=${readBack.album} ${readOk ? "" : "<-- MISMATCH"}');
      stdout.writeln('       ${before.length} -> ${after.length} bytes');
      if (tags.isNotEmpty) stdout.writeln('       wrote: ${tags.join('  ')}');
    }
  } finally {
    await work.delete(recursive: true);
  }
  return bad == 0 ? 0 : 1;
}
