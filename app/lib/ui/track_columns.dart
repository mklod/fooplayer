// Which columns the library list shows.
//
// Right-clicking the header offers every column here as a checkbox
// (asked for 2026-09-18, alongside the file-path column itself). Title is
// deliberately NOT in the list: a row with no title is not a row.
//
// The playlist view keeps its own fixed four-column layout -- #, Song,
// Album, Time -- because those columns answer a different question
// ("where am I in this playlist") and hiding any of them leaves nothing.
//
// Last modified: 2026-09-18--1600

/// A library-view column the user can hide.
enum TrackColumn {
  artist('Artist'),
  album('Album'),
  path('Path'),
  time('Time'),
  date('Date'),
  art('Art'),
  emb('Emb');

  const TrackColumn(this.label);

  /// What the header and the right-click menu call it.
  final String label;

  /// The stored id, so a renamed label never invalidates a saved choice.
  String get id => name;

  static TrackColumn? byId(String id) {
    for (final c in TrackColumn.values) {
      if (c.id == id) return c;
    }
    return null; // an id from a newer build: ignored, not fatal
  }
}
