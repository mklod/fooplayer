# Custom Music Player — Design Spec

Date: 2026-07-23
Status: approved in brainstorming session; ready for implementation planning

## Purpose

A custom music player for Android and Windows desktop that replaces foobar2000 as the daily driver. Three drivers, all first-class:

1. **Same experience everywhere** — one library, one UI concept, identical on phone and desktop.
2. **Total UI control** — the interface currently approximated with Columns UI + JScript Panel 3 hacks, owned outright.
3. **Programmatically drivable** — every player function reachable through an internal command layer, so scripted/remote control can be added cheaply later (no API ships in v1).

Non-negotiable requirement learned the hard way: **"date downloaded" is real data**, stored in a database the player owns — never derived from filesystem creation times, which tag editors (Mp3tag) clobber.

## Constraints and context

- Library: ~13.5k files, 68 GB, at `L:\music (original structure)` on the desktop. Fits whole on a modern phone.
- New music arrives on the desktop (Soulseek). Desktop is the source of truth.
- Existing playlists are `.txt` files (monthly, "alternative times").
- Historical `date_added` values are recoverable from restored file ctimes (`restore_ctimes.py`, dry-run verified 2026-07-23: 4,302 restorable, 523 already correct, 122 missing) plus the Oct 2025 `metadb.sqlite` backup at `L:\APPS\foobar [custom config files]\config backup\`.
- v1 must be dead simple: no server, no accounts, manual sync acceptable.

## Architecture

One **Flutter codebase**, two builds: Android app and Windows desktop app. Each is a fully self-contained local player — plays files on that device, no network dependency, ever. No server component.

Shared state travels in a **library manifest**: a single JSON file (`.library.json`) inside the music folder itself. Copying the folder copies the library — same date-downloaded order, same playlists, on every device that reads it.

```
music folder/
├── .library.json      ← manifest: date_added, playlists (portable truth)
├── .library.json.bak  ← previous manifest version
└── ... audio files    ← source of truth for musical metadata (tags)
```

Each app instance builds a local SQLite index from scanning the folder + reading the manifest. The index is a disposable cache: delete it and it rebuilds losslessly from files + manifest.

## Library & metadata model

**Division of truth:**
- Audio files (tags): artist, album, genre, title, art — read directly, never duplicated into the manifest.
- Manifest: only what files can't safely hold — `date_added`, playlists, later play counts.

**Track identity:** content ID = hash of the *audio data only*, skipping tag blocks (ID3/Vorbis/etc.). Retagging, renaming, or moving a file never changes its identity, `date_added`, or playlist membership. Hashes computed once, cached by (path, size, mtime).

**`date_added`:** when the desktop app first sees a new content ID, it stamps the current time into the manifest.

**Seed migration (one-time):** initial manifest for the existing library is generated from restored file ctimes, with the Oct 2025 `metadb.sqlite` as fallback for files the ctime restore can't fix. Existing `.txt` playlists are imported by filename matching. The migration has a dry-run report mode for eyeballing all dates before committing.

**Write discipline (v1):** only the desktop app writes the manifest. The phone is a read-only consumer holding its own local play state. One writer → zero sync conflicts, which is what makes serverless viable.

**Playlists:** ordered lists of content IDs in the manifest.

## UI structure

Shared vocabulary on both platforms: identical sort options, filter logic, and shuffle behavior. Switching devices should feel like resizing the same app.

**Desktop (Windows)** — the current Columns UI layout, rebuilt:
- Filter panels (Genre / Artist / Album) narrowing a track list
- Track list default-sorted by `date_added` descending
- Search; playlist sidebar
- Bottom now-playing bar recreating the current JScript panel: album art, title/artist/album, seekbar, prev/play/next, shuffle toggle, volume
- Menu bar hidden by default

**Android** — same model, phone-shaped:
- Home screen = date-downloaded feed, newest first
- Tabs/drawer: Genre → Artist → Album drill-down, playlists, search
- Persistent mini-player bar (art, title, play/pause) expanding to a full now-playing screen with seekbar/transport/shuffle

**v1 layout is fixed** (built to taste, not themeable). All UI actions route through a plain internal command layer (play, seek, filter, queue) — the seed for later scripted/remote control.

## Playback

- Android: just_audio + audio_service (ExoPlayer/media3 underneath) — background playback, lock-screen/notification controls, Bluetooth.
- Windows: media_kit (libmpv).
- Formats: MP3, FLAC, M4A, OGG covered on both platforms.

## Sync

**v1 — manual:** copy the folder to the phone by any means (USB, SMB). The app's "Rescan" action diffs filesystem vs. manifest:
- File present, not in manifest → plays fine, flagged "unindexed", sorted by file mtime until the desktop indexes it.
- Manifest entry, file missing → hidden, not an error.

**v1.5 — one-button LAN pull (additive, not a redesign):** desktop app serves the library folder read-only over HTTP on the LAN; the phone's "Pull from desktop" button fetches the manifest, diffs by content ID, downloads only new/changed files.

## Error handling

- Manifest writes are atomic (write-temp-then-rename) and keep a `.bak` of the previous version. Manifest schema is versioned.
- Corrupt/missing tags → fall back to filename parsing.
- Duplicate audio (same content ID, two paths) → keep earliest `date_added`, list both locations.
- Partially-copied file (hash mismatch) → flagged for re-copy, never silently indexed.

## Testing

- Unit tests on core logic: content-ID hashing, manifest read/diff/write, seed migration, `.txt` playlist import — with snapshots of the real library as fixtures.
- Seed migration dry-run report reviewed by hand before first commit of the manifest.
- Light widget-test pass on filter/sort logic.
- Playback verified manually on real devices.

## Out of scope for v1

- Any server component, streaming, or remote (off-LAN) access
- In-app tag editing (Mp3tag remains, now harmless to dates)
- Theming; API/remote control surface; play-count sync
- iOS, Linux, macOS builds

## Open follow-ups (separate from this project)

- Run `restore_ctimes.py --apply --fuzzy` to fix the 4,302 clobbered creation times before the seed migration (user deferred on 2026-07-23; script is path-updated and dry-run verified).
