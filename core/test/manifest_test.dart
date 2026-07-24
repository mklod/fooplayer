import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/manifest.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('mani'));
  tearDown(() async => root.delete(recursive: true));

  Manifest sample() {
    final m = Manifest.empty();
    m.tracks['abc123'] =
        TrackEntry(dateAdded: '2023-04-04T01:48:38.356840Z', paths: ['albums/x/y.mp3']);
    m.playlists.add(Playlist(name: 'monthly 2023-04', trackIds: ['abc123']));
    return m;
  }

  test('round-trips through JSON', () {
    final m2 = Manifest.fromJson(sample().toJson());
    expect(m2.schema, 1);
    expect(m2.tracks['abc123']!.dateAdded, '2023-04-04T01:48:38.356840Z');
    expect(m2.tracks['abc123']!.paths, ['albums/x/y.mp3']);
    expect(m2.playlists.single.name, 'monthly 2023-04');
    expect(m2.playlists.single.trackIds, ['abc123']);
  });

  test('load of missing file returns empty manifest', () {
    final m = loadManifest(root);
    expect(m.tracks, isEmpty);
    expect(m.playlists, isEmpty);
  });

  test('save then load; second save keeps previous version as .bak', () async {
    await saveManifest(sample(), root);
    expect(loadManifest(root).tracks.containsKey('abc123'), isTrue);

    final m2 = sample();
    m2.tracks['def456'] = TrackEntry(dateAdded: '2024-01-01T00:00:00.000Z', paths: ['a.mp3']);
    await saveManifest(m2, root);

    expect(loadManifest(root).tracks.length, 2);
    final bak = jsonDecode(File('${root.path}/.library.json.bak').readAsStringSync());
    expect((bak['tracks'] as Map).length, 1); // previous version
  });

  test('corrupt main file falls back to .bak', () async {
    await saveManifest(sample(), root);
    await saveManifest(sample(), root); // creates .bak
    File('${root.path}/.library.json').writeAsStringSync('{not json');
    expect(loadManifest(root).tracks.containsKey('abc123'), isTrue);
  });

  test('malformed but valid JSON (wrong types) in main falls back to .bak', () async {
    await saveManifest(sample(), root);
    await saveManifest(sample(), root); // creates .bak
    // Valid JSON, but 'tracks' is a List instead of a Map -> TypeError during parse.
    File('${root.path}/.library.json')
        .writeAsStringSync(jsonEncode({'schema': 1, 'tracks': [], 'playlists': []}));
    expect(loadManifest(root).tracks.containsKey('abc123'), isTrue);
  });

  test('rejects unknown schema version', () {
    File('${root.path}/.library.json')
        .writeAsStringSync(jsonEncode({'schema': 99, 'tracks': {}, 'playlists': []}));
    expect(() => loadManifest(root), throwsA(isA<FormatException>()));
  });
}
