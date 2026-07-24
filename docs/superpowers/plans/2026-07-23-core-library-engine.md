# Core Library Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Dart core of the music player — content-ID hashing, the `.library.json` manifest, library scanner, seed migration from the foobar2000 backup, and `.txt` playlist import — ending with the real 13.5k-track library seeded via CLI.

**Architecture:** A standalone Dart package (`core/`, package name `fooplayer_core`) with zero Flutter dependencies, exercised by unit tests and a small CLI (`foolib`). The manifest is the portable source of truth for `date_added` and playlists; audio files remain the source of truth for musical tags. A one-off Python script exports the foobar2000 `metadb.sqlite` backup to JSON so the Dart side never needs a native sqlite driver.

**Tech Stack:** Dart ≥3.4 (installed with the Flutter SDK), pub packages `crypto`, `path`, `args`, dev package `test`. Python 3 (already on this machine) for the one-off metadb export.

## Global Constraints

- Repo root: `L:\PROJECTS\foobar` (git, branch `main`). All paths below are relative to it.
- Dart package lives in `core/`, package name `fooplayer_core`. Only dependencies allowed: `crypto`, `path`, `args` (+ `test` as dev dependency).
- Manifest filename: `.library.json`, backup `.library.json.bak`, hash cache `.hash_cache.json` — all in the library root folder. Manifest `schema` field is the integer `1`.
- All timestamps in the manifest are ISO 8601 UTC strings (e.g. `2023-04-04T01:48:38.356840Z`).
- All track paths stored in manifest/cache are **relative to the library root, forward slashes**.
- Content ID = lowercase hex SHA-256 of the file's audio byte range (tag blocks excluded for MP3/FLAC; whole file for other formats).
- Real library root: `L:\music (original structure)`. foobar2000 backup: `L:\APPS\foobar [custom config files]\config backup\metadb.sqlite`.
- TDD throughout: failing test → minimal implementation → pass → commit. Run tests from `core/` with `dart test`.
- Never run a mutating CLI command (`--apply`) against the real library in this plan without the explicit user checkpoint in Task 9.

## File Structure

```
core/
├── pubspec.yaml
├── .gitignore
├── lib/
│   ├── fooplayer_core.dart          # public exports
│   └── src/
│       ├── audio_range.dart         # Task 1–2: tag-skipping byte ranges
│       ├── content_id.dart          # Task 2: hashing / dispatch
│       ├── manifest.dart            # Task 3: model + atomic save/load
│       ├── scanner.dart             # Task 4: walk + hash cache
│       ├── library_ops.dart         # Task 5: diff + apply (date_added stamping)
│       └── seed/
│           ├── metadb_index.dart    # Task 6: read exported metadb JSON
│           ├── seed_migration.dart  # Task 7: build initial manifest + report
│           └── playlist_import.dart # Task 8: .txt playlist import
├── bin/
│   └── foolib.dart                  # Task 9: CLI (status / update / seed)
├── tools/
│   └── export_metadb.py             # Task 6: sqlite → JSON (Python, stdlib only)
└── test/
    ├── audio_range_test.dart
    ├── content_id_test.dart
    ├── manifest_test.dart
    ├── scanner_test.dart
    ├── library_ops_test.dart
    ├── metadb_index_test.dart
    ├── seed_migration_test.dart
    └── playlist_import_test.dart
```

---

### Task 0: Toolchain and package scaffold

**Files:**
- Create: `core/pubspec.yaml`
- Create: `core/.gitignore`
- Create: `core/lib/fooplayer_core.dart`
- Test: `core/test/smoke_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: a `dart test`-runnable package every later task builds inside.

- [ ] **Step 1: Verify the Dart SDK is available**

Run: `dart --version`
Expected: `Dart SDK version: 3.x.x`. If the command is missing, install the Flutter SDK (which bundles `dart`): `winget install --id Google.Flutter -e`, open a new shell, re-run `dart --version`.

- [ ] **Step 2: Create the package files**

`core/pubspec.yaml`:

```yaml
name: fooplayer_core
description: Core library engine for the custom music player (content IDs, manifest, scanning, seed migration).
version: 0.1.0
environment:
  sdk: ^3.4.0
dependencies:
  args: ^2.5.0
  crypto: ^3.0.3
  path: ^1.9.0
dev_dependencies:
  test: ^1.25.0
```

`core/.gitignore`:

```
.dart_tool/
pubspec.lock
```

`core/lib/fooplayer_core.dart`:

```dart
library fooplayer_core;
```

- [ ] **Step 3: Fetch dependencies**

Run (from `core/`): `dart pub get`
Expected: `Got dependencies!`

- [ ] **Step 4: Write and run a smoke test**

`core/test/smoke_test.dart`:

```dart
import 'package:test/test.dart';

void main() {
  test('toolchain works', () {
    expect(1 + 1, equals(2));
  });
}
```

Run (from `core/`): `dart test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "chore: scaffold fooplayer_core Dart package"
```

---

### Task 1: MP3 audio byte range (tag skipping)

**Files:**
- Create: `core/lib/src/audio_range.dart`
- Test: `core/test/audio_range_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `class AudioRange { final int start; final int end; }` (start inclusive, end exclusive) and `AudioRange mp3AudioRange(Uint8List bytes)`. Task 2 dispatches to this.

Why this exists: the content ID must survive retagging, so the hash covers only audio bytes. For MP3 that means skipping an ID3v2 block at the start and ID3v1 (last 128 bytes) / APEv2 tags at the end.

- [ ] **Step 1: Write the failing tests**

`core/test/audio_range_test.dart`:

