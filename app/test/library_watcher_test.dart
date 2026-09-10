// LibraryWatcher: the watch-driven replacement for the five-minute crawl.
// The two properties that matter are self-trigger immunity (a rescan
// writes sidecars into the watched roots -- reacting to those loops
// forever) and the quiet-period debounce (a download is still being
// written when the first event arrives).
//
// Last modified: 2026-09-10--0400
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_watcher.dart';

void main() {
  test('a music file fires exactly one scan, after the quiet period', () {
    fakeAsync((async) {
      final controller = StreamController<String>.broadcast();
      var scans = 0;
      LibraryWatcher(
        roots: const ['/music'],
        onChanged: () async => scans++,
        quietPeriod: const Duration(seconds: 60),
        watchFactory: (_) => controller.stream,
      ).start();

      controller.add(('/music/new track.mp3'));
      async.elapse(const Duration(seconds: 59));
      expect(scans, 0, reason: 'must wait for the root to go quiet');

      async.elapse(const Duration(seconds: 2));
      expect(scans, 1);
    });
  });

  test('a still-writing download keeps resetting the debounce', () {
    fakeAsync((async) {
      final controller = StreamController<String>.broadcast();
      var scans = 0;
      LibraryWatcher(
        roots: const ['/music'],
        onChanged: () async => scans++,
        quietPeriod: const Duration(seconds: 60),
        watchFactory: (_) => controller.stream,
      ).start();

      // Progressive writes, 30s apart, for five minutes.
      for (var i = 0; i < 10; i++) {
        controller.add(('/music/downloading.mp3'));
        async.elapse(const Duration(seconds: 30));
      }
      expect(scans, 0, reason: 'never scan a file that is still growing');

      async.elapse(const Duration(seconds: 61));
      expect(scans, 1, reason: 'one scan once it finally goes quiet');
    });
  });

  test('sidecar writes are ignored -- no scan -> write -> scan loop', () {
    fakeAsync((async) {
      final controller = StreamController<String>.broadcast();
      var scans = 0;
      LibraryWatcher(
        roots: const ['/music'],
        onChanged: () async => scans++,
        quietPeriod: const Duration(seconds: 60),
        watchFactory: (_) => controller.stream,
      ).start();

      // Exactly what a rescan writes back into the watched root.
      for (final p in [
        r'L:\music\.library.json',
        r'L:\music\.library.json.bak',
        r'L:\music\.hash_cache.json',
        r'L:\music\.sync_state.json',
        r'L:\music\.artwork.json',
        r'L:\music\.artwork\cover.jpg',
        r'L:\music\.sync_tmp\partial.mp3',
        '/music/.playlists/mix.json',
      ]) {
        controller.add((p));
      }
      async.elapse(const Duration(minutes: 5));

      expect(scans, 0);
    });
  });

  test('a burst across roots collapses into one scan', () {
    fakeAsync((async) {
      final a = StreamController<String>.broadcast();
      final b = StreamController<String>.broadcast();
      var scans = 0;
      LibraryWatcher(
        roots: const ['/a', '/b'],
        onChanged: () async => scans++,
        quietPeriod: const Duration(seconds: 30),
        watchFactory: (root) => root == '/a' ? a.stream : b.stream,
      ).start();

      for (var i = 0; i < 25; i++) {
        (i.isEven ? a : b).add(('/root/track$i.mp3'));
      }
      async.elapse(const Duration(seconds: 31));

      expect(scans, 1, reason: 'a 25-file drop is one scan, not 25');
    });
  });

  test('events during a slow scan cause exactly one follow-up scan', () {
    fakeAsync((async) {
      final controller = StreamController<String>.broadcast();
      var scans = 0;
      final gate = <Completer<void>>[];
      LibraryWatcher(
        roots: const ['/music'],
        onChanged: () {
          scans++;
          final c = Completer<void>();
          gate.add(c);
          return c.future;
        },
        quietPeriod: const Duration(seconds: 10),
        watchFactory: (_) => controller.stream,
      ).start();

      controller.add(('/music/one.mp3'));
      async.elapse(const Duration(seconds: 11));
      expect(scans, 1);

      // Three more land while that scan is still running.
      for (var i = 0; i < 3; i++) {
        controller.add(('/music/two$i.mp3'));
      }
      async.elapse(const Duration(seconds: 11));
      expect(scans, 1, reason: 'still busy; must not run concurrently');

      gate.first.complete();
      async.elapse(const Duration(seconds: 1));
      expect(scans, 2, reason: 'exactly one coalesced follow-up');

      gate.last.complete();
      async.elapse(const Duration(seconds: 30));
      expect(scans, 2);
    });
  });

  test('an unwatchable root is reported, others still watched', () {
    fakeAsync((async) {
      final good = StreamController<String>.broadcast();
      final errors = <String>[];
      var scans = 0;
      final w = LibraryWatcher(
        roots: const ['/gone', '/good'],
        onChanged: () async => scans++,
        quietPeriod: const Duration(seconds: 5),
        watchFactory: (root) {
          if (root == '/gone') throw const FileSystemException('no such dir');
          return good.stream;
        },
        onWatchError: (root, _) => errors.add(root),
      )..start();

      expect(errors, ['/gone']);
      expect(w.watchedRoots, ['/good']);

      good.add(('/good/track.mp3'));
      async.elapse(const Duration(seconds: 6));
      expect(scans, 1, reason: 'the healthy root still works');
    });
  });

  test('a failing scan does not kill the watcher', () {
    fakeAsync((async) {
      final controller = StreamController<String>.broadcast();
      var calls = 0;
      LibraryWatcher(
        roots: const ['/music'],
        onChanged: () async {
          calls++;
          if (calls == 1) throw StateError('NAS went away');
        },
        quietPeriod: const Duration(seconds: 5),
        watchFactory: (_) => controller.stream,
      ).start();

      controller.add(('/music/a.mp3'));
      async.elapse(const Duration(seconds: 6));
      expect(calls, 1);

      controller.add(('/music/b.mp3'));
      async.elapse(const Duration(seconds: 6));
      expect(calls, 2, reason: 'still watching after a failed scan');
    });
  });

  test('dispose stops everything, including a pending debounce', () async {
    final controller = StreamController<String>.broadcast();
    var scans = 0;
    final w = LibraryWatcher(
      roots: const ['/music'],
      onChanged: () async => scans++,
      quietPeriod: const Duration(milliseconds: 40),
      watchFactory: (_) => controller.stream,
    )..start();

    controller.add(('/music/a.mp3'));
    await w.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(scans, 0);
    await controller.close();
  });
}
