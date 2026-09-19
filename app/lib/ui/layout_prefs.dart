import 'dart:async';
import 'package:flutter/foundation.dart';
import 'track_columns.dart';

/// Clamp bounds and defaults for the draggable panel sizes. Kept as public
/// constants so tests and callers can reason about them without duplicating
/// magic numbers.
const double kSidebarWidthMin = 140;
const double kSidebarWidthMax = 400;
const double kSidebarWidthDefault = 200;

const double kFilterHeightMin = 120;
const double kFilterHeightMax = 320;
const double kFilterHeightDefault = 180;

const Duration kLayoutPrefsSaveDebounce = Duration(milliseconds: 500);

/// Persists the `"ui"` subtree of config.json: `{"sidebarWidth": ...,
/// "filterHeight": ...}`. Callers own the actual file I/O -- this class
/// only clamps values and, when a [writer] is supplied, calls it with the
/// current `ui` map after a debounced delay so a flurry of drag updates
/// collapses into a single write.
class LayoutPrefs extends ChangeNotifier {
  double _sidebarWidth;
  double _filterHeight;

  /// Whether the Folder/Artist/Album filter row is collapsed away, leaving
  /// the track list the full height. Persisted like the sizes so the choice
  /// survives a restart.
  bool _filtersCollapsed;

  /// Whether the sidebar's Playlists / Folders sections are unfolded.
  ///
  /// Both default to FOLDED (asked for 2026-09-18): the sidebar's job at
  /// rest is Library, not an inventory of every playlist and root. The
  /// choice is persisted like the sizes, so a session spent inside one
  /// section doesn't start folded again tomorrow.
  bool _playlistsExpanded;
  bool _foldersExpanded;

  /// Library columns the user has hidden from the header's right-click
  /// menu. Empty by default -- everything shows until you say otherwise.
  final Set<TrackColumn> _hiddenColumns;

  /// Column sizes the user has dragged to, by column. Absent means the
  /// column's own default (see [TrackColumn.defaultSize]); the value is a
  /// flex weight or a pixel width depending on the column.
  final Map<TrackColumn, double> _columnSizes;
  final void Function(Map<String, dynamic> ui)? _writer;
  final Duration _debounce;
  Timer? _saveTimer;

  LayoutPrefs({
    double sidebarWidth = kSidebarWidthDefault,
    double filterHeight = kFilterHeightDefault,
    bool filtersCollapsed = false,
    bool playlistsExpanded = false,
    bool foldersExpanded = false,
    Set<TrackColumn> hiddenColumns = const {},
    Map<TrackColumn, double> columnSizes = const {},
    void Function(Map<String, dynamic> ui)? writer,
    Duration debounce = kLayoutPrefsSaveDebounce,
  }) : _sidebarWidth = _clampSidebarWidth(sidebarWidth),
       _filterHeight = _clampFilterHeight(filterHeight),
       // ignore: prefer_initializing_formals
       _playlistsExpanded = playlistsExpanded,
       // ignore: prefer_initializing_formals
       _foldersExpanded = foldersExpanded,
       _hiddenColumns = Set<TrackColumn>.of(hiddenColumns),
       _columnSizes = Map<TrackColumn, double>.of(columnSizes),
       // Same reason as _writer/_debounce below: a `this._filtersCollapsed`
       // initializing formal would expose the private name as the public
       // parameter name.
       // ignore: prefer_initializing_formals
       _filtersCollapsed = filtersCollapsed,
       // Can't use `this._writer`/`this._debounce` initializing formals
       // here: that would make the private field name itself the public
       // named-parameter name, which callers in other files couldn't pass.
       // ignore: prefer_initializing_formals
       _writer = writer,
       // ignore: prefer_initializing_formals
       _debounce = debounce;

