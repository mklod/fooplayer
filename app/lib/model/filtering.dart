import 'track.dart';

List<Track> sortByDateAddedDesc(List<Track> tracks) {
  final indexed = tracks.asMap().entries.toList();
  indexed.sort((a, b) {
    final byDate = b.value.dateAdded.compareTo(a.value.dateAdded);
    return byDate != 0 ? byDate : a.key.compareTo(b.key); // stable on ties
  });
  return indexed.map((e) => e.value).toList();
}

/// Filters [all] down to tracks matching every given criterion (fields
/// AND together). [artist]/[album]/[rootPath] are *sets*: an empty set
/// means "no restriction from this panel" (matches everything), a
/// non-empty set means the track's field must match ANY one of its
/// values -- i.e. within one filter panel, values OR together, matching
/// standard foobar2000 multi-select behavior (Ctrl+click several artists
/// to see tracks from any of them; combine with an Album selection and
/// only tracks satisfying both narrow the list further).
List<Track> applyFilters(
  List<Track> all, {
  String? genre,
  Set<String> artist = const {},
  Set<String> album = const {},
  // The track's library root ([Track.rootPath]) to restrict to (the
  // Folder filter panel's selection -- see LibraryModel.folderFilters).
  // Exact match, unlike [genre]'s single-value or [artist]/[album]'s
  // case-insensitive set membership: root paths come straight from
  // configured library roots, never free-typed or tag-derived text, so
  // there's no casing-variance to tolerate and an exact comparison avoids
  // any accidental collision between two differently-cased-but-distinct
  // paths.
  Set<String> rootPath = const {},
  String search = '',
}) {
  final q = search.trim().toLowerCase();
  final artistLower = {for (final v in artist) v.toLowerCase()};
  final albumLower = {for (final v in album) v.toLowerCase()};
  bool eq(String field, String? filter) =>
      filter == null || field.toLowerCase() == filter.toLowerCase();
  bool inSet(String field, Set<String> filterLower) =>
      filterLower.isEmpty || filterLower.contains(field.toLowerCase());
  bool inSetExact(String field, Set<String> filter) =>
      filter.isEmpty || filter.contains(field);
  return all.where((t) {
    if (!eq(t.genre, genre) ||
        !inSet(t.artist, artistLower) ||
        !inSet(t.album, albumLower) ||
        !inSetExact(t.rootPath, rootPath)) {
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
