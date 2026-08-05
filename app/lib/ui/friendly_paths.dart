// Friendly display names for Android filesystem paths in the settings
// surfaces -- `/storage/emulated/0/Music` reads as "Internal storage ›
// Music", the app-private data dir as "App storage", a removable card as
// "SD card". Pure string mapping, no Platform gates: desktop paths
// (`L:\music`, `C:\...`) match none of the prefixes and pass through
// unchanged, which is exactly right for the desktop settings dialog that
// shares these widgets.
//
// Display-only, always: config, sync state, and every code path keep the
// real path -- this exists because the raw Android spellings in the
// settings panel were reported as unreadable.
//
// Last modified: 2026-08-05--0810

/// The segment separator in friendly names.
const String _sep = ' › ';

/// Maps an absolute Android path to a readable label, or returns [path]
/// unchanged when it isn't one of the recognized Android shapes.
String friendlyAndroidPath(String path) {
  final normalized = path.replaceAll('\\', '/');

  String tail(String rest) {
    final parts = rest.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '' : _sep + parts.join(_sep);
  }

  // Internal shared storage: /storage/emulated/<user>/...
  final internal = RegExp(r'^/storage/emulated/\d+/?').firstMatch(normalized);
  if (internal != null) {
    return 'Internal storage${tail(normalized.substring(internal.end))}';
  }

  // App-private files dir: /data/user/<n>/<pkg>/files or /data/data/<pkg>/files
  final appFiles = RegExp(
    r'^/data/(user/\d+|data)/[^/]+/files/?',
  ).firstMatch(normalized);
  if (appFiles != null) {
    return 'App storage${tail(normalized.substring(appFiles.end))}';
  }

  // Removable volume: /storage/XXXX-XXXX/...
  final sdCard = RegExp(
    r'^/storage/[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}/?',
  ).firstMatch(normalized);
  if (sdCard != null) {
    return 'SD card${tail(normalized.substring(sdCard.end))}';
  }

  return path;
}
