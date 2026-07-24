import 'package:test/test.dart';
import 'package:fooplayer_core/src/scanner.dart';
import 'package:fooplayer_core/src/seed/seed_migration.dart';

ScannedTrack st(String path, String id, {int size = 100}) =>
    ScannedTrack(path, size, DateTime.utc(2026, 1, 1), id);

void main() {
  final ctimes = {
    'albums/x/a.mp3': DateTime.utc(2025, 12, 1),
    'albums/x/b.mp3': DateTime.utc(2025, 12, 2),
    'copy/a.mp3': DateTime.utc(2026, 2, 2),
  };
  DateTime ctimeOf(String p) => ctimes[p]!;

  test('metadb date wins over ctime', () {
    final r = buildSeedManifest(
      scan: [st('albums/x/a.mp3', 'id1')],
      metadb: {'a.mp3|100': DateTime.utc(2023, 4, 4)},
      ctimeOf: ctimeOf,
    );
    expect(r.manifest.tracks['id1']!.dateAdded, '2023-04-04T00:00:00.000Z');
    expect(r.fromMetadb, 1);
    expect(r.fromCtime, 0);
  });

  test('falls back to ctime when no metadb match', () {
    final r = buildSeedManifest(
      scan: [st('albums/x/b.mp3', 'id2')],
      metadb: {},
      ctimeOf: ctimeOf,
    );
    expect(r.manifest.tracks['id2']!.dateAdded, '2025-12-02T00:00:00.000Z');
    expect(r.fromCtime, 1);
  });

  test('duplicate content ID: earliest date, both paths', () {
    final r = buildSeedManifest(
      scan: [st('albums/x/a.mp3', 'id1'), st('copy/a.mp3', 'id1')],
      metadb: {},
      ctimeOf: ctimeOf,
    );
    expect(r.manifest.tracks.length, 1);
    expect(r.manifest.tracks['id1']!.dateAdded, '2025-12-01T00:00:00.000Z');
    expect(r.manifest.tracks['id1']!.paths, ['albums/x/a.mp3', 'copy/a.mp3']);
    expect(r.duplicateGroups, 1);
  });

  test('report contains counts', () {
    final r = buildSeedManifest(
      scan: [st('albums/x/a.mp3', 'id1')],
      metadb: {'a.mp3|100': DateTime.utc(2023, 4, 4)},
      ctimeOf: ctimeOf,
    );
    expect(r.report.join('\n'), contains('tracks: 1'));
    expect(r.report.join('\n'), contains('from metadb: 1'));
  });
}