```dart
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/audio_range.dart';

Uint8List id3v2(int payloadSize) {
  // "ID3" v2.3 header, syncsafe size (7 bits per byte).
  final h = BytesBuilder();
  h.add([0x49, 0x44, 0x33, 3, 0, 0]); // "ID3", version, flags
  h.add([
    (payloadSize >> 21) & 0x7F,
    (payloadSize >> 14) & 0x7F,
    (payloadSize >> 7) & 0x7F,
    payloadSize & 0x7F,
  ]);
  h.add(List.filled(payloadSize, 0xAA)); // tag payload
  return h.toBytes();
}

void main() {
  final audio = List<int>.filled(500, 0x55);

  test('plain file: whole range', () {
    final b = Uint8List.fromList(audio);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('skips ID3v2 header at start', () {
    final b = Uint8List.fromList([...id3v2(300), ...audio]);
    final r = mp3AudioRange(b);
    expect(r.start, 10 + 300);
    expect(r.end, b.length);
  });

  test('skips ID3v1 trailer', () {
    final v1 = [0x54, 0x41, 0x47, ...List.filled(125, 0)]; // "TAG" + 125 bytes
    final b = Uint8List.fromList([...audio, ...v1]);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('skips APEv2 tag (with header) before ID3v1', () {
    // APE tag: 32-byte header + 40 bytes of items + 32-byte footer.
    // APE "tag size" field = items + footer = 72.
    List<int> apeBlock(bool isHeader) => [
          0x41, 0x50, 0x45, 0x54, 0x41, 0x47, 0x45, 0x58, // "APETAGEX"
          0xD0, 0x07, 0x00, 0x00, // version 2000
          72, 0, 0, 0, // tag size (LE)
          1, 0, 0, 0, // item count
          0, 0, 0, isHeader ? 0xA0 : 0x80, // flags: has-header, (is-header)
          0, 0, 0, 0, 0, 0, 0, 0, // reserved
        ];
    final b = Uint8List.fromList([
      ...audio,
      ...apeBlock(true),
      ...List.filled(40, 0x11),
      ...apeBlock(false),
    ]);
    final r = mp3AudioRange(b);
    expect(r.start, 0);
    expect(r.end, 500);
  });

  test('identical audio with different tags yields identical range content', () {
    final a = Uint8List.fromList([...id3v2(64), ...audio]);
    final b2 = Uint8List.fromList([...id3v2(999), ...audio]);
    final ra = mp3AudioRange(a);
    final rb = mp3AudioRange(b2);
    expect(a.sublist(ra.start, ra.end), b2.sublist(rb.start, rb.end));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/audio_range_test.dart`
Expected: FAIL — `Error: Not found: 'package:fooplayer_core/src/audio_range.dart'`

- [ ] **Step 3: Implement**

`core/lib/src/audio_range.dart`:

```dart
import 'dart:typed_data';

/// Byte range [start, end) of the audio data within a file.
class AudioRange {
  final int start;
  final int end;
  const AudioRange(this.start, this.end);
}

int _syncsafe(Uint8List b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

AudioRange mp3AudioRange(Uint8List b) {
  var start = 0;
  var end = b.length;

  // ID3v2 at start: "ID3" <ver:2> <flags:1> <syncsafe size:4>
  if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    final size = _syncsafe(b, 6);
    final footer = (b[5] & 0x10) != 0 ? 10 : 0; // footer flag duplicates header at tag end
    start = (10 + size + footer).clamp(0, b.length);
  }

  // ID3v1: fixed 128-byte trailer starting "TAG".
  if (end - start >= 128 &&
      b[end - 128] == 0x54 &&
      b[end - 127] == 0x41 &&
      b[end - 126] == 0x47) {
    end -= 128;
  }

  // APEv2: 32-byte footer ending at `end`, magic "APETAGEX".
  // Footer's size field covers items + footer; a header (flag bit 31 of the
  // footer's flags at offset 20) adds another 32 bytes before that.
  const magic = [0x41, 0x50, 0x45, 0x54, 0x41, 0x47, 0x45, 0x58];
  if (end - start >= 32) {
    final f = end - 32;
    var isApe = true;
    for (var i = 0; i < 8; i++) {
      if (b[f + i] != magic[i]) {
        isApe = false;
        break;
      }
    }
    if (isApe) {
      final tagSize = _le32(b, f + 12);
      final flags = _le32(b, f + 20);
      final hasHeader = (flags & 0x80000000) != 0;
      final tagStart = end - tagSize - (hasHeader ? 32 : 0);
      if (tagStart >= start && tagStart < end) end = tagStart;
    }
  }

  if (start > end) start = end;
  return AudioRange(start, end);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/audio_range_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib/src/audio_range.dart core/test/audio_range_test.dart
git commit -m "feat: MP3 audio byte range with ID3v2/ID3v1/APEv2 skipping"
```

---

### Task 2: FLAC range, format dispatch, and content ID

**Files:**
- Modify: `core/lib/src/audio_range.dart` (append `flacAudioRange`)
- Create: `core/lib/src/content_id.dart`
- Modify: `core/lib/fooplayer_core.dart`
- Test: `core/test/content_id_test.dart`

**Interfaces:**
- Consumes: `AudioRange`, `mp3AudioRange` from Task 1.
- Produces: `AudioRange flacAudioRange(Uint8List bytes)`; `String contentIdForBytes(String filename, Uint8List bytes)` and `Future<String> contentIdForFile(File file)` in `content_id.dart`. Content ID is lowercase hex SHA-256. Tasks 4+ call `contentIdForFile`.

Format policy (from spec): `.mp3` and `.flac` get tag-skipping ranges; every other extension (`.m4a`, `.ogg`, `.opus`, `.wav`) hashes the whole file — documented tradeoff: retagging those changes identity; the library is overwhelmingly MP3.

- [ ] **Step 1: Write the failing tests**

`core/test/content_id_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/audio_range.dart';
import 'package:fooplayer_core/src/content_id.dart';

Uint8List flacFile({required int vorbisSize, required List<int> audio}) {
  // "fLaC" + STREAMINFO block (34 bytes, not last) + VORBIS_COMMENT (last) + audio.
  final b = BytesBuilder();
  b.add([0x66, 0x4C, 0x61, 0x43]); // "fLaC"
  b.add([0x00, 0x00, 0x00, 34]); // type 0 (STREAMINFO), len 34, not last
  b.add(List.filled(34, 0x01));
  b.add([0x84, (vorbisSize >> 16) & 0xFF, (vorbisSize >> 8) & 0xFF, vorbisSize & 0xFF]); // 0x80|4: last, VORBIS_COMMENT
  b.add(List.filled(vorbisSize, 0x02));
  b.add(audio);
  return b.toBytes();
}

void main() {
  final audio = List<int>.filled(300, 0x77);

  test('flac range starts after last metadata block', () {
    final b = flacFile(vorbisSize: 50, audio: audio);
    final r = flacAudioRange(b);
    expect(r.start, 4 + 4 + 34 + 4 + 50);
    expect(r.end, b.length);
  });

  test('flac with different vorbis comment sizes → same content id', () {
    final a = flacFile(vorbisSize: 50, audio: audio);
    final b = flacFile(vorbisSize: 200, audio: audio);
    expect(contentIdForBytes('x.flac', a), contentIdForBytes('x.flac', b));
  });

  test('mp3 with different ID3v2 sizes → same content id', () {
    Uint8List mp3(int pad) => Uint8List.fromList([
          0x49, 0x44, 0x33, 3, 0, 0, 0, 0, (pad >> 7) & 0x7F, pad & 0x7F,
          ...List.filled(pad, 0xAA),
          ...audio,
        ]);
    expect(contentIdForBytes('x.mp3', mp3(20)), contentIdForBytes('x.mp3', mp3(90)));
  });

  test('unknown format hashes whole file', () {
    final a = Uint8List.fromList(audio);
    final b = Uint8List.fromList([...audio, 0x00]);
    expect(contentIdForBytes('x.m4a', a), isNot(contentIdForBytes('x.m4a', b)));
  });

  test('contentIdForFile matches contentIdForBytes', () async {
    final dir = await Directory.systemTemp.createTemp('cid');
    final f = File('${dir.path}/t.mp3');
    await f.writeAsBytes(audio);
    expect(await contentIdForFile(f), contentIdForBytes('t.mp3', Uint8List.fromList(audio)));
    await dir.delete(recursive: true);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/content_id_test.dart`
