# Plan 3 — LAN Library Sync + Synced Playlists — Design Spec

Date: 2026-07-31 (written 2026-07-31--1416)
Status: approved in brainstorming session; ready for implementation planning

## Purpose

Two features, decided together because they share change detection and the
"everything is just the shared folder" philosophy:

1. **Phone/tablet library sync** — one-button LAN pull of music files +
   manifests from the NAS to the device, per-root opt-in, true mirror,
   download dates preserved.
2. **Persistent, synced playlists** — a playlist made on any device shows up
   on every device, with no account/login/server, because all devices point
   at the same music folder(s).

## Decisions made in brainstorming (with rationale)

| Decision | Choice | Why |
|---|---|---|
| Transport | **NAS-direct over SMB** (phone talks straight to `\\murkyserver\drop`, guest auth) | No middleman: works whenever the NAS is up, desktop can be off; playlist write-back is a plain file write. Rejected: desktop-serves-HTTP (desktop must be on, double hop), server on the NAS (a maintained component this project deliberately avoids). |
| SMB client | **Kotlin platform channel wrapping SMBJ** (Approach A) | SMBJ is mature, maintained, SMB 2/3. The need is Android-only (desktop reads `L:` natively), so pure-Dart buys nothing; the only pure-Dart option (`smb_connect`) is v0.0.9, 18 months stale, unverified publisher, SMB 2.1 max — a load-bearing stale dependency in the one part that must not be flaky. |
| Sync scope | **Per-root opt-in** — checkbox per NAS root, each mirrors to a folder under the device's music dir | Devices have different storage; the tablet's existing single root becomes "loose-2020, checked". |
| Deletions | **Mirror them**, listed in the sync report | True mirror, no zombie files; the report keeps it honest. |
| Playlist conflicts | **Whole-playlist last-write-wins + backup snapshot of the loser** | Simple, honest, nothing silently lost forever. Entry-level merge (CRDT-ish) rejected as real complexity for a two-device household. |
| Cadence | **Auto playlist reconcile when NAS reachable; music transfer manual-button only** | Playlists are KBs and should feel live; multi-GB transfers should never surprise. |

## Architecture

```
NAS  \\murkyserver\drop\music (original structure)\
├── .playlists\                  ← NEW: library-wide playlist sidecar dir
│   ├── p_a1b2c3d4.json          ←   one file per playlist, id = filename
│   ├── tombstones.json          ←   propagates deletions
│   └── backup\                  ←   LWW losers + deleted playlists
├── monthly\        .library.json, .artwork.json, .artwork\, audio…
├── alternative times\  (same)
├── albums\             (same)
├── loose tracks - 2020 and later\  (same)
└── loose tracks - old\             (same)

Phone  /storage/emulated/0/Music/
├── .playlists\                  ← local mirror, auto-reconciled
└── <one folder per checked root>\   ← mirrored by the manual Sync button
```

- **Desktop**: no transport, no sync UI. It reads and writes the NAS live
  over `L:` — playlists via the sidecar dir, music as today.
- **Phone/tablet**: local `.playlists/` reconciled automatically; music
  roots mirrored manually.

### New components

| Component | Where | What |
|---|---|---|
| Playlist sidecar model + IO | `core` (pure Dart) | Schema, tolerant parse, atomic write, tombstones. In core so `foolib` can see playlists. |
| Sync planner | `core` (pure Dart) | Pure function: (local manifest, local listing, sync-state) × (remote manifest, remote listing) → SyncPlan {copies, recopies, renames, deletes, sidecar copies}. Fully unit-testable. |
| SmbBridge | `app` Android (Kotlin + SMBJ) | Platform channel, high-level ops only: listTree, stat, downloadToFile, uploadFromFile, delete, mkdirs, progress events, cancel. Kotlin moves the bytes; Dart never sees chunks. |
| SyncTransport interface | `app` (Dart) | Abstraction over SmbBridge; a local-directory fake implements it for integration tests. |
| SyncEngine | `app` (Dart) | Orchestrates: reachability → playlist reconcile → per-root plan → execute → verify → manifest adopt → rescan → report. |
| Playlist reconciler | `app` (Dart) | LWW + tombstone logic between local and NAS `.playlists/`. |
| Sync settings + report UI | `app` | Host/share/base defaults prefilled, per-root checkboxes, Sync button, embed-pass-style report dialog that waits to be read. |

## Playlist sidecar

