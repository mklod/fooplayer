import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_home.dart';

void main() {
  test('override wins verbatim', () {
    expect(resolveLibraryHome([r'C:\a\b'], override: r'D:\home'), r'D:\home');
  });
  test('single root: home is its parent', () {
    expect(resolveLibraryHome([r'L:\music (original structure)\monthly']),
        r'L:\music (original structure)');
  });
  test('five siblings share their parent', () {
    expect(
      resolveLibraryHome([
        r'L:\music (original structure)\monthly',
        r'L:\music (original structure)\albums',
        r'L:\music (original structure)\loose tracks - old',
      ]),
      r'L:\music (original structure)',
    );
  });
  test('nested roots resolve to the shallower parent', () {
    expect(resolveLibraryHome([r'C:\m\a', r'C:\m\sub\b']), r'C:\m');
  });
  test('android-style forward-slash roots', () {
    expect(
      resolveLibraryHome(['/storage/emulated/0/Music/loose tracks - 2020 and later']),
      '/storage/emulated/0/Music',
    );
  });
  test('no common parent (different drives) is null', () {
    expect(resolveLibraryHome([r'C:\a', r'D:\b']), isNull);
  });
  test('empty roots is null', () {
    expect(resolveLibraryHome([]), isNull);
  });
  test('deviceLabel prefers config deviceName', () {
    expect(deviceLabel({'deviceName': 'tablet-s9'}), 'tablet-s9');
    expect(deviceLabel({'deviceName': ''}), isNotEmpty); // falls back to hostname
    expect(deviceLabel({}), isNotEmpty);
  });
}
