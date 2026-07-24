# Windows Desktop Player App (Plan 2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable Flutter Windows desktop player that reads the seeded `.library.json`, shows the date-downloaded feed with genre/artist/album cascade filters, search, and playlists, and plays music with a foobar-style bottom now-playing bar.

**Architecture:** One Flutter project in `app/` (Windows target only in this plan; Android added in Plan 2b). Pure-Dart core (manifest loading, tag parsing, filtering, queue logic) is unit-tested; Flutter widgets are a thin layer over two `ChangeNotifier`s (`LibraryModel`, `PlayerService`). Musical metadata is read from file tags with filename-parse fallback and cached in a disposable JSON cache (spec's "disposable index" — JSON instead of SQLite is an accepted YAGNI deviation; delete-and-rebuild semantics preserved). The app is a read-only consumer of the manifest — `foolib` (Plan 1) remains the sole writer.

**Tech Stack:** Flutter stable (Windows desktop), `media_kit` + `media_kit_libs_windows_audio` (libmpv playback), `audio_metadata_reader` (pure-Dart tag reading), `path`.

## Global Constraints

- Repo root: `L:\PROJECTS\foobar`, branch for this plan: `windows-app`. Flutter project lives in `app/`, project name `fooplayer_app`.
- Flutter SDK: install to `C:\dev\flutter` (shallow clone of stable). Bash PATH prefix for every shell:
  `export PATH="/c/dev/flutter/bin:/c/Users/mklod/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"`
- Only app dependencies allowed: `media_kit`, `media_kit_libs_windows_audio`, `audio_metadata_reader`, `path` (+ Flutter defaults `flutter_test`, `flutter_lints`).
- Manifest: `.library.json` (schema 1) in the library root; fields `schema`, `tracks` (`date_added`, `paths`), `playlists` (`name`, `track_ids`). The app never writes it.
- Default library root: `L:\music (original structure)`; overridable via `%APPDATA%\fooplayer\config.json` `{"libraryRoot": "..."}` (created with the default on first run). Metadata cache: `%APPDATA%\fooplayer\meta_cache.json`.
- Track list default sort: `date_added` descending. Filter cascade: Genre → Artist → Album, each narrowing the next; search matches title/artist/album case-insensitively. Bottom bar: album art (placeholder if none), title/artist/album, seekbar, prev/play-pause/next, shuffle toggle, volume slider.
- Dark theme, fixed layout (no theming system).
- Never run mutating commands against `L:\music (original structure)` or `L:\APPS`. Widget tests must not initialize media_kit natives (PlayerService creates its `Player` lazily).
- TDD for all pure-Dart logic; widget tests for UI structure; playback verified manually. Run tests from `app/` with `flutter test`.
- External-package note: if `audio_metadata_reader` or `media_kit` field/method names differ from this plan's code, adapt inside `tags.dart` / `player_service.dart` only (keep this plan's public signatures), and record the deviation in your report. This is the only sanctioned deviation.

## File Structure

```
app/
├── pubspec.yaml                    # via flutter create + flutter pub add
├── lib/
│   ├── main.dart                   # entry: config load, MediaKit init, HomeScreen
│   ├── model/
│   │   ├── track.dart              # Track value type
│   │   ├── manifest_io.dart        # .library.json parsing (read-only)
│   │   ├── filtering.dart          # pure filter/search/sort/distinct functions
│   │   └── library_model.dart      # ChangeNotifier: load + filter state
│   ├── metadata/
│   │   ├── tags.dart               # readTags (package) + parseFromFilename fallback + readArt
│   │   └── meta_cache.dart         # JSON cache keyed by contentId
│   ├── player/
│   │   ├── queue_controller.dart   # pure queue/shuffle logic
│   │   └── player_service.dart     # media_kit wrapper (lazy Player)
│   └── ui/
│       ├── home_screen.dart        # layout shell: sidebar | filters + list, bottom bar
│       ├── filter_panel.dart       # one selectable list (used 3×)
│       ├── track_list.dart         # the feed
│       └── now_playing_bar.dart    # bottom bar
├── test/
│   ├── manifest_io_test.dart
│   ├── tags_test.dart
│   ├── meta_cache_test.dart
│   ├── filtering_test.dart
│   ├── queue_controller_test.dart
│   └── ui_shell_test.dart
└── windows/                        # flutter create scaffolding (committed as-is)
```

---

### Task 0: Flutter SDK + app scaffold

**Files:**
- Create: `app/` (entire `flutter create` scaffold, Windows platform only)

**Interfaces:**
- Consumes: nothing.
- Produces: a Flutter project where `flutter test` and `flutter build windows` work; all later tasks build inside `app/`.

- [ ] **Step 1: Create the branch**

```bash
cd "L:/PROJECTS/foobar" && git checkout -b windows-app
```

- [ ] **Step 2: Install the Flutter SDK** (skip clone if `C:\dev\flutter\bin\flutter.bat` already exists)

```bash
git clone --depth 1 -b stable https://github.com/flutter/flutter.git /c/dev/flutter
export PATH="/c/dev/flutter/bin:$PATH"
flutter --version
flutter config --no-analytics --enable-windows-desktop
flutter doctor
```

Expected: a Flutter 3.x stable version line. `flutter doctor` must show a check for "Visual Studio - develop Windows apps" (VS Build Tools 2022 with C++ is preinstalled on this machine). Android/Chrome sections failing is fine. If the Visual Studio check FAILS, stop and report BLOCKED with the doctor output.

- [ ] **Step 3: Scaffold the app**

```bash
cd "L:/PROJECTS/foobar"
flutter create --platforms=windows --project-name fooplayer_app --org dev.mklod app
cd app && flutter pub add media_kit media_kit_libs_windows_audio audio_metadata_reader path
```

Expected: scaffold created; deps resolve without error.

- [ ] **Step 4: Verify the scaffold builds and tests run**

```bash
cd "L:/PROJECTS/foobar/app" && flutter test && flutter build windows --debug 2>&1 | tail -3
```