**Location:** `<library home>/.playlists/` where library home = the common
parent of the configured roots (NAS: `L:\music (original structure)`,
phone: `/storage/emulated/0/Music`), overridable via a config key for
layouts without a common parent. `AppConfig.raw` already round-trips
unknown keys, so the config addition is cheap.

**File per playlist**, filename = stable random id, so renames never change
identity (today the display name is the key and cross-root collisions get
" (2)" suffixes — hostile to merging):

```json
{ "schema": 1, "id": "p_a1b2c3d4", "name": "roadtrip",
  "track_ids": ["<content id>", "..."],
  "modified": "2026-07-31T18:00:00Z", "modified_by": "tablet-s9" }
```

- **Membership by content ID** (as today) — retag-proof, rescan-proof, and
  device-independent: the same playlist works across three devices with
  three different folder layouts.
- **Tolerant parse** (artwork-sidecar discipline, not manifest discipline):
  a corrupt file is skipped and noted in the report, never a crash. Unknown
  keys tolerated for forward compatibility.
- **Atomic writes** (tmp + rename), same as every other sidecar.
- **Deletions** write a tombstone into `.playlists/tombstones.json`
  (`{"<id>": {"deleted": "ISO UTC", "name": "..."}}`) so the deletion
  propagates. An edit with `modified` **newer** than the tombstone
  resurrects the playlist — an edit beats a stale delete. Tombstones are
  tiny and kept indefinitely.
- **Conflict rule:** whole-playlist last-write-wins by `modified`. The
  losing version — and every deleted playlist — is snapshotted to
  `.playlists/backup/<id>--<timestamp>.json`, and the sync report names the
  winner ("kept tablet's version of roadtrip; desktop's is in backup").
- **Accepted limitation:** LWW trusts device clocks. Household NTP skew
  (seconds–minutes) is harmless at whole-playlist granularity.

**Migration (one-time, idempotent, per root):** playlists currently live in
each root's `.library.json` `playlists` array. On first run of the new
build, each manifest playlist is written out as a sidecar file (id
generated) and the manifest's array is emptied — manifest schema stays 1;
old readers tolerate an empty array. Phone manifests are copies of NAS
manifests, so the second device to migrate sees identical (name,
track_ids) pairs already in the sidecar and skips them; a same-name,
different-content playlist imports with a " (2)" suffix. `PlaylistStore`
CRUD retargets to the sidecar store; UI is unchanged.

**Desktop concurrency:** sidecar writes go through the same serialized,
coalesced write chain pattern the artwork store uses; the in-process
manifest write gate is unaffected (playlists no longer touch manifests
after migration).

## Music sync (Android only)

**Settings** (stored in app config): host / share / base path, defaults
prefilled (`murkyserver` / `drop` / `music (original structure)`), guest
auth (no credentials), checkbox per NAS root — a root being any direct
subdirectory of the base path containing a `.library.json`. Local target: each checked root mirrors to
`<device music dir>/<root name>/`.

**Sync button flow, per checked root:**

1. **Fetch remote state** — the root's `.library.json` plus a recursive SMB
   listing covering audio files and sidecars (`.artwork.json`,
   `.artwork/`). `.hash_cache.json` is explicitly excluded both ways — it
   is a (path, size, mtime) cache whose semantics are device-local even
   though it lives in the root; copying it would poison the other device's
   hash cache.
2. **Plan** (pure core function) against local files, the local manifest,
   and `.sync_state.json` — a per-root record of each file's NAS mtime+size
   at last successful copy:
   - Remote file absent locally → **copy**.
   - Remote mtime/size differs from the sync-state record → **re-copy**.
     Keying off the recorded values (not local file attributes) catches
     retags and art embeds **even when ID3 padding keeps the size
     identical**.
   - Same content ID at a different relPath (from the two manifests) →
     **local rename**, not a re-download.
   - Local file whose content ID has no existing path on the NAS →
     **delete**, listed in the report. (The NAS manifest retains entries
     for missing files, so presence is judged from the listing joined with
     the manifest, not the manifest alone.)
3. **Execute** — free-space check first (planned bytes vs. free space,
   abort with a clear message if short). Every download lands in
   `<root>/.sync_tmp/`, is verified by size **and by content-ID hash
   against the remote manifest**, then renamed into place — a partial
   transfer can never be mistaken for a synced file. Renames and deletes
   apply after copies. Progress (file count + bytes) and cancel run through
   the existing ActivityModel footer; cancel calls into the Kotlin bridge.
   Sync-state records successes only, so re-running after an interruption
   re-plans exactly what is still missing; stale `.sync_tmp/` content is
   discarded at the next run.
