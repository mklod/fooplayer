import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/manifest_io.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mani'));
  tearDown(() async => tmp.delete(recursive: true));

  File write(Map<String, dynamic> json) =>
      File('${tmp.path}/.library.json')..writeAsStringSync(jsonEncode(json));

  test('parses tracks and playlists from schema-1 manifest', () {
    final f = write({
      'schema': 1,
      'tracks': {
        'id1': {
          'date_added': '2023-04-04T01:48:38.356840Z',
          'paths': ['albums/X/Artist - Song.mp3', 'copy/Artist - Song.mp3'],
        },
        'id2': {
          'date_added': '2024-01-01T00:00:00.000Z',
          'paths': ['loose/track2.mp3'],
        },
      },
      'playlists': [
        {
          'name': 'mix',
          'track_ids': ['id2', 'id1'],
        },
      ],
    });
    final data = loadManifestFile(f, rootPath: tmp.path);
    expect(data.tracks, hasLength(2));
    final t1 = data.tracks.singleWhere((t) => t.contentId == 'id1');
    expect(t1.relPath, 'albums/X/Artist - Song.mp3'); // first path wins
    expect(t1.rootPath, tmp.path);
    expect(t1.dateAdded, DateTime.utc(2023, 4, 4, 1, 48, 38, 356, 840));
    expect(
      t1.title,
      'Artist - Song',
    ); // filename sans extension until metadata fills it
    expect(t1.artist, '');
    expect(data.playlists.single.name, 'mix');
    expect(data.playlists.single.trackIds, ['id2', 'id1']);
  });

  test('rejects unknown schema', () {
    final f = write({'schema': 99, 'tracks': {}, 'playlists': []});
    expect(
      () => loadManifestFile(f, rootPath: tmp.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('copyWith fills metadata without touching identity', () {
    final f = write({
      'schema': 1,
      'tracks': {
        'id1': {
          'date_added': '2024-01-01T00:00:00.000Z',
          'paths': ['a.mp3'],
        },
      },
      'playlists': [],
    });
    final t = loadManifestFile(f, rootPath: tmp.path).tracks.single;
    final filled = t.copyWith(
      artist: 'Muse',
      title: 'New Born',
      album: 'Origin',
      genre: 'Rock',
    );
    expect(filled.contentId, t.contentId);
    expect(filled.relPath, t.relPath);
    expect(filled.rootPath, t.rootPath);
    expect(filled.artist, 'Muse');
    expect(filled.genre, 'Rock');
  });
}
