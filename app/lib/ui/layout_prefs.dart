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
  final void Function(Map<String, dynamic> ui)? _writer;
  final Duration _debounce;
  Timer? _saveTimer;

  LayoutPrefs({
    double sidebarWidth = kSidebarWidthDefault,
    double filterHeight = kFilterHeightDefault,
    void Function(Map<String, dynamic> ui)? writer,
    Duration debounce = kLayoutPrefsSaveDebounce,
  })  : _sidebarWidth = _clampSidebarWidth(sidebarWidth),
        _filterHeight = _clampFilterHeight(filterHeight),
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
    return LayoutPrefs(
      sidebarWidth: sidebarWidth,
      filterHeight: filterHeight,
      writer: writer,
      debounce: debounce,
    );
  }

  double get sidebarWidth => _sidebarWidth;
  double get filterHeight => _filterHeight;

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
  Map<String, dynamic> toJson() =>
      {'sidebarWidth': _sidebarWidth, 'filterHeight': _filterHeight};

  void _scheduleSave() {
    final writer = _writer;
    if (writer == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_debounce, () => writer(toJson()));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
