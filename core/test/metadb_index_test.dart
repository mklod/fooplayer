import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/seed/metadb_index.dart';

void main() {
  test('loads records keyed by basename|size', () async {
    final dir = await Directory.systemTemp.createTemp('mdb');
    final f = File('${dir.path}/m.json');
    f.writeAsStringSync(jsonEncode({
      'records': [
        {'basename': 'song.mp3', 'size': 100, 'created': '2023-04-04T01:48:38.356840+00:00'},
        {'basename': 'song.mp3', 'size': 100, 'created': '2022-01-01T00:00:00+00:00'},
        {'basename': 'other.mp3', 'size': 5, 'created': '2024-06-01T10:00:00+00:00'},
      ]
    }));
    final idx = loadMetadbIndex(f.path);
    expect(idx.length, 2);
    expect(idx['song.mp3|100'], DateTime.utc(2022, 1, 1)); // earliest wins
    expect(idx['other.mp3|5'], DateTime.utc(2024, 6, 1, 10));
    await dir.delete(recursive: true);
  });
}
