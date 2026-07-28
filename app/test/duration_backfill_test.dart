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
}) => File(
  '${root.path}/.library.json',
).writeAsString(jsonEncode({'schema': 1, 'tracks': tracks, 'playlists': []}));

Map<String, Object?> _trackJson(String path, String dateAdded) => {
  'paths': [path],
  'date_added': dateAdded,
};

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
  'rev': kMetaCacheRevision,
};

/// Loads a one-track library ('id1') whose cache entry has durationMs:null.
Future<LibraryModel> _loadNullDurationLibrary(
  Directory tmp,
  File cacheFile,
) async {
  final root = await _root(tmp, 'lib');
  await _writeManifest(
    root,
    tracks: {
      'id1': _trackJson(
        'loose tracks - 2020 and later/song.mp3',
        '2024-01-01T00:00:00Z',
      ),
    },
  );
  await cacheFile.writeAsString(jsonEncode({'id1': _nullDurationEntry()}));
  final model = LibraryModel();
  await model
      .load(libraryRoots: [root], cacheFile: cacheFile)
      .timeout(const Duration(seconds: 30));
  expect(
    model.allTracks.single.durationMs,
    isNull,
    reason: 'fixture: track must start with no duration',
  );
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
  setUp(
    () async =>
        tmp = await Directory.systemTemp.createTemp('duration_backfill'),
  );
  tearDown(() async => tmp.delete(recursive: true));

  group('LibraryModel.updateDuration', () {
    test('updates the in-memory track, notifies, and hands the pending '
        'batch to the cache writer on flush', () async {
      final model = await _loadNullDurationLibrary(
        tmp,
        File('${tmp.path}/meta_cache.json'),
      );
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
        {'id1': 370158},
      ]);

      // Nothing left pending: a second flush must not re-write.
      await model.flushPendingDurationSaves();
      expect(written.length, 1);
      model.dispose();
    });

    test('coalesces repeated updates for the same track into the latest '
        'value', () async {
      final model = await _loadNullDurationLibrary(
        tmp,
        File('${tmp.path}/meta_cache.json'),
      );
      final written = <Map<String, int>>[];
      model.durationCacheWriter = (pending) async => written.add(pending);

      model.updateDuration('id1', 370000);
      model.updateDuration('id1', 370158);
      await model.flushPendingDurationSaves();

      expect(written, [
        {'id1': 370158},
      ]);
      model.dispose();
    });

    test('no-ops (no track change, no notify, nothing pending) for an '
        'unknown contentId, a non-positive ms, or the value the track '
        'already has', () async {
      final model = await _loadNullDurationLibrary(
        tmp,
        File('${tmp.path}/meta_cache.json'),
      );
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
        'preserving its other tag fields, so it survives a reload', () async {
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

    test(
      'regression (adversarial review, MEDIUM): a track with no cache '
      'entry yet does not get a fabricated permanent one -- the update '
      'stays pending until a real (enriched) entry exists to merge into',
      () async {
        final cacheFile = File('${tmp.path}/meta_cache.json');
        final model = await _loadNullDurationLibrary(tmp, cacheFile);

        // Simulate "enrichment hasn't reached this file yet": whatever entry
        // _loadBody's own enrichment wrote for id1, wipe the cache file back
        // to knowing nothing about it -- allTracks (already loaded) is
        // unaffected, exactly matching the real race (a still-in-progress
        // scan's in-memory cache snapshot simply never touched this id).
        await cacheFile.writeAsString(jsonEncode(<String, Object?>{}));
        expect(
          MetaCache.load(cacheFile).entries['id1'],
          isNull,
          reason: 'fixture: id1 must be a genuine cache miss',
        );

        model.updateDuration('id1', 250000);
        expect(
          model.allTracks.single.durationMs,
          250000,
          reason: 'the in-memory track updates regardless of cache state',
        );
        await model.flushPendingDurationSaves(); // default writer: real file

        final afterFirstFlush = MetaCache.load(cacheFile);
        expect(
          afterFirstFlush.entries['id1'],
          isNull,
          reason:
              'a fabricated filename-derived entry would carry '
              'durationMs+trackNumber and so pass as already-enriched, '
              'permanently hiding id1 from real tag enrichment',
        );

        // Enrichment eventually reaches id1 and writes its real entry --
        // this particular format's parser still can't derive a duration
        // (durationMs stays null), exactly the case the backfill feature
        // exists for.
        await cacheFile.writeAsString(
          jsonEncode({
            'id1': {
              'title': 'Real Enriched Title',
              'artist': 'Real Enriched Artist',
              'album': 'Real Enriched Album',
              'genre': null,
              'durationMs': null,
              'trackNumber': 3,
              'rev': kMetaCacheRevision,
            },
          }),
        );

        // The update that couldn't merge earlier was kept pending, not
        // dropped -- retried (and this time succeeds) on the next flush.
        await model.flushPendingDurationSaves();
        final afterSecondFlush = MetaCache.load(cacheFile);
        final entry = afterSecondFlush.entries['id1']!;
        expect(entry.durationMs, 250000);
        expect(entry.title, 'Real Enriched Title');
        expect(entry.artist, 'Real Enriched Artist');
        expect(entry.trackNumber, 3);
        model.dispose();
      },
    );
  });

  group('LibraryModel enrichment cache-save merge (adversarial review, '
      'MEDIUM)', () {
    test("enrichment's own cache.save (Part B) does not clobber a duration "
        'backfill for an unrelated, already-cached track', () async {
      final cacheFile = File('${tmp.path}/meta_cache.json');
      final root = await _root(tmp, 'lib');
      await _writeManifest(
        root,
        tracks: {
          // Already a cache hit (durationMs:null) -- Part B's enrichment loop
          // never revisits it, only cache-miss entries.
          'known': _trackJson('known/song.mp3', '2024-01-01T00:00:00Z'),
          // A genuine cache miss, so Part B enrichment (and its periodic/
          // final cache.save) actually runs.
          'miss': _trackJson('miss/other.mp3', '2024-01-02T00:00:00Z'),
        },
      );
      await cacheFile.writeAsString(
        jsonEncode({'known': _nullDurationEntry()}),
      );

      final model = LibraryModel();
      await model
          .load(
            libraryRoots: [root],
            cacheFile: cacheFile,
            onProgress: (done, total) {
              // Fires mid-Part-B, while enrichment's own in-memory cache
              // snapshot still holds 'known' with durationMs:null (loaded
              // once at the top of _loadBody, never revisited for a
              // cache-hit track) -- exactly the moment a background play's
              // backfill lands in the real app.
              model.updateDuration('known', 555000);
            },
          )
          .timeout(const Duration(seconds: 30));

      expect(
        model.allTracks.singleWhere((t) => t.contentId == 'known').durationMs,
        555000,
      );

      final onDisk = MetaCache.load(cacheFile);
      expect(
        onDisk.entries['known']!.durationMs,
        555000,
        reason:
            "enrichment's own cache.save must not overwrite this "
            'with the stale null it loaded at start of load()',
      );
      expect(
        onDisk.entries['known']!.title,
        'Automatic (Frost Remix)',
        reason:
            'the merge must only touch durationMs, not the rest of '
            "the entry's already-enriched fields",
      );
      // Sanity: the actual cache-miss track was enriched too (nothing else
      // broken by the merge).
      expect(onDisk.entries['miss'], isNotNull);
      model.dispose();
    });
  });

  group('PlayerService duration observation', () {
    test('reports a nonzero duration for a current track that has no '
        'durationMs, mirroring it into `duration` and notifying', () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1')], 0);
      // Simulates what a real _openCurrent() records once player.open()
      // for id1 resolves -- see PlayerService._openedContentId's doc.
      ps.debugMarkOpened('id1');
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
      ps.debugMarkOpened('id1');
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));

      ps.handleDurationChange(Duration.zero);

      expect(ps.duration, Duration.zero);
      expect(observed, isEmpty);
    });

    test('does not report for a track whose durationMs is already known', () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1', durationMs: 231072)], 0);
      ps.debugMarkOpened('id1');
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
      ps2.debugMarkOpened('id1');
      // onObservedDuration left null -- must not throw.
      ps2.handleDurationChange(const Duration(minutes: 3));
      expect(ps2.duration, const Duration(minutes: 3));
    });

    test('does not report a duration event for a track that never finished '
        'opening (durationMs == null alone is not enough)', () {
      final ps = PlayerService();
      ps.queueController.setQueue([_track('id1')], 0);
      // player.open('id1') never resolved (e.g. still in flight) --
      // _openedContentId stays unset/stale, unlike `current`.
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));

      ps.handleDurationChange(const Duration(minutes: 3));

      expect(observed, isEmpty, reason: 'duration is not correlated to id1');
    });

    test('regression (adversarial review, HIGH): a stale duration event left '
        'over from a track already skipped past is dropped, not '
        'misattributed to whatever is current now', () {
      // Models rapid next/next/next (A -> B -> C): current has already
      // advanced to C, but B's open() never resolved (its duration event
      // is the "late" one arriving now) -- only A's open() ever finished.
      final ps = PlayerService();
      ps.queueController.setQueue([_track('a'), _track('b'), _track('c')], 0);
      ps.debugMarkOpened('a'); // A's open() resolved
      ps.queueController.advance(); // current -> B (synchronous, like skip)
      ps.queueController.advance(); // current -> C (second rapid skip)
      final observed = <(String, Duration)>[];
      ps.onObservedDuration = (id, d) => observed.add((id, d));

      // B's engine duration event arrives late, after current == C.
      ps.handleDurationChange(const Duration(minutes: 4));

      expect(
        observed,
        isEmpty,
        reason:
            'stale event for a track no longer opened must be dropped, '
            'not applied to the now-current track',
      );
      expect(ps.current!.contentId, 'c');
      expect(
        ps.current!.durationMs,
        isNull,
        reason: 'C must not have inherited a wrong duration',
      );

      // Once C's own open() genuinely resolves and its real duration
      // arrives, it's still correctly reported.
      ps.debugMarkOpened('c');
      ps.handleDurationChange(const Duration(minutes: 5));
      expect(observed, [('c', const Duration(minutes: 5))]);
    });
  });
}
