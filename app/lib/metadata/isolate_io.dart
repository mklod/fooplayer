import 'dart:async';
import 'dart:isolate';

/// Runs [entryPoint] -- a static or top-level function, per [Isolate.spawn]'s
/// own requirement (it can't be a closure that captures local state) --
/// inside its own isolate with [message], the same way `Isolate.run` would,
/// except that if it hasn't produced a result within [timeout] that isolate
/// is killed outright and this throws [TimeoutException], instead of
/// leaving a runaway synchronous computation (file I/O, a pathological
/// parse, ...) to keep burning CPU/IO in the background indefinitely.
///
/// [entryPoint] is handed `(message, resultPort)` and must, on completion,
/// call `Isolate.exit(resultPort, [result])` on success or
/// `Isolate.exit(resultPort, [error, stackTrace])` on failure. This
/// low-level two-element-list protocol -- rather than this helper accepting
/// an arbitrary closure and running it directly -- is what [Isolate.spawn]
/// itself forces on every caller: the entry point cannot close over this
/// function's local state (e.g. [message] gets passed as the isolate's
/// initial message, not captured), so each caller still needs its own
/// top-level wrapper function around whatever work it actually wants done.
///
/// Extracted from `LibraryModel`'s original `_readBatchIsolate` (batched tag
/// reading) so the same kill-capable-spawn-with-timeout machinery -- and its
/// close attention to result-port cleanup on a failed spawn -- backs both
/// that use and `metadata/tags.dart`'s `readArtSafe` (single-file cover-art
/// reads), rather than each maintaining its own copy.
Future<T> runIsolateWithTimeout<T, M>(
  void Function((M, SendPort)) entryPoint,
  M message, {
  required Duration timeout,
}) async {
  final resultPort = RawReceivePort();
  final completer = Completer<T>();
  resultPort.handler = (Object? response) {
    resultPort.close();
    if (response == null) {
      completer.completeError(
          StateError('isolate exited without a result'), StackTrace.current);
      return;
    }
    final list = response as List<Object?>;
    if (list.length == 2) {
      final error = list[0];
      final stack = list[1];
      if (stack is StackTrace) {
        completer.completeError(error!, stack);
      } else {
        // Two strings from the isolate's own onError handler (an uncaught
        // async error) rather than from entryPoint's own try/catch.
        completer.completeError(
            RemoteError(error.toString(), stack.toString()));
      }
    } else {
      completer.complete(list[0] as T);
    }
  };

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      entryPoint,
      (message, resultPort.sendPort),
      onError: resultPort.sendPort,
      onExit: resultPort.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    // Spawning itself failed (synchronously, or the returned Future
    // rejected) -- there's no isolate to kill, but resultPort must still
    // be closed or it leaks. Mirrors Isolate.run's own handling of this
    // case in dart:isolate.
    resultPort.close();
    rethrow;
  }

  try {
    return await completer.future.timeout(timeout);
  } finally {
    isolate.kill(priority: Isolate.immediate);
    resultPort.close();
  }
}
