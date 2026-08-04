// SyncForegroundNotifier: mirrors ActivityModel's `sync` job onto Android's
// SyncForegroundService (see android/.../SyncForegroundService.kt and
// SmbBridge.kt's three `syncFg*` MethodChannel handlers) -- a system-wide
// progress notification that ALSO keeps the sync's network alive while the
// app is backgrounded.
//
// Reported live: a sync survived fine with the app in the foreground and
// died with "connection closed midstream" the moment the phone screen
// locked -- Android cutting a backgrounded process's network -- and there
// was no indicator anywhere, on the phone, that a sync was even running.
// This class is the Dart half of the fix: it watches [ActivityModel] for
// the sync job (see [ActivityIds.sync]) the same way [ActivityBar] already
// does for the desktop strip, and translates its appear/change/disappear
// into start/update/stop calls against the platform channel.
//
// Deliberately push-only: nothing reads state back off this class, so it
// is not itself a ChangeNotifier.
//
// Last modified: 2026-08-04--0131

import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

import '../model/activity_model.dart';

/// Sends one platform-channel call. Production wires the same `smb`
/// MethodChannel SmbBridge.kt already listens on (see main.dart); tests
/// substitute a recording fake.
typedef ForegroundInvoker =
    Future<void> Function(String method, [Map<String, Object?>? args]);

/// Watches [activity] for [ActivityIds.sync] and mirrors it onto Android's
/// foreground service via [invoke].
class SyncForegroundNotifier {
  final ActivityModel _activity;
  final ForegroundInvoker _invoke;
  final Future<void> Function() _requestNotificationPermission;

  /// Whether the service currently believes a sync notification is up --
  /// tracked here (not read back from [_activity]) so a re-`start` only
  /// fires on a genuine appear-after-disappear, never on every notify()
  /// while the job is merely continuing.
  bool _present = false;

  /// The last `job.text` a start/update call was sent for, so a notify()
  /// that didn't actually change the visible text (e.g. some OTHER job in
  /// the model changed) doesn't churn the notification.
  String? _lastText;

  // Re-entrancy guard: [ActivityModel] can notify faster than a platform
  // channel round-trip returns (a burst of progress() calls mid-download).
  // Rather than queuing one invoke per notification -- which could pile up
  // arbitrarily behind a slow/hung channel call -- a change that arrives
  // while one is already in flight just marks [_dirty]; the in-flight call,
  // once it settles, re-reads the CURRENT state once more and stops. Latest
  // state wins, no queue buildup.
  bool _busy = false;
  bool _dirty = false;

  SyncForegroundNotifier(
    ActivityModel activity, {
    required ForegroundInvoker invoke,
    Future<void> Function()? requestNotificationPermission,
  }) : _activity = activity,
       // Can't use a `this._invoke` initializing formal here: that would
       // make the private field name itself the public named-parameter
       // name, which callers in other files couldn't pass.
       // ignore: prefer_initializing_formals
       _invoke = invoke,
       _requestNotificationPermission =
           requestNotificationPermission ??
           _defaultRequestNotificationPermission {
    _activity.addListener(_onActivityChanged);
  }

  static Future<void> _defaultRequestNotificationPermission() async {
    // No-op below Android 13 / on other platforms -- permission_handler
    // already encodes that, so there is nothing to branch on here.
    await Permission.notification.request();
  }

  void _onActivityChanged() {
    if (_busy) {
      _dirty = true;
      return;
    }
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    _busy = true;
    try {
      do {
        _dirty = false;
        await _syncOnce();
      } while (_dirty);
    } finally {
      _busy = false;
    }
  }

  Future<void> _syncOnce() async {
    try {
      final job = _findSyncJob();
      if (job == null) {
        if (_present) {
          _present = false;
          _lastText = null;
          await _invoke('syncFgStop');
        }
        return;
      }
      if (!_present) {
        // Once per appearance, and before the notification itself starts --
        // asking after start() would show a bare "Syncing" notification the
        // user never granted permission for, however briefly.
        await _requestNotificationPermission();
        _present = true;
        _lastText = job.text;
        await _invoke('syncFgStart', {'label': job.text});
        return;
      }
      if (job.text != _lastText) {
        _lastText = job.text;
        await _invoke('syncFgUpdate', {
          'label': job.text,
          'done': job.done ?? -1,
          'total': job.total ?? -1,
        });
      }
    } catch (_) {
      // A notification is a nicety -- a permission-dialog hiccup or a
      // platform-channel error must never propagate out of an ActivityModel
      // listener (that would break every OTHER listener's notification, not
      // just this one) or out of the fire-and-forget loop above.
    }
  }

  BackgroundActivity? _findSyncJob() {
    for (final job in _activity.active) {
      if (job.id == ActivityIds.sync) return job;
    }
    return null;
  }

  /// Stops listening. Deliberately does NOT send a final `syncFgStop` --
  /// this fires at app shutdown alongside everything else tearing down, and
  /// by then there is no channel left to reliably reach anyway.
  void dispose() {
    _activity.removeListener(_onActivityChanged);
  }
}
