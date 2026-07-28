import 'package:flutter/foundation.dart';

/// Holds the app's configured library-root paths and persists every change
/// immediately via [writer].
///
/// Unlike [LayoutPrefs]' debounced numeric writes (dragging a divider fires
/// many times a second), adding or removing a whole library root is a rare,
/// deliberate action from the settings dialog, so there's no benefit to
/// delaying the save -- and doing it immediately means a crash right after
/// the change can never lose it.
///
/// Notifies listeners after every change so callers (see main.dart) can
/// trigger a [LibraryModel] reload whenever the configured roots change.
class LibraryRootsPrefs extends ChangeNotifier {
  List<String> roots;
  final void Function(List<String> roots) writer;

  LibraryRootsPrefs({required List<String> roots, required this.writer})
    : roots = List<String>.of(roots);

  /// Adds [path] if it isn't already configured. No-op (and no write/reload)
  /// on a duplicate.
  void addRoot(String path) {
    if (roots.contains(path)) return;
    roots = [...roots, path];
    writer(roots);
    notifyListeners();
  }

  /// Removes [path]. No-op (and no write/reload) if it isn't configured.
  void removeRoot(String path) {
    if (!roots.contains(path)) return;
    roots = roots.where((r) => r != path).toList();
    writer(roots);
    notifyListeners();
  }
}