Expected: the template widget test passes; the build completes producing `build/windows/x64/runner/Debug/fooplayer_app.exe`. If the build fails with network-drive/symlink errors (the repo is on a mapped share), report BLOCKED with the exact error — do not improvise relocation.

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app && git commit -m "chore: scaffold fooplayer_app Flutter project (Windows)"
```

---

### Task 1: Track model and manifest loading

**Files:**
- Create: `app/lib/model/track.dart`
- Create: `app/lib/model/manifest_io.dart`
- Test: `app/test/manifest_io_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class Track { final String contentId; final String relPath; final DateTime dateAdded; final String title; final String artist; final String album; final String genre; Track copyWith({String? title, String? artist, String? album, String? genre}); }` — `title` defaults to the filename without extension; `artist`/`album`/`genre` default to `''` until metadata fills them.
  - `class ManifestPlaylist { final String name; final List<String> trackIds; }`
  - `class ManifestData { final List<Track> tracks; final List<ManifestPlaylist> playlists; }`
  - `ManifestData loadManifestFile(File f)` — parses schema-1 `.library.json`; first path of each entry is the track's `relPath`; throws `FormatException` on wrong schema.

- [ ] **Step 1: Write the failing tests**

`app/test/manifest_io_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/manifest_io.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mani'));
  tearDown(() async => tmp.delete(recursive: true));

  File write(Map<String, dynamic> json) =>
      File('${tmp.path}/.library.json')..writeAsStringSync(jsonEncode(json));

  test('parses tracks and playlists from schema-1 manifest', () {
    final f = write({
      'schema': 1,
      'tracks': {
        'id1': {'date_added': '2023-04-04T01:48:38.356840Z', 'paths': ['albums/X/Artist - Song.mp3', 'copy/Artist - Song.mp3']},
        'id2': {'date_added': '2024-01-01T00:00:00.000Z', 'paths': ['loose/track2.mp3']},
      },
      'playlists': [{'name': 'mix', 'track_ids': ['id2', 'id1']}],
    });
    final data = loadManifestFile(f);
    expect(data.tracks, hasLength(2));
    final t1 = data.tracks.singleWhere((t) => t.contentId == 'id1');
    expect(t1.relPath, 'albums/X/Artist - Song.mp3'); // first path wins
    expect(t1.dateAdded, DateTime.utc(2023, 4, 4, 1, 48, 38, 356, 840));
    expect(t1.title, 'Artist - Song'); // filename sans extension until metadata fills it
    expect(t1.artist, '');
    expect(data.playlists.single.name, 'mix');
    expect(data.playlists.single.trackIds, ['id2', 'id1']);
  });

  test('rejects unknown schema', () {
    final f = write({'schema': 99, 'tracks': {}, 'playlists': []});
    expect(() => loadManifestFile(f), throwsA(isA<FormatException>()));
  });

  test('copyWith fills metadata without touching identity', () {
    final f = write({
      'schema': 1,
      'tracks': {'id1': {'date_added': '2024-01-01T00:00:00.000Z', 'paths': ['a.mp3']}},
      'playlists': [],
    });
    final t = loadManifestFile(f).tracks.single;
    final filled = t.copyWith(artist: 'Muse', title: 'New Born', album: 'Origin', genre: 'Rock');
    expect(filled.contentId, t.contentId);
    expect(filled.relPath, t.relPath);
    expect(filled.artist, 'Muse');
    expect(filled.genre, 'Rock');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `app/`): `flutter test test/manifest_io_test.dart`
Expected: FAIL — `manifest_io.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/model/track.dart`:

```dart
class Track {
  final String contentId;
  final String relPath; // forward slashes, relative to library root
  final DateTime dateAdded;
  final String title;
  final String artist;
  final String album;
  final String genre;

  const Track({
    required this.contentId,
    required this.relPath,
    required this.dateAdded,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
  });

  Track copyWith({String? title, String? artist, String? album, String? genre}) =>
      Track(
        contentId: contentId,
        relPath: relPath,
        dateAdded: dateAdded,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        genre: genre ?? this.genre,
      );
}
```

`app/lib/model/manifest_io.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'track.dart';

class ManifestPlaylist {
  final String name;
  final List<String> trackIds;
  const ManifestPlaylist({required this.name, required this.trackIds});
}

class ManifestData {
  final List<Track> tracks;
  final List<ManifestPlaylist> playlists;
  const ManifestData({required this.tracks, required this.playlists});
}

ManifestData loadManifestFile(File f) {
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final schema = j['schema'] as int;
  if (schema != 1) throw FormatException('unsupported manifest schema: $schema');
  final tracks = <Track>[];
  (j['tracks'] as Map<String, dynamic>).forEach((id, v) {
    final entry = v as Map<String, dynamic>;
    final paths = (entry['paths'] as List).cast<String>();
    tracks.add(Track(
      contentId: id,
      relPath: paths.first,
      dateAdded: DateTime.parse(entry['date_added'] as String).toUtc(),
      title: p.basenameWithoutExtension(paths.first),
    ));
  });
  final playlists = (j['playlists'] as List)
      .map((e) => ManifestPlaylist(
            name: (e as Map<String, dynamic>)['name'] as String,
            trackIds: (e['track_ids'] as List).cast<String>(),
          ))
      .toList();
  return ManifestData(tracks: tracks, playlists: playlists);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `app/`): `flutter test test/manifest_io_test.dart`
Expected: `All tests passed!` (3 tests)

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/model app/test/manifest_io_test.dart && git commit -m "feat: Track model and read-only manifest loading"
```

---

### Task 2: Tag reading with filename fallback

**Files:**
- Create: `app/lib/metadata/tags.dart`
- Test: `app/test/tags_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class TrackTags { final String? title; final String? artist; final String? album; final String? genre; }`
  - `TrackTags parseFromFilename(String relPath)` — pure: basename `"Artist - Title.mp3"` → artist+title (split on the FIRST `" - "`); no separator → title only; album = parent directory name (or null at root).
  - `Future<TrackTags> readTags(File audioFile)` — tries `audio_metadata_reader`; on ANY exception or all-empty result falls back to `parseFromFilename`.
  - `Future<List<int>?> readArt(File audioFile)` — first embedded picture's bytes, or null (on any error, null).

- [ ] **Step 1: Write the failing tests**

`app/test/tags_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/tags.dart';

void main() {
  group('parseFromFilename', () {
    test('artist - title with album from parent dir', () {
      final t = parseFromFilename('albums/Arctic Monkeys - Humbug/Arctic Monkeys - Crying Lightning.mp3');
      expect(t.artist, 'Arctic Monkeys');
      expect(t.title, 'Crying Lightning');
      expect(t.album, 'Arctic Monkeys - Humbug');
    });

    test('splits on first separator only', () {
      final t = parseFromFilename('x/A - B - C.mp3');
      expect(t.artist, 'A');
      expect(t.title, 'B - C');
    });

    test('no separator: title only, no artist', () {
      final t = parseFromFilename('track01.mp3');
      expect(t.artist, isNull);
      expect(t.title, 'track01');
      expect(t.album, isNull);
    });
  });

  test('readTags falls back to filename parse on unreadable file', () async {
    final tmp = await Directory.systemTemp.createTemp('tags');
    final f = File('${tmp.path}/Muse - New Born.mp3');
    await f.writeAsBytes(List.filled(64, 0x00)); // not a valid mp3
    final t = await readTags(f);
    expect(t.artist, 'Muse');
    expect(t.title, 'New Born');
    await tmp.delete(recursive: true);
  });

  test('readArt returns null on unreadable file', () async {
    final tmp = await Directory.systemTemp.createTemp('art');
    final f = File('${tmp.path}/x.mp3');
    await f.writeAsBytes(List.filled(16, 0x01));
    expect(await readArt(f), isNull);
    await tmp.delete(recursive: true);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `app/`): `flutter test test/tags_test.dart`
Expected: FAIL — `tags.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/metadata/tags.dart`:

```dart
import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:path/path.dart' as p;

class TrackTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  const TrackTags({this.title, this.artist, this.album, this.genre});

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (artist == null || artist!.isEmpty) &&
      (album == null || album!.isEmpty);

  Map<String, dynamic> toJson() =>
      {'title': title, 'artist': artist, 'album': album, 'genre': genre};
  factory TrackTags.fromJson(Map<String, dynamic> j) => TrackTags(
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        genre: j['genre'] as String?,
      );
}

