import '../manifest.dart';
import '../scanner.dart' show audioExtensions;

class PlaylistImportResult {
  final Playlist playlist;
  final List<String> unmatched;
  PlaylistImportResult(this.playlist, this.unmatched);
}

PlaylistImportResult importTxtPlaylist(
  String name,
  List<String> lines,
  Map<String, String> basenameToId,
) {
  final trackIds = <String>[];
  final unmatched = <String>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    // Take the basename regardless of slash style.
    final base = line.split(RegExp(r'[\\/]')).last.toLowerCase();
    String? id = basenameToId[base];
    if (id == null && !base.contains('.')) {
      for (final ext in audioExtensions) {
        id = basenameToId['$base$ext'];
        if (id != null) break;
      }
    }
    if (id != null) {
      trackIds.add(id);
    } else {
      unmatched.add(line);
    }
  }
  return PlaylistImportResult(Playlist(name: name, trackIds: trackIds), unmatched);
}
