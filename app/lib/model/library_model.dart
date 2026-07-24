import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../metadata/meta_cache.dart';
import '../metadata/tags.dart';
import 'filtering.dart';
import 'manifest_io.dart';
import 'track.dart';

/// Cache-misses are enriched off the UI/platform thread in chunks this
/// large; each chunk's synchronous tag-reading runs inside its own isolate
/// (see [_readBatchIsolate]) so no single batch blocks the UI for too long
/// and progress can be reported between batches.
const _enrichBatchSize = 200;

/// How long a whole [_enrichBatchSize]-file batch is allowed to run before
/// it's treated as stuck and retried one file at a time (see
/// [_readBatchIsolate] and [_readBatchResilient]).
///
/// Some real-world files make `audio_metadata_reader`'s MP3 parser scan the
/// *entire* remainder of the file one byte at a time looking for a frame
/// sync it will never find (its `_findFirstMp3Frame` has no upper bound).
/// On local disk that is fast; over the SMB-mounted library share each byte
/// crossing the parser's 16KB read buffer is a network round trip, so one
/// such file can take minutes. 90s is comfortably above every batch
/// observed to be merely slow (not pathological) while still bounding the
/// worst case.
const _defaultBatchTimeout = Duration(seconds: 90);

/// Per-file budget used once a batch has already been flagged as stuck (see
/// [_defaultBatchTimeout]). Generous enough for any individually slow file,
/// short enough that a genuinely pathological file is skipped quickly
/// instead of blocking the rest of its batch.
const _defaultFileTimeout = Duration(seconds: 20);

/// The merged tag cache is flushed to disk after every this-many enrichment
/// batches (and unconditionally once enrichment finishes), so progress
/// survives an app restart partway through a large first-run scan instead
/// of only being saved after every last file has been read.
const _saveEveryNBatches = 5;

class LibraryModel extends ChangeNotifier {
  List<Track> allTracks = [];
  List<ManifestPlaylist> playlists = [];
  String? genreFilter;
  String? artistFilter;
  String? albumFilter;
  String search = '';
  String? activePlaylist;
  String status = 'idle';

  Future<void> load({
    required Directory libraryRoot,
    required File cacheFile,
    void Function(int done, int total)? onProgress,
    Duration batchTimeout = _defaultBatchTimeout,
    Duration fileTimeout = _defaultFileTimeout,
  }) async {
    try {
      status = 'loading manifest';
      notifyListeners();
      final manifest = File('${libraryRoot.path}/.library.json');
      if (!manifest.existsSync()) {
        status = 'no .library.json in ${libraryRoot.path}';
        notifyListeners();
        return;
      }
      final data = loadManifestFile(manifest);
      playlists = data.playlists;
      final cache = MetaCache.load(cacheFile);

      // Part A -- instant feed: apply any cached tags synchronously (cheap
      // map lookups) so the date-sorted view renders within ~2s of launch.
      // Tracks with no cached tags keep the manifest's filename-derived
      // title for now and get enriched in the background below.
      final tracks = List<Track>.of(data.tracks);
      final missing = <int>[]; // indices into `tracks` needing enrichment
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        final tags = cache.entries[t.contentId];
        if (tags == null) {
          missing.add(i);
          continue;
        }
        tracks[i] = t.copyWith(
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          genre: tags.genre,
        );
      }
      allTracks = tracks;
      status = missing.isEmpty ? 'ready' : 'ready (reading tags in background)';
      notifyListeners();

      if (missing.isNotEmpty) {
        // Part B -- off-thread enrichment: read tags for cache misses in
        // batches, each batch's synchronous file I/O running inside its own
        // isolate so the UI/platform thread never blocks on it. Merge
        // results back in between batches so the list keeps updating.
        var done = 0;
        var batchesSinceSave = 0;
        for (var start = 0; start < missing.length; start += _enrichBatchSize) {
          final end = (start + _enrichBatchSize < missing.length)
              ? start + _enrichBatchSize
              : missing.length;
          final batch = missing.sublist(start, end);
          final records = [
            for (final i in batch)
              (
                tracks[i].contentId,
                p.join(libraryRoot.path, tracks[i].relPath),
                tracks[i].relPath,
              )
          ];

          Map<String, TrackTags> results;
          try {
            results =
                await _readBatchIsolate(records, timeout: batchTimeout);
          } on TimeoutException {
            // The whole-batch read didn't finish in time, which means at
            // least one file in it is pathologically slow (see
            // _defaultBatchTimeout). Fall back to resolving this batch one
            // file at a time -- each with its own bounded budget -- so the
            // other ~199 good files aren't held hostage by the bad one(s).
            results = await _readBatchResilient(records, timeout: fileTimeout);
          }

          for (final i in batch) {
            final t = tracks[i];
            final tags = results[t.contentId];
            if (tags == null) continue;
            cache.entries[t.contentId] = tags;
            tracks[i] = t.copyWith(
              title: tags.title,
              artist: tags.artist,
              album: tags.album,
              genre: tags.genre,
            );
          }
          done += batch.length;
          allTracks = List<Track>.of(tracks);
          status = 'reading tags $done/${missing.length}';
          onProgress?.call(done, missing.length);
          notifyListeners();

          if (++batchesSinceSave >= _saveEveryNBatches) {
            await cache.save(cacheFile);
            batchesSinceSave = 0;
          }
        }
        await cache.save(cacheFile);
      }
      status = 'ready';
    } catch (e) {
      status = 'error: $e';
    }
    notifyListeners();
  }

  List<Track> get _searched => applyFilters(allTracks, search: search);

  List<String> get genres => distinctValues(_searched, (t) => t.genre);
  List<String> get artists => distinctValues(
      applyFilters(allTracks, genre: genreFilter, search: search), (t) => t.artist);
  List<String> get albums => distinctValues(
      applyFilters(allTracks,
          genre: genreFilter, artist: artistFilter, search: search),
      (t) => t.album);

  List<Track> get visibleTracks {
    if (activePlaylist != null) {
      final matches = playlists.where((p) => p.name == activePlaylist);
      if (matches.isEmpty) return [];
      final pl = matches.first;
      final byId = {for (final t in allTracks) t.contentId: t};
      return [for (final id in pl.trackIds) if (byId[id] != null) byId[id]!];
    }
    return sortByDateAddedDesc(applyFilters(allTracks,
        genre: genreFilter,
        artist: artistFilter,
        album: albumFilter,
        search: search));
  }

  void setGenre(String? g) {
    genreFilter = g;
    artistFilter = null;
    albumFilter = null;
    notifyListeners();
  }

  void setArtist(String? a) {
    artistFilter = a;
    albumFilter = null;
    notifyListeners();
  }

  void setAlbum(String? a) {
    albumFilter = a;
    notifyListeners();
  }

  void setSearch(String s) {
    search = s;
    notifyListeners();
  }

  void setPlaylist(String? name) {
    activePlaylist = name;
    genreFilter = artistFilter = albumFilter = null;
    search = '';
    notifyListeners();
  }
}