TrackTags parseFromFilename(String relPath) {
  final base = p.basenameWithoutExtension(relPath);
  final dir = p.dirname(relPath);
  final album = (dir == '.' || dir.isEmpty) ? null : p.basename(dir);
  final sep = base.indexOf(' - ');
  if (sep < 0) return TrackTags(title: base, album: album);
  return TrackTags(
    artist: base.substring(0, sep).trim(),
    title: base.substring(sep + 3).trim(),
    album: album,
  );
}

String? _blankAsNull(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

Future<TrackTags> readTags(File audioFile) async {
  try {
    final meta = amr.readMetadata(audioFile, getImage: false);
    final fromTags = TrackTags(
      title: _blankAsNull(meta.title),
      artist: _blankAsNull(meta.artist),
      album: _blankAsNull(meta.album),
      genre: _blankAsNull(meta.genres.isEmpty ? null : meta.genres.first),
    );
    if (fromTags.isEmpty) return parseFromFilename(audioFile.path);
    // Fill gaps (e.g. tagged title but no artist) from the filename.
    final fb = parseFromFilename(audioFile.path);
    return TrackTags(
      title: fromTags.title ?? fb.title,
      artist: fromTags.artist ?? fb.artist,
      album: fromTags.album ?? fb.album,
      genre: fromTags.genre,
    );
  } catch (_) {
    return parseFromFilename(audioFile.path);
  }
}

Future<List<int>?> readArt(File audioFile) async {
  try {
    final meta = amr.readMetadata(audioFile, getImage: true);
    if (meta.pictures.isEmpty) return null;
    return meta.pictures.first.bytes;
  } catch (_) {
    return null;
  }
}
```

(If `audio_metadata_reader`'s API differs — e.g. field names, sync vs async — adapt inside this file only, keep these signatures, note it in your report.)

- [ ] **Step 4: Run tests to verify they pass**

Run (from `app/`): `flutter test test/tags_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/metadata/tags.dart app/test/tags_test.dart && git commit -m "feat: tag reading with filename-parse fallback"
```

---

### Task 3: Metadata cache

**Files:**
- Create: `app/lib/metadata/meta_cache.dart`
- Test: `app/test/meta_cache_test.dart`

**Interfaces:**
- Consumes: `TrackTags` (Task 2), `Track` (Task 1).
- Produces:
  - `class MetaCache { final Map<String, TrackTags> entries; MetaCache.load(File f); Future<void> save(File f); }` — load returns empty on missing/corrupt file (disposable cache).
  - `Future<List<Track>> fillMetadata(List<Track> tracks, Directory libraryRoot, MetaCache cache, {void Function(int done, int total)? onProgress})` — for each track: cache hit by `contentId` → apply; miss → `readTags` on the file, store in cache, apply. Missing files keep filename-derived fields. Caller saves the cache afterwards.

- [ ] **Step 1: Write the failing tests**

`app/test/meta_cache_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/metadata/meta_cache.dart';
import 'package:fooplayer_app/metadata/tags.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, String relPath) => Track(
    contentId: id, relPath: relPath, dateAdded: DateTime.utc(2024), title: 'x');

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mc'));
  tearDown(() async => tmp.delete(recursive: true));

  test('round-trips entries; corrupt file loads empty', () async {
    final f = File('${tmp.path}/meta_cache.json');
    final c = MetaCache.load(f);
    expect(c.entries, isEmpty);
    c.entries['id1'] = const TrackTags(title: 'T', artist: 'A', album: 'B', genre: 'G');
    await c.save(f);
    expect(MetaCache.load(f).entries['id1']!.artist, 'A');
    f.writeAsStringSync('{nope');
    expect(MetaCache.load(f).entries, isEmpty);
  });

  test('fillMetadata uses cache without touching files, reads misses', () async {
    final root = await Directory('${tmp.path}/lib').create();
    // On-disk file for the cache-miss track (junk bytes → filename fallback).
    await File('${root.path}/Muse - New Born.mp3').writeAsBytes(List.filled(32, 0));
    final cache = MetaCache.load(File('${tmp.path}/meta_cache.json'));
    cache.entries['hit'] = const TrackTags(title: 'Cached', artist: 'CacheArtist');

    final tracks = [
      tr('hit', 'does/not/exist.mp3'), // cache hit: file never touched
      tr('miss', 'Muse - New Born.mp3'),
    ];
    final filled = await fillMetadata(tracks, root, cache);
    expect(filled[0].artist, 'CacheArtist');
    expect(filled[1].artist, 'Muse');
    expect(filled[1].title, 'New Born');
    expect(cache.entries.containsKey('miss'), isTrue); // stored for next time
  });

  test('missing file on cache miss keeps filename-derived fields', () async {
    final root = await Directory('${tmp.path}/lib2').create();
    final cache = MetaCache.load(File('${tmp.path}/mc2.json'));
    final filled = await fillMetadata([tr('gone', 'Artist X - Gone.mp3')], root, cache);
    expect(filled.single.artist, 'Artist X');
    expect(filled.single.title, 'Gone');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `app/`): `flutter test test/meta_cache_test.dart`
Expected: FAIL — `meta_cache.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/metadata/meta_cache.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'tags.dart';

class MetaCache {
  final Map<String, TrackTags> entries;
  MetaCache._(this.entries);

  factory MetaCache.load(File f) {
    if (!f.existsSync()) return MetaCache._({});
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map<String, dynamic>) return MetaCache._({});
      return MetaCache._(j.map(
          (k, v) => MapEntry(k, TrackTags.fromJson(v as Map<String, dynamic>))));
    } catch (_) {
      return MetaCache._({});
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    await f.writeAsString(
        jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson()))));
  }
}

Future<List<Track>> fillMetadata(
  List<Track> tracks,
  Directory libraryRoot,
  MetaCache cache, {
  void Function(int done, int total)? onProgress,
}) async {
  final out = <Track>[];
  var done = 0;
  for (final t in tracks) {
    TrackTags? tags = cache.entries[t.contentId];
    if (tags == null) {
      final file = File(p.join(libraryRoot.path, t.relPath));
      tags = file.existsSync()
          ? await readTags(file)
          : parseFromFilename(t.relPath);
      cache.entries[t.contentId] = tags;
    }
    out.add(t.copyWith(
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      genre: tags.genre,
    ));
    onProgress?.call(++done, tracks.length);
  }
  return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `app/`): `flutter test test/meta_cache_test.dart`
Expected: `All tests passed!` (3 tests)

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/metadata/meta_cache.dart app/test/meta_cache_test.dart && git commit -m "feat: disposable JSON metadata cache and fillMetadata"
```

---

### Task 4: Filtering, search, sort (pure) + LibraryModel

**Files:**
- Create: `app/lib/model/filtering.dart`
- Create: `app/lib/model/library_model.dart`
- Test: `app/test/filtering_test.dart`

**Interfaces:**
- Consumes: `Track` (Task 1), `ManifestData`/`loadManifestFile` (Task 1), `MetaCache`/`fillMetadata` (Task 3).
- Produces (filtering.dart, all pure):
  - `List<Track> sortByDateAddedDesc(List<Track> tracks)` (stable: ties keep input order; returns new list)
  - `List<Track> applyFilters(List<Track> all, {String? genre, String? artist, String? album, String search = ''})` — filters are ANDed; empty-string track fields only match a null filter; search is case-insensitive substring over title/artist/album.
  - `List<String> distinctValues(List<Track> tracks, String Function(Track) field)` — non-empty, case-insensitively deduped (first casing wins), sorted case-insensitively.
- Produces (library_model.dart):
  - `class LibraryModel extends ChangeNotifier` with: `List<Track> allTracks`, `List<ManifestPlaylist> playlists`, `String? genreFilter/artistFilter/albumFilter`, `String search`, `String? activePlaylist`; setters (`setGenre/setArtist/setAlbum/setSearch/setPlaylist`) that clear downstream filters (genre change clears artist+album; artist change clears album; playlist selection clears all filters+search) and `notifyListeners()`;
  - getters: `genres` (distinct over search-filtered tracks), `artists` (over genre+search-filtered), `albums` (over genre+artist+search-filtered), `visibleTracks` (playlist order when a playlist is active, otherwise filtered + date-desc);
  - `Future<void> load({required Directory libraryRoot, required File cacheFile, void Function(int, int)? onProgress})` — manifest → fillMetadata → cache save → notify. `String status` field: 'loading manifest' → 'reading tags i/N' → 'ready' (or an error message; a missing manifest must not crash the app).

- [ ] **Step 1: Write the failing tests**

`app/test/filtering_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/filtering.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, int day,
        {String title = 't', String artist = '', String album = '', String genre = ''}) =>
    Track(
        contentId: id,
        relPath: '$id.mp3',
        dateAdded: DateTime.utc(2024, 1, day),
        title: title,
        artist: artist,
        album: album,
        genre: genre);

void main() {
  final lib = [
    tr('a', 1, title: 'Alpha', artist: 'Muse', album: 'Origin', genre: 'Rock'),
    tr('b', 3, title: 'Beta', artist: 'Muse', album: 'Absolution', genre: 'Rock'),
    tr('c', 2, title: 'Gamma', artist: 'Feed Me', album: 'Calamari', genre: 'Electronic'),
    tr('d', 4, title: 'delta', artist: 'muse', album: 'Origin', genre: ''),
  ];

  test('sortByDateAddedDesc newest first, input not mutated', () {
    final sorted = sortByDateAddedDesc(lib);
    expect(sorted.map((t) => t.contentId).toList(), ['d', 'b', 'c', 'a']);
    expect(lib.first.contentId, 'a');
  });

  test('applyFilters ANDs genre/artist and search', () {
    expect(applyFilters(lib, genre: 'Rock').length, 2);
    expect(applyFilters(lib, genre: 'Rock', artist: 'Muse').length, 2);
    expect(applyFilters(lib, search: 'mus').length, 3); // case-insensitive artist match
    expect(applyFilters(lib, genre: 'Rock', search: 'beta').single.contentId, 'b');
  });

  test('null filter matches all; genre filter excludes empty-genre tracks', () {
    expect(applyFilters(lib).length, 4);
    expect(applyFilters(lib, genre: 'Rock').map((t) => t.contentId), isNot(contains('d')));
  });

  test('distinctValues dedupes case-insensitively, sorted', () {
    expect(distinctValues(lib, (t) => t.artist), ['Feed Me', 'Muse']);
    expect(distinctValues(lib, (t) => t.genre), ['Electronic', 'Rock']);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `app/`): `flutter test test/filtering_test.dart`
Expected: FAIL — `filtering.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/model/filtering.dart`:

```dart
import 'track.dart';

List<Track> sortByDateAddedDesc(List<Track> tracks) {
  final indexed = tracks.asMap().entries.toList();
  indexed.sort((a, b) {
    final byDate = b.value.dateAdded.compareTo(a.value.dateAdded);
    return byDate != 0 ? byDate : a.key.compareTo(b.key); // stable on ties
  });
  return indexed.map((e) => e.value).toList();
}

List<Track> applyFilters(
  List<Track> all, {
  String? genre,
  String? artist,
  String? album,
  String search = '',
}) {
  final q = search.trim().toLowerCase();
  bool eq(String field, String? filter) =>
      filter == null || field.toLowerCase() == filter.toLowerCase();
  return all.where((t) {
    if (!eq(t.genre, genre) || !eq(t.artist, artist) || !eq(t.album, album)) {
      return false;
    }
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q) ||
        t.album.toLowerCase().contains(q);
  }).toList();
}

