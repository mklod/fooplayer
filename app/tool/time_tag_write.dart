// Where the seconds actually go when a tag edit is applied.
//
// Reported as ~10s per track. The engine itself is fast (build + verify are
// tens of ms) and the meta cache is 53ms to load, so this times the REAL
// write path -- onto the SMB share, tmp-then-rename, timestamps restored --
// because that is the only part left that could cost seconds.
//
// Works on a copy in the same directory, so the share's own latency is what
// gets measured and the real file is never touched.
//
// Usage: dart run tool/time_tag_write.dart <file.mp3> [<file.mp3> ...]

import 'dart:io';

import 'package:fooplayer_app/artwork/tag_embed.dart';
import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:path/path.dart' as p;

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: time_tag_write <file.mp3> ...');
    return 64;
  }
  for (final path in args) {
    final source = File(path);
    final size = await source.length();
    final copy = File(p.join(p.dirname(path), '__timing__${p.basename(path)}'));

    final swCopy = Stopwatch()..start();
    await source.copy(copy.path);
    swCopy.stop();

    try {
      final sw = Stopwatch()..start();
      final report = await writeTags(copy, const TagEdits(artist: 'TIMING'));
      sw.stop();
      stdout.writeln(
        '${(size / 1e6).toStringAsFixed(1).padLeft(6)} MB  '
        'writeTags ${sw.elapsedMilliseconds}ms  '
        '(copy took ${swCopy.elapsedMilliseconds}ms)  '
        '${report.outcome.name}  ${p.basename(path)}',
      );
    } finally {
      if (copy.existsSync()) await copy.delete();
    }
  }
  return 0;
}
