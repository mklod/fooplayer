import 'track.dart';

List<Track> sortByDateAddedDesc(List<Track> tracks) {
  final indexed = tracks.asMap().entries.toList();
  indexed.sort((a, b) {
    final byDate = b.value.dateAdded.compareTo(a.value.dateAdded);
    return byDate != 0 ? byDate : a.key.compareTo(b.key); // stable on ties
  });
  return indexed.map((e) => e.value).toList();
}

List<Track> applyFilters(
  List<Track> all, {
  String? genre,
  String? artist,
  String? album,
  // The track's library root ([Track.rootPath]) to restrict to (the
  // Folder filter panel's selection -- see LibraryModel.folderFilter).
  // Exact match, unlike [genre]/[artist]/[album]'s case-insensitive [eq]:
  // root paths come straight from configured library roots, never
  // free-typed or tag-derived text, so there's no casing-variance to
  // tolerate and an exact comparison avoids any accidental collision
  // between two differently-cased-but-distinct paths.
  String? rootPath,
  String search = '',
}) {
  final q = search.trim().toLowerCase();
  bool eq(String field, String? filter) =>
      filter == null || field.toLowerCase() == filter.toLowerCase();
  bool eqExact(String field, String? filter) => filter == null || field == filter;
  return all.where((t) {
    if (!eq(t.genre, genre) ||
        !eq(t.artist, artist) ||
        !eq(t.album, album) ||
        !eqExact(t.rootPath, rootPath)) {
      return false;
    }
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q) ||
        t.album.toLowerCase().contains(q);
  }).toList();
}

List<String> distinctValues(List<Track> tracks, String Function(Track) field) {
  final seen = <String, String>{}; // lower → first casing
  for (final t in tracks) {
    final v = field(t);
    if (v.isEmpty) continue;
    seen.putIfAbsent(v.toLowerCase(), () => v);
  }
  final out = seen.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}