List<String> distinctValues(List<Track> tracks, String Function(Track) field) {
  final seen = <String, String>{}; // lower → first casing
  for (final t in tracks) {
    final v = field(t);
    if (v.isEmpty) continue;
    seen.putIfAbsent(v.toLowerCase(), () => v);
  }
  final out = seen.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}
```

`app/lib/model/library_model.dart`:

```dart
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
```

- [ ] **Step 4: Run tests to verify they pass, full suite green**

Run (from `app/`): `flutter test`
Expected: all tests pass (the skipped placeholder test shows as skipped — remove it if the runner objects; the two surrounding tests carry the assertions).

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/model app/test/filtering_test.dart && git commit -m "feat: pure filtering/search/sort and LibraryModel state"
```

---

### Task 5: QueueController (pure) + PlayerService

**Files:**
- Create: `app/lib/player/queue_controller.dart`
- Create: `app/lib/player/player_service.dart`
- Test: `app/test/queue_controller_test.dart`

**Interfaces:**
- Consumes: `Track` (Task 1).
- Produces (queue_controller.dart, pure, no I/O):
  - `class QueueController { List<Track> get queue; int get index; bool shuffle; Track? get current; void setQueue(List<Track> tracks, int startIndex); Track? advance(); Track? previous(); void toggleShuffle(int Function(int) randomBelow); }`
  - Shuffle semantics: `toggleShuffle` ON reorders the remaining upcoming tracks randomly (current track stays current, played order preserved behind it) using the injected `randomBelow` (Fisher-Yates); OFF restores original order with current position preserved. `advance()` past the end returns null (stop). `previous()` at index 0 returns the current track (restart).
