import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../metadata/meta_cache.dart';
import 'filtering.dart';
import 'manifest_io.dart';
import 'track.dart';

/// Cache-misses are enriched off the UI/platform thread in chunks this
/// large; each chunk's synchronous tag-reading runs inside its own
/// [Isolate.run] call so no single batch blocks the UI for too long and
/// progress can be reported between batches.
const _enrichBatchSize = 200;

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
        // batches, each batch's synchronous file I/O running inside
        // Isolate.run so the UI/platform thread never blocks on it. Merge
        // results back in between batches so the list keeps updating.
        var done = 0;
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
          final results = await Isolate.run(() => readTagsBatch(records));
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
