// What the app is doing in the background, said out loud.
//
// Long-running work here -- tag reading over SMB, artwork lookups throttled
// to a request a second, embedding covers into thousands of files -- runs for
// minutes. It used to announce itself with a three-second toast and then go
// silent, so "still working" and "finished twenty minutes ago" looked
// identical, and a greyed-out button was the only clue anything was happening
// at all.
//
// Everything long-running registers here instead, and the UI shows a
// persistent bar for as long as anything is registered.
//
// Last modified: 2026-07-28--1730

import 'package:flutter/foundation.dart';

/// One thing happening in the background.
@immutable
class BackgroundActivity {
  /// Stable key, so repeated progress updates replace rather than stack.
  final String id;

  /// What to tell the user -- a plain verb phrase: "Reading tags",
  /// "Embedding artwork".
  final String label;

  /// Progress, when it is known. A pass that can't count its work leaves
  /// these null and gets an indeterminate bar rather than a fake number.
  final int? done;
  final int? total;

  const BackgroundActivity({
    required this.id,
    required this.label,
    this.done,
    this.total,
  });

  bool get hasProgress => done != null && total != null && total! > 0;

  double? get fraction => hasProgress ? (done! / total!).clamp(0.0, 1.0) : null;

  /// "Embedding artwork — 1,204 / 5,470"
  String get text {
    if (!hasProgress) return label;
    return '$label — ${_thousands(done!)} / ${_thousands(total!)}';
  }

  static String _thousands(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// The set of background jobs currently running.
///
/// Deliberately a separate model from [LibraryModel]: the library's `status`
/// string is a description of the LIBRARY, while this is a description of the
/// APP's activity, and several things that are not library work (artwork
/// lookups, embedding) belong here too.
class ActivityModel extends ChangeNotifier {
  final Map<String, BackgroundActivity> _items = {};

  /// Everything currently running, in the order it started.
  List<BackgroundActivity> get active => List.unmodifiable(_items.values);

  bool get isBusy => _items.isNotEmpty;

  /// Registers (or re-labels) a job. Safe to call repeatedly.
  void start(String id, String label) {
    final existing = _items[id];
    if (existing != null && existing.label == label && !existing.hasProgress) {
      return;
    }
    _items[id] = BackgroundActivity(id: id, label: label);
    notifyListeners();
  }

  /// Updates a job's progress. Starts it if it wasn't registered, so a caller
  /// that only ever reports progress still shows up.
  void progress(String id, String label, int done, int total) {
    final existing = _items[id];
    if (existing != null &&
        existing.done == done &&
        existing.total == total &&
        existing.label == label) {
      return; // no visible change -- don't churn the tree
    }
    _items[id] = BackgroundActivity(
      id: id,
      label: label,
      done: done,
      total: total,
    );
    notifyListeners();
  }

  /// Removes a job. Idempotent -- a `finally { finish(id) }` that runs twice
  /// is not an error.
  void finish(String id) {
    if (_items.remove(id) != null) notifyListeners();
  }
}

/// Job ids, in one place so a `finish` can never miss its `start` through a
/// typo.
abstract final class ActivityIds {
  static const library = 'library';
  static const artworkHarvest = 'artwork-harvest';
  static const artworkLookup = 'artwork-lookup';
  static const artworkEmbed = 'artwork-embed';
}
