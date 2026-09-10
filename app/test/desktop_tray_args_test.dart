// The Startup-folder shortcut passes --tray so fooplayer boots straight
// into the notification area as the library's indexer; a hand-launched
// copy shows its window as usual. The native runner reads the same flag
// (windows/runner/main.cpp) to suppress show-on-first-frame.
//
// Last modified: 2026-09-10--0430
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/desktop_tray.dart';

void main() {
  test('--tray selects a hidden start; anything else does not', () {
    expect(startsHidden(['--tray']), isTrue);
    expect(startsHidden(['--verbose', '--tray']), isTrue);
    expect(startsHidden([]), isFalse);
    expect(startsHidden(['--verbose']), isFalse);
    // Not a prefix match -- only the exact flag counts.
    expect(startsHidden(['--tray-icon']), isFalse);
  });
}