- Produces (player_service.dart):
  - `class PlayerService extends ChangeNotifier { QueueController queue; bool playing; Duration position; Duration? duration; Track? get current; Future<void> playFrom(List<Track> tracks, int index); Future<void> togglePlayPause(); Future<void> next(); Future<void> previous(); Future<void> seek(Duration d); Future<void> setVolume(double v01); double volume; void toggleShuffle(); Future<void> dispose(); }`
  - Constructor: `PlayerService({required Directory libraryRoot})` — the media_kit `Player` is created LAZILY on first `playFrom` (widget tests never construct natives). Absolute file path = `p.join(libraryRoot.path, track.relPath)`. On track completion, auto-advance; at queue end, stop. Position/duration/playing mirrored from `player.stream.position/duration/playing` into notifier fields.

- [ ] **Step 1: Write the failing tests**

`app/test/queue_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/queue_controller.dart';

Track tr(String id) => Track(
    contentId: id, relPath: '$id.mp3', dateAdded: DateTime.utc(2024), title: id);

void main() {
  final tracks = ['a', 'b', 'c', 'd'].map(tr).toList();

  test('setQueue and linear advance to end', () {
    final q = QueueController();
    q.setQueue(tracks, 1);
    expect(q.current!.contentId, 'b');
    expect(q.advance()!.contentId, 'c');
    expect(q.advance()!.contentId, 'd');
    expect(q.advance(), isNull); // end of queue
  });

  test('previous restarts at start of queue', () {
    final q = QueueController();
    q.setQueue(tracks, 0);
    expect(q.previous()!.contentId, 'a');
  });

  test('shuffle keeps current, reorders upcoming deterministically, off restores', () {
    final q = QueueController();
    q.setQueue(tracks, 1); // current b; upcoming c,d
    q.toggleShuffle((n) => n - 1); // deterministic: pick last each time → reversed
    expect(q.current!.contentId, 'b');
    final order = [q.advance()!.contentId, q.advance()!.contentId];
    expect(order, ['d', 'c']); // reversed by our fake randomBelow
    q.toggleShuffle((n) => 0); // OFF: restore original order, keep position
    expect(q.current!.contentId, 'c'); // last-played track remains current
    expect(q.advance()!.contentId, 'd'); // original order resumes
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `app/`): `flutter test test/queue_controller_test.dart`
Expected: FAIL — `queue_controller.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/player/queue_controller.dart`:

```dart
import '../model/track.dart';

class QueueController {
  List<Track> _original = [];
  List<Track> _queue = [];
  int _index = -1;
  bool shuffle = false;

  List<Track> get queue => List.unmodifiable(_queue);
  int get index => _index;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  void setQueue(List<Track> tracks, int startIndex) {
    _original = List.of(tracks);
    _queue = List.of(tracks);
    _index = startIndex;
    shuffle = false;
  }

  Track? advance() {
    if (_index + 1 >= _queue.length) return null;
    _index++;
    return current;
  }

  Track? previous() {
    if (_index > 0) _index--;
    return current;
  }

