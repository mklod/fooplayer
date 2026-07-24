import 'package:test/test.dart';
import 'package:fooplayer_core/src/library_ops.dart';
import 'package:fooplayer_core/src/manifest.dart';
import 'package:fooplayer_core/src/scanner.dart';

ScannedTrack st(String path, String id) =>
    ScannedTrack(path, 100, DateTime.utc(2026, 1, 1), id);

void main() {
  final fixedNow = DateTime.utc(2026, 7, 23, 12);

  test('new track is stamped with now()', () {
    final m = Manifest.empty();
    final d = diffAgainstManifest(m, [st('a.mp3', 'id1')]);
    expect(d.newTracks.single.contentId, 'id1');
    applyDiff(m, d, [st('a.mp3', 'id1')], () => fixedNow);
    expect(m.tracks['id1']!.dateAdded, '2026-07-23T12:00:00.000Z');
    expect(m.tracks['id1']!.paths, ['a.mp3']);
  });

  test('known track at new path keeps date_added, updates path', () {
    final m = Manifest.empty();
    m.tracks['id1'] = TrackEntry(dateAdded: '2023-01-01T00:00:00.000Z', paths: ['old.mp3']);
    final scan = [st('new/dir/renamed.mp3', 'id1')];
    final d = diffAgainstManifest(m, scan);
    expect(d.newTracks, isEmpty);
    expect(d.movedOrRetagged['id1'], ['new/dir/renamed.mp3']);
    applyDiff(m, d, scan, () => fixedNow);
    expect(m.tracks['id1']!.dateAdded, '2023-01-01T00:00:00.000Z'); // unchanged
    expect(m.tracks['id1']!.paths, ['new/dir/renamed.mp3']);
  });

  test('missing file is reported but entry retained', () {
    final m = Manifest.empty();
    m.tracks['id1'] = TrackEntry(dateAdded: '2023-01-01T00:00:00.000Z', paths: ['gone.mp3']);
    final d = diffAgainstManifest(m, []);
    expect(d.missingTrackIds, ['id1']);
    applyDiff(m, d, [], () => fixedNow);
    expect(m.tracks.containsKey('id1'), isTrue); // hidden, not deleted
  });

  test('duplicate audio: one entry, both paths, single date', () {
    final m = Manifest.empty();
    final scan = [st('a.mp3', 'id1'), st('copy/a.mp3', 'id1')];
    final d = diffAgainstManifest(m, scan);
    expect(d.duplicates['id1'], ['a.mp3', 'copy/a.mp3']);
    applyDiff(m, d, scan, () => fixedNow);
    expect(m.tracks.length, 1);
    expect(m.tracks['id1']!.paths, ['a.mp3', 'copy/a.mp3']);
  });

  test('no changes → empty diff', () {
    final m = Manifest.empty();
    m.tracks['id1'] = TrackEntry(dateAdded: '2023-01-01T00:00:00.000Z', paths: ['a.mp3']);
    expect(diffAgainstManifest(m, [st('a.mp3', 'id1')]).isEmpty, isTrue);
  });
}
