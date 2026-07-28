# fooplayer — STATUS

*Current-state snapshot. History: [CHANGELOG.md](CHANGELOG.md) · Forward plan: [WORKPLAN.md](WORKPLAN.md). Last update: 2026-07-27.*

## Component status

| Component | State |
|---|---|
| Core engine (`fooplayer_core`: content-ID hashing, manifests, scanner, seed, `foolib` CLI) | ✅ Stable, merged, untouched by later rounds (36/36 tests) |
| Library manifests | ✅ Five scoped roots seeded (monthly 1,844 / alt-times 2,398 / albums 685 / loose-2020 437 / loose-old 92); dates permanent, retag-proof |
| Windows desktop app | ✅ Daily driver. iTunes-style light UI, sortable columns, folder drill-down with breadcrumb + ↑ up-one-level, ctrl/shift multi-select (rows and filters), search ✕, auto-rescan, on-play duration backfill, click-to-select / double-click-play, instant right-click menus, playlists (create/delete/add/remove) with the four-column playlist view + cover/title/"N tracks · MM min" header, metro transport glyphs, blue shuffle |
| Android app | ✅ Phone-native UI v1, verified live on the emulator: drawer shell (Library/Folders/Artists/Albums/Playlists/Settings), date feed, mini-player, Now Playing with metro transport (no volume slider — hardware keys own it), browse views, playlist management. Launcher icon + "fooplayer" label |
| Album artwork | ✅ Auto-enrichment (iTunes / Deezer / Cover Art Archive — keyless; conservative auto-apply at ≥75 score with ≥10 margin) + picker on both platforms (grid, choose file, paste URL, search again, remove). Stored per-root in `.artwork/` + `.artwork.json` sidecar; two adversarial-review passes' findings fixed |
| Test suite | ✅ 682 app tests + 36 core tests, `flutter analyze` clean; Windows release and debug APK both build from one tree |
| Android emulator | ✅ Healthy under Microsoft WHPX (15s boots), data partition 16 GB, seeded with the real 444-file "loose tracks - 2020 and later" library. AEHD driver permanently removed after it bluescreened the machine |
| Repo location | ✅ Migrated: canonical repo is `L:\PROJECTS\fooplayer`; old `L:\PROJECTS\foobar` deleted and verified clear (no processes, services, tasks, or git references) |
| Background audio (Plan 2c) | ⛔ Not started — lock-screen / notification controls via `audio_service` |
| Phone library sync (Plan 3) | ⛔ Not started — LAN pull of files + manifests to the phone |
| File-dates fix (foobar2000/Explorer sorting) | ⏸ ON HOLD by Mike's explicit instruction — see [docs/music-library-dates-issue.md](docs/music-library-dates-issue.md) |

## Where things run

- Repo: `L:\PROJECTS\fooplayer` (`main` = everything merged) · GitHub: https://github.com/mklod/fooplayer
- Desktop build worktree: `C:\dev\foobar-app` (branch `windows-app`) → `app\build\windows\x64\runner\Release\fooplayer_app.exe`; desktop shortcut "fooplayer"
- Android build worktree: `C:\dev\fooplayer-android` (branch `android-app`) → `app\build\app\outputs\flutter-apk\app-debug.apk`
- App config/caches: `%APPDATA%\fooplayer\` (config v2 with the five roots, `meta_cache.json`)
- Artwork: `<library root>\.artwork.json` + `<library root>\.artwork\` (travels with the music folder)

*Worktrees must live on `C:` — the NAS share can't host Flutter's plugin symlinks. The `foobar-app` folder name is legacy; the path is stale, its branch and contents are current.*

## Last session (2026-07-27)

- Fixed the add-to-playlist failure Mike reported. It was not the owning-root routing patched earlier: playlist writes gated on the library's coarse `busy` flag, which covers background tag reading (minutes on this library), so writes were refused all session and the refusal only surfaced after a 5-second deadline. The lock now covers only phases that touch a manifest. Reproduced and re-verified live in the running app, including the remove path.
- Playlist view completed to the reference design (four columns + cover/title/summary header); right-click menus open with no animation.

## Blocking on Mike

1. **File-dates decision** — mtime route / Samba fix / both / skip ([writeup](docs/music-library-dates-issue.md)). No filesystem-date action has been taken, and none will be without an explicit go-ahead.
2. **Real-device test** — plug the Pixel 7 in over USB whenever convenient; the APK installs with one command (the emulator already proves the pipeline).

## Known machine facts

- Never reinstall Google's AEHD emulator driver on this box (PFN_LIST_CORRUPT bluescreen, 2026-07-24). WHPX is the acceleration path.
- The page file must stay enabled — with it off, Gradle's default JVM heaps exhaust the commit ceiling and crash builds (`android/gradle.properties` heaps are trimmed as a safeguard).
- `L:` is `\\murkyserver\drop` (SMB): no Flutter symlinks, no creation-time writes, slow byte-wise reads — which is why tag reading, scanning, and artwork work all run in kill-capable isolates with timeouts.
- Artwork lookups make outbound calls to three public APIs (no keys or accounts); rate-limited, and they degrade silently to placeholders when offline.
