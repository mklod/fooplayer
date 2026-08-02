// makeSetUpRootAction: the pure action builder behind the Settings "Set up"
// button.
//
// Root-caused live: every outcome of tapping "Set up" for a manifest-less
// root looked like nothing happened --
//   1. permission denied / user backs out of the All-files screen -> the old
//      inline closure did `if (!await requestFullStorageAccess()) return;`
//      and bailed SILENTLY.
//   2. seed SUCCEEDS -> .library.json written, but nothing refreshed:
//      LibraryModel.rootsMissingManifest only updates inside load(), so the
//      row still said "not set up yet" until an app restart or the 5-minute
//      tick.
//   3. seedRoot returns null (busy / scan error) -> also silent.
// This action builder is the testable, widget-free core of the fix: it
// narrates every outcome as a typed [SetUpRootResult] and only reloads the
// library on the success path, awaiting the reload before it hands back
// [SetUpRootDone] so a caller that rebuilds on the result never races the
// library's own listeners.
//
// Last modified: 2026-08-01--1946

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/set_up_root.dart';

void main() {
  group('makeSetUpRootAction', () {
    test(
      'access denied returns SetUpRootDenied and calls neither seed nor '
      'reload',
      () async {
        final calls = <String>[];
        final action = makeSetUpRootAction(
          requestAccess: () async => false,
          seed: (root) async {
            calls.add('seed');
            return 5;
          },
          reloadLibrary: () async => calls.add('reload'),
          libraryStatus: () => 'should not be read',
        );

        final result = await action(r'C:\new drop');

        expect(result, isA<SetUpRootDenied>());
        expect(calls, isEmpty);
      },
    );

    test(
      'seed returning null returns SetUpRootFailed carrying libraryStatus() '
      'and does not reload',
      () async {
        final calls = <String>[];
        final action = makeSetUpRootAction(
          requestAccess: () async => true,
          seed: (root) async {
            calls.add('seed');
            return null;
          },
          reloadLibrary: () async => calls.add('reload'),
          libraryStatus: () => 'could not read C:\\new drop: timed out',
        );

        final result = await action(r'C:\new drop');

        expect(result, isA<SetUpRootFailed>());
        expect(
          (result as SetUpRootFailed).status,
          'could not read C:\\new drop: timed out',
        );
        expect(calls, ['seed'], reason: 'reload must not run on failure');
      },
    );

    test(
      'seed returning a count reloads the library BEFORE resolving with '
      'SetUpRootDone(n)',
      () async {
        final calls = <String>[];
        final action = makeSetUpRootAction(
          requestAccess: () async => true,
          seed: (root) async {
            calls.add('seed');
            return 42;
          },
          reloadLibrary: () async {
            // A real reload does actual async work; make sure the action
            // truly awaits it rather than firing-and-forgetting.
            await Future<void>.delayed(const Duration(milliseconds: 1));
            calls.add('reload');
          },
          libraryStatus: () => 'ready',
        );

        final result = await action(r'C:\new drop');

        expect(calls, ['seed', 'reload'], reason: 'reload before Done');
        expect(result, isA<SetUpRootDone>());
        expect((result as SetUpRootDone).tracks, 42);
      },
    );

    test('the requested root path is forwarded to seed', () async {
      String? seededPath;
      final action = makeSetUpRootAction(
        requestAccess: () async => true,
        seed: (root) async {
          seededPath = root;
          return 1;
        },
        reloadLibrary: () async {},
        libraryStatus: () => 'ready',
      );

      await action(r'D:\some\folder');

      expect(seededPath, r'D:\some\folder');
    });
  });
}
