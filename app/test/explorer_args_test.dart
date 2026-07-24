// Unit tests for explorerArgsFor (ui/track_list.dart): the argv handed to
// `explorer.exe` for "View in folder". The critical contract is that
// `/select,` and the path are TWO separate argv elements -- packed into one
// (`/select,C:\...`) explorer silently ignores the argument for any path
// containing spaces and opens Documents instead. The two-element form was
// live-verified to select the file correctly.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/ui/track_list.dart';

Track trackAt({required String rootPath, required String relPath}) => Track(
  contentId: 'id',
  relPath: relPath,
  rootPath: rootPath,
  dateAdded: DateTime.utc(2024, 1, 1),
  title: 't',
);

void main() {
  test('builds exactly two argv elements: bare /select, then the path', () {
    final args = explorerArgsFor(
      trackAt(rootPath: r'C:\Music', relPath: 'sub/Song.mp3'),
    );
    expect(args, hasLength(2));
    expect(args[0], '/select,'); // flag alone -- never fused with the path
    expect(args[1], r'C:\Music\sub\Song.mp3');
  });

  test(
    'paths with spaces stay a single second element, never split or fused',
    () {
      final args = explorerArgsFor(
        trackAt(
          rootPath: r'L:\music library',
          relPath: 'Feed Me/Feed Me (Deluxe)/01 One Click Headshot.mp3',
        ),
      );
      expect(args, [
        '/select,',
        r'L:\music library\Feed Me\Feed Me (Deluxe)\01 One Click Headshot.mp3',
      ]);
    },
  );

  test(
    'forward slashes in relPath are converted to backslashes throughout',
    () {
      final args = explorerArgsFor(
        trackAt(rootPath: r'D:\a', relPath: 'b/c/d.flac'),
      );
      expect(args[1], r'D:\a\b\c\d.flac');
      expect(args[1], isNot(contains('/')));
      // Absolute (drive-rooted) path, exactly as explorer requires.
      expect(RegExp(r'^[A-Za-z]:\\').hasMatch(args[1]), isTrue);
    },
  );
}
