// Last modified: 2026-07-31--2123
//
// Contract test for SmbTransport against a MOCKED MethodChannel/EventChannel
// -- no real Kotlin/SMBJ involved. Verifies each SyncTransport method sends
// the right platform-channel call and maps the result back correctly
// (including the null/empty/error edge cases the class doc pins down), the
// stale-handle reconnect-and-retry recovery (review round 1, Critical C-1),
// the shared/ref-counted progress subscription across instances (review
// round 1, Important I-3), and the two things that live only on
// SmbTransport itself: lazy connect and static freeSpace(). Kotlin-side
// correctness (SmbBridge.kt) is verified by `flutter build apk --debug`
// compiling and by live device testing in Task 12 -- this file only pins
// the Dart-side contract.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/sync/smb_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('dev.mklod.fooplayer/smb');
  const progressChannel = EventChannel('dev.mklod.fooplayer/smb-progress');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late SmbTransport transport;

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  Map<Object?, Object?> argsOf(MethodCall call) =>
      Map<Object?, Object?>.from(call.arguments as Map);

  setUp(() {
    calls = [];
    transport = SmbTransport(
      host: '192.168.1.12',
      share: 'drop',
      basePath: 'PROJECTS/fooplayer-sync',
    );
  });

  tearDown(() async {
    // The progress subscription/ref-count/callback registry are all
    // process-static (I-3 -- the native EventChannel supports exactly one
    // listener, so SmbTransport shares that state across every instance).
    // Every test must release whatever ref it took, or it leaks into the
    // NEXT test and corrupts that test's progress routing. close() is the
    // only way to release it, so install a permissive handler first -- a
    // test's OWN handler (which may `fail()` on anything unexpected) must
    // never see this teardown-only close() call.
    messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
    await transport.close();
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(progressChannel, null);
  });

  group('connect', () {
    test('is lazy: only sent on first real use, then reused', () async {
      setHandler((call) async {
        switch (call.method) {
          case 'connect':
            return 42;
          case 'listTree':
            return <Map<String, Object?>>[];
          case 'readFile':
            return null;
          default:
            fail('unexpected method ${call.method}');
        }
      });

      // Constructing the transport must not itself talk to the channel.
      expect(calls, isEmpty);

      await transport.listTree('');
      await transport.readFile('x.json');

      final connectCalls = calls.where((c) => c.method == 'connect').toList();
      expect(connectCalls, hasLength(1));
      expect(connectCalls.single.arguments, {
        'host': '192.168.1.12',
        'share': 'drop',
        'basePath': 'PROJECTS/fooplayer-sync',
      });

      final listTreeCall = calls.firstWhere((c) => c.method == 'listTree');
      expect(argsOf(listTreeCall), {'handle': 42, 'relDir': ''});
      final readCall = calls.firstWhere((c) => c.method == 'readFile');
      expect(argsOf(readCall), {'handle': 42, 'relPath': 'x.json'});
    });
  });

  group('probe', () {
    test('sends host/share/basePath and returns the platform bool', () async {
      setHandler((call) async {
        expect(call.method, 'probe');
        return true;
      });
      expect(await transport.probe(), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.arguments, {
        'host': '192.168.1.12',
        'share': 'drop',
        'basePath': 'PROJECTS/fooplayer-sync',
      });
    });

    test('never throws -- a platform error becomes false', () async {
      setHandler((call) async => throw PlatformException(code: 'smb', message: 'boom'));
      expect(await transport.probe(), isFalse);
    });

    test('a missing plugin becomes false too', () async {
      // No handler registered at all -- MissingPluginException path.
      expect(await transport.probe(), isFalse);
    });

    test('does not require (or trigger) a prior connect', () async {
      setHandler((call) async => true);
      await transport.probe();
      expect(calls.any((c) => c.method == 'connect'), isFalse);
    });
  });

  group('listTree', () {
    test('maps platform maps to core.RemoteFile', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        expect(argsOf(call), {'handle': 1, 'relDir': 'a'});
        return <Map<String, Object?>>[
          {'relPath': 'a/track.mp3', 'size': 12345, 'mtimeMs': 1700000000000},
          {'relPath': 'a/.artwork.json', 'size': 2, 'mtimeMs': 1700000000001},
        ];
      });

      final files = await transport.listTree('a');
      expect(files, hasLength(2));
      expect(files[0].relPath, 'a/track.mp3');
      expect(files[0].size, 12345);
      expect(files[0].mtimeMs, 1700000000000);
      expect(files[1].relPath, 'a/.artwork.json');
      expect(files[1].size, 2);
    });

    test('an empty platform result is an empty list (missing relDir case)', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : <Object?>[]);
      expect(await transport.listTree('nope'), isEmpty);
    });

    test('a null platform result is an empty list too', () async {
      // invokeMethod<List<Object?>> can hand back a bare null (not just an
      // empty list) for a void-ish/absent platform reply -- both must map
      // to [], never throw a cast error.
      setHandler((call) async => call.method == 'connect' ? 1 : null);
      expect(await transport.listTree(''), isEmpty);
    });

    test('a platform error propagates as PlatformException, not an empty list', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        throw PlatformException(code: 'smb', message: 'connection lost mid-walk');
      });
      await expectLater(
        transport.listTree(''),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            'connection lost mid-walk',
          ),
        ),
      );
    });
  });

  group('readFile', () {
    test('returns bytes when present', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : Uint8List.fromList([1, 2, 3]));
      expect(await transport.readFile('m.json'), [1, 2, 3]);
    });

    test('null passthrough -- means exactly "does not exist"', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : null);
      expect(await transport.readFile('nope.json'), isNull);
    });

    test('a platform error propagates -- never mistaken for not-found', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        throw PlatformException(code: 'smb', message: 'read failed');
      });
      await expectLater(transport.readFile('x.json'), throwsA(isA<PlatformException>()));
    });
  });

  group('writeFile', () {
    test('sends handle/relPath/bytes', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : null);
      await transport.writeFile('deep/f.json', [9, 9, 9]);
      final call = calls.firstWhere((c) => c.method == 'writeFile');
      final args = argsOf(call);
      expect(args['handle'], 1);
      expect(args['relPath'], 'deep/f.json');
      expect(args['bytes'], [9, 9, 9]);
    });

    test('a platform error propagates', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        throw PlatformException(code: 'smb', message: 'write failed');
      });
      await expectLater(
        transport.writeFile('f.json', [1]),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('deleteRemote', () {
    test('sends handle/relPath', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : null);
      await transport.deleteRemote('gone.json');
      final call = calls.firstWhere((c) => c.method == 'deleteRemote');
      expect(argsOf(call), {'handle': 1, 'relPath': 'gone.json'});
    });

    test('a platform error propagates', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        throw PlatformException(code: 'smb', message: 'delete failed');
      });
      await expectLater(
        transport.deleteRemote('gone.json'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('downloadToFile', () {
    late Directory localDir;
    setUp(() => localDir = Directory.systemTemp.createTempSync('smb_dl'));
    tearDown(() {
      if (localDir.existsSync()) localDir.deleteSync(recursive: true);
    });

    test('sends handle/relPath/localPath/taskId, creates local parent dirs', () async {
      setHandler((call) async => call.method == 'connect' ? 1 : true);
      final local = File('${localDir.path}/a/b/out.bin');

      await transport.downloadToFile('big.bin', local);

      expect(local.parent.existsSync(), isTrue);
      final call = calls.firstWhere((c) => c.method == 'downloadToFile');
      final args = argsOf(call);
      expect(args['handle'], 1);
      expect(args['relPath'], 'big.bin');
      expect(args['localPath'], local.path);
      expect(args['taskId'], isNotNull);
    });

    test('routes progress events by taskId to onProgress, ignoring other tasks', () async {
      late MockStreamHandlerEventSink progressSink;
      messenger.setMockStreamHandler(
        progressChannel,
        MockStreamHandler.inline(onListen: (args, events) => progressSink = events),
      );

      setHandler((call) async {
        if (call.method == 'connect') return 7;
        if (call.method == 'downloadToFile') {
          final taskId = argsOf(call)['taskId'];
          // An event for a DIFFERENT task must never reach this call's
          // onProgress -- simulates a second concurrent download.
          progressSink.success({'taskId': 'someone-elses-task', 'got': 999, 'total': 999});
          progressSink.success({'taskId': taskId, 'got': 500, 'total': 1000});
          progressSink.success({'taskId': taskId, 'got': 1000, 'total': 1000});
          // Real SmbBridge.kt posts progress events and this call's own
          // result through the SAME Handler(mainLooper) in that order, so
          // on a real device the events are always fully delivered before
          // this method call resolves. Yielding to a macrotask here (which
          // drains ALL pending microtasks first) reproduces that ordering
          // for this mock -- without it, downloadToFile's now-unconditional
          // finally-cleanup (see M-3 fix) can remove the taskId's callback
          // before these events are actually processed.
          await Future<void>.delayed(Duration.zero);
          return true;
        }
        fail('unexpected ${call.method}');
      });

      final local = File('${localDir.path}/out.bin');
      final progress = <List<int>>[];
      await transport.downloadToFile(
        'big.bin',
        local,
        onProgress: (got, total) => progress.add([got, total]),
      );

      expect(progress, [
        [500, 1000],
        [1000, 1000],
      ]);
    });

    test('a platform error propagates as PlatformException', () async {
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        throw PlatformException(code: 'smb', message: 'transport dropped');
      });
      final local = File('${localDir.path}/out.bin');
      await expectLater(
        transport.downloadToFile('big.bin', local),
        throwsA(isA<PlatformException>()),
      );
    });

    test('a failed download removes its progress callback -- a late event is a no-op', () async {
      late MockStreamHandlerEventSink progressSink;
      messenger.setMockStreamHandler(
        progressChannel,
        MockStreamHandler.inline(onListen: (args, events) => progressSink = events),
      );

      String? capturedTaskId;
      setHandler((call) async {
        if (call.method == 'connect') return 1;
        if (call.method == 'downloadToFile') {
          capturedTaskId = argsOf(call)['taskId'] as String;
          throw PlatformException(code: 'smb', message: 'transport dropped');
        }
        fail('unexpected ${call.method}');
      });

      final local = File('${localDir.path}/out.bin');
      final progress = <List<int>>[];
      await expectLater(
        transport.downloadToFile(
          'big.bin',
          local,
          onProgress: (got, total) => progress.add([got, total]),
        ),
        throwsA(isA<PlatformException>()),
      );

      // The callback for capturedTaskId must already be gone -- a late
      // event arriving after the fact (e.g. a stray platform message) must
      // not fire onProgress, and must not throw either.
      progressSink.success({'taskId': capturedTaskId, 'got': 1, 'total': 2});
      await pumpEventQueue();

      expect(progress, isEmpty);
    });
  });

  group('cancelInFlight', () {
    late Directory localDir;
    setUp(() => localDir = Directory.systemTemp.createTempSync('smb_cancel'));
    tearDown(() {
      if (localDir.existsSync()) localDir.deleteSync(recursive: true);
    });

    test(
      'sends cancel with the right taskId for an in-flight download',
      () async {
        final downloadCompleter = Completer<bool>();
        String? capturedTaskId;
        setHandler((call) async {
          switch (call.method) {
            case 'connect':
              return 1;
            case 'downloadToFile':
              capturedTaskId = argsOf(call)['taskId'] as String;
              return downloadCompleter.future;
            case 'cancel':
              return null;
            default:
              fail('unexpected ${call.method}');
          }
        });

        final local = File('${localDir.path}/out.bin');
        final downloadFuture = transport.downloadToFile('big.bin', local);
        // Let the invokeMethod call actually reach the mock handler (and
        // register the taskId as in-flight) before cancelling it.
        await Future<void>.delayed(Duration.zero);

        await transport.cancelInFlight();

        final cancelCall = calls.firstWhere((c) => c.method == 'cancel');
        expect(argsOf(cancelCall), {'taskId': capturedTaskId});

        downloadCompleter.complete(true);
        await downloadFuture;
      },
    );

    test(
      'after normal completion the in-flight set is empty -- cancelInFlight '
      'sends nothing',
      () async {
        setHandler((call) async => call.method == 'connect' ? 1 : true);
        final local = File('${localDir.path}/out.bin');
        await transport.downloadToFile('big.bin', local);

        await transport.cancelInFlight();

        expect(calls.any((c) => c.method == 'cancel'), isFalse);
      },
    );

    test(
      'a PlatformException from an individual cancel call is swallowed -- '
      'racing the download\'s own completion is normal',
      () async {
        final downloadCompleter = Completer<bool>();
        setHandler((call) async {
          switch (call.method) {
            case 'connect':
              return 1;
            case 'downloadToFile':
              return downloadCompleter.future;
            case 'cancel':
              throw PlatformException(code: 'smb', message: 'already finished');
            default:
              fail('unexpected ${call.method}');
          }
        });

        final local = File('${localDir.path}/out.bin');
        final downloadFuture = transport.downloadToFile('big.bin', local);
        await Future<void>.delayed(Duration.zero);

        await expectLater(transport.cancelInFlight(), completes);

        downloadCompleter.complete(true);
        await downloadFuture;
      },
    );
  });

  group('stale handle recovery (C-1)', () {
    test('a "no SMB session" error triggers exactly one reconnect+retry, then succeeds', () async {
      var connectCount = 0;
      var listTreeAttempt = 0;
      setHandler((call) async {
        switch (call.method) {
          case 'connect':
            connectCount++;
            return connectCount; // handle 1, then handle 2 after reconnect
          case 'listTree':
            listTreeAttempt++;
            if (listTreeAttempt == 1) {
              throw PlatformException(code: 'smb', message: 'no SMB session for handle 1');
            }
            expect(argsOf(call)['handle'], 2, reason: 'retry must use the FRESH handle');
            return <Map<String, Object?>>[
              {'relPath': 'a.mp3', 'size': 1, 'mtimeMs': 1},
            ];
          default:
            fail('unexpected ${call.method}');
        }
      });

      final files = await transport.listTree('');

      expect(files, hasLength(1));
      expect(connectCount, 2, reason: 'reconnected exactly once');
      expect(listTreeAttempt, 2, reason: 'retried exactly once');
    });

    test('a second consecutive "no SMB session" error is not retried again', () async {
      var connectCount = 0;
      setHandler((call) async {
        if (call.method == 'connect') {
          connectCount++;
          return connectCount;
        }
        throw PlatformException(code: 'smb', message: 'no SMB session for handle $connectCount');
      });

      await expectLater(transport.listTree(''), throwsA(isA<PlatformException>()));
      // One initial connect + one reconnect -- never a second reconnect
      // attempt chasing a retry that also failed the same way.
      expect(connectCount, 2);
    });

    test('an unrelated PlatformException is never treated as a stale handle', () async {
      var connectCount = 0;
      setHandler((call) async {
        if (call.method == 'connect') {
          connectCount++;
          return connectCount;
        }
        throw PlatformException(code: 'smb', message: 'connection lost mid-walk');
      });

      await expectLater(transport.listTree(''), throwsA(isA<PlatformException>()));
      expect(connectCount, 1, reason: 'no reconnect for a non-stale-handle error');
    });

    test('recovery is not listTree-specific -- writeFile as a representative '
        'sample (readFile/deleteRemote/downloadToFile all share the same '
        '_withSession wrapper)', () async {
      var connectCount = 0;
      var writeAttempt = 0;
      setHandler((call) async {
        switch (call.method) {
          case 'connect':
            connectCount++;
            return connectCount;
          case 'writeFile':
            writeAttempt++;
            if (writeAttempt == 1) {
              throw PlatformException(code: 'smb', message: 'no SMB session for handle 1');
            }
            return null;
          default:
            fail('unexpected ${call.method}');
        }
      });

      await transport.writeFile('f.json', [1]);
      expect(connectCount, 2);
      expect(writeAttempt, 2);
    });
  });

  group('shared progress subscription across instances (I-3)', () {
    late Directory localDir;
    setUp(() => localDir = Directory.systemTemp.createTempSync('smb_dl_i3'));
    tearDown(() {
      if (localDir.existsSync()) localDir.deleteSync(recursive: true);
    });

    test('closing one instance does not kill progress for another still-open instance', () async {
      late MockStreamHandlerEventSink progressSink;
      messenger.setMockStreamHandler(
        progressChannel,
        MockStreamHandler.inline(onListen: (args, events) => progressSink = events),
      );

      setHandler((call) async {
        switch (call.method) {
          case 'connect':
            return 1;
          case 'close':
            return null;
          case 'downloadToFile':
            final taskId = argsOf(call)['taskId'];
            progressSink.success({'taskId': taskId, 'got': 1, 'total': 1});
            await Future<void>.delayed(Duration.zero);
            return true;
          default:
            fail('unexpected ${call.method}');
        }
      });

      final transportA = SmbTransport(
        host: '192.168.1.12',
        share: 'drop',
        basePath: 'PROJECTS/fooplayer-sync',
      );
      // A takes a progress ref, then closes -- must not tear down the
      // SHARED subscription out from under B below.
      await transportA.downloadToFile(
        'a.bin',
        File('${localDir.path}/a.bin'),
        onProgress: (_, _) {},
      );
      await transportA.close();

      final transportB = SmbTransport(
        host: '192.168.1.12',
        share: 'drop',
        basePath: 'PROJECTS/fooplayer-sync',
      );
      addTearDown(transportB.close);
      final bProgress = <List<int>>[];
      await transportB.downloadToFile(
        'b.bin',
        File('${localDir.path}/b.bin'),
        onProgress: (got, total) => bProgress.add([got, total]),
      );

      expect(bProgress, [
        [1, 1],
      ]);
    });
  });

  group('close', () {
    test('sends close with the handle; a later call reconnects', () async {
      var connectCount = 0;
      setHandler((call) async {
        if (call.method == 'connect') {
          connectCount++;
          return connectCount;
        }
        return null;
      });

      await transport.readFile('a.json');
      await transport.close();
      await transport.readFile('b.json');

      expect(connectCount, 2);
      final closeCall = calls.firstWhere((c) => c.method == 'close');
      expect(argsOf(closeCall), {'handle': 1});
    });

    test('is a no-op if never connected -- no close call is sent', () async {
      setHandler((call) async => fail('unexpected ${call.method}'));
      await transport.close();
      expect(calls, isEmpty);
    });
  });

  group('SmbTransport.freeSpace', () {
    test('sends localPath and returns the platform int, independent of any handle', () async {
      setHandler((call) async {
        expect(call.method, 'freeSpace');
        expect(call.arguments, {'localPath': '/some/path'});
        return 123456789;
      });
      expect(await SmbTransport.freeSpace('/some/path'), 123456789);
      expect(calls.any((c) => c.method == 'connect'), isFalse);
    });

    test('a null platform result is a thrown error, never a silent 0', () async {
      setHandler((call) async => null);
      await expectLater(SmbTransport.freeSpace('/some/path'), throwsA(isA<PlatformException>()));
    });
  });
}
