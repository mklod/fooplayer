import 'track.dart';

/// One selected folder in the Folder pane's drill-down navigation (see
/// `LibraryModel.folderPath`/`folderSiblings`): a library root plus a
/// `/`-joined subdirectory prefix below it (empty [sub] = the root itself).
/// A track is inside this scope when its [Track.rootPath] equals [root]
/// exactly AND its [Track.relPath] lives at or below [sub] -- see
/// [trackInFolderScope].
typedef FolderScope = ({String root, String sub});

/// Whether [t] lives inside [scope]: exact root match (root paths come from
/// configured library roots, never free-typed text -- same reasoning as
/// `applyFilters`'s [rootPath] doc) plus a *segment-safe* relPath prefix
/// match: `sub: '2007-08'` matches `2007-08/x.mp3` but NOT `2007-085/x.mp3`
/// (the prefix comparison always includes the trailing `/`).
///
/// Case-insensitive, mirroring [subfolderNames]' casing-agnostic dedupe
/// (and [applyFilters]' artist/album matching): on a case-sensitive
/// filesystem, two differently-cased spellings of the same subfolder can
/// both appear as tracks under [scope.root], and [subfolderNames] merges
/// them into a single Folder-pane entry, so the entry it selects has to
/// match both casings too or drilling into it would silently drop one.
bool trackInFolderScope(Track t, FolderScope scope) {
  if (t.rootPath != scope.root) return false;
  if (scope.sub.isEmpty) return true;
  return t.relPath.toLowerCase().startsWith('${scope.sub.toLowerCase()}/');
}

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
  // legacy whole-root folder filter shape; the Folder pane's drill-down
  // selection now arrives via [folders] instead).
  // Exact match, unlike [genre]'s single-value or [artist]/[album]'s
  // case-insensitive set membership: root paths come straight from
  // configured library roots, never free-typed or tag-derived text, so
  // there's no casing-variance to tolerate and an exact comparison avoids
  // any accidental collision between two differently-cased-but-distinct
  // paths.
  Set<String> rootPath = const {},
  // Folder drill-down scopes (see [FolderScope]): empty list means "no
  // restriction from the Folder pane"; a non-empty list means the track
  // must be inside ANY one of the scopes (Ctrl+click-selected sibling
  // folders OR together, same panel-internal OR semantics as
  // [artist]/[album]/[rootPath]).
  List<FolderScope> folders = const [],
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
    if (folders.isNotEmpty && !folders.any((f) => trackInFolderScope(t, f))) {
      return false;
    }
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q) ||
        t.album.toLowerCase().contains(q);
  }).toList();
}

/// The immediate subdirectory names one level below `rootPath` + [prefix],
/// derived purely from [tracks]' relPaths (relPaths use forward slashes --
/// see `Track.relPath`) -- what the Folder pane lists after drilling into a
/// folder. [prefix] is a `/`-joined subpath below the root, either empty
/// (the root level itself) or WITHOUT a trailing slash (e.g. `'2007-08'`).
///
/// A track sitting directly at the [prefix] level (no further `/` in the
/// remainder of its relPath) contributes NO entry -- its filename is not a
/// directory, so no phantom entries appear. Names dedupe case-insensitively
/// (first casing seen wins) and sort case-insensitively, matching
/// [distinctValues]' conventions.
List<String> subfolderNames(
  List<Track> tracks, {
  required String rootPath,
  String prefix = '',
}) {
  final dirPrefix = prefix.isEmpty ? '' : '$prefix/';
  final seen = <String, String>{}; // lower → first casing
  for (final t in tracks) {
    if (t.rootPath != rootPath) continue;
    if (!t.relPath.startsWith(dirPrefix)) continue;
    final rest = t.relPath.substring(dirPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) continue; // a file at this level, or a degenerate path
    final name = rest.substring(0, slash);
    seen.putIfAbsent(name.toLowerCase(), () => name);
  }
  return seen.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// Whether [tracks] is a non-empty list whose tracks ALL carry the same
/// single, non-empty album (compared case-insensitively, mirroring
/// [applyFilters]' album matching) -- i.e. the list unambiguously shows ONE
/// album's own tracks.
///
/// This is what lets a Folder-pane selection of an album *folder* (e.g.
/// `albums/Alina Baraz & Galimatias - Urban Flora/` under a library root)
/// behave like selecting that album in the Albums pane -- '#' column
/// visible, track-number default sort (see
/// `LibraryModel.folderSelectionIsSingleAlbum`). An empty list is NOT a
/// single album (nothing to show a track order for), and any track with an
/// empty album disqualifies the set (its position in "the" album is
/// unknowable).
bool isSingleAlbum(List<Track> tracks) {
  if (tracks.isEmpty) return false;
  String? albumLower;
  for (final t in tracks) {
    if (t.album.isEmpty) return false;
    final lower = t.album.toLowerCase();
    albumLower ??= lower;
    if (lower != albumLower) return false;
  }
  return true;
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
