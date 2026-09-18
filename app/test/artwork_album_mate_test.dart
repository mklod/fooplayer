// A track with no cover of its own borrows one from another track on the
// same album -- DELIBERATELY, not by luck of the draw.
//
// Reported live 2026-09-18 from "Kanye West - Late Registration": 20 of 21
// files carry embedded art, `15 - Skit 3.mp3` does not, and the album has
// no recorded cover of its own. The skit still displayed the album cover,
// because the resolver caches by ALBUM and a sibling happened to resolve
// first -- and if the skit had resolved first instead, its "no art" answer
// would have been cached for the whole album and all 21 rows would have
// gone grey.
//
// Making the borrow an explicit last step in the chain is also what lets
// the library's Art column promise "you will see a cover on this row".
//
// Last modified: 2026-09-18--1520
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:path/path.dart' as p;

final mateBytes = [7, 7, 7];

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;
  late Directory albumDir;
  late File skit;
  late File mate;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fooplayer_album_mate');
    root = Directory(p.join(tmp.path, 'root'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
    albumDir = Directory(p.join(root.path, 'Kanye West', 'Late Registration'))
      ..createSync(recursive: true);
    skit = File(p.join(albumDir.path, '15 - Skit 3.mp3'))
      ..writeAsBytesSync([0]);
    mate = File(p.join(albumDir.path, '01 - Wake Up Mr. West.mp3'))
      ..writeAsBytesSync([0]);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ArtworkRequest skitRequest() => ArtworkRequest(
    rootPath: root.path,
    file: skit,
    artist: 'Kanye West',
    album: 'Late Registration',
    title: 'Skit 3',
    contentId: 'skit-content-id',
  );

  ArtworkStoreRegistry registry() => ArtworkStoreRegistry(appDataDir: appData);

  /// Only the mate carries embedded art.
  Future<List<int>?> onlyMateHasArt(File f) async =>
      f.path == mate.path ? mateBytes : null;

  test('a bare track shows an album-mate\'s cover on a COLD cache', () async {
    final resolver = ArtworkResolver(
      stores: registry(),
      embeddedLoader: onlyMateHasArt,
      albumMates: (req) => [mate],
    );
    addTearDown(resolver.dispose);

    // The skit is the FIRST track of this album anyone asks about.
    expect(await resolver.resolve(skitRequest()), mateBytes);
  });

  test('with no mate carrying art either, the answer is still null', () async {
    final resolver = ArtworkResolver(
      stores: registry(),
      embeddedLoader: (_) async => null,
      albumMates: (req) => [mate],
    );
    addTearDown(resolver.dispose);

    expect(await resolver.resolve(skitRequest()), isNull);
  });

  test('borrowing never overrides a cover the track itself has', () async {
    final resolver = ArtworkResolver(
      stores: registry(),
      embeddedLoader: (f) async => f.path == skit.path ? [9, 9, 9] : mateBytes,
      albumMates: (req) => [mate],
    );
    addTearDown(resolver.dispose);

    expect(await resolver.resolve(skitRequest()), [9, 9, 9]);
  });

  test('a track whose art was explicitly REMOVED still shows nothing',
      () async {
    final reg = registry();
    final store = reg.forRoot(root.path);
    await store.ensureLoaded();
    await store.remove(trackArtKey('skit-content-id'));

    final resolver = ArtworkResolver(
      stores: reg,
      embeddedLoader: onlyMateHasArt,
      albumMates: (req) => [mate],
    );
    addTearDown(resolver.dispose);

    expect(
      await resolver.resolve(skitRequest()),
      isNull,
      reason: 'a deliberate removal must not be undone by borrowing',
    );
  });
}