  /// randomBelow(n) returns an int in [0, n). Inject Random().nextInt for
  /// production; a deterministic function in tests.
  void toggleShuffle(int Function(int) randomBelow) {
    if (!shuffle) {
      shuffle = true;
      final upcoming = _queue.sublist(_index + 1);
      for (var i = upcoming.length - 1; i > 0; i--) {
        final j = randomBelow(i + 1);
        final tmp = upcoming[i];
        upcoming[i] = upcoming[j];
        upcoming[j] = tmp;
      }
      _queue = [..._queue.sublist(0, _index + 1), ...upcoming];
    } else {
      shuffle = false;
      final cur = current;
      _queue = List.of(_original);
      _index = cur == null
          ? -1
          : _queue.indexWhere((t) => t.contentId == cur.contentId);
    }
  }
}
```

`app/lib/player/player_service.dart`:

```dart
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import '../model/track.dart';
import 'queue_controller.dart';

class PlayerService extends ChangeNotifier {
  final Directory libraryRoot;
  final QueueController queueController = QueueController();
  final _rng = Random();

  Player? _player; // lazy: never constructed in widget tests
  bool playing = false;
  Duration position = Duration.zero;
  Duration? duration;
  double volume = 1.0;

  PlayerService({required this.libraryRoot});

  Track? get current => queueController.current;
  bool get shuffle => queueController.shuffle;

  Player _ensurePlayer() {
    if (_player != null) return _player!;
    final player = Player();
    player.stream.position.listen((d) {
      position = d;
      notifyListeners();
    });
    player.stream.duration.listen((d) {
      duration = d;
      notifyListeners();
    });
    player.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
    });
    player.stream.completed.listen((done) {
      if (done) next();
    });
    _player = player;
    return player;
  }

  Future<void> _openCurrent() async {
    final t = queueController.current;
    if (t == null) {
      await _player?.stop();
      return;
    }
    final path = p.join(libraryRoot.path, t.relPath);
    await _ensurePlayer().open(Media(path), play: true);
    notifyListeners();
  }

  Future<void> playFrom(List<Track> tracks, int index) async {
    queueController.setQueue(tracks, index);
    await _openCurrent();
  }

  Future<void> togglePlayPause() async {
    await _player?.playOrPause();
  }

  Future<void> next() async {
    if (queueController.advance() != null) {
      await _openCurrent();
    } else {
      await _player?.stop();
      playing = false;
      notifyListeners();
    }
  }

  Future<void> previous() async {
    queueController.previous();
    await _openCurrent();
  }

  Future<void> seek(Duration d) async => _player?.seek(d);

  Future<void> setVolume(double v01) async {
    volume = v01.clamp(0.0, 1.0);
    await _player?.setVolume(volume * 100);
    notifyListeners();
  }

  void toggleShuffle() {
    queueController.toggleShuffle(_rng.nextInt);
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _player?.dispose();
    super.dispose();
  }
}
```

(If media_kit's API differs — stream names, `open` signature — adapt inside this file only, keep signatures, note it in your report.)

- [ ] **Step 4: Run tests to verify they pass, full suite green**

Run (from `app/`): `flutter test`
Expected: all pass (PlayerService compiles; its behavior is manually verified in Task 8/9).

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/player app/test/queue_controller_test.dart && git commit -m "feat: pure queue/shuffle controller and lazy media_kit player service"
```

---

### Task 6: UI shell — sidebar, track list, status bar

**Files:**
- Create: `app/lib/ui/home_screen.dart`
- Create: `app/lib/ui/track_list.dart`
- Modify: `app/lib/main.dart` (replace template entirely)
- Delete: `app/test/widget_test.dart` (template test)
- Test: `app/test/ui_shell_test.dart`

**Interfaces:**
- Consumes: `LibraryModel` (Task 4), `PlayerService` (Task 5).
- Produces:
  - `class HomeScreen extends StatelessWidget { const HomeScreen({required LibraryModel library, required PlayerService player}); }` — layout: left sidebar (200 px: "Library" entry + playlist names; selection calls `setPlaylist`), main column (search field on top — filters row added in Task 7 — then `TrackListView`, then status text), bottom `NowPlayingBar` slot (added Task 8; until then a `SizedBox.shrink`).
  - `class TrackListView extends StatelessWidget { const TrackListView({required LibraryModel library, required PlayerService player}); }` — `ListView.builder` over `library.visibleTracks`; each row: title (bold), artist — album (dim), date `yyyy-MM-dd` right-aligned; single tap plays via `player.playFrom(library.visibleTracks, index)`.
  - `main.dart`: `main()` reads/creates `%APPDATA%\fooplayer\config.json`, constructs models, `MediaKit.ensureInitialized()`, `runApp(FooPlayerApp(...))` with `ThemeData.dark(useMaterial3: true)`, kicks off `library.load` after first frame.

- [ ] **Step 1: Write the failing widget test**

`app/test/ui_shell_test.dart`:

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/home_screen.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    Track(contentId: 'a', relPath: 'a.mp3', dateAdded: DateTime.utc(2026, 7, 1), title: 'Newest Song', artist: 'Muse', album: 'X', genre: 'Rock'),
    Track(contentId: 'b', relPath: 'b.mp3', dateAdded: DateTime.utc(2020, 1, 1), title: 'Oldest Song', artist: 'Feed Me', album: 'Y', genre: 'Electronic'),
  ];
  m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['b'])];
  m.status = 'ready';
  return m;
}

