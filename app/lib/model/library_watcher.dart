// Watch-driven library indexing: react when music actually lands, instead
// of crawling the whole share on a timer.
//
// Measured on the real NAS (2026-09-10): one full stat-walk of the five
// roots is ~31s over SMB for ~7,000 files. On the old five-minute timer
// that is a ~10% duty cycle of continuous SMB chatter, forever, almost
// always to discover that nothing changed. Samba answers SMB2
// CHANGE_NOTIFY (verified against this server: create/modify/delete all
// delivered within milliseconds, recursively), so the server can simply
// tell us -- idle cost is one pending request per root.
//
// This is deliberately NOT the only mechanism: change notification can
// silently drop events (a dropped connection, a server that stops
// notifying, a watch that errors out). main.dart keeps a slow full-rescan
// timer as the safety net, so the worst case degrades to plain polling
// rather than to "new music never appears".
//
// Last modified: 2026-09-10--0410

import 'dart:async';
import 'dart:io';

/// Opens a change stream for one root, yielding the PATH of whatever
/// changed. Paths rather than [FileSystemEvent]s because that is all this
/// class ever reads -- and because `FileSystemEvent` is sealed, so a test
/// cannot construct one. Injected so tests drive events through a
/// controller instead of a real filesystem watch (inherently
/// timing-dependent and platform-specific).
typedef WatchFactory = Stream<String> Function(String root);

Stream<String> _defaultWatch(String root) =>
    Directory(root).watch(recursive: true).map((event) => event.path);

/// Calls [onChanged] shortly after music appears in (or disappears from)
/// any watched root.
///
/// Two properties do the real work:
///
/// **Self-trigger immunity.** A rescan WRITES into the very directories
/// being watched -- `.library.json`, its `.bak`, `.hash_cache.json`, the
/// artwork sidecars. Reacting to those would loop forever: scan -> write
/// -> event -> scan. Every path containing a dot-segment is therefore
/// ignored ([_isIgnored]); real music files never start with a dot, and
/// every file this app writes does.
///
/// **Quiet-period debounce.** A download is written progressively, so the
/// first event arrives while the file is still half-written -- hashing it
/// then would mint a content ID for a partial file. [quietPeriod] waits
/// for the root to go silent before scanning, so files are complete by the
/// time they are indexed.
class LibraryWatcher {
  final List<String> roots;
  final Future<void> Function() onChanged;
  final Duration quietPeriod;
  final WatchFactory _watch;

  /// Reported (not thrown) so the caller can log a root that could not be
  /// watched -- the safety-net poll still covers it.
  final void Function(String root, Object error)? onWatchError;

  LibraryWatcher({
    required this.roots,
    required this.onChanged,
    this.quietPeriod = const Duration(seconds: 60),
    WatchFactory? watchFactory,
    this.onWatchError,
  }) : _watch = watchFactory ?? _defaultWatch;

  final List<StreamSubscription<String>> _subs = [];
  Timer? _debounce;
  bool _running = false;
  bool _pending = false;
  bool _disposed = false;

  /// Roots successfully being watched. A root that threw on subscribe is
  /// absent -- useful for a status line, and for telling "nothing changed"
  /// apart from "nothing was ever watched".
  final List<String> watchedRoots = [];

  void start() {
    for (final root in roots) {
      try {
        final sub = _watch(root).listen(
          _onEvent,
          onError: (Object e) => onWatchError?.call(root, e),
          cancelOnError: false,
        );
        _subs.add(sub);
        watchedRoots.add(root);
      } catch (e) {
        // A root that vanished, or a filesystem that can't watch: the
        // hourly rescan still covers it.
        onWatchError?.call(root, e);
      }
    }
  }

  void _onEvent(String path) {
    if (_disposed) return;
    if (_isIgnored(path)) return;
    _debounce?.cancel();
    _debounce = Timer(quietPeriod, _fire);
  }

  /// True for anything this app writes into a watched root -- see the
  /// class doc's self-trigger note. Matches a dot-segment anywhere in the
  /// path, so `.artwork/cover.jpg` and `.sync_tmp/partial.mp3` are covered
  /// as well as the top-level sidecars.
  static bool _isIgnored(String path) {
    for (final segment in path.split(RegExp(r'[\\/]'))) {
      if (segment.length > 1 && segment.startsWith('.')) return true;
    }
    return false;
  }

  void _fire() {
    _debounce = null;
    if (_running) {
      // Something landed while a scan was already in flight; run exactly
      // one more pass afterwards rather than queueing per event.
      _pending = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    try {
      do {
        _pending = false;
        try {
          await onChanged();
        } catch (_) {
          // A failed scan must not kill the watcher -- the next event (or
          // the safety-net poll) tries again.
        }
      } while (_pending && !_disposed);
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
