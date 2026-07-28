import 'dart:async';
import 'package:flutter/foundation.dart';

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
  final void Function(Map<String, dynamic> ui)? _writer;
  final Duration _debounce;
  Timer? _saveTimer;

  LayoutPrefs({
    double sidebarWidth = kSidebarWidthDefault,
    double filterHeight = kFilterHeightDefault,
    bool filtersCollapsed = false,
    void Function(Map<String, dynamic> ui)? writer,
    Duration debounce = kLayoutPrefsSaveDebounce,
  }) : _sidebarWidth = _clampSidebarWidth(sidebarWidth),
       _filterHeight = _clampFilterHeight(filterHeight),
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
      writer: writer,
      debounce: debounce,
    );
  }

  double get sidebarWidth => _sidebarWidth;
  double get filterHeight => _filterHeight;
  bool get filtersCollapsed => _filtersCollapsed;

  /// Collapses/expands the filter row (the stored height is kept, so
  /// expanding restores exactly the size the user had dragged to).
  void setFiltersCollapsed(bool collapsed) {
    if (collapsed == _filtersCollapsed) return;
    _filtersCollapsed = collapsed;
    _scheduleSave();
    notifyListeners();
  }

  void toggleFiltersCollapsed() => setFiltersCollapsed(!_filtersCollapsed);

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
