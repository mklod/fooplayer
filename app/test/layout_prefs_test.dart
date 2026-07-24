import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

void main() {
  group('LayoutPrefs defaults', () {
    test('defaults to sidebarWidth 200 / filterHeight 180', () {
      final prefs = LayoutPrefs();
      expect(prefs.sidebarWidth, 200);
      expect(prefs.filterHeight, 180);
    });
  });

  group('LayoutPrefs clamping', () {
    test('sidebarWidth clamps to the 140-400 range on both ends', () {
      final prefs = LayoutPrefs();
      prefs.setSidebarWidth(10);
      expect(prefs.sidebarWidth, kSidebarWidthMin);
      prefs.setSidebarWidth(9999);
      expect(prefs.sidebarWidth, kSidebarWidthMax);
      prefs.setSidebarWidth(250);
      expect(prefs.sidebarWidth, 250);
    });

    test('filterHeight clamps to the 120-320 range on both ends', () {
      final prefs = LayoutPrefs();
      prefs.setFilterHeight(1);
      expect(prefs.filterHeight, kFilterHeightMin);
      prefs.setFilterHeight(99999);
      expect(prefs.filterHeight, kFilterHeightMax);
      prefs.setFilterHeight(200);
      expect(prefs.filterHeight, 200);
    });

    test('constructor also clamps out-of-range initial values', () {
      final prefs = LayoutPrefs(sidebarWidth: 5, filterHeight: 5000);
      expect(prefs.sidebarWidth, kSidebarWidthMin);
      expect(prefs.filterHeight, kFilterHeightMax);
    });

    test('fromConfig clamps values loaded from a bad/legacy config map', () {
      final prefs = LayoutPrefs.fromConfig({
        'sidebarWidth': 1,
        'filterHeight': 10000,
      });
      expect(prefs.sidebarWidth, kSidebarWidthMin);
      expect(prefs.filterHeight, kFilterHeightMax);
    });

    test('fromConfig falls back to defaults for a null/empty ui map', () {
      final prefs = LayoutPrefs.fromConfig(null);
      expect(prefs.sidebarWidth, kSidebarWidthDefault);
      expect(prefs.filterHeight, kFilterHeightDefault);
    });
  });

  group('LayoutPrefs notifies listeners', () {
    test('setSidebarWidth notifies once per changed value, not on no-op', () {
      final prefs = LayoutPrefs();
      var notifications = 0;
      prefs.addListener(() => notifications++);
      prefs.setSidebarWidth(250);
      expect(notifications, 1);
      prefs.setSidebarWidth(250); // unchanged -> no extra notification
      expect(notifications, 1);
    });
  });

  group('LayoutPrefs debounced persistence', () {
    test('multiple set calls within 500ms collapse into a single write',
        () {
      fakeAsync((async) {
        final writes = <Map<String, dynamic>>[];
        final prefs = LayoutPrefs(writer: writes.add);

        prefs.setSidebarWidth(220);
        async.elapse(const Duration(milliseconds: 100));
        prefs.setSidebarWidth(240);
        async.elapse(const Duration(milliseconds: 100));
        prefs.setFilterHeight(200);
        async.elapse(const Duration(milliseconds: 100));

        // Still within the 500ms debounce window of the *last* call: no
        // write yet.
        expect(writes, isEmpty);

        async.elapse(const Duration(milliseconds: 500));

        expect(writes, hasLength(1));
        expect(writes.single, {'sidebarWidth': 240, 'filterHeight': 200});
      });
    });

    test('a write more than 500ms after the previous burst fires again', () {
      fakeAsync((async) {
        final writes = <Map<String, dynamic>>[];
        final prefs = LayoutPrefs(writer: writes.add);

        prefs.setSidebarWidth(220);
        async.elapse(const Duration(milliseconds: 500));
        expect(writes, hasLength(1));

        prefs.setSidebarWidth(300);
        async.elapse(const Duration(milliseconds: 500));
        expect(writes, hasLength(2));
        expect(writes.last, {'sidebarWidth': 300, 'filterHeight': 180});
      });
    });

    test('no writer supplied means no crash on debounce fire', () {
      fakeAsync((async) {
        final prefs = LayoutPrefs();
        prefs.setSidebarWidth(220);
        async.elapse(const Duration(milliseconds: 500));
        // Nothing to assert beyond "did not throw".
      });
    });
  });
}
