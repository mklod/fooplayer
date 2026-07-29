// Prints the content ID of each file named on the command line.
//
// Exists so tools outside Dart -- notably `tools/convert_to_mp3.py`, which
// has to migrate a manifest entry onto a re-encoded file's new ID -- can ask
// the core for an ID instead of reimplementing the hashing and drifting from
// it. The ID skips tag blocks and hashes audio bytes only, which is the whole
// reason a retag doesn't reset a track's date-added.
//
// Output: one `<64-hex>  <basename>` line per file, two spaces between, which
// is the format convert_to_mp3.py parses. Unreadable files go to stderr and
// set a non-zero exit, so a caller can tell "no ID" from "no output".
//
// Usage: dart run bin/content_id.dart <file> [<file> ...]
//
// Last modified: 2026-07-28--1855

import 'dart:io';

import 'package:fooplayer_core/fooplayer_core.dart';

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: content_id <file> [<file> ...]');
    return 64;
  }
  var failed = 0;
  for (final path in args) {
    try {
      final id = await contentIdForFile(File(path));
      stdout.writeln('$id  ${_basename(path)}');
    } catch (e) {
      stderr.writeln('$path: $e');
      failed++;
    }
  }
  return failed == 0 ? 0 : 1;
}

/// Deliberately not `package:path` -- this runs against Windows paths handed
/// over by a Python caller, and both separators turn up in them.
String _basename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}
