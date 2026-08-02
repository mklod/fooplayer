// Last modified: 2026-07-31--1727
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/sync/sync_transport.dart';

void main() {
  late Directory base;
  late LocalDirTransport transport;

  setUp(() {
    base = Directory.systemTemp.createTempSync('synctransport');
    transport = LocalDirTransport(base);
  });
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  group('probe', () {
    test('true for an existing base', () async {
      expect(await transport.probe(), isTrue);
    });

    test('false for a missing base', () async {
      final missing = Directory('${base.path}/does_not_exist');
      expect(await LocalDirTransport(missing).probe(), isFalse);
    });
  });

  group('listTree', () {
    test('returns nested relPaths with sizes+mtimes and includes dotfiles', () async {
      File('${base.path}/track.mp3').writeAsStringSync('abc');
      Directory('${base.path}/sub').createSync();
      File('${base.path}/sub/other.flac').writeAsStringSync('xyz12');
      File('${base.path}/.hidden.json').writeAsStringSync('{}');

      final files = await transport.listTree('');
      final byPath = {for (final f in files) f.relPath: f};

      expect(byPath.keys,
          unorderedEquals(['track.mp3', 'sub/other.flac', '.hidden.json']));
      expect(byPath['track.mp3']!.size, 3);
      expect(byPath['sub/other.flac']!.size, 5);
      expect(byPath['.hidden.json']!.size, 2);
      expect(byPath['track.mp3']!.mtimeMs, greaterThan(0));
    });

    test('a missing relDir returns empty, not an error', () async {
      final files = await transport.listTree('nope/nested');
      expect(files, isEmpty);
    });

    test('relDir scopes the listing to that subtree, paths still relative to base',
        () async {
      Directory('${base.path}/sub').createSync();
      File('${base.path}/sub/a.txt').writeAsStringSync('a');
      File('${base.path}/other.txt').writeAsStringSync('b');

      final files = await transport.listTree('sub');
      expect(files.map((f) => f.relPath), ['sub/a.txt']);
    });
  });

  group('readFile', () {
    test('returns the file bytes when present', () async {
      File('${base.path}/manifest.json').writeAsStringSync('{"a":1}');
      final bytes = await transport.readFile('manifest.json');
      expect(String.fromCharCodes(bytes!), '{"a":1}');
    });

    test('null on missing', () async {
      expect(await transport.readFile('nope.json'), isNull);
    });
  });

  group('writeFile', () {
    test('creates parent dirs and leaves no .tmp sibling', () async {
      await transport.writeFile('deep/nested/file.json', [1, 2, 3]);

      final target = File('${base.path}/deep/nested/file.json');
      expect(target.existsSync(), isTrue);
      expect(target.readAsBytesSync(), [1, 2, 3]);
      expect(File('${target.path}.tmp').existsSync(), isFalse);
    });

    test('overwrites an existing file', () async {
      await transport.writeFile('f.json', [1]);
      await transport.writeFile('f.json', [2, 2]);
      expect(File('${base.path}/f.json').readAsBytesSync(), [2, 2]);
    });
  });

  group('downloadToFile', () {
    test('streams bytes and fires onProgress with a final got == total', () async {
      // Larger than a single read-stream chunk so progress fires more than once.
      final bytes = List<int>.generate(300000, (i) => i % 256);
      File('${base.path}/big.bin').writeAsBytesSync(bytes);

      final localDir = Directory.systemTemp.createTempSync('synctransport_dl');
      final local = File('${localDir.path}/nested/out.bin');
      final progress = <List<int>>[];
      await transport.downloadToFile('big.bin', local,
          onProgress: (got, total) => progress.add([got, total]));

      expect(local.existsSync(), isTrue);
      expect(local.readAsBytesSync(), bytes);
      expect(progress, isNotEmpty);
      expect(progress.length, greaterThan(1),
          reason: 'expected multiple progress callbacks for a streamed file');
      expect(progress.last, [bytes.length, bytes.length]);
      localDir.deleteSync(recursive: true);
    });

    test('fires the final got == total callback even for a 0-byte file', () async {
      File('${base.path}/empty.bin').writeAsBytesSync([]);
      final localDir = Directory.systemTemp.createTempSync('synctransport_dl3');
      final local = File('${localDir.path}/out.bin');
      final progress = <List<int>>[];

      await transport.downloadToFile('empty.bin', local,
          onProgress: (got, total) => progress.add([got, total]));

      expect(local.existsSync(), isTrue);
      expect(local.readAsBytesSync(), isEmpty);
      expect(progress, isNotEmpty);
      expect(progress.last, [0, 0]);
      localDir.deleteSync(recursive: true);
    });

    test('creates local parent dirs that do not yet exist', () async {
      File('${base.path}/small.bin').writeAsBytesSync([9, 9, 9]);
      final localDir = Directory.systemTemp.createTempSync('synctransport_dl2');
      final local = File('${localDir.path}/a/b/c/out.bin');

      await transport.downloadToFile('small.bin', local);

      expect(local.existsSync(), isTrue);
      expect(local.readAsBytesSync(), [9, 9, 9]);
      localDir.deleteSync(recursive: true);
    });
  });

  group('deleteRemote', () {
    test('removes an existing file', () async {
      File('${base.path}/gone.json').writeAsStringSync('x');
      await transport.deleteRemote('gone.json');
      expect(File('${base.path}/gone.json').existsSync(), isFalse);
    });

    test('is idempotent -- deleting an absent path is a no-op', () async {
      await transport.deleteRemote('never_existed.json');
      await transport.deleteRemote('never_existed.json');
      // No throw is the assertion; nothing further to check.
    });
  });

  test('close is a no-op', () async {
    await transport.close();
  });
}
