// Last modified: 2026-07-31--1551
import 'dart:io';
import 'package:path/path.dart' as p;

/// Where `.playlists/` lives: [override] (config key `libraryHome`) verbatim,
/// else the deepest directory that is an ancestor-or-parent of every root.
/// Null when that doesn't exist — callers refuse playlist writes with a clear
/// message rather than guessing.
String? resolveLibraryHome(List<String> rootPaths, {String? override}) {
  if (override != null && override.isNotEmpty) return override;
  if (rootPaths.isEmpty) return null;
  var common = p.dirname(rootPaths.first);
  for (final root in rootPaths.skip(1)) {
    var candidate = p.dirname(root);
    while (!p.equals(candidate, common) &&
        !p.isWithin(common, candidate) &&
        !p.isWithin(candidate, common)) {
      final up = p.dirname(common);
      if (p.equals(up, common)) return null; // hit the filesystem root
      common = up;
    }
    if (p.isWithin(common, candidate)) {
      // candidate is deeper — common already covers it
    } else if (p.isWithin(candidate, common)) {
      common = candidate;
    }
  }
  return common;
}

/// Who signs `modified_by` in playlist files. Config `deviceName` if set,
/// else the OS hostname — good enough to tell tablet from desktop in reports.
String deviceLabel(Map<String, dynamic> configRaw) {
  final name = configRaw['deviceName'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  return Platform.localHostname;
}
