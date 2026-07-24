import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';

void main() {
  group('LibraryRootsPrefs.addRoot', () {
    test('adds a new root: writer invoked with the updated list, listeners notified', () {
      final writes = <List<String>>[];
      final prefs = LibraryRootsPrefs(roots: ['L:\\music'], writer: writes.add);
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.addRoot('L:\\downloads');

      expect(prefs.roots, ['L:\\music', 'L:\\downloads']);
      expect(writes, [
        ['L:\\music', 'L:\\downloads']
      ]);
      expect(notifications, 1);
    });

    test('adding an already-configured path no-ops: no write, no notify, list unchanged', () {
      final writes = <List<String>>[];
      final prefs = LibraryRootsPrefs(roots: ['L:\\music'], writer: writes.add);
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.addRoot('L:\\music');

      expect(prefs.roots, ['L:\\music']);
      expect(writes, isEmpty);
      expect(notifications, 0);
    });
  });

  group('LibraryRootsPrefs.removeRoot', () {
    test('removing a path that is not configured no-ops: no write, no notify, list unchanged', () {
      final writes = <List<String>>[];
      final prefs = LibraryRootsPrefs(roots: ['L:\\music'], writer: writes.add);
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.removeRoot('L:\\nowhere');

      expect(prefs.roots, ['L:\\music']);
      expect(writes, isEmpty);
      expect(notifications, 0);
    });

    test('removing a configured path removes it, writes the updated list, and notifies', () {
      final writes = <List<String>>[];
      final prefs = LibraryRootsPrefs(
          roots: ['L:\\music', 'L:\\downloads'], writer: writes.add);
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.removeRoot('L:\\music');

      expect(prefs.roots, ['L:\\downloads']);
      expect(writes, [
        ['L:\\downloads']
      ]);
      expect(notifications, 1);
    });
  });
}
