// SyncForegroundNotifier: the sync job appearing/changing/disappearing in
// ActivityModel has to reach Android's foreground service as
// start/update/stop calls, in that order, with permission requested exactly
// once (before the first start) and never once the notification is already
// up. A slow/erroring invoke must never surface -- to the ActivityModel
// listener chain or to the caller -- since a progress notification is a
// nicety, not something worth breaking a sync over.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/sync/sync_foreground.dart';

/// Records every invoke() call (method + args) in order. Optionally can be
/// told to fail the next N calls, or to hang until manually released --
/// covering the "error swallowed" and "in-flight call, then a burst of more
/// changes" cases without a real platform channel.
class _RecordingInvoker {
  final calls = <(String, Map<String, Object?>?)>[];
  final List<Object> _failNext = [];

  Future<void> Function(String, [Map<String, Object?>?]) get invoke =>
      (method, [args]) async {
        calls.add((method, args));
        if (_failNext.isNotEmpty) {
          _failNext.removeAt(0);
          throw StateError('injected failure for $method');
        }
      };

  void failNextCall() => _failNext.add(Object());
}

class _RecordingPermission {
  int requests = 0;
  Future<void> Function() get request => () async {
    requests++;
  };
}

void main() {
  group('SyncForegroundNotifier', () {
    test('a sync job appearing requests permission, then starts', () async {
      final invoker = _RecordingInvoker();
      final permission = _RecordingPermission();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: permission.request,
      );

      activity.start(ActivityIds.sync, 'Syncing with NAS');
      await pumpEventQueue();

      expect(permission.requests, 1);
      // Compared field-by-field, not as a whole record: a Map has no
      // structural `==`, so `expect(list-of-records, [literal])` would
      // compare the two Map instances by identity and always fail even
      // when their contents match -- unpacking `.$2` and comparing it
      // directly gets `equals()`'s real deep-map comparison instead.
      expect(invoker.calls, hasLength(1));
      expect(invoker.calls.single.$1, 'syncFgStart');
      expect(invoker.calls.single.$2, {'label': 'Syncing with NAS'});
    });

    test(
      'progress changes that alter the text send an update with done/total',
      () async {
        final invoker = _RecordingInvoker();
        final activity = ActivityModel();
        SyncForegroundNotifier(
          activity,
          invoke: invoker.invoke,
          requestNotificationPermission: () async {},
        );

        activity.start(ActivityIds.sync, 'Syncing with NAS');
        await pumpEventQueue();
        invoker.calls.clear();

        activity.progress(ActivityIds.sync, 'Syncing with NAS', 3, 10);
        await pumpEventQueue();

        expect(invoker.calls, hasLength(1));
        expect(invoker.calls.single.$1, 'syncFgUpdate');
        expect(invoker.calls.single.$2, {
          'label': 'Syncing with NAS — 3 / 10',
          'done': 3,
          'total': 10,
        });
      },
    );

    test('a repeated identical progress update does not resend', () async {
      final invoker = _RecordingInvoker();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: () async {},
      );

      activity.progress(ActivityIds.sync, 'Syncing with NAS', 3, 10);
      await pumpEventQueue();
      invoker.calls.clear();

      // ActivityModel itself dedupes an identical progress() call (no
      // notifyListeners at all) -- this exercises the notifier's OWN
      // dedupe by going through a DIFFERENT job whose change still fires
      // the listener, while the sync job's text is unchanged.
      activity.start('other', 'Some other job');
      await pumpEventQueue();

      expect(invoker.calls, isEmpty);
    });

    test('the job disappearing stops the notification', () async {
      final invoker = _RecordingInvoker();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: () async {},
      );

      activity.start(ActivityIds.sync, 'Syncing with NAS');
      await pumpEventQueue();
      invoker.calls.clear();

      activity.finish(ActivityIds.sync);
      await pumpEventQueue();

      expect(invoker.calls, [('syncFgStop', null)]);
    });

    test('finishing twice in a row only stops once', () async {
      final invoker = _RecordingInvoker();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: () async {},
      );

      activity.start(ActivityIds.sync, 'Syncing with NAS');
      await pumpEventQueue();
      invoker.calls.clear();

      activity.finish(ActivityIds.sync); // fires: job gone -> stop
      await pumpEventQueue();
      activity.start('other', 'Unrelated'); // fires again: still gone, no-op
      await pumpEventQueue();

      expect(invoker.calls, [('syncFgStop', null)]);
    });

    test('no duplicate starts: re-appearing after a stop starts again, but '
        'staying present never re-sends start', () async {
      final invoker = _RecordingInvoker();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: () async {},
      );

      activity.start(ActivityIds.sync, 'Syncing with NAS');
      await pumpEventQueue();
      // A second notify while still present (unrelated job) must not
      // resend syncFgStart.
      activity.start('other', 'Unrelated');
      await pumpEventQueue();
      expect(invoker.calls.where((c) => c.$1 == 'syncFgStart'), hasLength(1));

      invoker.calls.clear();
      activity.finish(ActivityIds.sync);
      await pumpEventQueue();
      activity.start(ActivityIds.sync, 'Syncing with NAS again');
      await pumpEventQueue();

      expect(invoker.calls.map((c) => c.$1).toList(), [
        'syncFgStop',
        'syncFgStart',
      ]);
      expect(invoker.calls[0].$2, isNull);
      expect(invoker.calls[1].$2, {'label': 'Syncing with NAS again'});
    });

    test('an error from invoke() is swallowed, not thrown', () async {
      final invoker = _RecordingInvoker()..failNextCall();
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: invoker.invoke,
        requestNotificationPermission: () async {},
      );

      // Nothing here should throw, synchronously or asynchronously.
      expect(
        () => activity.start(ActivityIds.sync, 'Syncing with NAS'),
        returnsNormally,
      );
      await pumpEventQueue();

      // The failed start still counted as an attempt; a later, unrelated
      // change keeps the notifier alive and working (the error didn't wedge
      // the listener).
      activity.progress(ActivityIds.sync, 'Syncing with NAS', 1, 4);
      await pumpEventQueue();
      expect(
        invoker.calls.map((c) => c.$1),
        containsAll(['syncFgStart', 'syncFgUpdate']),
      );
    });

    test('a burst of rapid changes while an invoke is in flight collapses '
        'to the latest state -- no queue buildup', () async {
      final calls = <(String, Map<String, Object?>?)>[];
      final release = <Completer<void>>[];
      final activity = ActivityModel();
      SyncForegroundNotifier(
        activity,
        invoke: (method, [args]) async {
          final c = Completer<void>();
          release.add(c);
          calls.add((method, args));
          await c.future;
        },
        requestNotificationPermission: () async {},
      );

      activity.start(ActivityIds.sync, 'Syncing with NAS');
      await pumpEventQueue();
      // The first invoke (syncFgStart) is now in flight, blocked on
      // release[0]. Fire a burst of progress changes while it's stuck.
      activity.progress(ActivityIds.sync, 'Syncing with NAS', 1, 10);
      activity.progress(ActivityIds.sync, 'Syncing with NAS', 2, 10);
      activity.progress(ActivityIds.sync, 'Syncing with NAS', 3, 10);
      release[0].complete();
      await pumpEventQueue();

      // Exactly one follow-up call, carrying the LATEST progress -- not
      // three queued updates.
      expect(calls.map((c) => c.$1), ['syncFgStart', 'syncFgUpdate']);
      expect(calls.last.$2, {
        'label': 'Syncing with NAS — 3 / 10',
        'done': 3,
        'total': 10,
      });

      // Let the second invoke settle too, so the test doesn't leak a
      // pending timer/microtask.
      release[1].complete();
      await pumpEventQueue();
    });
  });
}
