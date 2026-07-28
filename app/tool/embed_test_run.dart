// ignore_for_file: avoid_print -- diagnostic CLI, output IS the point
// Drives cover embedding over a folder and prints a before/after audit:
// content ID, timestamps, and size for every file. Written for the
// testdata/embed-test sandbox -- run it there, read the table, and only then
// consider pointing anything at the real library.
//
// Usage: dart run tool/embed_test_run.dart <folder> <cover.jpg>
import 'dart:io';
import 'dart:typed_data';

import 'package:fooplayer_app/artwork/tag_embed_io.dart';
import 'package:fooplayer_app/util/win_file_times.dart';
import 'package:fooplayer_core/fooplayer_core.dart' show contentIdForBytes;
import 'package:path/path.dart' as p;

String _short(String id) => '${id.substring(0, 8)}…';

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final image = Uint8List.fromList(await File(args[1]).readAsBytes());

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => const {'.mp3', '.m4a', '.flac'}
          .contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('cover: ${args[1]} (${image.length} bytes)\n');
  for (final f in files) {
    final name = p.basename(f.path);
    final beforeBytes = await f.readAsBytes();
    final beforeId = contentIdForBytes(name, beforeBytes);
    final beforeTimes = getFileTimes(f.path);

    final report = await embedCover(f, image);

    final afterBytes = await f.readAsBytes();
    final afterId = contentIdForBytes(name, afterBytes);
    final afterTimes = getFileTimes(f.path);

    final idSame = beforeId == afterId;
    final datesSame = beforeTimes != null &&
        afterTimes != null &&
        beforeTimes.lastWrite == afterTimes.lastWrite &&
        beforeTimes.creation == afterTimes.creation;

    print(name);
    print('  outcome : ${report.outcome.name}'
        '${report.reason.isEmpty ? "" : "  — ${report.reason}"}');
    print('  id      : ${_short(beforeId)} -> ${_short(afterId)}  '
        '${idSame ? "SAME ✓" : "CHANGED ✗"}');
    print('  dates   : ${beforeTimes?.lastWriteUtc} -> ${afterTimes?.lastWriteUtc}  '
        '${datesSame ? "SAME ✓" : "CHANGED ✗"}');
    print('  size    : ${beforeBytes.length} -> ${afterBytes.length}');
    print('');
  }
}
