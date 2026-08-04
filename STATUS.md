# fooplayer — STATUS

*Current-state snapshot. History: [CHANGELOG.md](CHANGELOG.md) · Forward plan: [WORKPLAN.md](WORKPLAN.md). Last update: 2026-08-04.*

## Next session starts here

**Sync-page live progress SHIPPED (2026-08-04, build 2026-08-04--0324,
merged `0c19cb6`, 1.0.0+8).** Second VTC capture of the night: the Sync
page still showed only the button spinner while the numbers lived on the
strip/notification. The engine's progress line + determinate bar now
render under the Sync now button (new optional ActivityModel seam through
SyncUiSeams). Emulator-verified mid-transfer.

**Sync foreground service SHIPPED (2026-08-04, build 2026-08-04--0230,
merged `164ead8`).** The VTC-reported gaps — no sync progress indicator on
the phone, and syncs dying "connection closed midstream" when the app was
backgrounded — are both closed by one `dataSync` foreground service: its
notification carries a live progress bar, an in-app activity strip mirrors
it on the library screens, and Android keeps the network alive while
backgrounded. Emulator-verified end-to-end (92-file root synced while
HOME'd; clean service teardown; report dialog on return). Release on
dist.flana.app/fooplayer; tablet not USB-connected — tap-install from
there. versionCode now 1.0.0+7 (arm64 = 2007).

**Debugging postmortem worth remembering:** a night was nearly lost to a
phantom "sync stall regression" that was actually (a) an adb tap missing a
moved Settings tile by 100px, so no sync ever started, and (b) checking
`/storage/emulated/0/Music` for files when the engine's local home is the
app-private `files/` dir. The first vtc test run had in fact synced
perfectly. Rule reaffirmed: dump-verify EVERY navigation tap, and verify
the destination path from the code, not from assumption.

## Previous snapshot (2026-08-03)

**Plan 3 SHIPPED; tablet rollout DONE (2026-08-02).** The Tab S9+ runs the
release build with sync configured (host 192.168.1.16): probe Connected,
five roots discovered, and its playlists ("alt", "summer") auto-pushed to
the NAS `.playlists/` — first real cross-device playlist sync. The
hardware pass caught and fixed two release-only bugs (probe teardown
race; full-share-walk discovery — see CHANGELOG 2026-08-02--0034).
**Desktop rollout DONE (2026-08-03):** daily driver rebuilt from `main`
(windows-app `b156976`), first run migrated the real playlists — echos
(9), monthly (1,841), sheepy mixes (12) — into the shared `.playlists/`
sidecar alongside the tablet's alt + summer; monthly manifest's array
emptied with `.bak` kept, `playlistsMigrated` set, pre-migration
snapshot kept in session scratchpad. **All three devices now share one
playlist truth.** The phone Now Playing screen got its artwork-tinted
reskin (build 2026-08-02--2348). Remaining: (1) Mike's optional tablet
stress items (big pull, mid-transfer Wi-Fi kill, cancel button);
(2) the small **post-merge cleanup** list queued in CHANGELOG's TODO;
(3) player tint tuning on request.

**Parked, not forgotten:** a UI reskin (moving/restyling existing
controls) is deliberately punted until Mike runs a dedicated Claude-design
pass on it — see WORKPLAN's "Deliberately parked" section. Don't fold
visual tweaks into unrelated functional work before that pass happens.

## Component status

| Component | State |
|---|---|
| Core engine (`fooplayer_core`: content-ID hashing, manifests, scanner, seed, `foolib` CLI) | ✅ Stable, merged, untouched by later rounds (36/36 tests) |
| Library manifests | ✅ Five scoped roots seeded (monthly 1,844 / alt-times 2,398 / albums 685 / loose-2020 437 / loose-old 92); dates permanent, retag-proof. Library is now 100% MP3 + 3 FLAC (the 13 m4a were converted 2026-07-27, date-added carried across) |
| Windows desktop app | ✅ Daily driver. iTunes-style light UI, sortable columns, folder drill-down with breadcrumb + ↑ up-one-level, ctrl/shift multi-select (rows and filters), search ✕, auto-rescan, on-play duration backfill, click-to-select / double-click-play, instant right-click menus, playlists (create/delete/add/remove) with the four-column playlist view + cover/title/"N tracks · MM min" header, metro transport glyphs, blue shuffle |
| Android app | ✅ Phone-native UI v1 + background audio + one-level Back + tap-to-full-screen. Storage access sorted (all-files, needed because the manifest/artwork sidecars are not media files) and a **Set up** button seeds a root that has no manifest — on a phone there is no CLI, so "seed with foolib" was a dead end. Running live on the Galaxy Tab S9+ off a single `/storage/emulated/0/Music` root, 467 tracks, real download dates. With a single root the Folder pane opens inside it — no root-list row to tap first. **A tablet gets the full desktop panel layout** (sidebar, Folder/Artist/Album filters, sortable seven-column list, now-playing bar, footer) in both orientations — keyed to the shortest side ≥700 logical px, which is device size rather than window width, so rotating never changes which app it is. Touch equivalents for what that layout assumed about a mouse: long-press opens the row menu and toggles a filter value, and "View in folder" is hidden where there is no Explorer. A phone keeps the compact shell. Touch selection waits for the finger to lift and only counts if it stayed within the scroll slop, so flicking through the library no longer selects a track on every swipe. Installed and exercised on a real Galaxy Tab S9+ (SM-X810, Android 16), verified live on the emulator: drawer shell (Library/Folders/Artists/Albums/Playlists/Settings), date feed, mini-player, Now Playing with metro transport (no volume slider — hardware keys own it), browse views, playlist management. Launcher icon and splash are vector, generated by `tools/build_icon.py` from `app/assets/icon/fooplayer_icon.svg` (a single-outline SVG, sharp junctions), so the Android 12 splash is sharp instead of an upscale of 96px art; "fooplayer" label |
| Artwork in file tags (in-app) | ✅ **Run across the library 2026-07-28.** Sidebar action "Embed art in files", confirmed by a dialog and closed by a report that waits to be read (reasons listed with counts, biggest first). Zero failures, zero disturbed dates. The Art/Emb columns now correct themselves from the pass rather than showing what the tag cache last saw |
| Artwork in file tags (engine) | ✅ ID3v2 APIC / FLAC PICTURE, content ID and dates provably unchanged, unsafe files refused. The `notMpeg` guard now scans through up to 8 KB of junk between tag and first frame — but only in a file that opened with a real ID3v2 tag, and only onto a header whose version/layer/bitrate/sample-rate could genuinely decode. That rescued 28 real MP3s and still refuses the one MP4 wearing an `.mp3` name ([review list](docs/artwork-embed-review.md)) |
| Embedded-cover coverage | ⚠️ 3,284 of 5,553 files (59.1%), measured by reading the files rather than asking the app. By root: albums 684/685, monthly 1,746/1,904, loose-2020 430/474, loose-old 49/92, **alternative times 375/2,398**. The shortfall is almost entirely the VA bootleg compilations, where no provider has a cover and no loose image sits beside the audio — nothing skipped in error. Raising it further means finding art for those, not fixing the pass |
| Tag reading | ✅ Own ID3 reader (`id3_text.dart`) recovers what the upstream parser drops — frames behind a large picture, ID3v2.2 IDs, stacked tags. Artist reads TPE1 before TPE2 (359 files were showing the album artist). 1 track library-wide has no artist, and it genuinely carries no tag |
| Durations | ✅ Persisted in the manifest beside `date_added` (5,453 written), so a cache loss no longer costs the Time column. Zero tracks missing a duration; a timed-out read falls back to the header-only estimator |
| Album artwork | ✅ Auto-enrichment (iTunes / Deezer / Cover Art Archive — keyless; conservative auto-apply at ≥75 score with ≥10 margin) + picker on both platforms (grid, choose file, paste URL, search again, remove). Stored per-root in `.artwork/` + `.artwork.json` sidecar; two adversarial-review passes' findings fixed. **A hand pick is scoped to exactly the tracks selected when the picker opens** — never a shared album key, which used to let picking a cover for one track silently change others sharing an unrelated album label. Multi-select right-click ("Album artwork... (N tracks)") applies to the whole selection, individually. The automatic best-guess pass is still correctly album-wide |
| Test suite | ✅ 969 app tests + 44 core tests; `flutter analyze` at 2 pre-existing style hints in test files; Windows release and debug APK both build from one tree |
| Android emulator | ✅ Healthy under Microsoft WHPX (15s boots), data partition 16 GB, seeded with the real 444-file "loose tracks - 2020 and later" library. AEHD driver permanently removed after it bluescreened the machine |
| Repo location | ✅ Migrated: canonical repo is `L:\PROJECTS\fooplayer`; old `L:\PROJECTS\foobar` deleted and verified clear (no processes, services, tasks, or git references) |
| Background audio (Plan 2c) | ✅ **Done 2026-07-29.** Foreground service + media session: lock screen, notification, headset and Bluetooth transport. Audio focus handled separately because libmpv never requests it — a call pauses and hands back, a permanent takeover pauses for good, navigation ducks, headphones out pauses and never self-resumes. Verified on the Pixel 7 emulator: still PLAYING after HOME, media keys driving it |
| Tag editing | ✅ **Done 2026-07-29.** Edit one track or a selection; MP3 via ID3v2, FLAC via Vorbis comments. "Find correct tags…" proposes MusicBrainz matches with a confidence bar and never writes on its own. Same guarantees as the cover embedding: content ID unmoved, dates restored and read back |
| Queue | ✅ **Reworked 2026-07-30, three follow-up bugs found and fixed live on the Galaxy Tab S9+ the same day.** Two things share the playback mechanism and are kept visibly distinct: a normal play still continues through whatever list it was clicked from (the "faux queue" — ordinary, unmet, needs no panel), while the first "Play next" / "Add to queue" discards that continuation down to just the current track and starts a real, small, user-built scratch playlist — current track + whatever gets added, nothing inherited from browsing. That's the only thing the **Queue** view shows: a sidebar destination now (not a popup), appearing right under Library once there is one to show, disappearing again once emptied back down. Rows now use the exact same #/Song/Album/Time grid the playlist view uses (shared widgets, not a look-alike copy) with a cover thumbnail per row; the # column carries a play/drag icon instead of a position number, and a remove button sits past Time. Drag to reorder, tap to jump, remove, clear; the playing track cannot be removed out from under itself. "Play next" is offered for a single track only — a selection of ten gets "Add to queue". Fixed along the way: the sidebar tile was showing on every normal play (now requires the explicit-queue flag, not just "anything queued up next"); the window footer said "2,548 tracks" while viewing a 2-song queue (now counts the queue itself); the rows didn't visually match a playlist's rows at all (no #/Album/Time/header) |
| Phone library sync (Plan 3) | ✅ **Shipped 2026-08-01.** NAS-direct SMB on Android (Kotlin/SMBJ bridge, guest auth): per-root opt-in mirror with verified downloads (size + content ID in `.sync_tmp`), retag/move/delete propagation, resume-from-state after interruption, free-space check, cancel, file+bytes progress, report dialog. Emulator-verified live against the real NAS: 92/92 + 685/685 dates exact, connection-kill → 'connection lost' with real counts → clean convergence. Tablet hardware pass pending (checklist in CHANGELOG 2026-08-01--1930) |
| Synced playlists (`.playlists/` sidecar) | ✅ **Shipped 2026-08-01.** One shared sidecar dir at the library home (per-playlist JSON, stable ids, content-ID membership), LWW + backup + tombstones + resurrect-on-edit, auto-reconcile on Android (start/edit-debounce/5-min tick, probe-gated). Live-verified round-trip incl. deletion propagation and NAS-side backups. Real-library migration happens on the desktop's first new-build run — NOT yet done (see Next section) |
| APK distribution | ✅ dist.flana.app/fooplayer/index.html (R2, `fooplayer/` prefix in flana-dist, `dist/upload-r2.sh`) — newest build pinned on top, tap to install |
| File-dates fix (foobar2000/Explorer sorting) | ✅ **Fully resolved 2026-07-28, and independently verified** — 5,553 of 5,553 files match their manifest `date_added` (checked by reading the manifests directly, not by trusting any pass's self-report). The last 66 were duplicate paths: the stamping tool iterated `paths[0]` only, so where one content ID names two files, the twin kept its copy-event date. Every root accounted for: `monthly` folder-derived (canon), `alternative times` split into its two acquisitions, `albums` placed album-by-album (13 individually, 2 on recovered evidence). Zero files disagree with their manifest date. Details: [docs/albums-date-recovery.md](docs/albums-date-recovery.md). Was: **Resolved 2026-07-28** — option 1 applied: every track's filesystem date stamped from its manifest `date_added` (5,483 tracks, 1,724 re-stamped, 0 failures). This share reports creation time as equal to modified time, so both Explorer columns and foobar2000's sort are now correct; no NAS config change needed. Reversible via the logged previous values |

## Where things run

- Repo: `L:\PROJECTS\fooplayer` (`main` = everything merged) · GitHub: https://github.com/mklod/fooplayer
- Desktop build worktree: `C:\dev\foobar-app` (branch `windows-app`) → `app\build\windows\x64\runner\Release\fooplayer_app.exe`; desktop shortcut "fooplayer"
- Android build worktree: `C:\dev\fooplayer-android` (branch `android-app`) → `app\build\app\outputs\flutter-apk\app-debug.apk`
- App config/caches: `%APPDATA%\fooplayer\` (config v2 with the five roots, `meta_cache.json`)
- Artwork: `<library root>\.artwork.json` + `<library root>\.artwork\` (travels with the music folder)

*Worktrees must live on `C:` — the NAS share can't host Flutter's plugin symlinks. The `foobar-app` folder name is legacy; the path is stale, its branch and contents are current.*

## Last session (2026-07-31 → 2026-08-01)

- **Plan 3 built end-to-end and merged** (`2309289` on main): brainstorm →
  approved spec → 12-task implementation plan → subagent-driven execution
  with a fresh implementer + adversarial reviewer per task. The review
  loop caught 18 Critical/Important defects before merge — highlights: a
  no-op playlist write that stamped `modified` and could out-vote a real
  edit under LWW (or resurrect a deletion), a planner rename-collision
  that silently dropped a remote file from the plan for a cycle, the
  migration re-running on every launch pre-frame, an Android
  Activity-recreation bug that orphaned the SMB bridge (sync dead until
  process restart + leaked sockets), a head-of-line-blocked cancel, and
  a `finally`-block `close()` that could replace a successful sync's
  report with an invisible error.
- **Live verification on the emulator against the real NAS** (tablet
  hardware pass still pending): fresh mirrors of two roots with
  byte-exact dates/durations, no-op re-sync, Wi-Fi killed mid-transfer →
  per-root 'connection lost' abort with true counts and per-file
  reasons, `.sync_tmp` clean, no manifest adopted → network back →
  re-run converged without re-downloading the 46 files that had landed.
  Playlists: created on-device → auto-pushed to the NAS in ~15s;
  NAS-side edit pulled on app start; a future-dated edit correctly
  RESURRECTED a locally-deleted playlist (LWW doing its job); re-delete
  after the clock passed → NAS file removed, tombstone + backup written
  remotely.
- **Side quest (user request): APK downloads page** — `dist/upload-r2.sh`
  clones flana's R2 pattern under the flana-dist `fooplayer/` prefix
  (decision: reuse bucket+token, zero new infra; S3 ListObjectsV2 for the
  index because the NAS bearer token 403s on the REST list). Bookmark:
  https://dist.flana.app/fooplayer/index.html
- Also fixed in passing: `SettingsDialog` dropping `onSetUpRoot` (tablets
  never saw the root "Set up" button).
- Suites: 1097 app + 100 core tests green; `flutter analyze` clean (3
  pre-existing infos). Plan worktree removed; `plan3-sync` branch deleted
  after merge.

## Earlier session (2026-07-30)

- **Two more Queue bugs reported live, with a screenshot comparison, right
  after the art-thumbnail build shipped**: "I'm in a queue of two songs,
  and the bottom status bar says 2,548 tracks" and "the cue does not match
  the playlist view... the formatting is different from the cue
  formatting." Both real, both fixed:
  - The footer's track count always read `LibraryModel.visibleTracks`,
    which the Queue destination deliberately leaves untouched (browsing
    state, not repurposed) rather than a queue-aware count — it now
    counts the queue itself while the queue is what's showing.
  - The art-thumbnail pass had kept the Queue's old bespoke row shape (a
    `ListTile` with no `#`, no Album, no Time, no column header) even
    after adding the cover — a real formatting mismatch next to a
    playlist's four-column grid. Rows now use `SongCell` and
    `PlainHeaderLabel` straight from track_list.dart (made public for
    this, not re-copied — a copy is what drifted last time), so a Queue
    row and a playlist row are built from the same widgets and can't
    silently diverge again.
  - Both verified fail-without-fix, then live on the Galaxy Tab S9+
    (footer reads "2 tracks" with a 2-song queue open; rows show
    #/Song/Album/Time matching a real playlist screenshot taken in the
    same session for comparison).
- **Queue rows now show album art**, matching every other playlist view —
  "queue needs formatting like any other playlist, with art showing."
  Same 36px `AlbumArt` thumbnail, same resolver, on both the desktop
  Queue destination and the phone's `QueueView`.
- **Found and fixed a real bug while verifying it live on the tablet**:
  the sidebar's Queue tile was appearing on every normal play, not just
  after an explicit queue action, because its visibility check only
  looked at whether anything was queued up next — and a normal play's
  faux-queue continuation covers the whole filtered library, so that was
  almost never empty. Now also requires the explicit-queue flag. The
  test that should have caught this was seeding a single-track faux
  queue (side-stepping the real condition) and asserting after a
  `pump()` that never actually rebuilt anything — both fixed alongside
  the app bug, verified fail-without-fix before restoring it.
- Also this session (folded into the 2026-07-30--0103 build, see
  CHANGELOG): the Queue redesign itself (faux vs. explicit queue,
  sidebar destination not a popup) and the Folder filter panel no longer
  showing the library root's own name at any depth.
- **Session wrap-up**: the Queue work is done and verified; a UI reskin
  (moving/restyling buttons) was raised but explicitly punted until Mike
  runs a dedicated Claude-design pass on it, rather than iterating it live
  — see WORKPLAN's "Deliberately parked" section. **Persistent, synced
  playlists** (no account/login — same-shared-folder mechanism as the rest
  of the library) was scoped as a new requirement to fold into Plan 3's
  design, not yet implemented — see WORKPLAN's Next section and
  CHANGELOG's TODO. Next session starts on **Plan 3, phone/LAN library
  sync.**

## Earlier session (2026-07-29)

- **A hand-picked cover no longer leaks to other tracks.** Reported live:
  fixing "Forgotten Dreams"'s art also silently changed "Colourful Emotions"
  and "Peaceful Solitude" — three unrelated tracks sharing a made-up album
  name, "Sheepy Mixes". The picker used to write both the track's own pin
  and the shared album key, reasoning that album-mates without a pick of
  their own should inherit one; the app has no way to tell a real album from
  a shortcut label, so that reasoning was the bug. A pick now writes only
  the track(s) explicitly selected, and multi-select (right-click a
  Ctrl/Shift-click block → "Album artwork... (N tracks)") applies to exactly
  that selection. The automatic best-guess pass is unchanged.
- **The tablet's library works off one root.** Two bugs, both found live. The
  app held **no storage permission at all**, so a folder with 474 tracks and a
  manifest in it showed nothing — it could list the folder and not open a
  single file in it. And once it could read, setting up `/Music` **reset every
  download date to today**: the music had been copied over as one folder, so
  every file's mtime was the copy's timestamp and the real 2019–2026 dates
  existed only in the `.library.json` that came with it. Seeding now adopts
  dates from any manifest already inside the folder, keyed by content ID,
  earliest wins — 467/467 dates and 467/467 durations verified against the
  original manifest. The rescan path had the same hole and is fixed too, which
  is the one that matters: dropping `monthly/` in later must not date it today.

- **Tag editing shipped end to end** — manual edits (MP3 + FLAC), a MusicBrainz matcher that proposes but never writes, applied optimistically so the library updates the instant you press Save while the files are written in the background.
- **Plan 2c done**: background audio on Android with lock-screen/notification controls and proper audio-focus handling, verified on the emulator. Installed on the Galaxy Tab S9+ too.
- **Phone navigation fixed**: tapping a song opens the full-screen player; Back unwinds one level and backgrounds the app at the root instead of closing it.
- **The queue is now an editable scratch playlist** with Play next / Add to queue and a Queue view on both platforms.
- **Five live-use bugs**, each with a regression test verified to fail without the fix: playlists refused during a scan, "Scanning…" showing permanently, ten-second tag edits, a search box that kept text the model had forgotten, and artwork orphaned by retagging.
- Now playing sits above the footer, can be dismissed, and the footer carries the transport as text while it is.

## Earlier session (2026-07-28, evening)

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