Expected: FAIL — `flacAudioRange` / `content_id.dart` not found.

- [ ] **Step 3: Implement**

Append to `core/lib/src/audio_range.dart`:

```dart
AudioRange flacAudioRange(Uint8List b) {
  // "fLaC" then metadata blocks: 1 byte (isLast<<7 | type) + 3-byte BE length.
  if (b.length < 8 || b[0] != 0x66 || b[1] != 0x4C || b[2] != 0x61 || b[3] != 0x43) {
    return AudioRange(0, b.length);
  }
  var o = 4;
  while (o + 4 <= b.length) {
    final isLast = (b[o] & 0x80) != 0;
    final len = (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    o += 4 + len;
    if (isLast) break;
  }
  if (o > b.length) o = b.length;
  return AudioRange(o, b.length);
}
```

`core/lib/src/content_id.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'audio_range.dart';

AudioRange audioRangeFor(String filename, Uint8List bytes) {
  switch (p.extension(filename).toLowerCase()) {
    case '.mp3':
      return mp3AudioRange(bytes);
    case '.flac':
      return flacAudioRange(bytes);
    default:
      return AudioRange(0, bytes.length);
  }
}

/// Lowercase hex SHA-256 of the file's audio byte range.
String contentIdForBytes(String filename, Uint8List bytes) {
  final r = audioRangeFor(filename, bytes);
  return sha256.convert(Uint8List.sublistView(bytes, r.start, r.end)).toString();
}

Future<String> contentIdForFile(File file) async {
  final bytes = await file.readAsBytes();
  return contentIdForBytes(p.basename(file.path), bytes);
}
```

Replace `core/lib/fooplayer_core.dart` with:

```dart
library fooplayer_core;

export 'src/audio_range.dart';
export 'src/content_id.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/content_id_test.dart
git commit -m "feat: FLAC range and content-ID hashing with format dispatch"
```

---

### Task 3: Manifest model with atomic save

**Files:**
- Create: `core/lib/src/manifest.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/manifest_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class TrackEntry { String dateAdded; List<String> paths; }`
  - `class Playlist { String name; List<String> trackIds; }`
  - `class Manifest { int schema; Map<String, TrackEntry> tracks; List<Playlist> playlists; Manifest.empty(); factory Manifest.fromJson(Map<String, dynamic>); Map<String, dynamic> toJson(); }`
  - `Future<void> saveManifest(Manifest m, Directory libraryRoot)` — atomic write-temp-then-rename, keeps previous version as `.library.json.bak`.
  - `Manifest loadManifest(Directory libraryRoot)` — returns `Manifest.empty()` if no file; falls back to `.bak` if the main file is corrupt; throws `FormatException` if both are corrupt.
- Tasks 5, 7, 8, 9 all read/write these types.

- [ ] **Step 1: Write the failing tests**

`core/test/manifest_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/manifest.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('mani'));
  tearDown(() async => root.delete(recursive: true));

  Manifest sample() {
    final m = Manifest.empty();
    m.tracks['abc123'] =
        TrackEntry(dateAdded: '2023-04-04T01:48:38.356840Z', paths: ['albums/x/y.mp3']);
    m.playlists.add(Playlist(name: 'monthly 2023-04', trackIds: ['abc123']));
    return m;
  }

  test('round-trips through JSON', () {
    final m2 = Manifest.fromJson(sample().toJson());
    expect(m2.schema, 1);
    expect(m2.tracks['abc123']!.dateAdded, '2023-04-04T01:48:38.356840Z');
    expect(m2.tracks['abc123']!.paths, ['albums/x/y.mp3']);
    expect(m2.playlists.single.name, 'monthly 2023-04');
    expect(m2.playlists.single.trackIds, ['abc123']);
  });

  test('load of missing file returns empty manifest', () {
    final m = loadManifest(root);
    expect(m.tracks, isEmpty);
    expect(m.playlists, isEmpty);
  });

  test('save then load; second save keeps previous version as .bak', () async {
    await saveManifest(sample(), root);
    expect(loadManifest(root).tracks.containsKey('abc123'), isTrue);

    final m2 = sample();
    m2.tracks['def456'] = TrackEntry(dateAdded: '2024-01-01T00:00:00.000Z', paths: ['a.mp3']);
    await saveManifest(m2, root);

    expect(loadManifest(root).tracks.length, 2);
    final bak = jsonDecode(File('${root.path}/.library.json.bak').readAsStringSync());
    expect((bak['tracks'] as Map).length, 1); // previous version
  });

  test('corrupt main file falls back to .bak', () async {
    await saveManifest(sample(), root);
    await saveManifest(sample(), root); // creates .bak
    File('${root.path}/.library.json').writeAsStringSync('{not json');
    expect(loadManifest(root).tracks.containsKey('abc123'), isTrue);
  });

  test('rejects unknown schema version', () {
    File('${root.path}/.library.json')
        .writeAsStringSync(jsonEncode({'schema': 99, 'tracks': {}, 'playlists': []}));
    expect(() => loadManifest(root), throwsA(isA<FormatException>()));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/manifest_test.dart`
Expected: FAIL — `manifest.dart` not found.

- [ ] **Step 3: Implement**

`core/lib/src/manifest.dart`:

