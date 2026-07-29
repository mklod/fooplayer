// Adopting download dates that manifests inside a folder already recorded.
//
// The bug this pins: setting up /Music as a single root, above a subfolder
// that had been seeded separately, minted a fresh date for all 467 tracks --
// on a tablet where every file's mtime was the copy's timestamp, so the real
// 2020-2025 download dates existed nowhere else. "Date downloaded is
// permanent" is the reason this app exists.
//
// Last modified: 2026-07-29--1300

import 'dart:convert';
import 'dart:io';

import 'package:fooplayer_core/src/library_ops.dart';
import 'package:fooplayer_core/src/manifest.dart';
import 'package:fooplayer_core/src/scanner.dart';
import 'package:test/test.dart';

ScannedTrack st(String path, String id) =>
    ScannedTrack(path, 100, DateTime.utc(2026, 1, 1), id);

void writeManifest(Directory dir, Manifest m) {
  dir.createSync(recursive: true);
  File('${dir.path}/$manifestFileName')
      .writeAsStringSync(jsonEncode(m.toJson()));
}

Manifest manifestOf(Map<String, TrackEntry> tracks) =>
    Manifest(schema: 1, tracks: tracks, playlists: []);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('known-entries'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('finds a manifest in a subfolder, with its date and duration', () {
    writeManifest(
      Directory('${tmp.path}/loose tracks'),
      manifestOf({
        'id1': TrackEntry(
          dateAdded: '2020-12-17T03:49:25.481662Z',
          paths: ['&ME - After Dark.mp3'],
          durationMs: 259134,
        ),
      }),
    );

    final known = knownEntriesWithin(tmp);
    expect(known.keys, ['id1']);
    expect(known['id1']!.dateAdded, '2020-12-17T03:49:25.481662Z');
    expect(known['id1']!.durationMs, 259134);
  });

  test('finds manifests nested several levels down, and more than one', () {
    writeManifest(
      Directory('${tmp.path}/a/deep/monthly'),
      manifestOf({
        'id1': TrackEntry(dateAdded: '2021-01-01T00:00:00.000Z', paths: ['x']),
      }),
    );
    writeManifest(
      Directory('${tmp.path}/b'),
      manifestOf({
        'id2': TrackEntry(dateAdded: '2022-02-02T00:00:00.000Z', paths: ['y']),
      }),
    );

    final known = knownEntriesWithin(tmp);
    expect(known.keys.toSet(), {'id1', 'id2'});
    expect(known['id1']!.dateAdded, '2021-01-01T00:00:00.000Z');
    expect(known['id2']!.dateAdded, '2022-02-02T00:00:00.000Z');
  });

  test('when two manifests disagree the earliest date wins', () {
    // The same track catalogued again by a later copy: owning it since 2020
    // is the fact, being re-catalogued in 2026 is not.
    writeManifest(
      Directory('${tmp.path}/original'),
      manifestOf({
        'id1': TrackEntry(dateAdded: '2020-05-05T00:00:00.000Z', paths: ['x']),
      }),
    );
    writeManifest(
      Directory('${tmp.path}/copy'),
      manifestOf({
        'id1': TrackEntry(
          dateAdded: '2026-07-29T00:00:00.000Z',
          paths: ['x'],
          durationMs: 12345,
        ),
      }),
    );

    final known = knownEntriesWithin(tmp);
    expect(known['id1']!.dateAdded, '2020-05-05T00:00:00.000Z');
    // ...but a duration the earlier one lacked is still worth having.
    expect(known['id1']!.durationMs, 12345);
  });

  test('a corrupt manifest is skipped, not fatal', () {
    Directory('${tmp.path}/bad').createSync();
    File('${tmp.path}/bad/$manifestFileName').writeAsStringSync('{not json');
    writeManifest(
      Directory('${tmp.path}/good'),
      manifestOf({
        'id1': TrackEntry(dateAdded: '2021-01-01T00:00:00.000Z', paths: ['x']),
      }),
    );

    final known = knownEntriesWithin(tmp);
    expect(known.keys, ['id1']);
  });

  test('a folder with no manifests anywhere yields nothing', () {
    Directory('${tmp.path}/music').createSync();
    File('${tmp.path}/music/a.mp3').writeAsStringSync('x');
    expect(knownEntriesWithin(tmp), isEmpty);
  });

  test('seeding a parent folder keeps the dates its children recorded', () {
    // The tablet, exactly: /Music seeded as one root, above a subfolder that
    // already had a manifest. Before the fix all 467 tracks came out dated
    // today.
    writeManifest(
      Directory('${tmp.path}/loose tracks - 2020 and later'),
      manifestOf({
        'id1': TrackEntry(
          dateAdded: '2020-12-17T03:49:25.481662Z',
          paths: ['&ME - After Dark.mp3'],
          durationMs: 259134,
        ),
      }),
    );

    final scan = [st('loose tracks - 2020 and later/&ME - After Dark.mp3', 'id1'), st('brand new.mp3', 'id2')];
    final m = Manifest.empty();
    final now = DateTime.utc(2026, 7, 29, 19, 39);
    applyDiff(m, diffAgainstManifest(m, scan), scan, () => now);
    // Both are "new" to an empty manifest, so both were stamped today.
    expect(m.tracks['id1']!.dateAdded, '2026-07-29T19:39:00.000Z');

    adoptKnownDates(m, knownEntriesWithin(tmp));

    expect(m.tracks['id1']!.dateAdded, '2020-12-17T03:49:25.481662Z');
    expect(m.tracks['id1']!.durationMs, 259134);
    // Paths belong to the manifest being written, not the one adopted from.
    expect(m.tracks['id1']!.paths, [
      'loose tracks - 2020 and later/&ME - After Dark.mp3',
    ]);
    // A track no manifest has ever seen genuinely is new today.
    expect(m.tracks['id2']!.dateAdded, '2026-07-29T19:39:00.000Z');
  });

  test('adoption is keyed by content ID, so a rename still keeps the date', () {
    writeManifest(
      Directory('${tmp.path}/sub'),
      manifestOf({
        'id1': TrackEntry(dateAdded: '2019-03-03T00:00:00.000Z', paths: ['old name.mp3']),
      }),
    );

    final scan = [st('sub/completely different name.mp3', 'id1')];
    final m = Manifest.empty();
    applyDiff(m, diffAgainstManifest(m, scan), scan, () => DateTime.utc(2026));
    adoptKnownDates(m, knownEntriesWithin(tmp));

    expect(m.tracks['id1']!.dateAdded, '2019-03-03T00:00:00.000Z');
    expect(m.tracks['id1']!.paths, ['sub/completely different name.mp3']);
  });

  test('adoption never invents an entry for a track that is not there', () {
    final m = Manifest.empty();
    adoptKnownDates(m, {
      'ghost': TrackEntry(dateAdded: '2020-01-01T00:00:00.000Z', paths: const []),
    });
    expect(m.tracks, isEmpty);
  });
}
