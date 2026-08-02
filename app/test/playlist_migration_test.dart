import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:fooplayer_app/model/playlist_migration.dart';

void main() {
  late Directory home, rootA, rootB;
  final t0 = DateTime.parse('2026-07-31T12:00:00Z');

  setUp(() {
    home = Directory.systemTemp.createTempSync('mig');
    rootA = Directory('${home.path}/rootA')..createSync();
    rootB = Directory('${home.path}/rootB')..createSync();
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> seedManifest(Directory root, List<core.Playlist> pls) =>
      core.saveManifest(
          core.Manifest(schema: 1, tracks: {}, playlists: pls), root);

  Future<List<String>> run() => migratePlaylistsToSidecar(
      roots: [rootA, rootB], home: home, device: 'test',
      now: () => t0, rng: Random(7));

  test('moves manifest playlists into the sidecar and empties the array', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await seedManifest(rootB, []);
    final notes = await run();
    expect(notes, isNotEmpty);
    final state = core.loadPlaylistsDir(home);
    expect(state.playlists.values.map((p) => p.name), ['mix']);
    expect(state.playlists.values.single.trackIds, ['x']);
    expect(core.loadManifest(rootA).playlists, isEmpty);
  });

  test('running twice is a no-op', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    final second = await run();
    expect(second, isEmpty);
    expect(core.loadPlaylistsDir(home).playlists, hasLength(1));
  });

  test('two devices with identical manifests dedupe by (name, trackIds)', () async {
    // Device 2's manifest copy still carries the playlist after device 1 migrated.
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    final notes = await run();
    expect(notes.single, contains('already'));
    expect(core.loadPlaylistsDir(home).playlists, hasLength(1));
  });

  test('same name, different content imports with a suffix', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['y'])]);
    await run();
    final names = core.loadPlaylistsDir(home).playlists.values.map((p) => p.name);
    expect(names, unorderedEquals(['mix', 'mix (2)']));
  });

  test('a root with no manifest is skipped without error', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: [])]);
    final rootC = Directory('${home.path}/rootC')..createSync();
    final notes = await migratePlaylistsToSidecar(
        roots: [rootA, rootC], home: home, device: 'test',
        now: () => t0, rng: Random(7));
    expect(notes, isNotEmpty);
  });
}