```dart
import 'dart:convert';
import 'dart:io';

const manifestFileName = '.library.json';
const manifestBakName = '.library.json.bak';

class TrackEntry {
  String dateAdded; // ISO 8601 UTC
  List<String> paths; // relative to library root, forward slashes
  TrackEntry({required this.dateAdded, required this.paths});

  Map<String, dynamic> toJson() => {'date_added': dateAdded, 'paths': paths};
  factory TrackEntry.fromJson(Map<String, dynamic> j) => TrackEntry(
        dateAdded: j['date_added'] as String,
        paths: (j['paths'] as List).cast<String>(),
      );
}

class Playlist {
  String name;
  List<String> trackIds;
  Playlist({required this.name, required this.trackIds});

  Map<String, dynamic> toJson() => {'name': name, 'track_ids': trackIds};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        name: j['name'] as String,
        trackIds: (j['track_ids'] as List).cast<String>(),
      );
}

class Manifest {
  int schema;
  Map<String, TrackEntry> tracks; // key: content ID
  List<Playlist> playlists;
  Manifest({required this.schema, required this.tracks, required this.playlists});

  Manifest.empty() : this(schema: 1, tracks: {}, playlists: []);

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
        'playlists': playlists.map((p) => p.toJson()).toList(),
      };

  factory Manifest.fromJson(Map<String, dynamic> j) {
    final schema = j['schema'] as int;
    if (schema != 1) throw FormatException('unsupported manifest schema: $schema');
    return Manifest(
      schema: schema,
      tracks: (j['tracks'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, TrackEntry.fromJson(v as Map<String, dynamic>))),
      playlists: (j['playlists'] as List)
          .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Atomic save: write .tmp, move current file to .bak, rename .tmp into place.
Future<void> saveManifest(Manifest m, Directory libraryRoot) async {
  final main = File('${libraryRoot.path}/$manifestFileName');
  final tmp = File('${libraryRoot.path}/$manifestFileName.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(m.toJson()));
  if (main.existsSync()) {
    final bak = File('${libraryRoot.path}/$manifestBakName');
    if (bak.existsSync()) bak.deleteSync();
    main.renameSync(bak.path);
  }
  tmp.renameSync(main.path);
}

Manifest _parse(File f) =>
    Manifest.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);

Manifest loadManifest(Directory libraryRoot) {
  final main = File('${libraryRoot.path}/$manifestFileName');
  final bak = File('${libraryRoot.path}/$manifestBakName');
  if (!main.existsSync() && !bak.existsSync()) return Manifest.empty();
  if (main.existsSync()) {
    try {
      return _parse(main);
    } on FormatException {
      if (!bak.existsSync()) rethrow;
    }
  }
  return _parse(bak);
}
```

