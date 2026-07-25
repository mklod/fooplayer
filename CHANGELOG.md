# fooplayer — CHANGELOG

*What shipped, when. Newest first. Status: [STATUS.md](STATUS.md) · Plan: [WORKPLAN.md](WORKPLAN.md).*

## 2026-07-24 — late night: Android goes native (Plan 2b)

- **Phone UI shipped and verified on the emulator**: hamburger drawer (Library / Folders / Artists / Albums / Playlists / Settings), date-feed home with tap-to-play, persistent mini-player, full Now Playing screen with the metro transport glyphs, drill-down folders, playlist management, settings page.
- **Audio playback confirmed on Android** — and the duration backfill corrected a wrong seeded duration (28:25 → 4:18) live on first play.
- android-app branch integrated with all ten desktop rounds first (one careful main.dart port), then three parallel implementers + merge + dual review; review fixes: phone Settings page, View-details sheet action, and a folder-scope leak into the phone Artists/Albums views. 318/318 tests; APK and Windows release build from the same tree.

## 2026-07-24 — night: post-reboot batch (ultracode round 2)

- **Emulator restored safely**: Pixel 7 AVD verified under Microsoft's WHPX hypervisor (15s boots) — bluescreen driver permanently gone.
- **Track numbers in album view** — root cause was view wiring, not tags: albums opened via Folder drill-down never triggered the `#` column (it only watched the Album filter). Single-album folder detection added; `#` + track-order sort now apply. Parser and cache were verified healthy.
- **Clickable breadcrumb** — "All / monthly / 2007-08": each segment pops back to that level; ✕ still full-resets.
- **Playlists**: create (+ New playlist), delete (right-click), add-to-playlist / remove via track context menus — persisted into the first root's manifest (atomic, `.bak`-protected, CLI-compatible); cross-root ownership guarded. Active-playlist deselection fixed (#30).
- **Metro transport buttons** — the original foobar JScript-panel glyphs (play/pause/next/prev/shuffle-state pair) bundled as app assets, ink-tinted for the light bar.
- **Adversarial catch of the round**: a timed-out rescan isolate could zombie on for minutes and clobber a fresh playlist write — now killed at the deadline via the shared kill-capable isolate helper, pinned by a regression test proven to fail on the old code. 275/275 tests.
- Repo relocated to `L:\PROJECTS\fooplayer` (docs at root; old dir frozen); session continuity verified across the reboot.

## 2026-07-24 — evening: first ultracode round (parallel multi-agent)

- **Process shift**: four features built simultaneously in isolated branch worktrees, merged conflict-free, adversarially reviewed, all findings fixed — ~18 min wall-clock for the implementation wave.
- **View in folder** (right-click → Explorer with file selected) — including the fix for a review-caught bug where any spaced path silently failed.
- **Click model**: single-click selects (snappy ~80ms highlight), double-click plays.
- **Folder drill-down**: click *monthly* → pane shows 2007-08 / 2007-09 / …; breadcrumb + pinned ✕; ctrl+click toggles sibling folders.
- **Search field ✕** clear button.
- **On-play duration backfill**: tracks whose tags carry no duration get it permanently the first time they play. Root cause found: APEv2 tags (mp3gain artifacts) shadowing MP3 parsing — not VBR headers as first suspected.
- **Adversarial-review fixes**: duration-event/track correlation race (fast skips could permanently stamp the wrong duration), enrichment-vs-backfill cache clobbering, fabricated cache entries, case-sensitivity and no-op-notify polish. 223/223 tests.

## 2026-07-24 — afternoon: feedback wave

- **Ctrl+click multi-select** across filter panels (OR within a panel, AND across).
- **Genre pane removed → Folders pane** (source folders as the first cascade level).
- **Pinned per-panel clear ✕**, visible while scrolling.
- **True columnar rows** (artist in its own column), uniform 13px typography across all columns incl. `#`, left-aligned `#`, Time/Date spacing.
- **Sortable columns** Title/Artist/Album/Time/Date (+ `#` in single-album/playlist views, track-number default sort in album view).
- **Instant filename-parsed columns** at launch (Artist – Title split before tag enrichment catches up); date-pattern folders (`2012-11`) no longer masquerade as albums.
- **Multiple source folders** + settings UI + config v2; **auto-rescan** (launch / Refresh / 5-min timer) so new downloads appear stamped with today as date-added.
- **Enrichment stall root-caused**: third-party MP3 parser scans unboundedly on pathological files (>280s over SMB) → kill-capable isolate timeouts, per-file fallback, incremental cache saves.
- **iTunes-style light theme** (central tokens, no Material purple), centered now-playing bar with fully visible track info, draggable persisted pane dividers (with flush-on-exit fix).
- **App icon** (pink note) embedded + desktop shortcut.
- **Incident**: `aehd.sys` (Android emulator hypervisor driver) bluescreened the PC ~30 min after install (PFN_LIST_CORRUPT, dump-confirmed). Driver removed; WHPX queued for next reboot. Android toolchain otherwise complete (SDK 35+36, Pixel 7 AVD); APK built and manifest pipeline verified on the emulator before the incident.

## 2026-07-23 — first build day

- **Design spec** agreed (serverless, portable per-folder `.library.json` manifests; date-downloaded as permanent data).
- **Plan 1 core engine** built TDD task-by-task with independent reviews and merged: content-ID hashing that survives retagging, atomic manifest writes, cached scanner, seed migration, `foolib` CLI.
- **Library seeded**: original download dates recovered from the Oct 2025 foobar2000 metadb backup (4,800 tracks) — Mp3tag's date clobbering permanently neutralized in the manifest; verified live.
- **Windows app v1** (dark): feed, filters, search, playlists, playback — verified against the real library the same night.
- Flutter SDK installed; SMB symlink limitation solved via local worktrees.

## Backstory

- 2026-04-16: foobar2000 UI restoration session; `metadb.sqlite` backup and `restore_ctimes.py` created — the recovery sources this project was seeded from.
- Oct 2025: foobar2000 config + metadb backup taken (the "source of truth" snapshot).
