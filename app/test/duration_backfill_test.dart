// On-play duration backfill (see LibraryModel.updateDuration and
// PlayerService.onObservedDuration): tracks whose cache entry was persisted
// with durationMs:null -- the tag parser couldn't derive a duration at scan
// time (e.g. an APEv2-tagged MP3 routed to ApeParser, which has no MP3
// stream-duration logic) -- permanently gain their duration the first time
// they're played, because PlayerService reports the engine-observed
// duration and LibraryModel folds it into the in-memory track and the
// on-disk tag cache.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';

Future<Directory> _root(Directory tmp, String name) =>
    Directory('${tmp.path}/$name').create();

Future<void> _writeManifest(
  Directory root, {
  required Map<String, Object?> tracks,
}) =>
    File('${root.path}/.library.json').writeAsString(jsonEncode({
      'schema': 1,
      'tracks': tracks,
      'playlists': [],
    }));

Map<String, Object?> _trackJson(String path, String dateAdded) =>
    {'paths': [path], 'date_added': dateAdded};

/// A cache entry shaped exactly like the real defect: fully enriched tags
/// but durationMs persisted as null (key present, value null -- which
/// MetaCache.load keeps, unlike a missing key).
Map<String, Object?> _nullDurationEntry() => {
      'title': 'Automatic (Frost Remix)',
      'artist': 'ZHU & AlunaGeorge',
      'album': 'loose tracks - 2020 and later',
      'genre': null,
      'durationMs': null,
      'trackNumber': null,
    };

/// Loads a one-track library ('id1') whose cache entry has durationMs:null.
Future<LibraryModel> _loadNullDurationLibrary(
    Directory tmp, File cacheFile) async {
  final root = await _root(tmp, 'lib');
  await _writeManifest(root, tracks: {
    'id1': _trackJson('loose tracks - 2020 and later/song.mp3',
        '2024-01-01T00:00:00Z'),
  });
  await cacheFile.writeAsString(jsonEncode({'id1': _nullDurationEntry()}));
  final model = LibraryModel();
  await model
      .load(libraryRoots: [root], cacheFile: cacheFile)
      .timeout(const Duration(seconds: 30));
  expect(model.allTracks.single.durationMs, isNull,
      reason: 'fixture: track must start with no duration');
  return model;
}

Track _track(String id, {int? durationMs}) => Track(
      contentId: id,
      relPath: 'x/$id.mp3',
      dateAdded: DateTime.utc(2024),
      title: id,
      durationMs: durationMs,
    );

void main() {
  late Directory tmp;
  setUp(() async =>
      tmp = await Directory.systemTemp.createTemp('duration_backfill'));
  tearDown(() async => tmp.delete(recursive: true));

  group('LibraryModel.updateDuration', () {
    test('updates the in-memory track, notifies, and hands the pending '
        'batch to the cache writer on flush', () async {
      final model = await _loadNullDurationLibrary(
          tmp, File('${tmp.path}/meta_cache.json'));
      final written = <Map<String, int>>[];
      model.durationCacheWriter = (pending) async => written.add(pending);
      var notified = 0;
      model.addListener(() => notified++);

      model.updateDuration('id1', 370158);

      expect(model.allTracks.single.durationMs, 370158);
      expect(notified, 1);
      // Other fields untouched by the copyWith.
      expect(model.allTracks.single.title, 'Automatic (Frost Remix)');

      expect(written, isEmpty, reason: 'save is debounced, not immediate');
      await model.flushPendingDurationSaves();
      expect(written, [
        {'id1': 370158}
      ]);

      // Nothing left pending: a second flush must not re-write.
      await model.flushPendingDurationSaves();
      expect(written.length, 1);
      model.dispose();
    });

    test('coalesces repeated updates for the same track into the latest '
        'value', () async {
      final model = await _loadNullDurationLibrary(
          tmp, File('${tmp.path}/meta_cache.json'));
      final written = <Map<String, int>>[];
      model.durationCacheWriter = (pending) async => written.add(pending);

      model.updateDuration('id1', 370000);
      model.updateDuration('id1', 370158);
      await model.flushPendingDurationSaves();

      expect(written, [
        {'id1': 370158}
      ]);
      model.dispose();
    });

    test('no-ops (no track change, no notify, nothing pending) for an '
        'unknown contentId, a non-positive ms, or the value the track '
        'already has', () async {
      final model = await _loadNullDurationLibrary(
          tmp, File('${tmp.path}/meta_cache.json'));
      final written = <Map<String, int>>[];
      model.durationCacheWriter = (pending) async => written.add(pending);

      model.updateDuration('id1', 370158); // establish a value
      await model.flushPendingDurationSaves();
      written.clear();

      var notified = 0;
      model.addListener(() => notified++);
      model.updateDuration('nope', 1000); // unknown id
      model.updateDuration('id1', 0); // non-positive
      model.updateDuration('id1', -5); // non-positive
      model.updateDuration('id1', 370158); // already-known value
      await model.flushPendingDurationSaves();

      expect(notified, 0);
      expect(written, isEmpty);
      model.dispose();
    });

    test('default writer merges the duration into the on-disk cache entry, '
        'preserving its other tag fields, so it survives a reload',
        () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final model = await _loadNullDurationLibrary(tmp, cacheFile);

      model.updateDuration('id1', 370158);
      await model.flushPendingDurationSaves(); // default writer: real file

      final reloaded = MetaCache.load(cacheFile);
      final entry = reloaded.entries['id1']!;
      expect(entry.durationMs, 370158);
      expect(entry.title, 'Automatic (Frost Remix)');
      expect(entry.artist, 'ZHU & AlunaGeorge');
      expect(entry.album, 'loose tracks - 2020 and later');
      model.dispose();
    });
  });

  group('PlayerService duration observation', () {
    test('reports a nonzero duration for a current track that has no '
        'durationMs, mirroring it into `duration` and notifying', () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1')], 0);
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));
      var notified = 0;
      ps.addListener(() => notified++);

      ps.handleDurationChange(const Duration(minutes: 6, seconds: 10));

      expect(ps.duration, const Duration(minutes: 6, seconds: 10));
      expect(notified, 1);
      expect(observed, [('id1', const Duration(minutes: 6, seconds: 10))]);
    });

    test('does not report Duration.zero (engine reset/no media), but still '
        'mirrors it', () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1')], 0);
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));

      ps.handleDurationChange(Duration.zero);

      expect(ps.duration, Duration.zero);
      expect(observed, isEmpty);
    });

    test('does not report for a track whose durationMs is already known',
        () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1', durationMs: 231072)], 0);
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));

      ps.handleDurationChange(const Duration(minutes: 3));

      expect(observed, isEmpty);
    });

    test('handles no current track (empty queue) without reporting or '
        'crashing, and a null callback without crashing', () {
      final ps = PlayerService();
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));
      ps.handleDurationChange(const Duration(minutes: 3));
      expect(observed, isEmpty);

      final ps2 = PlayerService();
      ps2.queueController.setQueue([_track('id1')], 0);
      // onObservedDuration left null -- must not throw.
      ps2.handleDurationChange(const Duration(minutes: 3));
      expect(ps2.duration, const Duration(minutes: 3));
    });
  });
}