/// Resolves [records] one at a time, each bounded by [timeout], for use
/// once a whole-batch read (see [_readBatchIsolate]) has already timed out.
///
/// A record whose own read doesn't finish in time -- or fails for any other
/// reason -- keeps its filename-derived fallback tags (the same fallback
/// [readTags] itself uses for unparseable/missing files) instead of taking
/// the rest of the batch down with it. This is what makes enrichment
/// survive a single pathological file: it's skipped, counted (the caller's
/// `done` still advances for every record in the batch), and enrichment
/// moves on.
Future<Map<String, TrackTags>> _readBatchResilient(
  List<(String, String, String)> records, {
  required Duration timeout,
}) async {
  final out = <String, TrackTags>{};
  for (final record in records) {
    final (contentId, _, relPath) = record;
    try {
      final single = await _readBatchIsolate([record], timeout: timeout);
      out[contentId] = single[contentId] ?? parseFromFilename(relPath);
    } catch (_) {
      out[contentId] = parseFromFilename(relPath);
    }
  }
  return out;
}

/// Runs [readTagsBatch] for [records] inside its own isolate, same as
/// `Isolate.run` -- except that if it hasn't produced a result within
/// [timeout], that isolate is killed outright and this throws
/// [TimeoutException], instead of leaving a runaway synchronous read (see
/// [_defaultBatchTimeout]) to keep burning CPU and network I/O in the
/// background indefinitely.
///
/// Any error [readTagsBatch] itself throws propagates normally (it is not
/// swallowed here), so a genuine failure still surfaces via the caller's
/// own error handling.
Future<Map<String, TrackTags>> _readBatchIsolate(
  List<(String, String, String)> records, {
  required Duration timeout,
}) async {
  final resultPort = RawReceivePort();
  final completer = Completer<Map<String, TrackTags>>();
  resultPort.handler = (Object? response) {
    resultPort.close();
    if (response == null) {
      completer.completeError(
          StateError('tag-reading isolate exited without a result'),
          StackTrace.current);
      return;
    }
    final list = response as List<Object?>;
    if (list.length == 2) {
      final error = list[0];
      final stack = list[1];
      if (stack is StackTrace) {
        completer.completeError(error!, stack);
      } else {
        // Two strings from the isolate's own onError handler (an uncaught
        // async error) rather than from our entry point's try/catch below.
        completer.completeError(
            RemoteError(error.toString(), stack.toString()));
      }
    } else {
      completer.complete(list[0] as Map<String, TrackTags>);
    }
  };

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _readBatchIsolateEntry,
      (records, resultPort.sendPort),
      onError: resultPort.sendPort,
      onExit: resultPort.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    // Spawning itself failed (synchronously, or the returned Future
    // rejected) -- there's no isolate to kill, but resultPort must still
    // be closed or it leaks. Mirrors Isolate.run's own handling of this
    // case in dart:isolate.
    resultPort.close();
    rethrow;
  }

  try {
    return await completer.future.timeout(timeout);
  } finally {
    isolate.kill(priority: Isolate.immediate);
    resultPort.close();
  }
}

void _readBatchIsolateEntry(
    (List<(String, String, String)>, SendPort) args) async {
  final (records, resultPort) = args;
  Map<String, TrackTags> result;
  try {
    result = await readTagsBatch(records);
  } catch (e, s) {
    Isolate.exit(resultPort, [e, s]);
  }
  Isolate.exit(resultPort, [result]);
}