4. **Adopt** — the remote manifest replaces the local one (atomic write,
   `.bak` kept). The NAS is authoritative for `date_added` and, after the
   playlist migration, the manifest holds nothing device-local. Then a
   quiet rescan indexes the new files; its diff against the
   freshly-adopted manifest is normally empty, and the existing
   date-adoption path (the machinery that carried 467/467 dates onto the
   tablet) remains the safety net for any local file the NAS manifest
   doesn't know.
5. **Report** — a dialog that waits to be read (embed-pass style): per root,
   files copied (with MB), updated, renamed, deleted; playlist LWW outcomes
   with backup pointers; failures with reasons; biggest counts first.

## Cadence

- **Playlist reconcile** (phone only): on app start, after any local
  playlist edit (debounced), and on the existing 5-minute tick — each time
  gated by a quick SMB reachability probe. Unreachable → silently skip;
  never nag.
- **Music transfer**: manual Sync button only.
- **Desktop**: nothing scheduled; its `.playlists/` reads and writes are
  live NAS operations by construction.

## Error handling

- Per-file SMB failure → one retry, then recorded in the report; the sync
  continues with the remaining files. Connection loss aborts the remainder
  and the report says what completed.
- Corrupt playlist sidecar file → skipped, reported, never fatal.
- Two devices writing NAS `.playlists/` concurrently → per-file atomic
  renames mean the last rename wins; the next reconcile detects the
  divergence and snapshots the loser to backup. Same LWW rule, no special
  case.
- The sync's local-manifest overwrite goes through the existing in-process
  manifest write gate (`tryBeginManifestWrite`), same as every other
  manifest writer.
- Free space insufficient → abort before any transfer, with the shortfall
  stated.

## Testing

- **Core (pure, fixture-driven):** sync planner matrix — new / changed
  (mtime, size, and size-unchanged-retag cases) / moved / deleted /
  sidecar-included / hash-cache-excluded; playlist sidecar IO round-trips
  incl. corrupt-file tolerance; the full LWW × tombstone matrix
  (edit-vs-edit both orders, edit-vs-delete, delete-vs-edit, resurrect);
  migration idempotency (run twice, run on two "devices" with identical
  manifests, same-name-different-content collision).
- **App integration:** SyncTransport is an interface; a local-directory
  fake drives complete "NAS dir → phone dir" syncs in tests, including
  interruption mid-execute and re-run convergence, free-space abort, and
  report contents.
- **Live verification (house rules — verify, don't assume), on the tablet
  against the real NAS:** first sync of a fresh root → every content ID and
  `date_added` matches the NAS manifest (the 467/467 check, scaled); retag
  a file on the NAS → re-sync → phone copy updated; delete on the NAS →
  mirrored with report line; edit the same playlist on desktop and tablet
  → LWW resolves, loser present in `.playlists/backup/`; kill Wi-Fi
  mid-transfer → no partial file indexed, re-run completes.

## Out of scope (deliberate)

- Phone→NAS music upload — the desktop/NAS stays the source of truth for
  audio; only playlist files flow both ways.
- Off-LAN / remote access, accounts, any server component.
- Per-folder partial root mirrors ("only 2025 folders of monthly") —
  per-root granularity only in v1.
- Automatic/background music transfer.
- Play-count sync.

## Existing code this builds on (from the pre-design code map)

- `core/lib/src/manifest.dart` — manifest schema 1, atomic save, `.bak`
  fallback. Playlists currently live here; this design moves them out.
- `core/lib/src/library_ops.dart` — `diffAgainstManifest`,
  `knownEntriesWithin`, `adoptKnownDates`: the proven date-preservation
  path.
- `core/lib/src/scanner.dart` — `.hash_cache.json` (the file the sync must
  NOT copy).
- `app/lib/artwork/artwork_store.dart` — the sidecar discipline to copy:
  tolerant parse, additive keys, atomic + coalesced saves, read-only-root
  fallback, per-root registry.
- `app/lib/model/playlist_store.dart` — CRUD that retargets to the sidecar;
  its documented cross-root wart (playlist in root D referencing tracks in
  root A) is exactly what the library-wide sidecar location fixes.
- `app/lib/ui/phone/storage_access.dart` + all-files access — already in
  place for sidecar reads/writes.
- Known pre-existing bug to fix in passing (it blocks the tablet's sync
  settings surface): `app/lib/ui/settings_dialog.dart:160` drops
  `onSetUpRoot`, so tablets never see the root "Set up" button.
