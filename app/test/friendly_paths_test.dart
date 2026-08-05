// friendlyAndroidPath: readable labels for Android paths in the settings
// surfaces; anything unrecognized (desktop paths above all) passes through
// unchanged. Display-only -- config and sync state keep real paths.
//
// Last modified: 2026-08-05--0810
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/friendly_paths.dart';

void main() {
  test('internal shared storage', () {
    expect(
      friendlyAndroidPath('/storage/emulated/0/Music'),
      'Internal storage › Music',
    );
    expect(
      friendlyAndroidPath('/storage/emulated/0/Music/albums'),
      'Internal storage › Music › albums',
    );
    expect(friendlyAndroidPath('/storage/emulated/0'), 'Internal storage');
    expect(friendlyAndroidPath('/storage/emulated/0/'), 'Internal storage');
  });

  test('app-private files dir', () {
    expect(
      friendlyAndroidPath(
        '/data/user/0/dev.mklod.fooplayer_app/files/loose tracks - old',
      ),
      'App storage › loose tracks - old',
    );
    expect(
      friendlyAndroidPath('/data/user/0/dev.mklod.fooplayer_app/files'),
      'App storage',
    );
    expect(
      friendlyAndroidPath('/data/data/dev.mklod.fooplayer_app/files/music'),
      'App storage › music',
    );
  });

  test('removable SD card volume', () {
    expect(
      friendlyAndroidPath('/storage/1234-ABCD/Music'),
      'SD card › Music',
    );
  });

  test('everything else passes through unchanged', () {
    expect(friendlyAndroidPath(r'L:\music (original structure)'),
        r'L:\music (original structure)');
    expect(friendlyAndroidPath(r'C:\Users\mklod\Music'),
        r'C:\Users\mklod\Music');
    expect(friendlyAndroidPath('/home/user/music'), '/home/user/music');
  });
}
