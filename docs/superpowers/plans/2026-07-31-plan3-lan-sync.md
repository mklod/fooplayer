# Plan 3 — LAN Library Sync + Synced Playlists — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Playlists live in a shared `.playlists/` sidecar directory synced across all devices, and the Android app gains a one-button SMB pull that mirrors chosen NAS roots (files + manifests + artwork sidecars) with dates preserved.

**Architecture:** Pure-Dart sidecar/reconcile/planner logic in `fooplayer_core` (fixture-testable, no I/O beyond local files); a `SyncTransport` interface in the app with a local-directory fake for integration tests and a Kotlin/SMBJ platform-channel implementation for the real NAS; a `SyncEngine` orchestrating plan → execute → verify → adopt → rescan → report. Desktop needs no transport — it reads/writes the NAS live over `L:`.

**Tech Stack:** Dart/Flutter (existing), Kotlin platform channel, SMBJ (`com.hierynomus:smbj`, Gradle — the ONLY new dependency; no new pub packages).

**Spec:** `docs/superpowers/specs/2026-07-31-plan3-sync-design.md` — read it first; decisions there are settled (NAS-direct SMB, per-root opt-in, mirrored deletions, whole-playlist LWW + backup, auto playlist reconcile / manual music transfer).

## Global Constraints

