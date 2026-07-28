// Unit tests for the shared kill-capable-spawn-with-timeout helper
// extracted (Plan 2a.2 final-review Fix 1) out of LibraryModel's original
// _readBatchIsolate, so both LibraryModel's tag-batch reads and
// tags.dart's readArtSafe share one implementation instead of each keeping
// its own copy.
//
// Isolate.spawn requires its entry point to be a static/top-level function
// (it can't close over local state), so the fixture entry points below are
// top-level, matching the shape runIsolateWithTimeout's own doc describes:
// handed `(message, resultPort)`, must call `Isolate.exit(resultPort,
// [result])` on success or `Isolate.exit(resultPort, [error, stackTrace])`
// on failure.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/isolate_io.dart';

void _echoEntry((String, SendPort) args) async {
  final (message, resultPort) = args;
  Isolate.exit(resultPort, [message]);
}

void _throwingEntry((String, SendPort) args) async {
  final (_, resultPort) = args;
  try {
    throw StateError('boom from entry point');
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
}

/// Busy-waits synchronously for [delayMs] before completing -- deliberately
/// NOT `Future.delayed`, so this genuinely occupies the spawned isolate's
/// event loop the whole time, the same "synchronous all the way down" shape
/// the real pathological-file bug has (a plain async delay would still let
/// the isolate service other events/messages and wouldn't prove the kill
/// actually tears down a busy isolate).
void _slowEntry((int, SendPort) args) async {
  final (delayMs, resultPort) = args;
  final until = DateTime.now().add(Duration(milliseconds: delayMs));
  while (DateTime.now().isBefore(until)) {
    // busy-wait
  }
  Isolate.exit(resultPort, ['done']);
}

void main() {
  test(
    'completes normally with the entry point\'s result within the timeout',
    () async {
      final result = await runIsolateWithTimeout<String, String>(
        _echoEntry,
        'hello',
        timeout: const Duration(seconds: 5),
      );
      expect(result, 'hello');
    },
  );

  test(
    'an error thrown inside the entry point propagates to the caller',
    () async {
      await expectLater(
        runIsolateWithTimeout<String, String>(
          _throwingEntry,
          'x',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('a synchronous computation that outruns the timeout is killed and '
      'throws TimeoutException, bounded by the timeout itself (not the '
      "computation's full length)", () async {
    final stopwatch = Stopwatch()..start();
    await expectLater(
      runIsolateWithTimeout<String, int>(
        _slowEntry,
        // The entry point busy-waits far longer than the timeout below --
        // if the kill didn't actually work, this call (and this test)
        // would hang for the full 10s instead of returning at ~300ms.
        10000,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    stopwatch.stop();
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(5000),
      reason:
          'the call must return promptly at the timeout, not wait '
          "for the killed isolate's own busy-wait to finish",
    );
  });
}