void main() {
  testWidgets('shows feed newest-first with sidebar playlists', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(library: lib, player: player)));
    expect(find.text('Newest Song'), findsOneWidget);
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('mix'), findsOneWidget); // playlist in sidebar
    // Feed order: Newest above Oldest.
    final newestY = tester.getTopLeft(find.text('Newest Song')).dy;
    final oldestY = tester.getTopLeft(find.text('Oldest Song')).dy;
    expect(newestY, lessThan(oldestY));
  });

  testWidgets('selecting a playlist shows its tracks only', (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(library: lib, player: player)));
    await tester.tap(find.text('mix'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest Song'), findsOneWidget);
    expect(find.text('Newest Song'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `app/`): `flutter test test/ui_shell_test.dart`
Expected: FAIL — `home_screen.dart` not found.

- [ ] **Step 3: Implement**

`app/lib/ui/track_list.dart`:

```dart
import 'package:flutter/material.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class TrackListView extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const TrackListView({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, player]),
      builder: (context, _) {
        final tracks = library.visibleTracks;
        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) {
            final t = tracks[i];
            final isCurrent = player.current?.contentId == t.contentId;
            return ListTile(
              dense: true,
              selected: isCurrent,
              title: Text(t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  [t.artist, t.album].where((s) => s.isNotEmpty).join(' — '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              trailing: Text(_fmtDate(t.dateAdded),
                  style: Theme.of(context).textTheme.bodySmall),
              onTap: () => player.playFrom(tracks, i),
            );
          },
        );
      },
    );
  }
}
```

`app/lib/ui/home_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../model/library_model.dart';
import '../player/player_service.dart';
import 'track_list.dart';

class HomeScreen extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const HomeScreen({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 200, child: _Sidebar(library: library)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: _SearchField(library: library),
                      ),
                      // Filter panels row inserted here in Task 7.
                      Expanded(
                          child: TrackListView(library: library, player: player)),
                      _StatusBar(library: library),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // NowPlayingBar inserted here in Task 8.
          const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final LibraryModel library;
  const _Sidebar({required this.library});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => ListView(
        children: [
          ListTile(
            title: const Text('Library'),
            selected: library.activePlaylist == null,
            onTap: () => library.setPlaylist(null),
          ),
          const Divider(),
          for (final pl in library.playlists)
            ListTile(
              title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: library.activePlaylist == pl.name,
              onTap: () => library.setPlaylist(pl.name),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final LibraryModel library;
  const _SearchField({required this.library});

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Search title, artist, album',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: library.setSearch,
    );
  }
}

class _StatusBar extends StatelessWidget {
  final LibraryModel library;
  const _StatusBar({required this.library});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '${library.status} — ${library.visibleTracks.length} tracks',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
```

`app/lib/main.dart` (replace the template file entirely):

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'model/library_model.dart';
import 'player/player_service.dart';
import 'ui/home_screen.dart';

const _defaultLibraryRoot = r'L:\music (original structure)';

Directory _appDataDir() =>
    Directory(p.join(Platform.environment['APPDATA']!, 'fooplayer'));

String _loadLibraryRoot() {
  final cfg = File(p.join(_appDataDir().path, 'config.json'));
  try {
    if (cfg.existsSync()) {
      final j = jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
      final root = j['libraryRoot'] as String?;
      if (root != null && root.isNotEmpty) return root;
    }
  } catch (_) {}
  cfg.parent.createSync(recursive: true);
  cfg.writeAsStringSync(jsonEncode({'libraryRoot': _defaultLibraryRoot}));
  return _defaultLibraryRoot;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final root = Directory(_loadLibraryRoot());
  final library = LibraryModel();
  final player = PlayerService(libraryRoot: root);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    library.load(
      libraryRoot: root,
      cacheFile: File(p.join(_appDataDir().path, 'meta_cache.json')),
    );
  });
  runApp(FooPlayerApp(library: library, player: player));
}

class FooPlayerApp extends StatelessWidget {
  final LibraryModel library;
  final PlayerService player;
  const FooPlayerApp({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fooplayer',
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(library: library, player: player),
    );
  }
}
```

Delete `app/test/widget_test.dart` (references the removed template counter app).

- [ ] **Step 4: Run tests, full suite green**

Run (from `app/`): `flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add -A app && git commit -m "feat: UI shell with sidebar, date feed, search, and status bar"
```

---

### Task 7: Filter panels (Genre / Artist / Album cascade)

**Files:**
- Create: `app/lib/ui/filter_panel.dart`
- Modify: `app/lib/ui/home_screen.dart` (insert the filters row at the marked comment)
- Test: append to `app/test/ui_shell_test.dart`

**Interfaces:**
- Consumes: `LibraryModel` getters/setters (Task 4).
- Produces: `class FilterPanel extends StatelessWidget { const FilterPanel({required String title, required List<String> values, required String? selected, required ValueChanged<String?> onSelect}); }` — a titled list; first entry `All (N)`; tapping a value selects it, tapping the selected value or `All` clears (calls `onSelect(null)`).

- [ ] **Step 1: Write the failing widget test** (append to `app/test/ui_shell_test.dart`)

```dart
  testWidgets('genre selection cascades into artist panel and track list',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(library: lib, player: player)));
    // Both artists visible initially in the Artist panel.
    expect(find.text('Muse'), findsWidgets);
    expect(find.text('Feed Me'), findsWidgets);
    await tester.tap(find.text('Rock')); // select genre
    await tester.pumpAndSettle();
    expect(lib.genreFilter, 'Rock');
    expect(find.text('Feed Me'), findsNothing); // filtered out everywhere
    expect(find.text('Oldest Song'), findsNothing); // track list narrowed
    await tester.tap(find.text('Rock')); // tap again clears
    await tester.pumpAndSettle();
    expect(lib.genreFilter, isNull);
    expect(find.text('Oldest Song'), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `app/`): `flutter test test/ui_shell_test.dart`
Expected: the new test FAILS (no filter panels rendered yet); prior tests still pass.

- [ ] **Step 3: Implement**

`app/lib/ui/filter_panel.dart`:

```dart
import 'package:flutter/material.dart';

class FilterPanel extends StatelessWidget {
  final String title;
  final List<String> values;
  final String? selected;
  final ValueChanged<String?> onSelect;
  const FilterPanel({
    super.key,
    required this.title,
    required this.values,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('All (${values.length})'),
                selected: selected == null,
                onTap: () => onSelect(null),
              ),
              for (final v in values)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: v == selected,
                  onTap: () => onSelect(v == selected ? null : v),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
```

In `app/lib/ui/home_screen.dart`, add the import and replace the marker comment `// Filter panels row inserted here in Task 7.` with:

```dart
                      SizedBox(
                        height: 180,
                        child: ListenableBuilder(
                          listenable: library,
                          builder: (context, _) => Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: FilterPanel(
                                  title: 'Genre',
                                  values: library.genres,
                                  selected: library.genreFilter,
                                  onSelect: library.setGenre,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: FilterPanel(
                                  title: 'Artist',
                                  values: library.artists,
                                  selected: library.artistFilter,
                                  onSelect: library.setArtist,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: FilterPanel(
                                  title: 'Album',
                                  values: library.albums,
                                  selected: library.albumFilter,
                                  onSelect: library.setAlbum,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
```

with import line `import 'filter_panel.dart';` added at the top of `home_screen.dart`.

- [ ] **Step 4: Run tests, full suite green**