- **Worktree:** Flutter cannot run on `L:` (SMB can't host plugin symlinks). Create worktree `C:\dev\fooplayer-plan3` on new branch `plan3-sync` off `main` (Task 1 Step 0). All build/test commands run there. Commit + push after every task.
- **Test commands:** core: `dart test` in `core/`; app: `flutter test` in `app/`; `flutter analyze` must show no NEW issues (2 pre-existing style hints in test files are accepted).
- **Manifest schema stays 1.** Never bump it; `Manifest.fromJson` throws on anything else and both apps enforce it.
- **Parse discipline:** manifests are strict (throw), sidecars are tolerant (skip + report, never throw) — same split the artwork sidecar already uses.
- **Never sync:** `.hash_cache.json` (device-local semantics), `.sync_state.json`, `.sync_tmp/`, `.playlists/backup/` (backups stay on the side that made them).
- **Timestamps:** every touched source file updates its `// Last modified:` header comment. NEVER guess the time — run `powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd--HHmm'"`.
- **UI reskin is parked:** add new controls only; do not move or restyle existing ones.
- **Content ID is the join key everywhere.** It hashes audio bytes only (`core/lib/src/content_id.dart`) — retagging never changes it.
- Commit messages: `feat(sync): ...` / `feat(playlists): ...` / `test: ...`, why-focused, per the repo's convention.

## File Structure (locked in)

```
core/lib/src/playlist_sidecar.dart      NEW  sidecar model + IO + tombstones + backups
core/lib/src/playlist_reconcile.dart    NEW  pure LWW reconciler (state × state → actions)
core/lib/src/sync_plan.dart             NEW  RemoteFile/SyncState/planRootSync (pure planner)
core/lib/fooplayer_core.dart            MOD  export the three files above
core/test/playlist_sidecar_test.dart    NEW
core/test/playlist_reconcile_test.dart  NEW
core/test/sync_plan_test.dart           NEW

app/lib/model/library_home.dart         NEW  resolveLibraryHome() + deviceLabel()
app/lib/model/playlist_migration.dart   NEW  one-time manifest→sidecar migration
app/lib/model/playlist_store.dart       MOD  CRUD retargeted to sidecar
app/lib/model/manifest_io.dart          MOD  ManifestPlaylist gains `id`
app/lib/model/library_model.dart        MOD  libraryHome field; reloadPlaylists + load-merge read sidecar
app/lib/model/activity_model.dart       MOD  ActivityIds.sync
app/lib/sync/sync_transport.dart        NEW  SyncTransport interface + LocalDirTransport
app/lib/sync/smb_transport.dart         NEW  platform-channel-backed transport (Android)
app/lib/sync/playlist_reconciler.dart   NEW  executes reconcile actions via transport + scheduler
app/lib/sync/sync_settings.dart         NEW  config model under raw key "sync"
app/lib/sync/sync_engine.dart           NEW  orchestration + SyncReport
app/lib/ui/sync_view.dart               NEW  settings UI + Sync button + report dialog
app/lib/ui/settings_dialog.dart         MOD  forward onSetUpRoot (pre-existing bug) + Sync… entry (Android)
app/lib/ui/phone/phone_settings_view.dart MOD  Sync page entry
app/lib/main.dart                       MOD  home resolution, migration call, scheduler wiring
app/test/... (see per-task Test entries)

app/android/app/src/main/kotlin/dev/mklod/fooplayer_app/SmbBridge.kt  NEW
app/android/app/src/main/kotlin/dev/mklod/fooplayer_app/MainActivity.kt MOD register bridge
app/android/app/build.gradle.kts        MOD  SMBJ dependency
app/android/app/src/main/AndroidManifest.xml MOD explicit INTERNET permission
```

---

## Phase 1 — Playlist sidecar (Tasks 1–5). Deliverable: playlists live in `.playlists/`, desktop-synced by construction.

### Task 1: Core playlist sidecar model + IO

**Files:**
- Create: `core/lib/src/playlist_sidecar.dart`
- Modify: `core/lib/fooplayer_core.dart` (add `export 'src/playlist_sidecar.dart';`)
- Test: `core/test/playlist_sidecar_test.dart`

**Interfaces:**
- Consumes: nothing new (dart:io, dart:convert, dart:math).
- Produces (later tasks rely on these exact names):
  - `const playlistsDirName = '.playlists'`, `playlistTombstonesFileName = 'tombstones.json'`, `playlistBackupDirName = 'backup'`
  - `class PlaylistFile { final String id; String name; List<String> trackIds; DateTime created; DateTime modified; String modifiedBy; Map<String,dynamic> toJson(); static PlaylistFile? fromJson(Map<String,dynamic>); bool sameContentAs(PlaylistFile); }`
  - `class PlaylistTombstone { final DateTime deleted; final String name; }`
  - `class PlaylistSidecarState { final Map<String,PlaylistFile> playlists; final Map<String,PlaylistTombstone> tombstones; final List<String> corruptFiles; }`
  - `PlaylistSidecarState loadPlaylistsDir(Directory home)` (sync, tolerant)
  - `Future<void> savePlaylistFile(Directory home, PlaylistFile p)` (atomic)
  - `Future<void> saveTombstones(Directory home, Map<String,PlaylistTombstone> t)` (atomic)
  - `Future<void> backupPlaylistFile(Directory home, PlaylistFile p, DateTime now)`
  - `Future<void> removePlaylistFile(Directory home, String id)`
  - `String newPlaylistId([Random? rng])` → `p_` + 8 lowercase hex chars

- [ ] **Step 0: Create the worktree** (one-time, whole plan works here)

```powershell
git -C L:\PROJECTS\fooplayer worktree add C:\dev\fooplayer-plan3 -b plan3-sync main
cd C:\dev\fooplayer-plan3\core; dart pub get; cd ..\app; flutter pub get
```

- [ ] **Step 1: Write the failing tests**

```dart
// core/test/playlist_sidecar_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('plsc'));
  tearDown(() => home.deleteSync(recursive: true));

  PlaylistFile pf(String id, String name, List<String> ids, String mod) =>
      PlaylistFile(id: id, name: name, trackIds: ids,
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse(mod), modifiedBy: 'test');

  test('save then load round-trips a playlist file', () async {
    final p = pf('p_00000001', 'roadtrip', ['id-a', 'id-b'], '2026-07-31T12:00:00Z');
    await savePlaylistFile(home, p);
    final state = loadPlaylistsDir(home);
    expect(state.playlists.keys, ['p_00000001']);
    final got = state.playlists['p_00000001']!;
    expect(got.name, 'roadtrip');
    expect(got.trackIds, ['id-a', 'id-b']);
    expect(got.modified, DateTime.parse('2026-07-31T12:00:00Z'));
    expect(got.created, DateTime.parse('2026-07-01T00:00:00Z'));
    expect(got.modifiedBy, 'test');
  });

  test('loadPlaylistsDir on a home with no .playlists dir is empty, not an error', () {
    final state = loadPlaylistsDir(home);
    expect(state.playlists, isEmpty);
    expect(state.tombstones, isEmpty);
    expect(state.corruptFiles, isEmpty);
  });

  test('a corrupt playlist file is skipped and reported, never thrown', () async {
    await savePlaylistFile(home, pf('p_00000001', 'ok', [], '2026-07-31T12:00:00Z'));
    final dir = Directory('${home.path}/$playlistsDirName');
    File('${dir.path}/p_bad.json').writeAsStringSync('{not json');
    File('${dir.path}/p_wrongshape.json').writeAsStringSync('{"schema":1,"id":42}');
    final state = loadPlaylistsDir(home);
    expect(state.playlists.keys, ['p_00000001']);
    expect(state.corruptFiles, unorderedEquals(['p_bad.json', 'p_wrongshape.json']));
  });

  test('missing created falls back to modified (older writers)', () {
    final j = {'schema': 1, 'id': 'p_x', 'name': 'n', 'track_ids': <String>[],
               'modified': '2026-07-31T12:00:00Z', 'modified_by': 'd'};
    final p = PlaylistFile.fromJson(j)!;
    expect(p.created, p.modified);
  });

  test('unknown keys are tolerated (forward compatibility)', () {
    final j = {'schema': 1, 'id': 'p_x', 'name': 'n', 'track_ids': <String>[],
               'modified': '2026-07-31T12:00:00Z', 'future_key': {'a': 1}};
    expect(PlaylistFile.fromJson(j), isNotNull);
  });

  test('save is atomic: tmp file never left behind, second save replaces', () async {
    final p = pf('p_00000001', 'v1', [], '2026-07-31T12:00:00Z');
    await savePlaylistFile(home, p);
    p.name = 'v2';
    await savePlaylistFile(home, p);
    final dir = Directory('${home.path}/$playlistsDirName');
    expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    expect(loadPlaylistsDir(home).playlists['p_00000001']!.name, 'v2');
  });

  test('tombstones round-trip and tolerate a corrupt file', () async {
    await saveTombstones(home, {
      'p_dead': PlaylistTombstone(
          deleted: DateTime.parse('2026-07-30T00:00:00Z'), name: 'old mix'),
    });
    var state = loadPlaylistsDir(home);
    expect(state.tombstones['p_dead']!.name, 'old mix');
    File('${home.path}/$playlistsDirName/$playlistTombstonesFileName')
        .writeAsStringSync('garbage');
    state = loadPlaylistsDir(home);
    expect(state.tombstones, isEmpty); // degraded, not thrown
  });

  test('backupPlaylistFile writes a timestamped snapshot under backup/', () async {
    final p = pf('p_00000001', 'keep me', ['x'], '2026-07-31T12:00:00Z');
    await backupPlaylistFile(home, p, DateTime.parse('2026-07-31T13:14:15Z'));
    final backups = Directory('${home.path}/$playlistsDirName/$playlistBackupDirName')
        .listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(backups, ['p_00000001--20260731-131415.json']);
    final j = jsonDecode(File(
        '${home.path}/$playlistsDirName/$playlistBackupDirName/${backups.single}')
        .readAsStringSync()) as Map<String, dynamic>;
    expect(j['name'], 'keep me');
  });

  test('removePlaylistFile deletes the file and is idempotent', () async {
    await savePlaylistFile(home, pf('p_00000001', 'x', [], '2026-07-31T12:00:00Z'));
    await removePlaylistFile(home, 'p_00000001');
    await removePlaylistFile(home, 'p_00000001'); // second call: no throw
    expect(loadPlaylistsDir(home).playlists, isEmpty);
  });

  test('newPlaylistId shape and seeded determinism', () {
    expect(newPlaylistId(Random(1)), matches(RegExp(r'^p_[0-9a-f]{8}$')));
    expect(newPlaylistId(Random(1)), newPlaylistId(Random(1)));
  });

  test('sameContentAs compares name and ordered trackIds only', () {
    final a = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z');
    final b = pf('p_2', 'n', ['x', 'y'], '2026-01-01T00:00:00Z');
    expect(a.sameContentAs(b), isTrue);
    b.trackIds = ['y', 'x'];
    expect(a.sameContentAs(b), isFalse); // order matters: playlists are ordered
  });
}
```

- [ ] **Step 2: Run to verify failure** — `dart test test/playlist_sidecar_test.dart` in `core/`. Expected: compile errors (`playlist_sidecar.dart` doesn't exist).

- [ ] **Step 3: Implement**

```dart
// core/lib/src/playlist_sidecar.dart
// Last modified: <real timestamp>
//
// The playlist sidecar: one JSON file per playlist in <library home>/.playlists/,
// membership by content ID. Tolerant parse (artwork-sidecar discipline, NOT the
// manifest's strict throw): a corrupt file degrades to "skipped + reported".
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const playlistsDirName = '.playlists';
const playlistTombstonesFileName = 'tombstones.json';
const playlistBackupDirName = 'backup';

class PlaylistFile {
  final String id;
  String name;
  List<String> trackIds;
  DateTime created;   // sidebar sort order: "the order I made them"
  DateTime modified;  // UTC; the LWW clock
  String modifiedBy;  // device label, for the report ("kept tablet's version")

  PlaylistFile({required this.id, required this.name, required this.trackIds,
      required this.created, required this.modified, required this.modifiedBy});

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'id': id,
        'name': name,
        'track_ids': trackIds,
        'created': created.toUtc().toIso8601String(),
        'modified': modified.toUtc().toIso8601String(),
        'modified_by': modifiedBy,
      };

  /// Tolerant: null on anything unusable. Unknown keys ignored; missing
  /// `created` falls back to `modified` (older writers).
  static PlaylistFile? fromJson(Map<String, dynamic> j) {
    final id = j['id'], name = j['name'], ids = j['track_ids'];
    if (id is! String || id.isEmpty || name is! String || ids is! List) {
      return null;
    }
    DateTime? parseTime(Object? v) {
      if (v is! String) return null;
      try {
        return DateTime.parse(v).toUtc();
      } catch (_) {
        return null;
      }
    }
    final modified = parseTime(j['modified']);
    if (modified == null) return null;
    return PlaylistFile(
      id: id,
      name: name,
      trackIds: ids.whereType<String>().toList(),
      created: parseTime(j['created']) ?? modified,
      modified: modified,
      modifiedBy: j['modified_by'] is String ? j['modified_by'] as String : '',
    );
  }

  /// Same user-visible content: name + ordered membership. Timestamps and
  /// authorship excluded — two devices writing the identical edit should
  /// reconcile to "nothing to do", not to a copy.
  bool sameContentAs(PlaylistFile other) {
    if (name != other.name || trackIds.length != other.trackIds.length) {
      return false;
    }
    for (var i = 0; i < trackIds.length; i++) {
      if (trackIds[i] != other.trackIds[i]) return false;
    }
    return true;
  }
}

class PlaylistTombstone {
  final DateTime deleted; // UTC
  final String name;      // for the report; the file is gone by then
  PlaylistTombstone({required this.deleted, required this.name});

  Map<String, dynamic> toJson() =>
      {'deleted': deleted.toUtc().toIso8601String(), 'name': name};

  static PlaylistTombstone? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final del = j['deleted'];
    if (del is! String) return null;
    final DateTime deleted;
    try {
      deleted = DateTime.parse(del).toUtc();
    } catch (_) {
      return null;
    }
    return PlaylistTombstone(deleted: deleted, name: name is String ? name : '');
  }
}

class PlaylistSidecarState {
  final Map<String, PlaylistFile> playlists;      // by id
  final Map<String, PlaylistTombstone> tombstones; // by id
  final List<String> corruptFiles;                 // basenames, for the report
  PlaylistSidecarState(this.playlists, this.tombstones, this.corruptFiles);
}

Directory _dirIn(Directory home) => Directory('${home.path}/$playlistsDirName');

/// Tolerant load of `<home>/.playlists/`: missing dir → empty state; a corrupt
/// playlist or tombstones file is skipped and listed in [corruptFiles].
PlaylistSidecarState loadPlaylistsDir(Directory home) {
  final dir = _dirIn(home);
  final playlists = <String, PlaylistFile>{};
  final corrupt = <String>[];
  var tombstones = <String, PlaylistTombstone>{};
  if (!dir.existsSync()) {
    return PlaylistSidecarState(playlists, tombstones, corrupt);
  }
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File || !e.path.endsWith('.json')) continue;
    final base = e.uri.pathSegments.last;
    if (base == playlistTombstonesFileName) {
      tombstones = _loadTombstones(e, corrupt);
      continue;
    }
    if (base.endsWith('.tmp')) continue;
    PlaylistFile? p;
    try {
      final j = jsonDecode(e.readAsStringSync());
      if (j is Map<String, dynamic>) p = PlaylistFile.fromJson(j);
    } catch (_) {}
    if (p == null) {
      corrupt.add(base);
    } else {
      playlists[p.id] = p;
    }
  }
  return PlaylistSidecarState(playlists, tombstones, corrupt);
}

Map<String, PlaylistTombstone> _loadTombstones(File f, List<String> corrupt) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    final raw = (j as Map<String, dynamic>)['tombstones'];
    if (raw is Map<String, dynamic>) {
      final out = <String, PlaylistTombstone>{};
      raw.forEach((id, v) {
        if (v is Map<String, dynamic>) {
          final t = PlaylistTombstone.fromJson(v);
          if (t != null) out[id] = t;
        }
      });
      return out;
    }
  } catch (_) {}
  corrupt.add(playlistTombstonesFileName);
  return {};
}

Future<void> _atomicWrite(File target, String content) async {
  target.parent.createSync(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(content);
  if (target.existsSync()) target.deleteSync(); // Windows rename won't overwrite
  tmp.renameSync(target.path);
}

Future<void> savePlaylistFile(Directory home, PlaylistFile p) => _atomicWrite(
    File('${_dirIn(home).path}/${p.id}.json'),
    const JsonEncoder.withIndent('  ').convert(p.toJson()));

Future<void> saveTombstones(
        Directory home, Map<String, PlaylistTombstone> t) =>
    _atomicWrite(
        File('${_dirIn(home).path}/$playlistTombstonesFileName'),
        const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'tombstones': t.map((k, v) => MapEntry(k, v.toJson())),
        }));

/// `backup/<id>--YYYYMMDD-HHMMSS.json` — the LWW loser / deleted playlist.
Future<void> backupPlaylistFile(
    Directory home, PlaylistFile p, DateTime now) async {
  final u = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${u.year}${two(u.month)}${two(u.day)}'
      '-${two(u.hour)}${two(u.minute)}${two(u.second)}';
  await _atomicWrite(
      File('${_dirIn(home).path}/$playlistBackupDirName/${p.id}--$stamp.json'),
      const JsonEncoder.withIndent('  ').convert(p.toJson()));
}

Future<void> removePlaylistFile(Directory home, String id) async {
  final f = File('${_dirIn(home).path}/$id.json');
  if (f.existsSync()) f.deleteSync();
}

String newPlaylistId([Random? rng]) {
  final r = rng ?? Random.secure();
  return 'p_${List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join()}';
}
```

Add to `core/lib/fooplayer_core.dart`: `export 'src/playlist_sidecar.dart';`

- [ ] **Step 4: Run to verify pass** — `dart test test/playlist_sidecar_test.dart`. Expected: all PASS. Then full `dart test` (44 existing + new, all pass).

- [ ] **Step 5: Commit**

```bash
git add core/lib/src/playlist_sidecar.dart core/lib/fooplayer_core.dart core/test/playlist_sidecar_test.dart
git commit -m "feat(playlists): core playlist sidecar - one file per playlist, tombstones, backups"
git push -u origin plan3-sync
```

---

### Task 2: Core LWW reconciler (pure)

**Files:**
- Create: `core/lib/src/playlist_reconcile.dart`
- Modify: `core/lib/fooplayer_core.dart` (export)
- Test: `core/test/playlist_reconcile_test.dart`

**Interfaces:**
- Consumes: `PlaylistFile`, `PlaylistTombstone`, `PlaylistSidecarState` (Task 1).
- Produces:
  - `enum PlaylistSyncOp { copyToLocal, copyToRemote, deleteLocal, deleteRemote, tombstoneToLocal, tombstoneToRemote }`
  - `class PlaylistSyncAction { final PlaylistSyncOp op; final String id; final bool backupFirst; final String note; }`
  - `List<PlaylistSyncAction> reconcilePlaylists(PlaylistSidecarState local, PlaylistSidecarState remote, {required String localLabel, required String remoteLabel})`

**Semantics (spec):** whole-playlist LWW by `modified`; an edit newer than a tombstone resurrects; the overwritten/deleted side is backed up first when its content differs; tombstones flow both ways so deletions propagate; equal timestamps + different content → remote (NAS) wins deterministically, noted.

- [ ] **Step 1: Write the failing tests**

```dart
// core/test/playlist_reconcile_test.dart
import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

void main() {
  PlaylistFile pf(String id, String name, List<String> ids, String mod,
          {String by = 'dev'}) =>
      PlaylistFile(id: id, name: name, trackIds: ids,
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse(mod), modifiedBy: by);
  PlaylistSidecarState state(
          {Map<String, PlaylistFile>? p, Map<String, PlaylistTombstone>? t}) =>
      PlaylistSidecarState(p ?? {}, t ?? {}, []);
  PlaylistTombstone ts(String when, [String name = 'gone']) =>
      PlaylistTombstone(deleted: DateTime.parse(when), name: name);
  List<PlaylistSyncAction> run(PlaylistSidecarState l, PlaylistSidecarState r) =>
      reconcilePlaylists(l, r, localLabel: 'tablet', remoteLabel: 'NAS');

  test('identical sides produce no actions', () {
    final a = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final b = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    expect(run(state(p: {'p_1': a}), state(p: {'p_1': b})), isEmpty);
  });

  test('same content, different timestamps: no copy (idempotent double-sync)', () {
    final a = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final b = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z');
    expect(run(state(p: {'p_1': a}), state(p: {'p_1': b})), isEmpty);
  });

  test('local newer wins: copyToRemote with backup', () {
    final l = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z', by: 'tablet');
    final r = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z', by: 'desktop');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts, hasLength(1));
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
    expect(acts.single.backupFirst, isTrue);
    expect(acts.single.note, contains('tablet'));
  });

  test('remote newer wins: copyToLocal with backup', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z');
    final r = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts.single.op, PlaylistSyncOp.copyToLocal);
    expect(acts.single.backupFirst, isTrue);
  });

  test('equal timestamps, different content: remote wins deterministically', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final r = pf('p_1', 'n', ['y'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts.single.op, PlaylistSyncOp.copyToLocal);
    expect(acts.single.note, contains('same timestamp'));
  });

  test('local-only playlist with no remote tombstone: new, copyToRemote, no backup', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state());
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
    expect(acts.single.backupFirst, isFalse);
  });

  test('remote tombstone newer than local playlist: deleteLocal with backup + tombstoneToLocal', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T10:00:00Z');
    final acts = run(state(p: {'p_1': l}),
        state(t: {'p_1': ts('2026-07-31T12:00:00Z')}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.deleteLocal, PlaylistSyncOp.tombstoneToLocal]));
    expect(acts.firstWhere((a) => a.op == PlaylistSyncOp.deleteLocal).backupFirst,
        isTrue);
  });

  test('local edit newer than remote tombstone: resurrect (copyToRemote)', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}),
        state(t: {'p_1': ts('2026-07-31T10:00:00Z')}));
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
  });

  test('tombstone only on local side propagates to remote', () {
    final acts = run(state(t: {'p_1': ts('2026-07-31T12:00:00Z')}), state());
    expect(acts.single.op, PlaylistSyncOp.tombstoneToRemote);
  });

  test('remote tombstone deletes a remote-unaware local AND mirrors symmetrically', () {
    // mirror case of deleteLocal: remote has the live playlist, local has the newer tombstone
    final r = pf('p_1', 'n', ['x'], '2026-07-31T10:00:00Z');
    final acts = run(state(t: {'p_1': ts('2026-07-31T12:00:00Z')}),
        state(p: {'p_1': r}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.deleteRemote, PlaylistSyncOp.tombstoneToRemote]));
  });

  test('independent ids on both sides sync both ways', () {
    final l = pf('p_1', 'a', [], '2026-07-31T12:00:00Z');
    final r = pf('p_2', 'b', [], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_2': r}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.copyToRemote, PlaylistSyncOp.copyToLocal]));
  });
}
```

- [ ] **Step 2: Run to verify failure** — compile error (no `playlist_reconcile.dart`).

- [ ] **Step 3: Implement**

```dart
// core/lib/src/playlist_reconcile.dart
// Last modified: <real timestamp>
//
// Pure whole-playlist LWW between two sidecar states. Produces actions; the
// app-side executor does the I/O. Never touches disk itself.
import 'playlist_sidecar.dart';

enum PlaylistSyncOp {
  copyToLocal, copyToRemote,
  deleteLocal, deleteRemote,
  tombstoneToLocal, tombstoneToRemote,
}

class PlaylistSyncAction {
  final PlaylistSyncOp op;
  final String id;
  /// Snapshot the about-to-be-overwritten/deleted side to backup/ first.
  final bool backupFirst;
  /// Human-readable report line ("kept tablet's version of roadtrip ...").
  final String note;
  PlaylistSyncAction(this.op, this.id,
      {this.backupFirst = false, this.note = ''});
}

List<PlaylistSyncAction> reconcilePlaylists(
  PlaylistSidecarState local,
  PlaylistSidecarState remote, {
  required String localLabel,
  required String remoteLabel,
}) {
  final actions = <PlaylistSyncAction>[];
  final ids = <String>{
    ...local.playlists.keys, ...remote.playlists.keys,
    ...local.tombstones.keys, ...remote.tombstones.keys,
  };
  for (final id in ids) {
    final lp = local.playlists[id], rp = remote.playlists[id];
    final lt = local.tombstones[id], rt = remote.tombstones[id];
    // A tombstone only counts against a playlist it postdates; an older
    // tombstone under a re-edited playlist is stale and ignored.
    final localDead = lp == null
        ? lt != null
        : (lt != null && !lt.deleted.isBefore(lp.modified));
    final remoteDead = rp == null
        ? rt != null
        : (rt != null && !rt.deleted.isBefore(rp.modified));

    if (!localDead && lp != null && !remoteDead && rp != null) {
      if (lp.sameContentAs(rp)) continue; // converged, however it happened
      if (lp.modified.isAfter(rp.modified)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToRemote, id,
            backupFirst: true,
            note: 'kept $localLabel\'s version of "${lp.name}"; '
                '$remoteLabel\'s is in backup'));
      } else if (rp.modified.isAfter(lp.modified)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            backupFirst: true,
            note: 'kept $remoteLabel\'s version of "${rp.name}"; '
                '$localLabel\'s is in backup'));
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            backupFirst: true,
            note: 'same timestamp, different content for "${rp.name}" — '
                '$remoteLabel wins (deterministic); $localLabel\'s is in backup'));
      }
      continue;
    }

    if (!localDead && lp != null) {
      // Live locally; remote is dead or absent.
      final tomb = rt ?? lt;
      if (tomb != null && !lp.modified.isAfter(tomb.deleted)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.deleteLocal, id,
            backupFirst: true,
            note: 'deleted "${lp.name}" (removed on $remoteLabel); '
                'copy kept in backup'));
        if (rt != null && (lt == null || rt.deleted.isAfter(lt.deleted))) {
          actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToLocal, id));
        }
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToRemote, id,
            note: tomb == null
                ? 'new playlist "${lp.name}" from $localLabel'
                : 'restored "${lp.name}" — edited on $localLabel after deletion'));
      }
      continue;
    }

    if (!remoteDead && rp != null) {
      final tomb = lt ?? rt;
      if (tomb != null && !rp.modified.isAfter(tomb.deleted)) {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.deleteRemote, id,
            backupFirst: true,
            note: 'deleted "${rp.name}" on $remoteLabel (removed on $localLabel); '
                'copy kept in backup'));
        if (lt != null && (rt == null || lt.deleted.isAfter(rt.deleted))) {
          actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToRemote, id));
        }
      } else {
        actions.add(PlaylistSyncAction(PlaylistSyncOp.copyToLocal, id,
            note: tomb == null
                ? 'new playlist "${rp.name}" from $remoteLabel'
                : 'restored "${rp.name}" — edited on $remoteLabel after deletion'));
      }
      continue;
    }

    // Dead (or tombstone-only) on both sides: converge tombstones newest-first.
    if (lt != null && (rt == null || lt.deleted.isAfter(rt.deleted))) {
      actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToRemote, id));
    } else if (rt != null && (lt == null || rt.deleted.isAfter(lt.deleted))) {
      actions.add(PlaylistSyncAction(PlaylistSyncOp.tombstoneToLocal, id));
    }
  }
  return actions;
}
```

Export from `fooplayer_core.dart`.

- [ ] **Step 4: Run to verify pass** — `dart test test/playlist_reconcile_test.dart`, then full `dart test`.

- [ ] **Step 5: Commit** — `git commit -m "feat(playlists): pure LWW reconciler with tombstones, backups, resurrect-on-edit"` + push.

---

### Task 3: Library home resolution + device label (app)

**Files:**
- Create: `app/lib/model/library_home.dart`
- Test: `app/test/library_home_test.dart`

**Interfaces:**
- Consumes: `package:path` only.
- Produces:
  - `String? resolveLibraryHome(List<String> rootPaths, {String? override})` — override wins verbatim; else the deepest common parent directory of all roots; null when roots is empty or no common parent exists (different drives).
  - `String deviceLabel(Map<String, dynamic> configRaw)` — config raw key `deviceName` if a non-empty string, else `Platform.localHostname`.

- [ ] **Step 1: Write the failing tests**

```dart
// app/test/library_home_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_home.dart';

void main() {
  test('override wins verbatim', () {
    expect(resolveLibraryHome([r'C:\a\b'], override: r'D:\home'), r'D:\home');
  });
  test('single root: home is its parent', () {
    expect(resolveLibraryHome([r'L:\music (original structure)\monthly']),
        r'L:\music (original structure)');
  });
  test('five siblings share their parent', () {
    expect(
      resolveLibraryHome([
        r'L:\music (original structure)\monthly',
        r'L:\music (original structure)\albums',
        r'L:\music (original structure)\loose tracks - old',
      ]),
      r'L:\music (original structure)',
    );
  });
  test('nested roots resolve to the shallower parent', () {
    expect(resolveLibraryHome([r'C:\m\a', r'C:\m\sub\b']), r'C:\m');
  });
  test('android-style forward-slash roots', () {
    expect(
      resolveLibraryHome(['/storage/emulated/0/Music/loose tracks - 2020 and later']),
      '/storage/emulated/0/Music',
    );
  });
  test('no common parent (different drives) is null', () {
    expect(resolveLibraryHome([r'C:\a', r'D:\b']), isNull);
  });
  test('empty roots is null', () {
    expect(resolveLibraryHome([]), isNull);
  });
  test('deviceLabel prefers config deviceName', () {
    expect(deviceLabel({'deviceName': 'tablet-s9'}), 'tablet-s9');
    expect(deviceLabel({'deviceName': ''}), isNotEmpty); // falls back to hostname
    expect(deviceLabel({}), isNotEmpty);
  });
}
```

- [ ] **Step 2: Run to verify failure** — `flutter test test/library_home_test.dart` in `app/`. Compile error.

- [ ] **Step 3: Implement**

```dart
// app/lib/model/library_home.dart
// Last modified: <real timestamp>
import 'dart:io';
import 'package:path/path.dart' as p;

/// Where `.playlists/` lives: [override] (config key `libraryHome`) verbatim,
/// else the deepest directory that is an ancestor-or-parent of every root.
/// Null when that doesn't exist — callers refuse playlist writes with a clear
/// message rather than guessing.
String? resolveLibraryHome(List<String> rootPaths, {String? override}) {
  if (override != null && override.isNotEmpty) return override;
  if (rootPaths.isEmpty) return null;
  var common = p.dirname(rootPaths.first);
  for (final root in rootPaths.skip(1)) {
    var candidate = p.dirname(root);
    while (!p.equals(candidate, common) &&
        !p.isWithin(common, candidate) &&
        !p.isWithin(candidate, common)) {
      final up = p.dirname(common);
      if (p.equals(up, common)) return null; // hit the filesystem root
      common = up;
    }
    if (p.isWithin(common, candidate)) {
      // candidate is deeper — common already covers it
    } else if (p.isWithin(candidate, common)) {
      common = candidate;
    }
  }
  return common;
}

/// Who signs `modified_by` in playlist files. Config `deviceName` if set,
/// else the OS hostname — good enough to tell tablet from desktop in reports.
String deviceLabel(Map<String, dynamic> configRaw) {
  final name = configRaw['deviceName'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  return Platform.localHostname;
}
```

- [ ] **Step 4: Run to verify pass**, then full `flutter test`.

- [ ] **Step 5: Commit** — `git commit -m "feat(playlists): library-home resolution (common parent + override) and device label"` + push.

---

### Task 4: Manifest → sidecar migration (one-time, idempotent)

**Files:**
- Create: `app/lib/model/playlist_migration.dart`
- Test: `app/test/playlist_migration_test.dart`

**Interfaces:**
- Consumes: `core.loadManifest`, `core.saveManifest`, Task 1 sidecar IO, `core.Playlist`.
- Produces: `Future<List<String>> migratePlaylistsToSidecar({required List<Directory> roots, required Directory home, required String device, DateTime Function()? now, Random? rng})` → report lines (empty list = nothing to migrate). Called from `main.dart` before the first `load()` (Task 5).

**Rules (spec):** for every root manifest with a non-empty `playlists` array: write each playlist as a sidecar file (fresh id, `created`/`modified` = now, `modifiedBy` = device) unless the sidecar already holds one with identical (name, ordered trackIds) — then skip. Same name but different content imports under `"name (2)"`. After all sidecar writes for a root succeed, clear that root's manifest `playlists` array and save (schema stays 1). Roots with missing/corrupt manifests are skipped. Run-twice = no-op.

- [ ] **Step 1: Write the failing tests**

```dart
// app/test/playlist_migration_test.dart
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:fooplayer_app/model/playlist_migration.dart';

void main() {
  late Directory home, rootA, rootB;
  final t0 = DateTime.parse('2026-07-31T12:00:00Z');

  setUp(() {
    home = Directory.systemTemp.createTempSync('mig');
    rootA = Directory('${home.path}/rootA')..createSync();
    rootB = Directory('${home.path}/rootB')..createSync();
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> seedManifest(Directory root, List<core.Playlist> pls) =>
      core.saveManifest(
          core.Manifest(schema: 1, tracks: {}, playlists: pls), root);

  Future<List<String>> run() => migratePlaylistsToSidecar(
      roots: [rootA, rootB], home: home, device: 'test',
      now: () => t0, rng: Random(7));

  test('moves manifest playlists into the sidecar and empties the array', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await seedManifest(rootB, []);
    final notes = await run();
    expect(notes, isNotEmpty);
    final state = core.loadPlaylistsDir(home);
    expect(state.playlists.values.map((p) => p.name), ['mix']);
    expect(state.playlists.values.single.trackIds, ['x']);
    expect(core.loadManifest(rootA).playlists, isEmpty);
  });

  test('running twice is a no-op', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    final second = await run();
    expect(second, isEmpty);
    expect(core.loadPlaylistsDir(home).playlists, hasLength(1));
  });

  test('two devices with identical manifests dedupe by (name, trackIds)', () async {
    // Device 2's manifest copy still carries the playlist after device 1 migrated.
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    final notes = await run();
    expect(notes.single, contains('already'));
    expect(core.loadPlaylistsDir(home).playlists, hasLength(1));
  });

  test('same name, different content imports with a suffix', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['x'])]);
    await run();
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: ['y'])]);
    await run();
    final names = core.loadPlaylistsDir(home).playlists.values.map((p) => p.name);
    expect(names, unorderedEquals(['mix', 'mix (2)']));
  });

  test('a root with no manifest is skipped without error', () async {
    await seedManifest(rootA, [core.Playlist(name: 'mix', trackIds: [])]);
    final rootC = Directory('${home.path}/rootC')..createSync();
    final notes = await migratePlaylistsToSidecar(
        roots: [rootA, rootC], home: home, device: 'test',
        now: () => t0, rng: Random(7));
    expect(notes, isNotEmpty);
  });
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

```dart
// app/lib/model/playlist_migration.dart
// Last modified: <real timestamp>
//
// One-time move of playlists out of each root's .library.json into the
// shared .playlists/ sidecar. Idempotent: identical (name, trackIds) pairs
// already in the sidecar are skipped, so the second device to update (whose
// manifest copy still carries the array) migrates to a no-op.
import 'dart:io';
import 'dart:math';
import 'package:fooplayer_core/fooplayer_core.dart' as core;
import 'package:path/path.dart' as p;

Future<List<String>> migratePlaylistsToSidecar({
  required List<Directory> roots,
  required Directory home,
  required String device,
  DateTime Function()? now,
  Random? rng,
}) async {
  final clock = now ?? () => DateTime.now().toUtc();
  final notes = <String>[];
  var state = core.loadPlaylistsDir(home);

  bool alreadyThere(core.Playlist pl) => state.playlists.values.any((existing) {
        if (existing.name != pl.name ||
            existing.trackIds.length != pl.trackIds.length) {
          return false;
        }
        for (var i = 0; i < pl.trackIds.length; i++) {
          if (existing.trackIds[i] != pl.trackIds[i]) return false;
        }
        return true;
      });

  String freeName(String name) {
    final used = state.playlists.values.map((e) => e.name).toSet();
    if (!used.contains(name)) return name;
    var n = 2;
    while (used.contains('$name ($n)')) n++;
    return '$name ($n)';
  }

  for (final root in roots) {
    if (!File(p.join(root.path, core.manifestFileName)).existsSync()) continue;
    final core.Manifest manifest;
    try {
      manifest = core.loadManifest(root);
    } catch (_) {
      continue; // corrupt: load() reports it; migration must not crash startup
    }
    if (manifest.playlists.isEmpty) continue;

    for (final pl in manifest.playlists) {
      if (alreadyThere(pl)) {
        notes.add('"${pl.name}" already in the sidecar — skipped');
        continue;
      }
      final t = clock();
      final file = core.PlaylistFile(
        id: core.newPlaylistId(rng),
        name: freeName(pl.name),
        trackIds: List.of(pl.trackIds),
        created: t,
        modified: t,
        modifiedBy: device,
      );
      await core.savePlaylistFile(home, file);
      state = core.loadPlaylistsDir(home); // keep dedupe/name checks current
      notes.add('moved "${file.name}" (${file.trackIds.length} tracks) '
          'from ${p.basename(root.path)} into the sidecar');
    }
    manifest.playlists.clear();
    await core.saveManifest(manifest, root);
  }
  return notes;
}
```

- [ ] **Step 4: Run to verify pass**, then full `flutter test`.

- [ ] **Step 5: Commit** — `git commit -m "feat(playlists): idempotent manifest-to-sidecar migration"` + push.

---

### Task 5: Retarget PlaylistStore + LibraryModel to the sidecar

The riskiest task: playlists change their backing store while every UI surface stays untouched. Existing playlist tests (`app/test/playlist_store_test.dart`, `playlist_ui_test.dart`, `track_list_playlist_view_test.dart`) must be updated to seed a sidecar home instead of manifest playlists — same behaviors asserted, new fixtures.

**Files:**
- Modify: `app/lib/model/manifest_io.dart` (`ManifestPlaylist` gains `final String? id;` constructor param)
- Modify: `app/lib/model/playlist_store.dart` (CRUD → sidecar)
- Modify: `app/lib/model/library_model.dart` (add `String? libraryHome`; `load(..., {String? libraryHome})` remembers it; `reloadPlaylists()` and the `_loadBody` playlist merge both read the sidecar via one shared private helper)
- Modify: `app/lib/main.dart` (compute home via `resolveLibraryHome(libraryRootsPrefs.roots, override: config['libraryHome'] as String?)`, pass to `load`, run `migratePlaylistsToSidecar` before the first load, construct PlaylistStore with `device:` and `onMutated:`)
- Test: update the three playlist test files; add `app/test/playlist_sidecar_store_test.dart` for new behaviors

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces (later tasks rely on):
  - `PlaylistStore({required LibraryModel library, required String device, void Function()? onMutated})` — same public mutation signatures as today: `createPlaylist(String)`, `deletePlaylist(String)`, `addTrack(String, String)`, `removeTrack(String, String)`, `addTracks(String, List<String>) → Future<int>`, `removeTracks(String, List<String>) → Future<int>`, `validateNewPlaylistName(String)`. All throw `PlaylistStoreException` with user-presentable messages. Every successful mutation calls `onMutated?.call()` (the Task 8 scheduler hook) after `library.reloadPlaylists()`.
  - `LibraryModel.libraryHome` (String?, set by `load`), `LibraryModel.reloadPlaylists()` unchanged signature.
  - Merged entries: `ManifestPlaylist(id: ..., name: displayName, trackIds: ..., sourceName: sidecarName)` sorted by sidecar `created` ascending; display-name collisions still get " (2)" suffixes via the existing `_uniquePlaylistName`.

**Implementation notes (the code the engineer writes):**

1. `ManifestPlaylist`: add `final String? id;` to the const constructor (null for legacy fixtures). `rootPath`/`sourceIndex` stay for compatibility but are null for sidecar entries.

2. `LibraryModel`: field `String? libraryHome;`. In `load()`, accept and remember `libraryHome`. Replace the per-root playlist merge inside `_loadBody` (library_model.dart:371-382) and the body of `reloadPlaylists()` (:1873-1903) with one helper:

```dart
List<ManifestPlaylist> _sidecarPlaylists() {
  final home = libraryHome;
  if (home == null) return const [];
  final state = core.loadPlaylistsDir(Directory(home));
  final entries = state.playlists.values.toList()
    ..sort((a, b) {
      final byCreated = a.created.compareTo(b.created);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
  final used = <String>{};
  return [
    for (final p in entries)
      ManifestPlaylist(
        id: p.id,
        name: _uniquePlaylistName(p.name, used),
        trackIds: List.of(p.trackIds),
        sourceName: p.name,
      ),
  ];
}
```

`reloadPlaylists()` becomes: `playlists = _sidecarPlaylists();` plus the existing `activePlaylist` fallback and `notifyListeners()`. The manifest-phase lock around the old merge is no longer needed for playlists (different file); manifests are still merged for tracks under the existing lock.

3. `PlaylistStore` rewrite — drop `_withManifest`/`_acquireBusy`/`_ownedRoot`/`_manifestIndexOf`, `busyRetryEvery/For` params, and the "seed with foolib" manifest check. New core cycle:

```dart
Future<void> _withPlaylist(String displayName,
    void Function(core.PlaylistFile p) mutate) async {
  final entry = _resolveEntry(displayName); // by display name, as today
  final id = entry.id;
  final home = library.libraryHome;
  if (home == null) {
    throw PlaylistStoreException(
        'No library home for playlists — configure library roots first.');
  }
  final state = core.loadPlaylistsDir(Directory(home)); // fresh, never cached
  final p = id == null ? null : state.playlists[id];
  if (p == null) {
    throw PlaylistStoreException(
        'Playlist "$displayName" is no longer present — it may have been '
        'changed outside the app.');
  }
  mutate(p);
  p.modified = DateTime.now().toUtc();
  p.modifiedBy = device;
  await core.savePlaylistFile(Directory(home), p);
  library.reloadPlaylists();
  onMutated?.call();
}
```

`createPlaylist`: validate name (same rules), build `core.PlaylistFile(id: core.newPlaylistId(), name: trimmed, trackIds: [], created/modified: now, modifiedBy: device)`, save, reload, `onMutated`. `deletePlaylist`: resolve entry → load state → `backupPlaylistFile` → merge-write tombstone (`saveTombstones` with existing map + new entry `PlaylistTombstone(deleted: now, name: p.name)`) → `removePlaylistFile` → reload → `onMutated`. Add/remove track(s): via `_withPlaylist`, preserving the set-in-order and return-count semantics documented in the current code.

4. `main.dart`: before the first `reloadLibrary()` call, if home != null run `migratePlaylistsToSidecar(roots: ..., home: Directory(home), device: deviceLabel(config))` inside a try/catch (a failed migration logs and continues — playlists stay in manifests until it succeeds). Pass `libraryHome: home` into `library.load(...)` inside `reloadLibrary` (recompute home from current roots each reload).

- [ ] **Step 1: Write the new-behavior tests** (`app/test/playlist_sidecar_store_test.dart`): create-writes-a-sidecar-file (assert file exists under home, has id/created/modified/modifiedBy), delete-writes-backup-and-tombstone, addTracks-bumps-modified-and-preserves-order, mutation-calls-onMutated, no-home-throws-clear-message, external-edit (file changed on disk between reload and mutate) is picked up because every mutation re-loads fresh.
- [ ] **Step 2: Run to verify the new tests fail.**
- [ ] **Step 3: Implement** per the notes above.
- [ ] **Step 4: Update the three existing playlist test files** — replace manifest-playlist seeding with sidecar seeding (write `PlaylistFile`s into a temp home + pass `libraryHome` to `load`). Assertions stay the same: the point is that UI behavior is unchanged.
- [ ] **Step 5: Full `flutter test` + `flutter analyze`** — all pass, no new analyzer issues.
- [ ] **Step 6: Manual desktop smoke** — run the Windows app from the worktree (`flutter run -d windows` or build + launch): confirm existing playlists appear (migrated), create/add/remove/delete work, `.playlists/` appears in `L:\music (original structure)\`, manifests' `playlists` arrays are now empty.
- [ ] **Step 7: Commit** — `git commit -m "feat(playlists): retarget store+model to the shared sidecar; migrate on startup"` + push.

---

## Phase 2 — Sync engine over a fake transport (Tasks 6–9). Deliverable: a full NAS→phone mirror, integration-tested against local directories.

### Task 6: Core sync planner + sync-state IO

**Files:**
- Create: `core/lib/src/sync_plan.dart`
- Modify: `core/lib/fooplayer_core.dart` (export)
- Test: `core/test/sync_plan_test.dart`

**Interfaces:**
- Consumes: `Manifest` (Task-independent, exists).
- Produces:
  - `class RemoteFile { final String relPath; final int size; final int mtimeMs; }` (relPath forward-slash, relative to the ROOT)
  - `class SyncStateEntry { final int mtimeMs; final int size; }`
  - `class SyncState { final Map<String, SyncStateEntry> entries; static SyncState load(File f); Future<void> save(File f); }` — tolerant load (corrupt → empty), atomic save. File name constant: `const syncStateFileName = '.sync_state.json';` plus `const syncTmpDirName = '.sync_tmp';`
  - `class SyncPlan { final List<RemoteFile> copies; final List<RemoteFile> recopies; final Map<String, String> renames; /* localRelPath → remoteRelPath */ final List<String> deletes; final List<RemoteFile> sidecarCopies; final List<String> adoptions; /* relPaths recorded without copying */ final List<String> unindexedLocal; /* left alone, reported */ int get totalBytes; bool get isEmpty; }`
  - `SyncPlan planRootSync({required Manifest remoteManifest, required List<RemoteFile> remoteListing, required Manifest localManifest, required Set<String> localFiles, required SyncState state})`

**Planner rules (spec §Music sync, made precise):**
- Audio file = extension in `core.audioExtensions`. Sidecar file = `.artwork.json` or path starting `.artwork/`. Excluded everywhere: `.hash_cache.json`, `.library.json`, `.library.json.bak`, `.sync_state.json`, anything under `.sync_tmp/` or `.playlists/` (manifest is staged by the engine, playlists by the reconciler).
- Remote truth = listing ∩ manifest: an audio relPath in the listing whose content ID the remote manifest knows (reverse map path→id). A listed audio file the remote manifest does NOT know is skipped (NAS hasn't indexed it yet — next sync catches it).
- **copy**: remote audio path, not in `localFiles`, and its ID has no local path (per `localManifest`).
- **rename**: remote audio path not in `localFiles`, but its ID maps to a `localFiles` path that no longer exists remotely → `renames[localPath] = remotePath`.
- **recopy**: path in both; `state.entries[relPath]` differs from remote (mtimeMs, size) → recopy. Path in both but NO state entry: if local manifest's ID for that path == remote manifest's ID → **adoption** (record state, no copy — the tablet's hand-seeded 467 files sync in seconds); else recopy.
- **delete**: local audio path (in `localFiles`, known to `localManifest`) whose content ID has no existing remote path → delete. A local file the local manifest doesn't know goes to `unindexedLocal` (left alone, reported) — the mirror never deletes what it never indexed.
- **sidecarCopies**: remote sidecar file with no state entry or a differing one.

- [ ] **Step 1: Write the failing tests** — fixture helpers build manifests/listings inline; cover every rule above plus: empty-everything → `isEmpty`; recopy-on-same-size-different-mtime (the ID3-padding retag case); rename beats copy+delete for a moved file; `.hash_cache.json` in the listing is ignored; unindexed-local never deleted; state round-trip (save→load) and corrupt state file → empty.

```dart
// core/test/sync_plan_test.dart — representative cases (write all listed above)
import 'dart:io';
import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

Manifest mf(Map<String, List<String>> idToPaths) => Manifest(
    schema: 1,
    tracks: idToPaths.map((id, paths) => MapEntry(
        id, TrackEntry(dateAdded: '2026-01-01T00:00:00Z', paths: paths))),
    playlists: []);
RemoteFile rf(String rel, {int size = 100, int mtime = 1000}) =>
    RemoteFile(relPath: rel, size: size, mtimeMs: mtime);

void main() {
  test('new remote file is a copy', () {
    final plan = planRootSync(
      remoteManifest: mf({'idA': ['a.mp3']}),
      remoteListing: [rf('a.mp3')],
      localManifest: mf({}),
      localFiles: {},
      state: SyncState({}),
    );
    expect(plan.copies.map((f) => f.relPath), ['a.mp3']);
    expect(plan.deletes, isEmpty);
  });

  test('retag with unchanged size still recopies (mtime moved)', () {
    final plan = planRootSync(
      remoteManifest: mf({'idA': ['a.mp3']}),
      remoteListing: [rf('a.mp3', size: 100, mtime: 2000)],
      localManifest: mf({'idA': ['a.mp3']}),
      localFiles: {'a.mp3'},
      state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
    );
    expect(plan.recopies.map((f) => f.relPath), ['a.mp3']);
  });

  test('hand-seeded file with matching IDs is adopted, not copied', () {
    final plan = planRootSync(
      remoteManifest: mf({'idA': ['a.mp3']}),
      remoteListing: [rf('a.mp3')],
      localManifest: mf({'idA': ['a.mp3']}),
      localFiles: {'a.mp3'},
      state: SyncState({}),
    );
    expect(plan.adoptions, ['a.mp3']);
    expect(plan.copies, isEmpty);
    expect(plan.recopies, isEmpty);
  });

  test('moved on NAS becomes a local rename, not copy+delete', () {
    final plan = planRootSync(
      remoteManifest: mf({'idA': ['new/a.mp3']}),
      remoteListing: [rf('new/a.mp3')],
      localManifest: mf({'idA': ['old/a.mp3']}),
      localFiles: {'old/a.mp3'},
      state: SyncState({'old/a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
    );
    expect(plan.renames, {'old/a.mp3': 'new/a.mp3'});
    expect(plan.copies, isEmpty);
    expect(plan.deletes, isEmpty);
  });

  test('gone from NAS is a local delete; unindexed local is spared', () {
    final plan = planRootSync(
      remoteManifest: mf({}),
      remoteListing: [],
      localManifest: mf({'idA': ['a.mp3']}),
      localFiles: {'a.mp3', 'stray.mp3'},
      state: SyncState({'a.mp3': SyncStateEntry(mtimeMs: 1000, size: 100)}),
    );
    expect(plan.deletes, ['a.mp3']);
    expect(plan.unindexedLocal, ['stray.mp3']);
  });

  // ...plus: sidecar copy on changed .artwork.json; .hash_cache.json ignored;
  // remote-listed-but-unindexed remote file skipped; isEmpty; totalBytes sums
  // copies+recopies+sidecarCopies; SyncState round-trip + corrupt→empty.
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** — direct transcription of the rules; build `remotePathToId` / `localPathToId` reverse maps from the manifests' `paths` lists, then walk the four sets. `SyncState.load` mirrors `_loadCache` in `scanner.dart` (tolerant); `save` mirrors `_atomicWrite` from Task 1.

- [ ] **Step 4: Run to verify pass** — full `dart test`.

- [ ] **Step 5: Commit** — `git commit -m "feat(sync): pure per-root sync planner + sync-state IO"` + push.

---

### Task 7: SyncTransport interface + LocalDirTransport

**Files:**
- Create: `app/lib/sync/sync_transport.dart`
- Test: `app/test/sync_transport_test.dart`

**Interfaces:**
- Produces:

```dart
abstract class SyncTransport {
  /// Cheap reachability check — false must come back fast (a few seconds).
  Future<bool> probe();
  /// Recursive listing under [relDir] ('' = base). Forward-slash relPaths
  /// RELATIVE TO BASE. Directories omitted; dotfiles INCLUDED (sidecars).
  Future<List<core.RemoteFile>> listTree(String relDir);
  /// Whole small file (manifest, playlist json). Null when absent.
  Future<List<int>?> readFile(String relPath);
  /// Atomic-ish remote write: tmp + rename. Creates parent dirs.
  Future<void> writeFile(String relPath, List<int> bytes);
  /// Stream a large file to [local] (creates parent dirs), reporting bytes.
  Future<void> downloadToFile(String relPath, File local,
      {void Function(int got, int total)? onProgress});
  Future<void> deleteRemote(String relPath);
  Future<void> close();
}
```

- `class LocalDirTransport implements SyncTransport { LocalDirTransport(Directory base); }` — dart:io implementation used by every integration test (and by nothing in production).

- [ ] **Step 1: Write the failing tests** — round-trip each method against a temp dir: listTree returns nested relPaths with sizes+mtimes and includes dotfiles; readFile null on missing; writeFile creates dirs and leaves no `.tmp`; downloadToFile streams bytes and fires onProgress with a final `got == total`; deleteRemote idempotent; probe true for an existing base, false for a missing one.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** (`LocalDirTransport` is ~80 lines of dart:io).
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): SyncTransport interface + local-directory implementation"` + push.

---

### Task 8: Playlist reconciler executor + auto-cadence scheduler

**Files:**
- Create: `app/lib/sync/playlist_reconciler.dart`
- Modify: `app/lib/main.dart` (scheduler wiring, Android only)
- Test: `app/test/playlist_reconciler_test.dart`

**Interfaces:**
- Consumes: Task 2 `reconcilePlaylists`, Task 1 sidecar IO, Task 7 `SyncTransport`.
- Produces:
  - `class PlaylistReconciler { PlaylistReconciler({required Directory localHome, required SyncTransport transport, required String localLabel}); Future<List<String>> run(); }` — remote sidecar dir is `'.playlists'` under the transport base. `run()`: list+read remote `.playlists/*.json` (skip `backup/`), build remote `PlaylistSidecarState` with the same tolerant parse, load local, `reconcilePlaylists`, execute actions (backups on the side being overwritten: local via `backupPlaylistFile`, remote via `writeFile('.playlists/backup/<id>--<stamp>.json', ...)`), merge + write tombstone files on whichever sides changed, return the actions' non-empty notes.
  - `class PlaylistSyncScheduler { PlaylistSyncScheduler({required Future<List<String>> Function() runReconcile, required Future<bool> Function() probe, Duration editDebounce = const Duration(seconds: 3)}); void onAppStart(); void onPlaylistMutated(); void onPeriodicTick(); Future<void> get idle; }` — single-flight (a run in progress absorbs triggers), probe-gated, silent on unreachable. This is what `PlaylistStore.onMutated` points at.
- **Wiring in `main.dart` (Android only):** construct only when `Platform.isAndroid` and sync settings exist (Task 10 provides `SmbTransport`; until then the wiring compiles behind the settings null-check and simply never runs — the LocalDirTransport tests exercise the logic). `onAppStart` after first load; `onPeriodicTick` inside the existing `rescanTimer` callback; `onPlaylistMutated` via PlaylistStore's hook. After any reconcile that returns notes, call `library.reloadPlaylists()`.

- [ ] **Step 1: Write the failing tests** — with `LocalDirTransport` over a temp "NAS" dir and a temp local home: remote-newer flows to local (with local backup written); local-newer flows to remote; local delete propagates (tombstone appears remotely, remote file gone, remote backup written); remote corrupt playlist file skipped with a note; scheduler: mutate-burst debounces to one run, unreachable probe skips silently, overlapping triggers don't double-run (use `fake_async` where timing matters).
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass** — full `flutter test`.
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): playlist reconciler over transport + probe-gated auto scheduler"` + push.

---### Task 9: SyncEngine — plan → execute → verify → adopt → rescan → report

**Files:**
- Create: `app/lib/sync/sync_settings.dart`, `app/lib/sync/sync_engine.dart`
- Modify: `app/lib/model/activity_model.dart` (add `static const sync = 'sync';` to `ActivityIds`)
- Test: `app/test/sync_engine_test.dart`

**Interfaces:**
- Consumes: Tasks 6–8, `core.contentIdForFile`, `core.loadManifest`/`saveManifest`, `LibraryModel.rescan(quiet: true)`, `LibraryModel.tryBeginManifestWrite`/`endManifestWrite`, `ActivityModel`.
- Produces:

```dart
class SyncSettings {
  String host;            // default 'murkyserver'
  String share;           // default 'drop'
  String basePath;        // default 'music (original structure)'
  Map<String, bool> roots; // NAS root folder name -> checked
  static SyncSettings? fromConfig(Map<String, dynamic> raw);   // raw['sync']
  Map<String, dynamic> toJson();
  bool get anyChecked;
}

class SyncFailure { final String relPath; final String reason; }
class RootSyncResult {
  final String rootName;
  final int copied; final int copiedBytes; final int updated;
  final int renamed; final int deleted; final int adopted;
  final List<String> unindexedLocal;
  final List<SyncFailure> failures;
  final bool aborted; final String? abortReason;
}
class SyncReport {
  final List<String> playlistNotes;
  final List<RootSyncResult> roots;
  final DateTime finishedAt;
  bool get hadFailures;
}

class SyncEngine {
  SyncEngine({
    required SyncTransport transport,       // base = SyncSettings.basePath
    required Directory localHome,           // e.g. /storage/emulated/0/Music
    required SyncSettings settings,
    required LibraryModel library,
    required ActivityModel activity,
    required Future<int> Function(String path) freeSpace, // injectable seam
    PlaylistReconciler? reconciler,         // optional so tests can isolate
  });
  Future<SyncReport> run();
  void cancel();                            // stops after the in-flight file
}
```

**`run()` order (spec):** probe (fail → report with abort) → playlist reconcile → for each checked root (remote dir = `<rootName>/`, local dir = `<localHome>/<rootName>/`): read remote `.library.json` via `readFile` (unparseable → abort THIS root, keep going with others) → `listTree(rootName)` → build local inputs (local manifest via `core.loadManifest`, local audio file set via a directory walk with the same exclusions) → `planRootSync` → free-space check (`plan.totalBytes` vs `freeSpace(localDir)`, abort root if short) → execute copies+recopies (download to `<localDir>/.sync_tmp/<basename>`, verify size, verify `core.contentIdForFile` == remote manifest's ID for that path, rename into place — one retry per file, then record a `SyncFailure` and continue; **3 consecutive transport failures = connection lost → abort this root** with `abortReason: 'connection lost'`, reporting what completed) → renames → deletes → sidecarCopies (no hash verify — not audio; size check only) → save updated `SyncState` (successes only) → replace local manifest: parse remote manifest bytes strictly, then `tryBeginManifestWrite` (retry ~5s as PlaylistStore did), `core.saveManifest(parsed, localRoot)`, `endManifestWrite` → progress throughout via `activity.progress(ActivityIds.sync, 'Syncing <root>', done, total)`. After all roots: `library.rescan(quiet: true)`, `activity.finish`, return report. `cancel()` sets a flag checked between files; a cancelled root reports `aborted: true, abortReason: 'cancelled'`.

- [ ] **Step 1: Write the failing integration tests** — two temp dirs ("NAS" via LocalDirTransport, local home), real small files with real content IDs (write a few hundred bytes each; content-ID them with `core.contentIdForFile` when building the NAS manifest so verification passes honestly). Cases: fresh root fully mirrors (copies + manifest replaced + state recorded); second run is a no-op; NAS-side retag (rewrite file bytes, same audio? — simpler: bump mtime + change size) → recopy; NAS-side move → local rename; NAS-side delete → local delete listed in report; corrupted download (make the "NAS" file's manifest ID wrong) → failure recorded, file NOT placed, other files still land; free-space short → root aborted with reason, nothing copied; interrupted then re-run converges (delete `.sync_tmp` leftovers); unparseable remote manifest aborts only that root; a transport whose downloads start throwing (fake that fails everything after file N) → root aborts as 'connection lost' after 3 consecutive failures, report shows what completed.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass** — full `flutter test` + `flutter analyze`.
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): SyncEngine - plan/execute/verify/adopt/report, integration-tested over LocalDirTransport"` + push.

---

## Phase 3 — Android SMB + UI + live verification (Tasks 10–12)

### Task 10: Kotlin SmbBridge (SMBJ) + SmbTransport

**Files:**
- Create: `app/android/app/src/main/kotlin/dev/mklod/fooplayer_app/SmbBridge.kt`
- Modify: `app/android/app/src/main/kotlin/dev/mklod/fooplayer_app/MainActivity.kt` (instantiate + register in `configureFlutterEngine`)
- Modify: `app/android/app/build.gradle.kts` (`dependencies { implementation("com.hierynomus:smbj:0.13.0") }` — check pub for the latest stable at build time; pin whatever builds)
- Modify: `app/android/app/src/main/AndroidManifest.xml` (`<uses-permission android:name="android.permission.INTERNET"/>` — explicit, so release builds don't depend on a plugin's merged manifest)
- Create: `app/lib/sync/smb_transport.dart`

**Interfaces:**
- MethodChannel `dev.mklod.fooplayer/smb`, all calls run on a Kotlin worker thread (never the main thread — SMBJ blocks):
  - `connect {host, share, basePath}` → `handle` (int). Guest auth: `AuthenticationContext.guest()`.
  - `probe {host, share, basePath}` → bool (connect + access base dir, 5s timeout, never throws)
  - `listTree {handle, relDir}` → `List<Map{relPath, size, mtimeMs}>`
  - `readFile {handle, relPath}` → `ByteArray?` (null if absent)
  - `writeFile {handle, relPath, bytes}` → writes `<path>.tmp`, renames over (SMBJ `FileStandardInformation` rename with replace)
  - `downloadToFile {handle, relPath, localPath, taskId}` → bool; streams SMBJ InputStream → local temp file in Kotlin; posts `{taskId, got, total}` every ≥256 KB to EventChannel `dev.mklod.fooplayer/smb-progress`
  - `deleteRemote {handle, relPath}`, `cancel {taskId}`, `close {handle}`, `freeSpace {localPath}` → `android.os.StatFs(path).availableBytes`
- `class SmbTransport implements SyncTransport { SmbTransport({required String host, required String share, required String basePath}); }` — thin Dart mapping; also exposes `static Future<int> freeSpace(String localPath)`.

**Kotlin skeleton the engineer fills (structure, naming, and threading are the contract):**

```kotlin
// SmbBridge.kt
class SmbBridge(messenger: BinaryMessenger) {
    private val executor = Executors.newSingleThreadExecutor()
    private val client = SMBClient()
    private val sessions = ConcurrentHashMap<Int, DiskShare>() // handle -> share
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private var progressSink: EventChannel.EventSink? = null
    // MethodChannel(messenger, "dev.mklod.fooplayer/smb") — every handler:
    // executor.execute { runCatching { ... }.fold(
    //     { v -> post { result.success(v) } },
    //     { e -> post { result.error("smb", e.message, null) } }) }
    // downloadToFile: share.openFile(...).inputStream.copyTo(FileOutputStream(tmp))
    //   with a manual loop that checks cancelled.contains(taskId) and posts
    //   progress; rename tmp -> localPath on success (java.io.File.renameTo).
}
```

- [ ] **Step 1: Dart-side contract test** — `app/test/smb_transport_test.dart` with a mocked MethodChannel (`TestDefaultBinaryMessengerBinding.setMockMethodCallHandler`): each SyncTransport method sends the right method name + args and maps results/nulls/errors correctly. Write, verify fail, implement `smb_transport.dart`, verify pass.
- [ ] **Step 2: Kotlin build check** — `flutter build apk --debug` compiles the bridge (no device needed). Kotlin logic itself is device-verified in Task 12 (house rule: real-NAS verification, not emulated SMB).
- [ ] **Step 3: Register the bridge in MainActivity** — construct in `configureFlutterEngine` after `super`.
- [ ] **Step 4: Full `flutter test` + `flutter build apk --debug` green.**
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): SMBJ platform bridge + Dart SmbTransport (Android-only)"` + push.

---

### Task 11: Sync UI — settings, button, report; onSetUpRoot fix

**Files:**
- Create: `app/lib/ui/sync_view.dart`
- Modify: `app/lib/ui/settings_dialog.dart` — (a) BUG FIX: `SettingsDialog.build` must forward `onSetUpRoot: onSetUpRoot` to `LibraryRootsEditor` (settings_dialog.dart:160-167 currently drops it, so tablets never see "Set up"); (b) when `Platform.isAndroid`, add a `TextButton` "Sync…" (key `'open-sync-view'`) to the dialog's actions that opens `SyncView` in a dialog.
- Modify: `app/lib/ui/phone/phone_settings_view.dart` — add a "Sync" `ListTile` (key `'phone-sync-entry'`) navigating to `SyncView` as a page.
- Modify: `app/lib/main.dart` — construct `SyncSettings.fromConfig(config)`, persist edits via the same `config['sync'] = settings.toJson(); _writeConfig(config, dataDir);` pattern LayoutPrefs uses; provide the engine factory to the UI.
- Test: `app/test/sync_view_test.dart`, extend `app/test/settings_dialog_test.dart` (or create) for the onSetUpRoot forwarding.

**SyncView contents (new controls only — reskin stays parked):**
- Text fields host/share/base (keys `sync-host`, `sync-share`, `sync-base`), prefilled from settings or defaults.
- "Check connection" button → `transport.probe()` → inline result line.
- Root checkboxes: discovered via `listTree('')` top-level dirs that contain a `.library.json` (`readFile('<dir>/.library.json') != null`), each `CheckboxListTile` keyed `sync-root-<name>`; checked state persisted to settings.
- "Sync now" button (key `sync-now`) — disabled while running; runs `SyncEngine.run()`; progress rides the existing ActivityModel footer; on completion, opens the report dialog (key `sync-report-dialog`): playlist notes, per-root counts ("monthly — 12 copied (48 MB), 3 updated, 1 renamed, 2 deleted, 465 adopted"), failures with reasons, biggest first; stays until dismissed (embed-pass discipline).
- After a first successful sync of a newly-checked root, if `<localHome>/<rootName>` is not among configured roots, add it via `LibraryRootsPrefs.addRoot` (this is what makes the new root play).

**Engine/UI seam for tests:** `SyncView` takes `{required SyncSettings settings, required void Function(SyncSettings) onSave, required Future<SyncReport> Function() runSync, required Future<bool> Function() probe, required Future<List<String>> Function() discoverRoots}` — widget tests drive fakes; main.dart supplies real implementations built on `SmbTransport`.

- [ ] **Step 1: Widget tests first** (fail → implement → pass): settings fields round-trip through onSave; probe result line renders both outcomes; discovered roots render checkboxes and toggle persists; Sync-now disabled while a (fake, slow) runSync is in flight; report dialog shows per-root lines and failures and requires explicit dismissal; SettingsDialog forwards onSetUpRoot (assert "Set up" button appears for a missing-manifest root on the DIALOG, not just the editor).
- [ ] **Step 2: Full `flutter test` + `flutter analyze`.**
- [ ] **Step 3: Commit** — `git commit -m "feat(sync): sync settings/report UI; fix SettingsDialog dropping onSetUpRoot"` + push.

---

### Task 12: Live verification on the tablet + wrap-up

No new code except fixes it surfaces. House rule: verify against the real NAS, don't assume.

- [ ] **Step 1: Build + install** — `flutter build apk --debug` in the worktree; install on the Galaxy Tab S9+ over USB (`adb install -r`).
- [ ] **Step 2: Tablet adoption (one-time reorganization).** The tablet's 467 tracks sit directly in `/storage/emulated/0/Music` (the configured root). Sync maps NAS roots to `<Music>/<rootName>/` subfolders. Using a file manager (or adb), move the existing files into `/storage/emulated/0/Music/loose tracks - 2020 and later/` (matching NAS relPaths — they were seeded from that root), update the configured root in app settings to that subfolder, rescan, confirm dates survive (adoption from the moved-along manifest). THEN first sync should mostly ADOPT, not copy.
- [ ] **Step 3: Verify each spec scenario live, in order:**
  - Playlist reconcile: desktop creates a playlist on `L:` → tablet app start or 5-min tick pulls it; tablet edit flows back; edit both sides offline-ish (airplane wifi toggle) → LWW resolves, loser lands in `.playlists/backup/`, report note names the winner. Delete on tablet → gone on desktop, tombstone present.
  - First music sync of the loose-2020 root: expect ~467 adoptions, few copies; every content ID + `date_added` matches the NAS manifest afterward (spot-check with `foolib status`, and by sorting Date added in-app).
  - Check a second small root (loose-old, 92 tracks) → full copy path, dates correct, root auto-added, plays.
  - Retag a file on the NAS (desktop tag editor) → re-sync → recopy observed, tag visible on tablet.
  - Delete a file on the NAS → re-sync → mirrored deletion, listed in report.
  - Kill Wi-Fi mid-transfer → failure recorded, no partial file in the library (`.sync_tmp` only), re-run completes.
  - Free-space message: temporarily set a checked root larger than free space if practical, else verify the code path stayed covered by Task 9's test and note that.
- [ ] **Step 4: Desktop regression** — Windows build from the same branch: playlists (now sidecar-backed) create/edit/delete live against `L:`, visible on the tablet after its next reconcile.
- [ ] **Step 5: Suites green** — `flutter test`, `dart test` (core), `flutter analyze` no new issues.
- [ ] **Step 6: Merge + docs.** Use superpowers:finishing-a-development-branch (merge `plan3-sync` → `main`, push). Update: CHANGELOG.md (new build section `## Build <real timestamp>` with Changes + Testing Checklist per house format — move the TODO's playlist-sync item into it), STATUS.md (component table rows for Plan 3 + playlists; "Next session starts here"), WORKPLAN.md (Plan 3 → done; open follow-ups). Show the testing checklist to Mike.

---

## Self-Review Notes (kept for the executor)

- Playlists' spec'd "auto reconcile on app start / edit / 5-min tick" is DESKTOP-exempt by design: desktop's sidecar IS the NAS copy (`L:`), nothing to reconcile. The scheduler is Android-only wiring (Task 8), and until Task 10 lands there is no real transport on Android — the scheduler stays dormant behind the settings null-check. This ordering is deliberate, not an oversight.
- The engine replaces the local manifest wholesale (spec §Adopt): correct ONLY because Task 5 emptied `playlists` out of manifests first. Do not reorder Phase 2 before Phase 1.
- `PlaylistStore` loses the busy-flag dance on purpose (sidecar ≠ manifest file); the ENGINE still takes `tryBeginManifestWrite` for its manifest replacement. If a test hangs on busy, that's the engine's gate, not the store's.
- `RemoteFile.relPath` is always root-relative in the planner but base-relative in the transport; the engine prefixes `<rootName>/` when calling the transport and strips it when planning. Keep that seam in the engine — the planner and transport must not know about each other's frames.
- Windows `renameSync` doesn't overwrite — every atomic write here deletes-then-renames (matches `saveManifest`).
