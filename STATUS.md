# fooplayer — STATUS

*Current-state snapshot. History: [CHANGELOG.md](CHANGELOG.md) · Forward plan: [WORKPLAN.md](WORKPLAN.md). Last update: 2026-07-24.*

## Component status

| Component | State |
|---|---|
| Core engine (`fooplayer_core`: content-ID hashing, manifests, scanner, seed, `foolib` CLI) | ✅ Stable, merged |
| Library manifests | ✅ Five scoped roots seeded (monthly 1,844 / alt-times 2,398 / albums 685 / loose-2020 437 / loose-old 92); dates permanent, retag-proof |
| Windows desktop app | ✅ Daily-drivable. iTunes-style light UI, sortable columns, folder drill-down, multi-select filters, search ✕, auto-rescan, on-play duration backfill, view-in-folder, select/double-click-play. 223/223 tests, whole-branch + adversarial reviews clean, merged to `main` |
| Android | ✅ Phone-native UI v1 shipped & verified live on the emulator: drawer shell, date feed, mini-player, Now Playing with metro transport, browse views, playlists, settings; playback + on-play duration backfill confirmed. Next: background audio (2c), real-device storage/sync (Plan 3) |
| Android emulator | ✅ Verified under WHPX post-reboot (15s boots); AEHD permanently removed 
| File-dates fix (foobar2000/Explorer sorting) | ⏸ ON HOLD by Mike's explicit instruction — see [music-library-dates-issue.md](docs/music-library-dates-issue.md) |
| Repo migration to `L:\PROJECTS\fooplayer` | ⏸ Deferred — empty target dir created by Mike; plan: fresh clone from GitHub + re-point worktrees (worktree metadata makes in-place copies messy) |
| LAN sync / phone library sync (Plan 3) | ⛔ Not started |

## Where things run

- Repo: `L:\PROJECTS\foobar` (`main` = everything merged; GitHub: https://github.com/mklod/fooplayer)
- Desktop build worktree: `C:\dev\foobar-app` (branch `windows-app`); exe `app\build\windows\x64\runner\Release\fooplayer_app.exe`; desktop shortcut "fooplayer"
- Android worktree: `C:\dev\fooplayer-android` (branch `android-app` — pre-dates the last two desktop rounds; rebase onto `main` before next Android work)
- App config/caches: `%APPDATA%\fooplayer\` (config.json v2 with the five roots; meta_cache.json)

## Blocking on Mike

1. ~~Reboot~~ done — emulator verified, batch #27–31 shipped.
2. **File-dates decision** (mtime route / Samba fix / both / skip).

## Known machine facts

- No AEHD ever again (bluescreen); WHPX after reboot. Pagefile was temporarily off (restored on reboot); Gradle heaps trimmed in `android/gradle.properties` as safeguard.
- L: is `\\murkyserver\drop` (SMB): no Flutter symlinks, no creation-time writes, slow byte-wise reads (drove the enrichment isolate/timeout architecture).
