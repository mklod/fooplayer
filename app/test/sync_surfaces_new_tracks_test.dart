// EXPERIMENT (2026-09-18): "LAN sync reported two new loose-tracks files
// synced; nothing at the top of the library for ~10 minutes, then a single
// new track appeared."
//
// End-to-end: real temp "NAS" and "phone" dirs, real LocalDirTransport,
// real LibraryModel loaded against the phone mirror. The contract under
// test is the user-visible one: when SyncEngine.run() returns having
// copied a track, the library must already show it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/activity_model.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/sync/sync_engine.dart';
import 'package:fooplayer_app/sync/sync_settings.dart';
import 'package:fooplayer_app/sync/sync_transport.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;

void main() {
  late Directory nasHome;
  late Directory localHome;

  setUp(() {
    nasHome = Directory.systemTemp.createTempSync('surf_nas');
    localHome = Directory.systemTemp.createTempSync('surf_local');
  });
  tearDown(() {
    if (nasHome.existsSync()) nasHome.deleteSync(recursive: true);
    if (localHome.existsSync()) localHome.deleteSync(recursive: true);
  });

  Future<String> writeNasTrack(String rootName, String relPath, int seed) async {
    final bytes = List<int>.generate(300, (i) => (seed + i) % 256);
    final f = File('${nasHome.path}/$rootName/$relPath');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return core.contentIdForFile(f);
  }

  Future<void> writeNasManifest(
    String rootName,
    Map<String, List<String>> idToPaths,
  ) async {
    final manifest = core.Manifest(
      schema: 1,
      tracks: {
        for (final e in idToPaths.entries)
          e.key: core.TrackEntry(
            dateAdded: DateTime.utc(2026, 9, 17, 12).toIso8601String(),
            paths: e.value,
          ),
      },
      playlists: [],
    );
    await core.saveManifest(manifest, Directory('${nasHome.path}/$rootName'));
  }

  SyncEngine buildEngine(LibraryModel library) => SyncEngine(
    transport: LocalDirTransport(nasHome),
    localHome: localHome,
    settings: SyncSettings(roots: const {'RootA': true}),
    library: library,
    activity: ActivityModel(),
    freeSpace: (_) async => 1 << 40,
  );

  test('a track copied by a sync is in allTracks the moment run() returns',
      () async {
    final idA = await writeNasTrack('RootA', 'a.wav', 1);
    await writeNasManifest('RootA', {idA: ['a.wav']});

    // First sync: the phone mirror is created.
    final library = LibraryModel();
    await buildEngine(library).run();

    // The app then loads the library off that mirror, as it does at launch.
    final root = Directory('${localHome.path}/RootA');
    final cacheFile = File('${localHome.path}/meta_cache.json');
    await library
        .load(libraryRoots: [root], cacheFile: cacheFile)
        .timeout(const Duration(seconds: 30));
    expect(library.allTracks, hasLength(1));

    // A new track lands on the NAS and is indexed there.
    final idB = await writeNasTrack('RootA', 'Slowburn - I Want You.wav', 2);
    await writeNasManifest('RootA', {
      idA: ['a.wav'],
      idB: ['Slowburn - I Want You.wav'],
    });

    // Sync now.
    final report = await buildEngine(library).run().timeout(
      const Duration(seconds: 60),
    );
    final result = report.roots.single;
    expect(result.copied, greaterThan(0), reason: 'the file must have landed');
    expect(
      File('${root.path}/Slowburn - I Want You.wav').existsSync(),
      isTrue,
    );

    expect(
      library.allTracks.map((t) => t.contentId),
      contains(idB),
      reason: 'the feed must show it as soon as the sync reports it copied',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a copied sidecar is counted as a file but NOT as a track', () async {
    final idA = await writeNasTrack('RootA', 'a.wav', 1);
    await writeNasManifest('RootA', {idA: ['a.wav']});
    // The artwork sidecar the desktop writes next to the music.
    final sidecar = File('${nasHome.path}/RootA/.artwork.json');
    await sidecar.writeAsString('{"schema":1,"entries":{}}');

    final library = LibraryModel();
    final result = (await buildEngine(library).run()).roots.single;

    expect(result.copied, 2, reason: 'the track and the sidecar both landed');
    expect(
      result.copiedTracks,
      1,
      reason: 'only one of them was a song -- reporting 2 as a track count '
          'is what made a correct sync look broken',
    );
    expect(
      File('${localHome.path}/RootA/.artwork.json').existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
