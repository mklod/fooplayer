import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('plsc'));
  tearDown(() => home.deleteSync(recursive: true));

  PlaylistFile pf(String id, String name, List<String> ids, String mod) =>
      PlaylistFile(id: id, name: name, trackIds: ids,
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse(mod), modifiedBy: 'test');

  test('save then load round-trips a playlist file', () async {
    final p = pf('p_00000001', 'roadtrip', ['id-a', 'id-b'], '2026-07-31T12:00:00Z');
    await savePlaylistFile(home, p);
    final state = loadPlaylistsDir(home);
    expect(state.playlists.keys, ['p_00000001']);
    final got = state.playlists['p_00000001']!;
    expect(got.name, 'roadtrip');
    expect(got.trackIds, ['id-a', 'id-b']);
    expect(got.modified, DateTime.parse('2026-07-31T12:00:00Z'));
    expect(got.created, DateTime.parse('2026-07-01T00:00:00Z'));
    expect(got.modifiedBy, 'test');
  });

  test('loadPlaylistsDir on a home with no .playlists dir is empty, not an error', () {
    final state = loadPlaylistsDir(home);
    expect(state.playlists, isEmpty);
    expect(state.tombstones, isEmpty);
    expect(state.corruptFiles, isEmpty);
  });

  test('a corrupt playlist file is skipped and reported, never thrown', () async {
    await savePlaylistFile(home, pf('p_00000001', 'ok', [], '2026-07-31T12:00:00Z'));
    final dir = Directory('${home.path}/$playlistsDirName');
    File('${dir.path}/p_bad.json').writeAsStringSync('{not json');
    File('${dir.path}/p_wrongshape.json').writeAsStringSync('{"schema":1,"id":42}');
    final state = loadPlaylistsDir(home);
    expect(state.playlists.keys, ['p_00000001']);
    expect(state.corruptFiles, unorderedEquals(['p_bad.json', 'p_wrongshape.json']));
  });

  test('missing created falls back to modified (older writers)', () {
    final j = {'schema': 1, 'id': 'p_x', 'name': 'n', 'track_ids': <String>[],
               'modified': '2026-07-31T12:00:00Z', 'modified_by': 'd'};
    final p = PlaylistFile.fromJson(j)!;
    expect(p.created, p.modified);
  });

  test('unknown keys are tolerated (forward compatibility)', () {
    final j = {'schema': 1, 'id': 'p_x', 'name': 'n', 'track_ids': <String>[],
               'modified': '2026-07-31T12:00:00Z', 'future_key': {'a': 1}};
    expect(PlaylistFile.fromJson(j), isNotNull);
  });

  test('save is atomic: tmp file never left behind, second save replaces', () async {
    final p = pf('p_00000001', 'v1', [], '2026-07-31T12:00:00Z');
    await savePlaylistFile(home, p);
    p.name = 'v2';
    await savePlaylistFile(home, p);
    final dir = Directory('${home.path}/$playlistsDirName');
    expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    expect(loadPlaylistsDir(home).playlists['p_00000001']!.name, 'v2');
  });

  test('tombstones round-trip and tolerate a corrupt file', () async {
    await saveTombstones(home, {
      'p_dead': PlaylistTombstone(
          deleted: DateTime.parse('2026-07-30T00:00:00Z'), name: 'old mix'),
    });
    var state = loadPlaylistsDir(home);
    expect(state.tombstones['p_dead']!.name, 'old mix');
    File('${home.path}/$playlistsDirName/$playlistTombstonesFileName')
        .writeAsStringSync('garbage');
    state = loadPlaylistsDir(home);
    expect(state.tombstones, isEmpty); // degraded, not thrown
  });

  test('backupPlaylistFile writes a timestamped snapshot under backup/', () async {
    final p = pf('p_00000001', 'keep me', ['x'], '2026-07-31T12:00:00Z');
    await backupPlaylistFile(home, p, DateTime.parse('2026-07-31T13:14:15Z'));
    final backups = Directory('${home.path}/$playlistsDirName/$playlistBackupDirName')
        .listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(backups, ['p_00000001--20260731-131415.json']);
    final j = jsonDecode(File(
        '${home.path}/$playlistsDirName/$playlistBackupDirName/${backups.single}')
        .readAsStringSync()) as Map<String, dynamic>;
    expect(j['name'], 'keep me');
  });

  test('removePlaylistFile deletes the file and is idempotent', () async {
    await savePlaylistFile(home, pf('p_00000001', 'x', [], '2026-07-31T12:00:00Z'));
    await removePlaylistFile(home, 'p_00000001');
    await removePlaylistFile(home, 'p_00000001'); // second call: no throw
    expect(loadPlaylistsDir(home).playlists, isEmpty);
  });

  test('newPlaylistId shape and seeded determinism', () {
    expect(newPlaylistId(Random(1)), matches(RegExp(r'^p_[0-9a-f]{8}$')));
    expect(newPlaylistId(Random(1)), newPlaylistId(Random(1)));
  });

  test('sameContentAs compares name and ordered trackIds only', () {
    final a = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z');
    final b = pf('p_2', 'n', ['x', 'y'], '2026-01-01T00:00:00Z');
    expect(a.sameContentAs(b), isTrue);
    b.trackIds = ['y', 'x'];
    expect(a.sameContentAs(b), isFalse); // order matters: playlists are ordered
  });
}
