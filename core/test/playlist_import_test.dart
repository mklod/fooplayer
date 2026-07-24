import 'package:test/test.dart';
import 'package:fooplayer_core/src/seed/playlist_import.dart';

void main() {
  final ids = {
    'crying lightning.mp3': 'id1',
    'my propeller.mp3': 'id2',
    'secret door.flac': 'id3',
  };

  test('matches bare names, full paths, and mixed case', () {
    final r = importTxtPlaylist('mix', [
      'Crying Lightning.mp3',
      r'C:\music\albums\Humbug\My Propeller.mp3',
      'some/dir/Secret Door.flac',
    ], ids);
    expect(r.playlist.name, 'mix');
    expect(r.playlist.trackIds, ['id1', 'id2', 'id3']);
    expect(r.unmatched, isEmpty);
  });

  test('extensionless lines try audio extensions', () {
    final r = importTxtPlaylist('mix', ['Secret Door'], ids);
    expect(r.playlist.trackIds, ['id3']);
  });

  test('skips blanks and comments, reports unmatched', () {
    final r = importTxtPlaylist('mix', ['', '# comment', 'Nope.mp3'], ids);
    expect(r.playlist.trackIds, isEmpty);
    expect(r.unmatched, ['Nope.mp3']);
  });

  test('preserves order and duplicates', () {
    final r = importTxtPlaylist('mix',
        ['My Propeller.mp3', 'Crying Lightning.mp3', 'My Propeller.mp3'], ids);
    expect(r.playlist.trackIds, ['id2', 'id1', 'id2']);
  });
}
