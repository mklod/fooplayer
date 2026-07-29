# fooplayer — STATUS

*Current-state snapshot. History: [CHANGELOG.md](CHANGELOG.md) · Forward plan: [WORKPLAN.md](WORKPLAN.md). Last update: 2026-07-28.*

## Component status

| Component | State |
|---|---|
| Core engine (`fooplayer_core`: content-ID hashing, manifests, scanner, seed, `foolib` CLI) | ✅ Stable, merged, untouched by later rounds (36/36 tests) |
| Library manifests | ✅ Five scoped roots seeded (monthly 1,844 / alt-times 2,398 / albums 685 / loose-2020 437 / loose-old 92); dates permanent, retag-proof. Library is now 100% MP3 + 3 FLAC (the 13 m4a were converted 2026-07-27, date-added carried across) |
| Windows desktop app | ✅ Daily driver. iTunes-style light UI, sortable columns, folder drill-down with breadcrumb + ↑ up-one-level, ctrl/shift multi-select (rows and filters), search ✕, auto-rescan, on-play duration backfill, click-to-select / double-click-play, instant right-click menus, playlists (create/delete/add/remove) with the four-column playlist view + cover/title/"N tracks · MM min" header, metro transport glyphs, blue shuffle |
| Android app | ✅ Phone-native UI v1, verified live on the emulator: drawer shell (Library/Folders/Artists/Albums/Playlists/Settings), date feed, mini-player, Now Playing with metro transport (no volume slider — hardware keys own it), browse views, playlist management. Launcher icon + "fooplayer" label |
| Artwork in file tags (in-app) | ✅ **Run across the library 2026-07-28.** Sidebar action "Embed art in files", confirmed by a dialog and closed by a report that waits to be read (reasons listed with counts, biggest first). Zero failures, zero disturbed dates. The Art/Emb columns now correct themselves from the pass rather than showing what the tag cache last saw |
| Artwork in file tags (engine) | ✅ ID3v2 APIC / FLAC PICTURE, content ID and dates provably unchanged, unsafe files refused. The `notMpeg` guard now scans through up to 8 KB of junk between tag and first frame — but only in a file that opened with a real ID3v2 tag, and only onto a header whose version/layer/bitrate/sample-rate could genuinely decode. That rescued 28 real MP3s and still refuses the one MP4 wearing an `.mp3` name ([review list](docs/artwork-embed-review.md)) |
| Embedded-cover coverage | ⚠️ 3,284 of 5,553 files (59.1%), measured by reading the files rather than asking the app. By root: albums 684/685, monthly 1,746/1,904, loose-2020 430/474, loose-old 49/92, **alternative times 375/2,398**. The shortfall is almost entirely the VA bootleg compilations, where no provider has a cover and no loose image sits beside the audio — nothing skipped in error. Raising it further means finding art for those, not fixing the pass |
| Tag reading | ✅ Own ID3 reader (`id3_text.dart`) recovers what the upstream parser drops — frames behind a large picture, ID3v2.2 IDs, stacked tags. Artist reads TPE1 before TPE2 (359 files were showing the album artist). 1 track library-wide has no artist, and it genuinely carries no tag |
| Durations | ✅ Persisted in the manifest beside `date_added` (5,453 written), so a cache loss no longer costs the Time column. Zero tracks missing a duration; a timed-out read falls back to the header-only estimator |
| Album artwork | ✅ Auto-enrichment (iTunes / Deezer / Cover Art Archive — keyless; conservative auto-apply at ≥75 score with ≥10 margin) + picker on both platforms (grid, choose file, paste URL, search again, remove). Stored per-root in `.artwork/` + `.artwork.json` sidecar; two adversarial-review passes' findings fixed |
| Test suite | ✅ 735 app tests + 36 core tests, `flutter analyze` clean; Windows release and debug APK both build from one tree |
| Android emulator | ✅ Healthy under Microsoft WHPX (15s boots), data partition 16 GB, seeded with the real 444-file "loose tracks - 2020 and later" library. AEHD driver permanently removed after it bluescreened the machine |
| Repo location | ✅ Migrated: canonical repo is `L:\PROJECTS\fooplayer`; old `L:\PROJECTS\foobar` deleted and verified clear (no processes, services, tasks, or git references) |
| Background audio (Plan 2c) | ⛔ Not started — lock-screen / notification controls via `audio_service` |
| Phone library sync (Plan 3) | ⛔ Not started — LAN pull of files + manifests to the phone |
| File-dates fix (foobar2000/Explorer sorting) | ✅ **Fully resolved 2026-07-28, and independently verified** — 5,553 of 5,553 files match their manifest `date_added` (checked by reading the manifests directly, not by trusting any pass's self-report). The last 66 were duplicate paths: the stamping tool iterated `paths[0]` only, so where one content ID names two files, the twin kept its copy-event date. Every root accounted for: `monthly` folder-derived (canon), `alternative times` split into its two acquisitions, `albums` placed album-by-album (13 individually, 2 on recovered evidence). Zero files disagree with their manifest date. Details: [docs/albums-date-recovery.md](docs/albums-date-recovery.md). Was: **Resolved 2026-07-28** — option 1 applied: every track's filesystem date stamped from its manifest `date_added` (5,483 tracks, 1,724 re-stamped, 0 failures). This share reports creation time as equal to modified time, so both Explorer columns and foobar2000's sort are now correct; no NAS config change needed. Reversible via the logged previous values |

## Where things run

- Repo: `L:\PROJECTS\fooplayer` (`main` = everything merged) · GitHub: https://github.com/mklod/fooplayer
- Desktop build worktree: `C:\dev\foobar-app` (branch `windows-app`) → `app\build\windows\x64\runner\Release\fooplayer_app.exe`; desktop shortcut "fooplayer"
- Android build worktree: `C:\dev\fooplayer-android` (branch `android-app`) → `app\build\app\outputs\flutter-apk\app-debug.apk`
- App config/caches: `%APPDATA%\fooplayer\` (config v2 with the five roots, `meta_cache.json`)
- Artwork: `<library root>\.artwork.json` + `<library root>\.artwork\` (travels with the music folder)

*Worktrees must live on `C:` — the NAS share can't host Flutter's plugin symlinks. The `foobar-app` folder name is legacy; the path is stale, its branch and contents are current.*

## Last session (2026-07-28, evening)

- **Artwork embedded across the library** — the covers are in the files now, not only in a sidecar fooplayer can read. Zero failures, zero disturbed dates.
- **Three reporting bugs, each of which made working code look broken.** The Emb column showed what the tag cache last saw, so files the pass had just written still read as bare (this was "El Manana appears to have artwork, but it is not embedded" — the cover was on disk all along). The end-of-pass report was a six-second SnackBar closing a fifteen-minute job. And the duration write-back was silently clearing the embedded-art flag on any track that got its duration by being played.
- **The `notMpeg` refusal was right once and wrong 28 times** — 28 ordinary MP3s carry junk between the tag's declared end and the first audio frame; only `MrSuicideSheep - Best of 2025.mp3` genuinely isn't an MP3 (it's MP4). Guard relaxed under two conditions that keep that one refused.
- **66 download dates were quietly wrong** — duplicate paths the stamping tool never visited. Found by checking the manifests directly rather than trusting the pass. Now 5,553/5,553.
- Track count moved to a persistent window footer, sharing the strip with background work.

## Earlier session (2026-07-28)

- **Download dates finished.** All five roots accounted for; the `albums` root placed album-by-album, two of them from a full-directory sweep that recovered a real 2007-11 Rehab download date from copies living outside the fooplayer roots. Reversible throughout.
- **Artwork embedding merged into the app** ("Embed art in files"), with the identity + dates guarantee enforced and stated in its confirmation dialog.
- **Library view**: Art/Emb status columns, selected-track cover preview in the sidebar, and the idle status line no longer twitches.

- **"Date downloaded" resolved** (option 1): filesystem dates re-derived from the manifest for all 5,483 tracks, so foobar2000 and Explorer finally sort correctly. Zero-Seven duplicate folder deduped (FLACs kept, MP3 transcodes removed — they carried a wrong 2024 date-added).
- **Metadata pipeline overhauled after live-use bug reports.** Own ID3 reader recovers tags the upstream parser drops (57 tracks across 5 albums); artist now reads TPE1 rather than TPE2 (359 files affected); durations persist in the manifest and no track is missing one; a cache-revision refresh no longer blanks the library, no longer marks itself done without doing the work, and a timed-out read recovers instead of staying wrong forever. See CHANGELOG for the full account.
- UI: selection highlights on pointer-down (the ~300 ms double-tap window *was* the stutter), hero cover opens the artwork picker, artwork first in the row context menu, grey app-icon placeholder, no column-header hover tint.
- Earlier in the same session: cover art embeds into files (MP3 APIC / FLAC PICTURE) with content ID and dates provably unchanged, applied to the 3 FLACs and the 13 converted m4a. The full-library pass over ~3,659 art-less MP3s is built but deliberately unrun, pending Mike's review.

- Fixed the add-to-playlist failure Mike reported. It was not the owning-root routing patched earlier: playlist writes gated on the library's coarse `busy` flag, which covers background tag reading (minutes on this library), so writes were refused all session and the refusal only surfaced after a 5-second deadline. The lock now covers only phases that touch a manifest. Reproduced and re-verified live in the running app, including the remove path.
- Playlist view completed to the reference design (four columns + cover/title/summary header); right-click menus open with no animation.

## Blocking on Mike

1. **Real-device test** — plug the Pixel 7 in over USB whenever convenient; the APK installs with one command (the emulator already proves the pipeline).

## Known machine facts

- Never reinstall Google's AEHD emulator driver on this box (PFN_LIST_CORRUPT bluescreen, 2026-07-24). WHPX is the acceleration path.
- The page file must stay enabled — with it off, Gradle's default JVM heaps exhaust the commit ceiling and crash builds (`android/gradle.properties` heaps are trimmed as a safeguard).
- `L:` is `\\murkyserver\drop` (SMB): no Flutter symlinks, no creation-time writes, slow byte-wise reads — which is why tag reading, scanning, and artwork work all run in kill-capable isolates with timeouts.
- Artwork lookups make outbound calls to three public APIs (no keys or accounts); rate-limited, and they degrade silently to placeholders when offline.