  /// Builds a [LayoutPrefs] from the already-decoded `"ui"` map read out of
  /// config.json (or `null` if the key was absent / the file didn't
  /// exist yet), falling back to the defaults for missing/invalid entries.
  factory LayoutPrefs.fromConfig(
    Map<String, dynamic>? ui, {
    void Function(Map<String, dynamic> ui)? writer,
    Duration debounce = kLayoutPrefsSaveDebounce,
  }) {
    final sidebarWidth =
        (ui?['sidebarWidth'] as num?)?.toDouble() ?? kSidebarWidthDefault;
    final filterHeight =
        (ui?['filterHeight'] as num?)?.toDouble() ?? kFilterHeightDefault;
    final filtersCollapsed = ui?['filtersCollapsed'] == true;
    return LayoutPrefs(
      sidebarWidth: sidebarWidth,
      filterHeight: filterHeight,
      filtersCollapsed: filtersCollapsed,
      // Absent (a fresh config, or one written before these existed)
      // means folded -- the deliberate default, not just a falsy read.
      playlistsExpanded: ui?['playlistsExpanded'] == true,
      foldersExpanded: ui?['foldersExpanded'] == true,
      // Unknown ids (a column this build no longer has, or one from a
      // newer build) are dropped rather than treated as an error.
      hiddenColumns: {
        for (final raw in (ui?['hiddenColumns'] as List<dynamic>? ?? const []))
          if (raw is String && TrackColumn.byId(raw) != null)
            TrackColumn.byId(raw)!,
      },
      columnSizes: {
        for (final e
            in (ui?['columnSizes'] as Map<String, dynamic>? ?? const {})
                .entries)
          // Anything narrower than the minimum is not a width this app
          // ever wrote deliberately -- see TrackColumnLayout.widthOf for
          // the upgrade that produced some. Dropped here too, so they
          // are not written back out.
          if (TrackColumn.byId(e.key) != null &&
              e.value is num &&
              (e.value as num) >= kMinColumnWidth)
            TrackColumn.byId(e.key)!: (e.value as num).toDouble(),
      },
      writer: writer,
      debounce: debounce,
    );
  }

  double get sidebarWidth => _sidebarWidth;
  double get filterHeight => _filterHeight;
  bool get filtersCollapsed => _filtersCollapsed;
  bool get playlistsExpanded => _playlistsExpanded;
  bool get foldersExpanded => _foldersExpanded;

  /// Read-only view; mutate through [toggleColumn].
  Set<TrackColumn> get hiddenColumns => Set<TrackColumn>.unmodifiable(
    _hiddenColumns,
  );

  bool isColumnVisible(TrackColumn column) => !_hiddenColumns.contains(column);

  /// Hidden columns and dragged widths together -- what the track list
  /// needs to lay itself out.
  TrackColumnLayout get columnLayout =>
      TrackColumnLayout(hidden: hiddenColumns, sizes: columnSizes);

  Map<TrackColumn, double> get columnSizes =>
      Map<TrackColumn, double>.unmodifiable(_columnSizes);

  double columnSize(TrackColumn column) =>
      _columnSizes[column] ?? column.width;

  /// Drag of the divider after [column]: [delta] is the pointer movement
  /// in pixels, and the new width is clamped into
  /// [kMinColumnWidth]..[maxWidth].
  ///
  /// One column, one width -- no redistribution. The first cut stored
  /// flex weights, so dragging Artist resized Title and Path too; that
  /// was rejected, and this is the whole of the fix.
  void resizeColumn(TrackColumn column, double delta, double maxWidth) {
    if (delta == 0) return;
    final current = columnSize(column);
    final ceiling = maxWidth < kMinColumnWidth ? kMinColumnWidth : maxWidth;
    final next = (current + delta).clamp(kMinColumnWidth, ceiling);
    if (next == current) return;
    _columnSizes[column] = next;
    _scheduleSave();
    notifyListeners();
  }

  /// Puts every column back to its built-in size.
  void resetColumnSizes() {
    if (_columnSizes.isEmpty) return;
    _columnSizes.clear();
    _scheduleSave();
    notifyListeners();
  }

  void toggleColumn(TrackColumn column) {
    if (!_hiddenColumns.remove(column)) _hiddenColumns.add(column);
    _scheduleSave();
    notifyListeners();
  }

  /// Whether the now-playing strip is hidden.
  ///
  /// Deliberately NOT persisted, and deliberately not owned by the strip
  /// itself: the sidebar's selected-track cover needs the same answer. That
  /// preview hides while the strip is up, because the strip already shows a
  /// large cover and two of them is clutter -- so if the strip's own state
  /// were private, dismissing it would leave BOTH covers hidden, which is
  /// the opposite of why anyone dismisses it.
  bool get nowPlayingHidden => _nowPlayingHidden;
  bool _nowPlayingHidden = false;

