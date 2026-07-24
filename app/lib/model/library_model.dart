import 'dart:io';
import 'package:flutter/foundation.dart';
import '../metadata/meta_cache.dart';
import 'filtering.dart';
import 'manifest_io.dart';
import 'track.dart';

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
      allTracks = await fillMetadata(data.tracks, libraryRoot, cache,
          onProgress: (d, t) {
        status = 'reading tags $d/$t';
        if (d % 200 == 0 || d == t) notifyListeners();
        onProgress?.call(d, t);
      });
      await cache.save(cacheFile);
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
