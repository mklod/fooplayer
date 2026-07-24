# fooplayer — Project Status & Changelog

*Living document; updated at each milestone. Last update: 2026-07-24 (late night).*

## What this is

A custom music player replacing foobar2000: Windows desktop app now, Android next, built around a portable `.library.json` manifest per music folder that stores **date downloaded as permanent data** (immune to tag editors). Spec: [superpowers/specs/2026-07-23-music-player-design.md](superpowers/specs/2026-07-23-music-player-design.md). Working title "fooplayer" (placeholder — rename anytime).

## Component status

| Component | Status | Where |
|---|---|---|
| Core engine (`fooplayer_core`: content-ID hashing, manifest, scanner, seed, `foolib` CLI) | ✅ Done, merged to main | `core/` |
| Library seeding (full library + scoped 5-root reseed) | ✅ Done | manifests inside each music folder |
| Windows desktop app — v1 (dark) | ✅ Superseded by UI rework | branch `windows-app` |
| UI rework: light iTunes theme, centered bar, draggable dividers, multi-root + settings, auto-rescan, sortable columns | 🔄 ~90% — final fix loop + verification in flight | branch `windows-app`, built at `C:\dev\foobar-app` |
| Android build (Pixel 7 emulator smoke test) | 🔄 In progress (parallel branch) | branch `android-app`, `C:\dev\foobar-android` |
| File-dates fix for foobar2000/Explorer | ⏸ ON HOLD pending Mike's decision | [music-library-dates-issue.md](music-library-dates-issue.md) |
| LAN sync / phone library sync (Plan 3) | ⛔ Not started | — |

## Changelog

### 2026-07-24
- **Sortable columns** (Title/Artist/Album/Time/Date) with duration captured during tag enrichment.
- **Auto-rescan**: new files in library folders appear automatically (launch + Refresh button + 5-min timer); fix loop in flight for a launch-trigger bug caught in review.
- **Multiple source folders** with settings UI (add/remove roots, native folder picker); config v2.
- **Scoped 5-root reseed** per Mike's directive: monthly (1,844), alternative times (2,398 + playlist), albums (685), loose tracks 2020+ (437), loose tracks old (92) — 5,456 tracks.
- **iTunes-style light theme** (white/grey, blue accent, no purple), **centered now-playing bar** with fully visible track info, **draggable pane dividers** with sizes persisted (incl. flush-on-close fix).
- **Enrichment stall root-caused and fixed**: third-party MP3 parser scans unboundedly on one pathological file (>280s stall over SMB) — now isolate-kill timeouts, per-file fallback, incremental cache saves.
- **App icon** (pink music note) embedded; **desktop shortcut** created.
- **Seek-bar visibility** and **album-art flicker** fixed (theme-color collision; image re-decode per tick).
- **Android toolchain installed** (JDK 17, SDK 35+36, emulator, Pixel 7 AVD — flutter doctor green); Android platform build started on parallel branch.
- **Filesystem dates finding**: the NAS's Samba silently discards creation-time writes over SMB — options documented in [music-library-dates-issue.md](music-library-dates-issue.md), awaiting decision.

### 2026-07-23
- **Design spec** agreed and written (serverless, manifest-first architecture).
- **Plan 1 (core engine) built and merged**: 9 TDD tasks + reviews; `foolib` CLI (status/update/seed).
- **Full library seeded**: 10,604 tracks, dates recovered from the Oct 2025 foobar2000 metadb backup (4,800 tracks) — the Mp3tag date-clobbering problem is permanently neutralized in the manifest.
- **Windows app v1 built** (9 tasks + reviews): feed, filters, search, playlists, playback — verified live against the real library.
- Flutter SDK installed; SMB-symlink blocker solved via local worktree.

## Key paths

- Repo: `L:\PROJECTS\foobar` (main branch = merged work; `windows-app` / `android-app` = active branches)
- Desktop build/worktree: `C:\dev\foobar-app` → exe at `app\build\windows\x64\runner\Release\fooplayer_app.exe` (desktop shortcut exists)
- App config/caches: `%APPDATA%\fooplayer\`
- Music roots + manifests: inside `L:\music (original structure)\<folder>\.library.json`
- Detailed engineering ledger (scratch): `.superpowers\sdd\progress.md`; per-task reports alongside it

## Known issues / deferred

- foobar2000/Explorer still sort by clobbered filesystem dates (fix on hold — Mike to choose approach).
- Tracks in excluded folders (iTunes, _to dl, xmas, albums [no scrape]) aren't in the current 5-root library — add as sources via Settings when wanted.
- 26 freetext lines of the "alternative times" playlist unmatched (need fuzzy title matching — future).
- Minor review-deferred items tracked in the ledger for the whole-branch review to triage.