Note: the schema-99 test expects a throw; the corrupt-main test expects `.bak` fallback — both paths go through `FormatException`, which is why the fallback only rethrows when no `.bak` exists.

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/manifest.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/manifest_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/manifest_test.dart
git commit -m "feat: manifest model with atomic save and .bak fallback"
```

---

### Task 4: Library scanner with hash cache

**Files:**
- Create: `core/lib/src/scanner.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/scanner_test.dart`

**Interfaces:**
- Consumes: `contentIdForFile` (Task 2).
- Produces:
  - `class ScannedTrack { String relPath; int size; DateTime mtime; String contentId; }`
  - `Future<List<ScannedTrack>> scanLibrary(Directory root, {void Function(int done, int total)? onProgress})` — walks recursively, includes extensions `.mp3 .flac .m4a .ogg .opus .wav`, skips dot-files, relative forward-slash paths, sorted by `relPath`. Reads/writes `.hash_cache.json` in the root: an entry is reused when `size` and `mtime` (ms precision) match, so only new/changed files get hashed.
- Tasks 5, 7, 9 consume `List<ScannedTrack>`.

- [ ] **Step 1: Write the failing tests**

`core/test/scanner_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/scanner.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan');
    Directory('${root.path}/albums/A').createSync(recursive: true);
    File('${root.path}/albums/A/one.mp3').writeAsBytesSync(List.filled(100, 1));
    File('${root.path}/two.flac').writeAsBytesSync(List.filled(200, 2));
    File('${root.path}/notes.txt').writeAsStringSync('not audio');
    File('${root.path}/.library.json').writeAsStringSync('{}'); // dot-file: skipped
  });
  tearDown(() async => root.delete(recursive: true));

  test('finds only audio files, relative forward-slash paths, sorted', () async {
    final tracks = await scanLibrary(root);
    expect(tracks.map((t) => t.relPath).toList(), ['albums/A/one.mp3', 'two.flac']);
    expect(tracks.first.size, 100);
    expect(tracks.first.contentId, hasLength(64));
  });

  test('second scan reuses cache for unchanged files', () async {
    await scanLibrary(root);
    final cacheFile = File('${root.path}/.hash_cache.json');
    expect(cacheFile.existsSync(), isTrue);

    // Poison the cached ID; unchanged file must keep the poisoned value (cache hit).
    final cache = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    (cache['albums/A/one.mp3'] as Map<String, dynamic>)['id'] = 'poisoned';
    cacheFile.writeAsStringSync(jsonEncode(cache));

    final tracks = await scanLibrary(root);
    expect(tracks.firstWhere((t) => t.relPath == 'albums/A/one.mp3').contentId, 'poisoned');
  });

  test('changed file is re-hashed', () async {
    await scanLibrary(root);
    File('${root.path}/albums/A/one.mp3').writeAsBytesSync(List.filled(150, 9));
    final tracks = await scanLibrary(root);
    final t = tracks.firstWhere((t) => t.relPath == 'albums/A/one.mp3');
    expect(t.size, 150);
    expect(t.contentId, isNot('poisoned'));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/scanner_test.dart`
Expected: FAIL — `scanner.dart` not found.

- [ ] **Step 3: Implement**

`core/lib/src/scanner.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'content_id.dart';

const hashCacheName = '.hash_cache.json';
const audioExtensions = {'.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav'};

class ScannedTrack {
  final String relPath;
  final int size;
  final DateTime mtime;
  final String contentId;
  ScannedTrack(this.relPath, this.size, this.mtime, this.contentId);
}

Future<List<ScannedTrack>> scanLibrary(
  Directory root, {
  void Function(int done, int total)? onProgress,
}) async {
  final cacheFile = File('${root.path}/$hashCacheName');
  final cache = cacheFile.existsSync()
      ? (jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>)
      : <String, dynamic>{};

  final files = <File>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (p.basename(e.path).startsWith('.')) continue;
    if (!audioExtensions.contains(p.extension(e.path).toLowerCase())) continue;
    files.add(e);
  }

  final tracks = <ScannedTrack>[];
  final newCache = <String, dynamic>{};
  var done = 0;
  for (final f in files) {
    final rel = p.relative(f.path, from: root.path).replaceAll('\\', '/');
    final stat = f.statSync();
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final cached = cache[rel] as Map<String, dynamic>?;
    final String id;
    if (cached != null && cached['size'] == stat.size && cached['mtimeMs'] == mtimeMs) {
      id = cached['id'] as String;
    } else {
      id = await contentIdForFile(f);
    }
    newCache[rel] = {'size': stat.size, 'mtimeMs': mtimeMs, 'id': id};
    tracks.add(ScannedTrack(rel, stat.size, stat.modified, id));
    onProgress?.call(++done, files.length);
  }

  cacheFile.writeAsStringSync(jsonEncode(newCache));
  tracks.sort((a, b) => a.relPath.compareTo(b.relPath));
  return tracks;
}
```

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/scanner.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/scanner_test.dart`
Expected: `All tests passed!` (3 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/scanner_test.dart
git commit -m "feat: recursive library scanner with size+mtime hash cache"
```

---

### Task 5: Diff and apply (date_added stamping)

**Files:**
- Create: `core/lib/src/library_ops.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/library_ops_test.dart`

**Interfaces:**
- Consumes: `Manifest`, `TrackEntry` (Task 3); `ScannedTrack` (Task 4).
- Produces:
  - `class LibraryDiff { List<ScannedTrack> newTracks; Map<String, List<String>> movedOrRetagged; List<String> missingTrackIds; Map<String, List<String>> duplicates; bool get isEmpty; }`
  - `LibraryDiff diffAgainstManifest(Manifest m, List<ScannedTrack> scan)`
  - `void applyDiff(Manifest m, LibraryDiff d, List<ScannedTrack> scan, DateTime Function() now)` — stamps `date_added = now().toUtc().toIso8601String()` for new tracks; refreshes every known track's `paths` from the scan; entries whose files are gone are kept (spec: hidden, not an error).
- Task 7 reuses the duplicate policy; Task 9's `status`/`update` commands are thin wrappers over these two functions.

- [ ] **Step 1: Write the failing tests**

`core/test/library_ops_test.dart`:

```dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/library_ops_test.dart`
Expected: FAIL — `library_ops.dart` not found.

- [ ] **Step 3: Implement**

`core/lib/src/library_ops.dart`:

```dart
import 'manifest.dart';
import 'scanner.dart';

class LibraryDiff {
  final List<ScannedTrack> newTracks; // content IDs not in manifest (one per ID)
  final Map<String, List<String>> movedOrRetagged; // id → new paths, when path set changed
  final List<String> missingTrackIds; // in manifest, no file on disk
  final Map<String, List<String>> duplicates; // id → paths, when a scan ID has >1 path
  LibraryDiff(this.newTracks, this.movedOrRetagged, this.missingTrackIds, this.duplicates);

  bool get isEmpty =>
      newTracks.isEmpty && movedOrRetagged.isEmpty && missingTrackIds.isEmpty;
}

Map<String, List<String>> _pathsById(List<ScannedTrack> scan) {
  final byId = <String, List<String>>{};
  for (final t in scan) {
    byId.putIfAbsent(t.contentId, () => []).add(t.relPath);
  }
  for (final paths in byId.values) {
    paths.sort();
  }
  return byId;
}

LibraryDiff diffAgainstManifest(Manifest m, List<ScannedTrack> scan) {
  final byId = _pathsById(scan);

  final newTracks = <ScannedTrack>[];
  final seenNew = <String>{};
  for (final t in scan) {
    if (!m.tracks.containsKey(t.contentId) && seenNew.add(t.contentId)) {
      newTracks.add(t);
    }
  }

  final moved = <String, List<String>>{};
  for (final e in m.tracks.entries) {
    final current = byId[e.key];
    if (current != null && current.join('\n') != (List.of(e.value.paths)..sort()).join('\n')) {
      moved[e.key] = current;
    }
  }

  final missing =
      m.tracks.keys.where((id) => !byId.containsKey(id)).toList()..sort();
  final duplicates = <String, List<String>>{
    for (final e in byId.entries)
      if (e.value.length > 1) e.key: e.value,
  };
  return LibraryDiff(newTracks, moved, missing, duplicates);
}

void applyDiff(
  Manifest m,
  LibraryDiff d,
  List<ScannedTrack> scan,
  DateTime Function() now,
) {
  final byId = _pathsById(scan);
  for (final t in d.newTracks) {
    m.tracks[t.contentId] = TrackEntry(
      dateAdded: now().toUtc().toIso8601String(),
      paths: byId[t.contentId]!,
    );
  }
  for (final id in d.movedOrRetagged.keys) {
    m.tracks[id]!.paths = byId[id]!;
  }
  // Missing entries: retained untouched — hidden by consumers, never deleted here.
}
```

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/library_ops.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/library_ops_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/library_ops_test.dart
git commit -m "feat: manifest diff/apply with date_added stamping and duplicate policy"
```

---

### Task 6: metadb export (Python) and metadb index (Dart)

**Files:**
- Create: `core/tools/export_metadb.py`
- Create: `core/lib/src/seed/metadb_index.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/metadb_index_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `export_metadb.py <metadb.sqlite> <out.json>` — writes `{"records": [{"basename": "...", "size": <int>, "created": "<ISO 8601 UTC>"}]}`. Basenames lowercased.
  - `Map<String, DateTime> loadMetadbIndex(String jsonPath)` in Dart — key `'<basename>|<size>'` (basename lowercase), value = created time; on key collision keeps the **earliest** date.
- Task 7 consumes the returned map.

Background: the foobar2000 backup `metadb.sqlite` has table `metadb` with columns `name` (like `0+file://C:\...\track.mp3`), `created` (Windows FILETIME: 100-ns ticks since 1601-01-01 UTC), `size`. The Unix epoch in FILETIME is exactly `116444736000000000` — used as the conversion anchor and as a test anchor.

- [ ] **Step 1: Write the Python export script**

`core/tools/export_metadb.py`:

```python
"""Export foobar2000 v2 metadb.sqlite to JSON for the Dart seed migration.

Usage: python export_metadb.py <metadb.sqlite> <out.json>
"""
import json
import ntpath
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

FILETIME_EPOCH = datetime(1601, 1, 1, tzinfo=timezone.utc)
PREFIX = "0+file://"


def main(db_path: str, out_path: str) -> None:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    records = []
    for name, created, size in con.execute(
        "SELECT name, created, size FROM metadb WHERE created IS NOT NULL"
    ):
        if not name.startswith(PREFIX):
            continue
        path = name[len(PREFIX):]
        created_dt = FILETIME_EPOCH + timedelta(microseconds=created / 10)
        records.append({
            "basename": ntpath.basename(path).lower(),
            "size": size,
            "created": created_dt.isoformat(),
        })
    con.close()
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"records": records}, f)
    print(f"exported {len(records)} records to {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
```

- [ ] **Step 2: Run it against the real backup to verify**

Run (from `core/`):
```
python tools/export_metadb.py "L:\APPS\foobar [custom config files]\config backup\metadb.sqlite" tools/metadb_dates.json
```
Expected: `exported 4947 records to tools/metadb_dates.json` (4,947 matches the restore-script dry run of 2026-07-23).

- [ ] **Step 3: Write the failing Dart tests**

`core/test/metadb_index_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:fooplayer_core/src/seed/metadb_index.dart';

void main() {
  test('loads records keyed by basename|size', () async {
    final dir = await Directory.systemTemp.createTemp('mdb');
    final f = File('${dir.path}/m.json');
    f.writeAsStringSync(jsonEncode({
      'records': [
        {'basename': 'song.mp3', 'size': 100, 'created': '2023-04-04T01:48:38.356840+00:00'},
        {'basename': 'song.mp3', 'size': 100, 'created': '2022-01-01T00:00:00+00:00'},
        {'basename': 'other.mp3', 'size': 5, 'created': '2024-06-01T10:00:00+00:00'},
      ]
    }));
    final idx = loadMetadbIndex(f.path);
    expect(idx.length, 2);
    expect(idx['song.mp3|100'], DateTime.utc(2022, 1, 1)); // earliest wins
    expect(idx['other.mp3|5'], DateTime.utc(2024, 6, 1, 10));
    await dir.delete(recursive: true);
  });
}
```

- [ ] **Step 4: Run test to verify it fails**

Run (from `core/`): `dart test test/metadb_index_test.dart`
Expected: FAIL — `metadb_index.dart` not found.

- [ ] **Step 5: Implement**

`core/lib/src/seed/metadb_index.dart`:

```dart
import 'dart:convert';
import 'dart:io';

/// Loads the JSON produced by tools/export_metadb.py.
/// Key: '<basename lowercase>|<size>'. Collisions keep the earliest date.
Map<String, DateTime> loadMetadbIndex(String jsonPath) {
  final j = jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, dynamic>;
  final idx = <String, DateTime>{};
  for (final r in (j['records'] as List).cast<Map<String, dynamic>>()) {
    final key = '${(r['basename'] as String).toLowerCase()}|${r['size']}';
    final created = DateTime.parse(r['created'] as String).toUtc();
    final existing = idx[key];
    if (existing == null || created.isBefore(existing)) idx[key] = created;
  }
  return idx;
}
```

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/seed/metadb_index.dart';
```

- [ ] **Step 6: Run tests to verify they pass**

Run (from `core/`): `dart test test/metadb_index_test.dart`
Expected: `All tests passed!` (1 test)

- [ ] **Step 7: Commit** (the exported JSON is an artifact, not source — ignore it)

Append to `core/.gitignore`:

```
tools/metadb_dates.json
```

```bash
git add core/tools/export_metadb.py core/lib core/test/metadb_index_test.dart core/.gitignore
git commit -m "feat: metadb export script and Dart metadb index loader"
```

---

### Task 7: Seed migration

**Files:**
- Create: `core/lib/src/seed/seed_migration.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/seed_migration_test.dart`

**Interfaces:**
- Consumes: `ScannedTrack` (Task 4), `Manifest`/`TrackEntry` (Task 3), metadb index map (Task 6).
- Produces:
  - `class SeedResult { Manifest manifest; int fromMetadb; int fromCtime; int duplicateGroups; List<String> report; }`
  - `SeedResult buildSeedManifest({required List<ScannedTrack> scan, required Map<String, DateTime> metadb, required DateTime Function(String relPath) ctimeOf})`
  - Date priority per file: metadb match on `basename|size` → else `ctimeOf(relPath)` (the CLI passes `FileStat.changed`, which **on Windows is the file creation time** — correct after `restore_ctimes.py --apply`). For duplicate content IDs the earliest resolved date wins and all paths are listed.
  - `report` is a human-readable summary: counts + 10 newest and 10 oldest entries for eyeballing (spec requires a reviewed dry run before first manifest commit).
- Task 9's `seed` command wraps this.

- [ ] **Step 1: Write the failing tests**

`core/test/seed_migration_test.dart`:

```dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/seed_migration_test.dart`
Expected: FAIL — `seed_migration.dart` not found.

- [ ] **Step 3: Implement**

`core/lib/src/seed/seed_migration.dart`:

```dart
import 'package:path/path.dart' as p;
import '../manifest.dart';
import '../scanner.dart';

class SeedResult {
  final Manifest manifest;
  final int fromMetadb;
  final int fromCtime;
  final int duplicateGroups;
  final List<String> report;
  SeedResult(this.manifest, this.fromMetadb, this.fromCtime, this.duplicateGroups,
      this.report);
}

SeedResult buildSeedManifest({
  required List<ScannedTrack> scan,
  required Map<String, DateTime> metadb,
  required DateTime Function(String relPath) ctimeOf,
}) {
  final m = Manifest.empty();
  var fromMetadb = 0;
  var fromCtime = 0;

  // Resolve a date per scanned file, then reduce per content ID (earliest wins).
  final dates = <String, DateTime>{}; // content ID → earliest date
  final paths = <String, List<String>>{};
  for (final t in scan) {
    final key = '${p.basename(t.relPath).toLowerCase()}|${t.size}';
    final DateTime date;
    if (metadb.containsKey(key)) {
      date = metadb[key]!;
      fromMetadb++;
    } else {
      date = ctimeOf(t.relPath).toUtc();
      fromCtime++;
    }
    final prev = dates[t.contentId];
    if (prev == null || date.isBefore(prev)) dates[t.contentId] = date;
    paths.putIfAbsent(t.contentId, () => []).add(t.relPath);
  }

  var duplicateGroups = 0;
  for (final id in dates.keys) {
    final ps = paths[id]!..sort();
    if (ps.length > 1) duplicateGroups++;
    m.tracks[id] = TrackEntry(dateAdded: dates[id]!.toIso8601String(), paths: ps);
  }

  final sorted = m.tracks.entries.toList()
    ..sort((a, b) => a.value.dateAdded.compareTo(b.value.dateAdded));
  String line(MapEntry<String, TrackEntry> e) =>
      '  ${e.value.dateAdded}  ${e.value.paths.first}';
  final report = <String>[
    'tracks: ${m.tracks.length}',
    'from metadb: $fromMetadb',
    'from ctime: $fromCtime',
    'duplicate groups: $duplicateGroups',
    'oldest:',
    ...sorted.take(10).map(line),
    'newest:',
    ...sorted.reversed.take(10).map(line),
  ];
  return SeedResult(m, fromMetadb, fromCtime, duplicateGroups, report);
}
```

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/seed/seed_migration.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/seed_migration_test.dart`
Expected: `All tests passed!` (4 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/seed_migration_test.dart
git commit -m "feat: seed migration building initial manifest from metadb + ctimes"
```

---

### Task 8: .txt playlist import

**Files:**
- Create: `core/lib/src/seed/playlist_import.dart`
- Modify: `core/lib/fooplayer_core.dart` (add export)
- Test: `core/test/playlist_import_test.dart`

**Interfaces:**
- Consumes: `Playlist` (Task 3).
- Produces:
  - `class PlaylistImportResult { Playlist playlist; List<String> unmatched; }`
  - `PlaylistImportResult importTxtPlaylist(String name, List<String> lines, Map<String, String> basenameToId)` — `basenameToId` maps lowercase basenames (e.g. `song.mp3`) to content IDs. Lines may be bare names, full paths (either slash style), with or without extension; blank lines and `#` comments are skipped. Extensionless lines try each audio extension. Unmatched lines are reported, not fatal.
- Task 9's `seed` command builds `basenameToId` from the scan and calls this per `.txt` file (playlist name = filename without extension).

- [ ] **Step 1: Write the failing tests**

`core/test/playlist_import_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:fooplayer_core/src/seed/playlist_import.dart';

void main() {
  final ids = {
    'crying lightning.mp3': 'id1',
    'my propeller.mp3': 'id2',
    'secret door.flac': 'id3',
  };

  test('matches bare names, full paths, and mixed case', () {
    final r = importTxtPlaylist('mix', [
      'Crying Lightning.mp3',
      r'C:\music\albums\Humbug\My Propeller.mp3',
      'some/dir/Secret Door.flac',
    ], ids);
    expect(r.playlist.name, 'mix');
    expect(r.playlist.trackIds, ['id1', 'id2', 'id3']);
    expect(r.unmatched, isEmpty);
  });

  test('extensionless lines try audio extensions', () {
    final r = importTxtPlaylist('mix', ['Secret Door'], ids);
    expect(r.playlist.trackIds, ['id3']);
  });

  test('skips blanks and comments, reports unmatched', () {
    final r = importTxtPlaylist('mix', ['', '# comment', 'Nope.mp3'], ids);
    expect(r.playlist.trackIds, isEmpty);
    expect(r.unmatched, ['Nope.mp3']);
  });

  test('preserves order and duplicates', () {
    final r = importTxtPlaylist('mix',
        ['My Propeller.mp3', 'Crying Lightning.mp3', 'My Propeller.mp3'], ids);
    expect(r.playlist.trackIds, ['id2', 'id1', 'id2']);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `core/`): `dart test test/playlist_import_test.dart`
Expected: FAIL — `playlist_import.dart` not found.

- [ ] **Step 3: Implement**

`core/lib/src/seed/playlist_import.dart`:

```dart
import '../manifest.dart';
import '../scanner.dart' show audioExtensions;

class PlaylistImportResult {
  final Playlist playlist;
  final List<String> unmatched;
  PlaylistImportResult(this.playlist, this.unmatched);
}

PlaylistImportResult importTxtPlaylist(
  String name,
  List<String> lines,
  Map<String, String> basenameToId,
) {
  final trackIds = <String>[];
  final unmatched = <String>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    // Take the basename regardless of slash style.
    final base = line.split(RegExp(r'[\\/]')).last.toLowerCase();
    String? id = basenameToId[base];
    if (id == null && !base.contains('.')) {
      for (final ext in audioExtensions) {
        id = basenameToId['$base$ext'];
        if (id != null) break;
      }
    }
    if (id != null) {
      trackIds.add(id);
    } else {
      unmatched.add(line);
    }
  }
  return PlaylistImportResult(Playlist(name: name, trackIds: trackIds), unmatched);
}
```

Add to `core/lib/fooplayer_core.dart`:

```dart
export 'src/seed/playlist_import.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `core/`): `dart test test/playlist_import_test.dart`
Expected: `All tests passed!` (4 tests)

- [ ] **Step 5: Commit**

```bash
git add core/lib core/test/playlist_import_test.dart
git commit -m "feat: tolerant .txt playlist import by basename matching"
```

---

### Task 9: CLI and real-library seed (with user checkpoint)

**Files:**
- Create: `core/bin/foolib.dart`
- Test: full suite + manual dry run against the real library

**Interfaces:**
- Consumes: everything above.
- Produces the `foolib` CLI:
  - `dart run fooplayer_core:foolib status --root <path>` — scan, diff vs manifest, print report. Read-only.
  - `dart run fooplayer_core:foolib update --root <path> [--apply]` — stamp new tracks / refresh paths; dry-run by default.
  - `dart run fooplayer_core:foolib seed --root <path> --metadb-json <file> [--playlists <dir>] [--apply]` — build initial manifest; **refuses if a manifest already exists** (unless `--force`); dry-run by default, printing the seed report.

- [ ] **Step 1: Implement the CLI** (thin wrapper — logic is already tested; no new unit tests, but the full suite must stay green)

`core/bin/foolib.dart`:

```dart
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:fooplayer_core/fooplayer_core.dart';

// Dart ignores main's return value, so the exit code must be set explicitly.
Future<void> main(List<String> argv) async {
  exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  if (argv.isEmpty) {
    stderr.writeln('usage: foolib <status|update|seed> --root <path> [options]');
    return 2;
  }
  final cmd = argv.first;
  final parser = ArgParser()
    ..addOption('root', mandatory: true)
    ..addOption('metadb-json')
    ..addOption('playlists')
    ..addFlag('apply', defaultsTo: false)
    ..addFlag('force', defaultsTo: false);
  final args = parser.parse(argv.skip(1).toList());
  final root = Directory(args['root'] as String);
  if (!root.existsSync()) {
    stderr.writeln('root not found: ${root.path}');
    return 2;
  }

  stdout.writeln('scanning ${root.path} ...');
  final scan = await scanLibrary(root, onProgress: (d, t) {
    if (d % 500 == 0 || d == t) stdout.writeln('  $d / $t');
  });
  stdout.writeln('scanned ${scan.length} audio files');

  switch (cmd) {
    case 'status':
      final m = loadManifest(root);
      final d = diffAgainstManifest(m, scan);
      stdout
        ..writeln('manifest tracks : ${m.tracks.length}')
        ..writeln('new tracks      : ${d.newTracks.length}')
        ..writeln('moved/retagged  : ${d.movedOrRetagged.length}')
        ..writeln('missing files   : ${d.missingTrackIds.length}')
        ..writeln('duplicate groups: ${d.duplicates.length}');
      for (final t in d.newTracks.take(20)) {
        stdout.writeln('  new: ${t.relPath}');
      }
      return 0;

    case 'update':
      final m = loadManifest(root);
      final d = diffAgainstManifest(m, scan);
      stdout.writeln(
          'would stamp ${d.newTracks.length} new, update ${d.movedOrRetagged.length} paths');
      if (args['apply'] as bool) {
        applyDiff(m, d, scan, DateTime.now);
        await saveManifest(m, root);
        stdout.writeln('manifest written.');
      } else {
        stdout.writeln('dry run — pass --apply to write.');
      }
      return 0;

    case 'seed':
      final manifestFile = File('${root.path}/$manifestFileName');
      if (manifestFile.existsSync() && !(args['force'] as bool)) {
        stderr.writeln('manifest already exists — seed refused (use --force to overwrite).');
        return 1;
      }
      final metadbJson = args['metadb-json'] as String?;
      if (metadbJson == null) {
        stderr.writeln('seed requires --metadb-json (from tools/export_metadb.py)');
        return 2;
      }
      final metadb = loadMetadbIndex(metadbJson);
      final result = buildSeedManifest(
        scan: scan,
        metadb: metadb,
        // FileStat.changed is the creation time on Windows.
        ctimeOf: (rel) =>
            File(p.join(root.path, rel)).statSync().changed.toUtc(),
      );

      final playlistsDir = args['playlists'] as String?;
      final unmatchedTotal = <String, List<String>>{};
      if (playlistsDir != null) {
        final basenameToId = <String, String>{
          for (final t in scan) p.basename(t.relPath).toLowerCase(): t.contentId,
        };
        final txts = Directory(playlistsDir)
            .listSync()
            .whereType<File>()
            .where((f) => p.extension(f.path).toLowerCase() == '.txt');
        for (final f in txts) {
          final r = importTxtPlaylist(
              p.basenameWithoutExtension(f.path), f.readAsLinesSync(), basenameToId);
          result.manifest.playlists.add(r.playlist);
          if (r.unmatched.isNotEmpty) unmatchedTotal[r.playlist.name] = r.unmatched;
        }
      }

      result.report.forEach(stdout.writeln);
      for (final e in unmatchedTotal.entries) {
        stdout.writeln('playlist "${e.key}": ${e.value.length} unmatched lines');
        e.value.take(5).forEach((l) => stdout.writeln('    $l'));
      }
      stdout.writeln('playlists imported: ${result.manifest.playlists.length}');

      if (args['apply'] as bool) {
        await saveManifest(result.manifest, root);
        stdout.writeln('manifest written to ${manifestFile.path}');
      } else {
        stdout.writeln('dry run — pass --apply to write.');
      }
      return 0;

    default:
      stderr.writeln('unknown command: $cmd');
      return 2;
  }
}
```

- [ ] **Step 2: Run the full test suite**

Run (from `core/`): `dart test`
Expected: `All tests passed!`

- [ ] **Step 3: Smoke-test the CLI on a temp folder**

Run (from `core/`):
```
mkdir %TEMP%\foolib-smoke 2>NUL & copy /Y NUL %TEMP%\foolib-smoke\t.mp3 >NUL
dart run fooplayer_core:foolib status --root %TEMP%\foolib-smoke
```
(or the PowerShell/bash equivalent). Expected: scan report with `scanned 1 audio files`, `new tracks : 1`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add core/bin/foolib.dart
git commit -m "feat: foolib CLI with status, update, and seed commands"
```

- [ ] **Step 5: Export the real metadb and dry-run the real seed** (read-only — no `--apply`)

Run (from `core/`):
```
python tools/export_metadb.py "L:\APPS\foobar [custom config files]\config backup\metadb.sqlite" tools/metadb_dates.json
dart run fooplayer_core:foolib seed --root "L:\music (original structure)" --metadb-json tools/metadb_dates.json --playlists "L:\music (original structure)"
```
Expected: first full scan hashes ~13.5k files (68 GB — this takes a while; subsequent runs are cache-fast), then a seed report with `tracks:` ≈ 13.5k, `from metadb:` in the ~4–5k range, oldest/newest samples, and playlist import results for the `.txt` files in the library root.

- [ ] **Step 6: USER CHECKPOINT — stop and present the dry-run report**

Show the user the seed report (counts, oldest/newest samples, unmatched playlist lines). Remind them: `restore_ctimes.py --apply --fuzzy` has **not** been run yet (deferred 2026-07-23); files not covered by the metadb backup will get their current (possibly clobbered) ctimes as `date_added`. The user decides whether to run the ctime restore first, and when to run seed with `--apply`. **Do not run `seed --apply` without their explicit go-ahead.**

- [ ] **Step 7: After user approval, apply and verify**

Run (from `core/`):
```
dart run fooplayer_core:foolib seed --root "L:\music (original structure)" --metadb-json tools/metadb_dates.json --playlists "L:\music (original structure)" --apply
dart run fooplayer_core:foolib status --root "L:\music (original structure)"
```
Expected: manifest written; `status` then reports `new tracks : 0`, `missing files : 0`.

- [ ] **Step 8: Final commit**

```bash
git add -A
git commit -m "chore: complete core engine plan — real library seeded"
```

---

## Out of scope for this plan

- Flutter apps, UI, playback (Plan 2)
- LAN pull / HTTP sync (Plan 3)
- Play counts, tag editing, theming (spec: out of v1 entirely)
