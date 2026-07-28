// The periodic rescan must not narrate itself.
//
// The status line sits under the sidebar buttons reading "ready — 5470
// tracks". Every timer tick, the background rescan wrote "scanning monthly…",
// "scanning alternative times…" and so on for all five roots, then "ready"
// again — so an idle library twitched on a loop, saying nothing useful. A
// quiet pass stays silent unless it actually finds something.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';

Future<Directory> _root(Directory tmp, String name) async {
  final root = await Directory('${tmp.path}/$name').create();
  await File('${root.path}/.library.json').writeAsString(jsonEncode({
    'schema': 1,
    'tracks': {
      'a': {'date_added': '2024-01-01T00:00:00Z', 'paths': ['a.mp3']},
    },
    'playlists': [],
  }));
  return root;
}

void main() {
  late Directory tmp;
  late LibraryModel model;
  late File cacheFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('quietrescan');
    cacheFile = File('${tmp.path}/cache.json');
    model = LibraryModel();
    await model
        .load(libraryRoots: [await _root(tmp, 'r1')], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('a quiet rescan that finds nothing leaves the status untouched',
      () async {
    model.status = 'ready';
    final seen = <String>[];
    model.addListener(() => seen.add(model.status));

    await model.rescan(quiet: true).timeout(const Duration(seconds: 60));

    expect(model.status, 'ready');
    expect(seen.where((s) => s.startsWith('scanning')), isEmpty,
        reason: 'no per-root chatter from a pass nobody asked for');
  });

  test('a loud rescan still narrates -- the sidebar button wants feedback',
      () async {
    model.status = 'ready';
    final seen = <String>[];
    model.addListener(() => seen.add(model.status));

    await model.rescan().timeout(const Duration(seconds: 60));

    expect(seen.where((s) => s.startsWith('scanning')), isNotEmpty);
    expect(model.status, 'ready');
  });
}