  /// The track the strip was hidden for. Hiding is not for the session --
  /// it lifts as soon as something different starts, which is the only time
  /// the strip has something new to say.
  String? get nowPlayingHiddenFor => _nowPlayingHiddenFor;
  String? _nowPlayingHiddenFor;

  void hideNowPlaying(String? contentId) {
    _nowPlayingHidden = true;
    _nowPlayingHiddenFor = contentId;
    notifyListeners();
  }

  void showNowPlaying() {
    if (!_nowPlayingHidden) return;
    _nowPlayingHidden = false;
    _nowPlayingHiddenFor = null;
    notifyListeners();
  }

  /// Collapses/expands the filter row (the stored height is kept, so
  /// expanding restores exactly the size the user had dragged to).
  void setFiltersCollapsed(bool collapsed) {
    if (collapsed == _filtersCollapsed) return;
    _filtersCollapsed = collapsed;
    _scheduleSave();
    notifyListeners();
  }

  void toggleFiltersCollapsed() => setFiltersCollapsed(!_filtersCollapsed);

  void setPlaylistsExpanded(bool expanded) {
    if (expanded == _playlistsExpanded) return;
    _playlistsExpanded = expanded;
    _scheduleSave();
    notifyListeners();
  }

  void togglePlaylistsExpanded() => setPlaylistsExpanded(!_playlistsExpanded);

  void setFoldersExpanded(bool expanded) {
    if (expanded == _foldersExpanded) return;
    _foldersExpanded = expanded;
    _scheduleSave();
    notifyListeners();
  }

  void toggleFoldersExpanded() => setFoldersExpanded(!_foldersExpanded);

  static double _clampSidebarWidth(double v) =>
      v.clamp(kSidebarWidthMin, kSidebarWidthMax);
  static double _clampFilterHeight(double v) =>
      v.clamp(kFilterHeightMin, kFilterHeightMax);

  void setSidebarWidth(double value) {
    final clamped = _clampSidebarWidth(value);
    if (clamped == _sidebarWidth) return;
    _sidebarWidth = clamped;
    notifyListeners();
    _scheduleSave();
  }

  void setFilterHeight(double value) {
    final clamped = _clampFilterHeight(value);
    if (clamped == _filterHeight) return;
    _filterHeight = clamped;
    notifyListeners();
    _scheduleSave();
  }

  /// The current `"ui"` map, suitable for writing straight into
  /// config.json under that key.
  Map<String, dynamic> toJson() => {
    'sidebarWidth': _sidebarWidth,
    'filterHeight': _filterHeight,
    'filtersCollapsed': _filtersCollapsed,
    'playlistsExpanded': _playlistsExpanded,
    'foldersExpanded': _foldersExpanded,
    // Sorted so the file doesn't churn on set-iteration order.
    'hiddenColumns': (_hiddenColumns.map((c) => c.id).toList()..sort()),
    'columnSizes': {
      for (final id in (_columnSizes.keys.map((c) => c.id).toList()..sort()))
        id: _columnSizes[TrackColumn.byId(id)!],
    },
  };

  void _scheduleSave() {
    final writer = _writer;
    if (writer == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_debounce, () {
      _saveTimer = null;
      writer(toJson());
    });
  }

  /// If a debounced save is currently pending, cancels the timer and calls
  /// [writer] synchronously with the latest values right now instead of
  /// waiting out the rest of the debounce window.
  ///
  /// This is what makes a drag-then-immediately-close-the-app sequence
  /// durable: without an explicit flush, a pending write is only ever
  /// delivered by the [Timer] firing on its own schedule, which a process
  /// exit can cut off entirely. No-op if nothing is pending (nothing
  /// changed since the last save, or no [writer] was supplied).
  void flush() {
    final timer = _saveTimer;
    if (timer == null) return;
    timer.cancel();
    _saveTimer = null;
    _writer?.call(toJson());
  }

  @override
  void dispose() {
    flush();
    super.dispose();
  }
}