Run (from `app/`): `flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/ui app/test/ui_shell_test.dart && git commit -m "feat: genre/artist/album cascade filter panels"
```

---

### Task 8: Now-playing bar

**Files:**
- Create: `app/lib/ui/now_playing_bar.dart`
- Modify: `app/lib/ui/home_screen.dart` (replace the `const SizedBox.shrink()` slot)
- Test: append to `app/test/ui_shell_test.dart`

**Interfaces:**
- Consumes: `PlayerService` (Task 5), `readArt` (Task 2).
- Produces: `class NowPlayingBar extends StatelessWidget { const NowPlayingBar({required PlayerService player, required Directory libraryRoot}); }` — height 84; row: 68×68 album art (via `readArt` in a `FutureBuilder` keyed by current track, `Icons.album` placeholder), title/artist/album column, transport (`skip_previous`, `play_arrow`/`pause`, `skip_next`), shuffle `IconButton` (highlighted when on), position/duration labels around a seek `Slider`, volume `Slider` (0–1) width 120. Hidden (SizedBox.shrink) when `player.current == null`.

- [ ] **Step 1: Write the failing widget test** (append to `app/test/ui_shell_test.dart`)

```dart
  testWidgets('now-playing bar hidden with no track, transport icons exist otherwise',
      (tester) async {
    final lib = fixtureLibrary();
    final player = PlayerService(libraryRoot: Directory.systemTemp);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(library: lib, player: player)));
    expect(find.byIcon(Icons.play_arrow), findsNothing); // no current track
    // Simulate a queue without touching media_kit natives; setVolume triggers
    // notifyListeners without creating the Player.
    player.queueController.setQueue(lib.allTracks, 0);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `app/`): `flutter test test/ui_shell_test.dart`
Expected: the new test FAILS (bar not rendered); prior tests pass.

- [ ] **Step 3: Implement**

`app/lib/ui/now_playing_bar.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../metadata/tags.dart';
import '../player/player_service.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class NowPlayingBar extends StatelessWidget {
  final PlayerService player;
  final Directory libraryRoot;
  const NowPlayingBar(
      {super.key, required this.player, required this.libraryRoot});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        final total = player.duration ?? Duration.zero;
        final pos = player.position > total ? total : player.position;
        return Container(
          height: 84,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              FutureBuilder<List<int>?>(
                key: ValueKey(t.contentId),
                future: readArt(File(p.join(libraryRoot.path, t.relPath))),
                builder: (context, snap) {
                  final bytes = snap.data;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: bytes == null
                        ? const SizedBox(
                            width: 68, height: 68, child: Icon(Icons.album, size: 48))
                        : Image.memory(Uint8List.fromList(bytes),
                            width: 68, height: 68, fit: BoxFit.cover),
                  );
                },
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 220,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text([t.artist, t.album].where((s) => s.isNotEmpty).join(' — '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: player.previous),
              IconButton(
                iconSize: 36,
                icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                onPressed: player.togglePlayPause,
              ),
              IconButton(
                  icon: const Icon(Icons.skip_next), onPressed: player.next),
              IconButton(
                icon: const Icon(Icons.shuffle),
                isSelected: player.shuffle,
                color: player.shuffle
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: player.toggleShuffle,
              ),
              const SizedBox(width: 8),
              Text(_fmt(pos), style: Theme.of(context).textTheme.bodySmall),
              Expanded(
                child: Slider(
                  value: total.inMilliseconds == 0
                      ? 0
                      : pos.inMilliseconds / total.inMilliseconds,
                  onChanged: (v) => player.seek(Duration(
                      milliseconds: (v * total.inMilliseconds).round())),
                ),
              ),
              Text(_fmt(total), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
              const Icon(Icons.volume_up, size: 18),
              SizedBox(
                width: 120,
                child: Slider(
                    value: player.volume, onChanged: player.setVolume),
              ),
            ],
          ),
        );
      },
    );
  }
}
```

In `app/lib/ui/home_screen.dart`: add imports `import 'dart:io';` and `import 'now_playing_bar.dart';`, and replace the bottom-slot lines

```dart
          // NowPlayingBar inserted here in Task 8.
          const SizedBox.shrink(),
```

with

```dart
          NowPlayingBar(player: player, libraryRoot: player.libraryRoot),
```

(`libraryRoot` is already a public final field on `PlayerService`.)

- [ ] **Step 4: Run tests, full suite green**

Run (from `app/`): `flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd "L:/PROJECTS/foobar" && git add app/lib/ui app/test/ui_shell_test.dart && git commit -m "feat: bottom now-playing bar with art, transport, seek, shuffle, volume"
```

---

### Task 9: Real-library run and verification

**Files:**
- None new (fixes only, if the run surfaces small issues).

**Interfaces:**
- Consumes: everything.
- Produces: the app verified against the real library, with a screenshot.

- [ ] **Step 1: Build and launch against the real library**

```bash
cd "L:/PROJECTS/foobar/app" && flutter build windows --release 2>&1 | tail -3
./build/windows/x64/runner/Release/fooplayer_app.exe &
```

Expected: window opens; status line progresses through `reading tags i/10604` (first run reads tags for all tracks — minutes over the network share; subsequent launches are cache-fast) and reaches `ready — 10604 tracks` with the feed newest-first.

- [ ] **Step 2: Verify interactively** (controller/user-driven; capture a screenshot)

Verify: feed order matches `date_added` desc (tonight's downloads on top); genre click narrows artists/albums/list; search narrows; playlist "alternative times - mike playlist" shows its imported tracks in order; clicking a track plays it (audible), bar shows art/title, seek and volume respond, shuffle toggles. Screenshot the window (Pillow `ImageGrab` method from project memory) and show the user.

- [ ] **Step 3: Fix-and-commit loop for small issues** (each fix: test if logic, `flutter test`, commit)

- [ ] **Step 4: Final commit**

```bash
cd "L:/PROJECTS/foobar" && git add -A && git commit -m "chore: complete Plan 2a — Windows player verified against real library" --allow-empty
```

---

## Out of scope for this plan

- Android target, APK build, device sync (Plan 2b)
- LAN pull (Plan 3); manifest writing from the app (foolib remains the writer)
- Theming, tag editing, play counts (spec: out of v1)
