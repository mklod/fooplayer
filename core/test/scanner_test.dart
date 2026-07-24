import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/scanner.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan');
    Directory('${root.path}/albums/A').createSync(recursive: true);
    File('${root.path}/albums/A/one.mp3').writeAsBytesSync(List.filled(100, 1));
    File('${root.path}/two.flac').writeAsBytesSync(List.filled(200, 2));
    File('${root.path}/notes.txt').writeAsStringSync('not audio');
    File('${root.path}/.library.json').writeAsStringSync('{}'); // dot-file: skipped
  });
  tearDown(() async => root.delete(recursive: true));

  test('finds only audio files, relative forward-slash paths, sorted', () async {
    final tracks = await scanLibrary(root);
    expect(tracks.map((t) => t.relPath).toList(), ['albums/A/one.mp3', 'two.flac']);
    expect(tracks.first.size, 100);
    expect(tracks.first.contentId, hasLength(64));
  });

  test('second scan reuses cache for unchanged files', () async {
    await scanLibrary(root);
    final cacheFile = File('${root.path}/.hash_cache.json');
    expect(cacheFile.existsSync(), isTrue);

    // Poison the cached ID; unchanged file must keep the poisoned value (cache hit).
    final cache = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    (cache['albums/A/one.mp3'] as Map<String, dynamic>)['id'] = 'poisoned';
    cacheFile.writeAsStringSync(jsonEncode(cache));

    final tracks = await scanLibrary(root);
    expect(tracks.firstWhere((t) => t.relPath == 'albums/A/one.mp3').contentId, 'poisoned');
  });

  test('changed file is re-hashed', () async {
    await scanLibrary(root);
    File('${root.path}/albums/A/one.mp3').writeAsBytesSync(List.filled(150, 9));
    final tracks = await scanLibrary(root);
    final t = tracks.firstWhere((t) => t.relPath == 'albums/A/one.mp3');
    expect(t.size, 150);
    expect(t.contentId, isNot('poisoned'));
  });
}
