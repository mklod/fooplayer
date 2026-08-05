# fooplayer — CHANGELOG

*What shipped, when. Newest first. Status: [STATUS.md](STATUS.md) · Plan: [WORKPLAN.md](WORKPLAN.md).*

## TODO
> [!tip] Queued for next build
> - **Post-merge cleanup from Plan 3's final review** (triaged non-blocking,
>   2026-08-01): reconciler re-read-before-overwrite guard (narrow
>   edit-during-reconcile window can overwrite a local edit with only the
>   pre-edit backup); shallow `listDir` for sync-root discovery (currently
>   walks the whole share); structural `smb_no_session` error code instead
>   of the substring match; post-sync rescan retry when the periodic tick
>   holds the flag; connect timeout 3s < probe 5s; sidecar deletions not
>   mirrored; assorted test-coverage and doc nits from per-task reviews.
> - **Playlist `modified_by` shows "localhost" on Android** (found
>   2026-08-02): `Platform.localHostname` is useless there — use a real
>   device label (Build.MODEL via a channel, or default the config
>   `deviceName` per platform).
> - **Inline metadata editing in the track list** (raised 2026-07-31):
>   edit a track's artist/title/album/etc. directly in its row, like an
>   Excel spreadsheet cell — click into the field, type, commit — instead
>   of only through the tag-edit dialog. Same write path and invariants as
>   the existing tag editing (content ID unmoved, file dates restored).
> - **Tag lookup must prefer the ORIGINAL release over later compilations.**
>   A 1970s track should not have a ca. 2000s Various-Artists mixtape or
>   collection promoted over the album it actually came from — and the album
>   decides the artwork query, so a wrong album also costs the good cover.
>   Two concrete problems in `metadata/tag_scoring.dart` + `tag_providers.dart`:
>   1. **Nothing currently distinguishes releases at all.** Every release of a
>      recording gets identical title (40) / artist (30) / duration (20)
>      scores, because those fields are per-recording. So which release wins is
>      decided by the 10-point album term alone, or arbitrarily.
>   2. **That album term rewards agreeing with the tag being corrected.** It
>      scores the candidate album against the file's *current* album — so on a
>      file whose album is wrong, the closest match to the wrong value wins.
>      Backwards for the one job it has.
>   Fix: add a release-preference term fed by data MusicBrainz already has but
>   the query does not ask for (`inc=releases+release-groups`) — penalise
>   `secondary-types` of Compilation / DJ-mix / Mixtape+Street / Live / Remix,
>   penalise a release credited to Various Artists, and reward a release date
>   equal to the release-group's `first-release-date` (that is what "original"
>   means). Then stop scoring album against the existing tag.

## Build 2026-08-05--0056

APK: https://dist.flana.app/fooplayer/index.html (tap-install)

### Changes

- **Dark mode.** Android follows the system setting — flip the phone to
  dark and the whole app re-skins live, no restart (verified both
  directions on the emulator). The dark palette mirrors the light theme's
  iTunes grey-stepping in near-blacks: #1C1C1E window, stepped panels/bars,
  light ink, the same blue accent, deep-blue selection fill;
  brightness-aware Material scheme, status-bar icons, and phone chrome
  follow. Desktop keeps the light iTunes look untouched. (Mechanism:
  AppColors' tokens became mutable statics swapped in place — all 59
  const usages de-consted analyzer-driven.)
- **Queue opens at the playing track** (reported live: shuffling the whole
  library buried the current row thousands of entries down and the Queue
  button dropped you at the top). It now opens scrolled so the playing row
  is first; after that the scroll is yours. 1.0.0+15.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Toggle system dark mode with the app open: everything re-skins live, both directions, nothing unreadable
>   - Notes:
> - [ ] Queue button during a big shuffle lands on the current track
>   - Notes:
> - [ ] Tablet (desktop layout, Android): dark mode also applies there — flag anything that looks off
>   - Notes:

## Build 2026-08-05--0007

APK: https://dist.flana.app/fooplayer/index.html (tap-install)

### Changes

- **Transport buttons at Apple-Music proportions** — pause was oversized
  (68px against 48px neighbors). Now previous/next 44px, play/pause 48px,
  wider 40px gaps: near-equal visual weight, pause just a touch larger,
  per the reference. 1.0.0+14.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Player transport reads like the Apple Music reference (balanced sizes, airy spacing)
>   - Notes:

## Build 2026-08-04--2358

APK: https://dist.flana.app/fooplayer/index.html (tap-install)

### Changes

- **Background audio no longer dies after a track switch** (reported live:
  "audio cut out randomly early in the song, in BG playback, til I …
  pause/play [on the notification] and it resumes"). Two stacked causes:
  mpv emits a transient `playing=false` at every end-of-file before the
  next track's open flips it back, and the audio service was configured to
  drop out of the foreground on pause — so every auto-advance while
  backgrounded flapped the service out of/into the foreground, exactly
  the window where Android demotes/freezes a process (the notification
  tap is a MediaSession command whose foreground-start exemption
  restored it, which is why that always worked). Now the playback service
  stays foreground for the whole session, the EOF flicker is debounced
  away (400ms — a false erased by the next track's true never escapes),
  and explicit play/pause update the UI optimistically. 1.0.0+13.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Background playback across many auto-advances (screen off, 15+ min): no dropouts
>   - Notes:
> - [ ] Notification play/pause icon stays truthful across track switches
>   - Notes:

## Build 2026-08-04--2348

APK: https://dist.flana.app/fooplayer/index.html (tap-install)

### Changes

- **Player glyphs uncircled.** The metro transport PNGs had the circle
  baked into the pixels — new ring-free variants were generated from the
  originals (ring erased radially, inner glyph rescaled to fill the
  canvas) and the player page now uses them: bare ⏮ ▶/⏸ ⏭ at the same
  large sizes. Shuffle and the ⋯ overflow lost their translucent circles
  and grew (30px / 34px); shuffle-on is the same bare arrows in accent
  blue. Desktop bar and mini player keep the circled originals. 1.0.0+12.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Player: all five controls bare (no rings), shuffle/⋯ noticeably bigger; shuffle-on turns the arrows blue
>   - Notes:

## Build 2026-08-04--1845

APK: https://dist.flana.app/fooplayer/index.html (tap-install on phone; **tablet already updated over USB** — arm64 2011)

### Changes

- **Artwork on desktop but not on the phone — fixed, two stacked causes**
  (confirmed on The Streets "Computers and Blues" + the Japanese edition;
  systemic for every album whose art is a folder image):
  1. LAN sync **never copied folder images at all** — the planner's
     manifest-joined walk moved audio and `.artwork` sidecars only, so
     `cover.jpg` never left the NAS. `folder`/`cover`/`front` ×
     `.jpg`/`.jpeg`/`.png` now sync with the same state-tracked sidecar
     semantics (name-exact, so booklet scans stay home). **Run a sync on
     each device to pull the images down.**
  2. The artwork resolver probed exact lowercase filenames — Windows'
     case-insensitive filesystem forgave `Folder.jpg`/`COVER.JPG`, Android
     never did. The sibling lookup now lists the directory once and
     matches case-insensitively.
- **Swipe down anywhere on the player = dismiss**, same as the top-left
  chevron (the scroll view yields the gesture whenever the content fits
  the screen). 1.0.0+11.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] After a sync: The Streets albums (and other folder-image albums) show art on phone/tablet
>   - Notes:
> - [ ] Swipe down on the player closes it; seek drag still works
>   - Notes:

## Build 2026-08-04--1725 (desktop)

Daily driver rebuilt (`C:\dev\foobar-app`, windows-app @ `191f46d`) — launch via the usual "fooplayer" shortcut.

### Changes

- **Arrow keys move the library selection** (reported live: they did
  nothing — only Ctrl+A was ever handled). ArrowUp/Down move the
  highlighted row with Explorer semantics: Shift+arrow extends the range
  from the anchor, holding the key walks, ends are clamped, and the list
  scrolls just enough to keep the selection on screen.
- **Right-click the bottom-left corner art preview → full-resolution
  artwork viewer**: read-only modal with the real pixels (up to 85% of the
  window) and a `WxH px` caption. Left-click still opens the picker.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Click a track, arrow up/down through the library; Shift+arrow grows the selection; list follows
>   - Notes:
> - [ ] With nothing playing and a track selected, right-click the corner cover → full-res popup
>   - Notes:

## Build 2026-08-04--1655

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tap-install)

### Changes

- **Now Playing rebuilt to the Apple-Music reference** (two screenshots
  provided). Artwork pushed to the top with flexible breathing room;
  title / artist / **source folder** left-aligned (folder = the file's
  immediate parent directory, e.g. "loose tracks - old"); shuffle and
  overflow are now small circular translucent buttons to the right of the
  title block (the reference's star/dots); the seek bar is a fat 7px
  rounded fill with **no thumb dot**, still draggable, with the times
  directly beneath it (current position left, total right); exactly three
  large transport controls (previous / play-pause / next). 1.0.0+10
  (arm64 = 2010).
- **Persistent bottom shortcut bar on the player** (per the second
  reference): Library · Queue · Folders · Artists · Playlists. Tapping one
  closes the player and jumps the shell straight to that view — verified
  live (player → Folders).

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Player matches the reference: left-aligned text, thumbless fat seekbar, times under the bar, three big buttons
>   - Notes:
> - [ ] Third metadata line shows the track's source folder
>   - Notes:
> - [ ] Bottom bar shortcuts land on the right views with the mini player showing
>   - Notes:

## Build 2026-08-04--0341

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tap-install)

### Changes

- **Phone chrome made readable** (reported live: transport buttons "black
  and much too small", library text / drawer / mini player all too small).
  - **Transport glyphs were literally invisible-by-default**: the metro
    PNGs are baked ink-dark (~#1D1D1F), not white as `MetroIcon`'s doc
    claimed, and prev/play/next never passed a tint — black icons on the
    dark player gradient. Now explicitly white and much larger
    (prev/next 40px, play/pause 60px, shuffle 32px, tightened gaps so a
    360dp screen still fits the row).
  - **Phone-scaled theme ramp**: `buildAppTheme(phone: true)` — 15px rows
    / 13px subtitles (up from the desktop's 13/11.5), standard density,
    non-dense ListTiles — applied via `MaterialApp.builder` so every phone
    route inherits it. Desktop AND tablet (which uses the desktop panel
    layout) are untouched.
  - **Mini player**: 76px bar, 56px art, 40px play/pause (was 64/48/32).
  - **Drawer** widened to 340dp; track rows now take theme sizes; folders
    breadcrumb and details dialog bumped to match.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Player screen: prev/play/next clearly white and comfortably large on any cover
>   - Notes:
> - [ ] Library/browse rows, drawer, mini player: text readable at arm's length
>   - Notes:
> - [ ] Tablet + desktop unchanged (dense iTunes look preserved)
>   - Notes:

## Build 2026-08-04--0324

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tap-install)

### Changes

- **The Sync page itself now shows live progress** (voice capture
  2026-08-04: "still just shows spinning wheel… no transparency"). The
  notification and library-screen strip had the numbers, but the page with
  the Sync now button — where you actually watch a sync — showed only the
  button's 16px spinner. The engine's own progress line ("Syncing loose
  tracks - old — 59.1 MB — 13 / 126") plus a determinate bar now render
  directly under the button, updating live. New optional `ActivityModel`
  seam through `SyncUiSeams`; desktop's sync dialog gets the same line for
  free. 1.0.0+8 (arm64 = 2008).

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Sync now on the phone: progress text + bar appear under the button within a few seconds and count up
>   - Notes:

## Build 2026-08-04--0230

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tap-install on phone/tablet)

### Changes

- **LAN sync now shows progress on the phone and survives backgrounding**
  (voice capture 2026-08-03 + "connection closed midstream" follow-up).
  Three pieces, one fix: (1) a `dataSync` foreground service holds the
  network alive while the app is backgrounded — Android was cutting the
  process's connections the moment the screen locked, which is exactly the
  mid-sync "connection closed" that was reported; (2) the service's
  mandatory notification doubles as the missing status indicator — live
  label, MB count, and a determinate progress bar in the shade; (3) a slim
  in-app activity strip on the phone's library screens mirrors the same
  progress ("Syncing loose tracks - old — 68.0 MB — 14 / 126"). Verified
  on the emulator end-to-end: full 92-file root synced with the app
  HOME'd mid-transfer, notification live throughout, service torn down
  clean at completion, report dialog surfaced on return. Notification
  permission is requested once, when the first sync job appears.
- Answer to "does fooplayer need to stay in the foreground during the
  entire sync?": **no longer.** Start the sync, background the app; the
  notification tracks it.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Start a sync on the phone, press Home mid-transfer: notification shows progress, files keep landing, "Sync finished" dialog waits when you come back
>   - Notes:
> - [ ] Library screens show the bottom activity strip while a sync runs
>   - Notes:
> - [ ] First sync on a fresh install asks for notification permission once
>   - Notes:

## Build 2026-08-02--2348

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tablet updated over USB)

### Changes

- **Now Playing reskin (the commissioned design pass, scoped to the
  player screen).** Full-bleed immersive page: the whole background takes
  a muted wash of the artwork's dominant color — extracted per track
  (12-bucket HSV vote, near-grey pixels excluded, circular-mean hue),
  then deliberately muted (saturation and brightness clamped into a
  slate band) so ANY cover produces the same calm, readable feel; 400ms
  crossfade between tracks, neutral slate fallback for bare art.
  Layout: dismiss chevron, large rounded artwork with soft shadow,
  title/artist/album·date centered in white, white seekbar, and exactly
  five controls — shuffle (blue when on) · previous · play/pause ·
  next · an ⋯ opening the existing track sheet. Metro glyphs unchanged.
  Deliberately absent: repeat, EQ, volume (hardware keys), rew/ffwd.
  Verified live on the emulator across warm and dark covers.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] Player screen: tint follows the artwork and changes with the track; text readable on your brightest and darkest covers
>   - Notes:
> - [ ] Five controls only; ⋯ opens the usual track sheet; chevron closes; Back still works
>   - Notes:

## Build 2026-08-02--0034

APK: https://dist.flana.app/fooplayer/index.html (newest release on top; tablet already updated over USB)

### Changes

- **First real-hardware pass on the Tab S9+ — two release-only bugs found
  live and fixed.** (1) The sync probe reported "NAS unreachable" on a
  perfectly reachable NAS: SMBJ's session teardown races Samba's logoff,
  the second logoff throws STATUS_USER_SESSION_DELETED — from inside the
  probe's `.use{}` chain, AFTER the actual check had already succeeded.
  Release-build timing hit it deterministically; debug and the emulator's
  NAT latency dodged it. Cleanup now runs in a `finally` and can never
  veto the answer. (2) Root discovery walked the ENTIRE share (~15k files
  over Wi-Fi — minutes) to derive five folder names; the roots list looked
  permanently stuck. New shallow `listDir` bridge call: one round trip,
  all five roots in seconds.
- The SMB bridge now logs probe/discovery steps (`fooplayer.smb` tag) —
  the silent catch-everything probe is what made this take hours to find.
- **versionCode discipline**: `--split-per-abi` mints versionCode
  1000×abi+N (arm64 release = 2001), which then BLOCKS any plain build
  (code 1) from installing. pubspec is now `1.0.0+3`; bump the build
  number every release.
- Verified end-state on the tablet: probe Connected, five roots discovered
  in seconds, and the tablet's real playlists ("alt", "summer") were
  auto-pushed to the NAS `.playlists/` by the scheduler — the first real
  cross-device playlist sync. Desktop picks them up when it gets the new
  build.

## Build 2026-08-01--2005

APK: https://dist.flana.app/fooplayer/fooplayer-2026-08-01--2005-release.apk (26 MB — first RELEASE build)

### Changes

- **Fixed: "Set up" looked like it did nothing** (reported live from
  Mike's phone, first real phone install, within the hour of release —
  reproduced and root-caused on the emulator). Two silent failures
  stacked: a denied/backed-out All-files permission bailed with no
  feedback, and a SUCCESSFUL seed never refreshed anything —
  `rootsMissingManifest` only updates inside `load()`, so the row kept
  saying "not set up yet" and the library stayed empty until an app
  restart or the 5-minute tick. Now every outcome speaks:
  denied → SnackBar with an "Open settings" action; failure → the
  library's status line; success → "Set up complete — N tracks found"
  AND an immediate library reload (row refreshes, feed populates).
  Verified end-to-end on the emulator in release mode, both paths.
- **The dist page now serves RELEASE builds — 26 MB instead of 200.**
  The debug APKs carried the Dart JIT runtime, debug symbols, and four
  CPU architectures. First release build surfaced the R8/SMBJ issue
  Task 10's review predicted: `-dontwarn` rules added for SMBJ's
  Kerberos/EL corners (dead code on Android; guest auth only). Release
  verified live: Set-up flow, tag reading, SMB probe + five-root
  discovery against the real NAS.
- Known papercut (pre-existing, queued): the launch-time All-files
  request can background the app right after the audio-permission
  dialog on a fresh install — the contextual Set-up/sync requests are
  the reliable path now; consider dropping the launch-time request.

### Testing Checklist

> [!warning] Testing Checklist
> - [ ] On the phone: install the release build, add your music folder, tap Set up → grant All files access → expect "Set up complete — N tracks found" and the library populating immediately
>   - Notes:
> - [ ] Deny the permission instead → expect the "needs All files access" SnackBar with Open settings
>   - Notes:

## Build 2026-08-01--1930

APK: https://dist.flana.app/fooplayer/fooplayer-2026-08-01--1918-app-debug.apk

### Changes

- **Plan 3 shipped: LAN library sync.** One-button SMB pull straight from
  the NAS on Android — no desktop needed, no server, guest share as-is.
  Settings → Sync: NAS host/share/base (prefilled), a checkbox per
  discovered root, Check connection, Sync now with live file+bytes
  progress in the footer, a Cancel button that actually interrupts the
  transfer, and a report dialog that waits to be read (files copied with
  MB, updated, renamed, deleted, adopted — failures listed with reasons,
  aborted roots say why). True mirror per checked root: new files copied,
  retags re-copied (even when ID3 padding keeps the size identical), NAS
  moves become local renames without re-downloading, NAS deletions
  mirrored and reported, hand-seeded files adopted without copying.
  Every download is verified by size AND content ID in `.sync_tmp`
  before it enters the library; interrupted syncs resume from
  `.sync_state.json` (verified live: 46 files landed pre-kill were not
  re-downloaded); a mid-transfer connection loss aborts that root with
  its real counts after 3 consecutive failures. Dates provably survive:
  92/92 and 685/685 `date_added` + durations matched the NAS manifests
  byte-for-byte on the emulator's first syncs.
- **Persistent playlists, synced across devices, no account/login**
  (closes the 2026-07-31 TODO): playlists moved out of each root's
  `.library.json` into one shared `.playlists/` sidecar at the library
  home (one JSON file per playlist, stable id, content-ID membership) —
  desktop reads/writes it live on `L:`, Android reconciles automatically
  on app start, 3s after any playlist edit, and on the 5-minute tick,
  silently skipping when the NAS is unreachable. Conflicts resolve
  whole-playlist last-write-wins with the loser snapshotted to
  `.playlists/backup/`; deletions propagate via tombstones; an edit
  newer than a deletion resurrects the playlist (all three verified live
  against the real NAS, including the backup landing on the NAS).
  One-time idempotent migration runs at startup and empties the manifest
  arrays; a `playlistsMigrated` flag keeps it off the hot path after.
- **APK downloads page** (closes the 2026-07-31 TODO):
  https://dist.flana.app/fooplayer/index.html — R2-backed under the
  flana-dist bucket's `fooplayer/` prefix, newest build pinned on top,
  regenerated by `dist/upload-r2.sh` on every upload.
- **Fixed in passing:** `SettingsDialog` dropped `onSetUpRoot`, so
  tablets (desktop layout) never showed the root "Set up" button.
- Process: 12-task subagent plan; every task adversarially reviewed with
  fix rounds (18 Critical/Important findings caught and fixed pre-merge,
  incl. an LWW-poisoning no-op write, a rename-collision that silently
  dropped files, and an Android Activity-recreation bridge leak); final
  whole-branch review + live emulator verification against the real NAS
  before merge. 1097 app + 100 core tests green.

### Testing Checklist (tablet — Galaxy Tab S9+)

> [!warning] Testing Checklist
> - [ ] Install from https://dist.flana.app/fooplayer/index.html (tap newest build; updates in place)
>   - Notes:
> - [ ] Settings → Sync: set NAS host to `192.168.1.16` (name won't resolve on Android), Check connection succeeds
>   - Notes:
> - [ ] Sync a small root first (loose tracks - old): dates correct in the feed, tracks play
>   - Notes:
> - [ ] Kill Wi-Fi mid-sync of a big root: report says "connection lost" with real counts; re-run converges without re-downloading what landed
>   - Notes:
> - [ ] Cancel button stops a large transfer
>   - Notes:
> - [ ] Make a playlist on the tablet → appears on desktop (after desktop runs the new build); edit on desktop → appears on tablet within ~5 min at home
>   - Notes:
> - [ ] Real-hardware quirks: non-ASCII filenames sync correctly; battery/thermals during a multi-GB pull; "Don't keep activities" ON → background → return → sync still works
>   - Notes:
> - [ ] ROLLOUT ORDER: tablet may upgrade any time (its playlists push first and dedupe later). Desktop's first run of the new build migrates the REAL library's playlists to `.playlists/` — old builds stop seeing playlists after that, so upgrade both ends the same day
>   - Notes:

## Build 2026-07-30--0205

### Changes

- **Queue rows now match the playlist view's column layout exactly.**
  Reported live with a side-by-side screenshot: "the cue does not match
  the playlist view... if you create a playlist, the formatting is
  different from the cue formatting." The previous build added a cover
  thumbnail to Queue rows but kept a bespoke shape with no `#`, no
  Album, no Time, and no column header — exactly the mismatch the
  screenshot caught. Rows now use the same `#`/Song/Album/Time grid as
  a playlist, built from the actual widgets the playlist view uses
  (made public for reuse rather than duplicated, since a duplicate is
  what drifted out of sync last time). The `#` column carries the
  play/drag icon instead of a position number; a remove button sits
  past Time.
- **Fixed: the footer said "2,548 tracks" while viewing a 2-song
  Queue.** Reported alongside the formatting bug. The footer's track
  count was always reading the underlying library view's track count,
  which the Queue destination deliberately leaves untouched rather than
  repurposing. It now counts the queue itself while the queue is what's
  showing.

> [!warning] Testing Checklist
> - [ ] Open the Queue — header row reads #, SONG, ALBUM, TIME, same as
>       a playlist; each row shows its album and duration
>   - Notes:
> - [ ] While the Queue is open with 2 songs in it, the footer at the
>       bottom of the window says "2 tracks", not the full library count
>   - Notes:
> - [ ] Click back to Library or a playlist — the footer count goes back
>       to the full/filtered count immediately
>   - Notes:

## Build 2026-07-30--0139

### Changes

- **Queue rows now show a cover, like every other playlist row.**
  "Queue needs formatting like any other playlist — with art showing."
  Each row carries the same 36px `AlbumArt` thumbnail the playlist view
  uses, resolved the same way (embedded art, sidecar, sibling file), so a
  track looks like the same track whichever list it's seen in.
- **Fixed: the Queue sidebar tile was appearing on every normal play, not
  just after an explicit queue action.** Found while verifying the art
  change on-device — double-clicking a track and doing nothing else was
  enough to make "Queue" show up in the sidebar, even though nothing had
  been explicitly queued. Root cause: the tile's visibility check only
  asked "is there anything queued up next" (`upcoming.isNotEmpty`), but a
  normal play's faux-queue continuation IS the rest of the filtered
  library — so `upcoming` is essentially never empty during ordinary
  playback. Fixed by also requiring `hasExplicitQueue`. The test that
  should have caught this was seeding the faux queue with a single track
  (sidestepping the real condition) and asserting after a `pump()` that
  never actually triggered a rebuild — both fixed alongside the real bug.

> [!warning] Testing Checklist
> - [ ] Double-click a track and just let it keep playing — no "Queue"
>       tile appears in the sidebar (faux queue, nothing explicit)
>   - Notes:
> - [ ] Right-click another track → Add to queue — the Queue tile now
>       appears, current track keeps playing uninterrupted
>   - Notes:
> - [ ] Open Queue — both tracks show, each with its own cover art,
>       matching the look of a regular playlist row
>   - Notes:

## Build 2026-07-30--0103

### Changes

- **The Queue no longer inherits the whole library.** Double-clicking a
  track (desktop) or tapping one (phone) is still a normal music player —
  it keeps playing through whatever list it was clicked from, current
  sort/filter, shuffle or not, exactly as before. But that continuation
  is a "faux queue": nothing the user built, and it is never what the
  visible **Queue** means. The moment "Play next" / "Add to queue" is
  used for the first time, that faux continuation is discarded down to
  just the track playing, and from then on it is a real, small,
  user-built scratch playlist — current track plus whatever gets added,
  nothing inherited from browsing. A second explicit add builds on the
  first rather than re-discarding it; a fresh normal play ends the
  scratch playlist and starts a new browsing session. `QueueController`
  gains `hasExplicitQueue` to tell the two apart; nothing about ordinary
  continuous playback changed.
- **Queue is a sidebar destination now, not a popup.** Moved from the
  bottom action group (Rescan/Enrich/Embed/Settings) to right under
  **Library**, above the saved playlists. Clicking it swaps the main
  content area — search field, Folder/Artist/Album filters, track list —
  for the queue itself, the same way clicking a playlist does; no dialog
  anywhere. It only appears once there is a real queue to show (the faux
  one needs no panel of its own — it's just whatever the library view
  already shows); clicking Library or a playlist leaves it without
  clearing it, so more can be queued while browsing and it is reachable
  again.
- **The Folder filter panel no longer shows "Music."** Not just at the
  top (fixed yesterday) — at every depth. Drilled into `monthly` now
  shows just "monthly," not "Music › monthly": a single library root
  names a place nothing is ever NOT under, so putting its own name in
  front of every real folder was a header nobody could act on. With
  several roots (the desktop's five) a root's name is real information
  and nothing changes.
- Fixed in passing: clicking Library after viewing a playlist was
  resetting the Folder pane to *empty* on a single-root device — the
  exact "tap the root before you see anything" bug from yesterday,
  reappearing through a second code path (`setPlaylist` hard-coded `[]`
  instead of resetting to the implicit root). Both now go through one
  shared reset.

> [!warning] Testing Checklist
> - [ ] Double-click a track in the full library — it plays and keeps
>       going into the next one, same order as the column sort
>   - Notes:
> - [ ] No "Queue" in the sidebar until you right-click → Add to queue
>   - Notes:
> - [ ] After Add to queue: sidebar shows Queue, right under Library;
>       clicking it shows current track + what you added, nothing else
>   - Notes:
> - [ ] Add a second track to the queue — both stay, in order added
>   - Notes:
> - [ ] Click Library, browse elsewhere, add another track to the queue
>       — it's still there when you click Queue again
>   - Notes:
> - [ ] Remove every added track from the queue — the Queue sidebar
>       entry disappears again
>   - Notes:
> - [ ] Let the queue play out to the end — playback stops, does not
>       fall back to the library
>   - Notes:
> - [ ] Folder panel: drill into any subfolder — no "Music" prefix
>       anywhere in the breadcrumb
>   - Notes:

## Build 2026-07-29--2354

### Changes

- **Adding art to one track adds art to that one track — nothing else.**
  Reported live: editing "Forgotten Dreams"'s cover also silently changed
  "Colourful Emotions" and "Peaceful Solitude", three unrelated YouTube mixes
  that happen to share a made-up album name, "Sheepy Mixes". Root cause: a
  hand pick in the picker wrote BOTH the track's own pin and the shared
  album key, on the reasoning that "album-mates without a pick of their own
  should still inherit one" — a real album's tracks share a name because
  they're a real release; twelve YouTube mixes share a name because someone
  needed a shortcut, and the app cannot tell those apart. So it no longer
  guesses: **a hand pick now writes ONLY the track (or tracks) that were
  explicitly selected when the picker was opened, never the album key.**
  Same fix, same reasoning, for "Remove artwork".
- **Multi-select now means what it looks like it means.** Ctrl/Shift-click a
  block of tracks, right-click, "Album artwork... (N tracks)" — the search
  is anchored on whichever row was clicked, but a pick (or a removal)
  applies to every track in the selection, individually. The picker header
  says so explicitly ("Applies to N selected tracks") so it is never a
  surprise. A single row keeps the old plain label and behaviour.
- The automatic best-guess pass (the one that quietly fills in reasonable
  covers across the whole library) is **unaffected** — it still applies at
  the album level, which is the right thing for a bulk pass with no
  per-track curation, and it is what "Enrich artwork" already did correctly.
  Only the interactive picker's guess-by-inheritance was the bug.

> [!warning] Testing Checklist
> - [ ] Select 3 unrelated tracks (different albums), right-click → "Album
>       artwork... (3 tracks)"; pick a cover → all 3 show it, nothing else
>       on the library changes
>   - Notes:
> - [ ] Same selection → Remove artwork → all 3 go back to no cover
>   - Notes:
> - [ ] Single track: menu says plain "Album artwork...", picking one only
>       changes that track
>   - Notes:
> - [ ] The Sheepy Mixes tracks specifically: fix each one individually now
>       (see the artwork-lookup thread) rather than trusting the old
>       album-wide behavior
>   - Notes:

## Build 2026-07-29--2230

### Changes

- **The icon comes from a real SVG now** — `app/assets/icon/fooplayer_icon.svg`,
  supplied by Mike. The previous attempt reconstructed the note by measuring
  the old bitmap, which was wrong twice: it hard-coded a drawing in Python, and
  it built the note from separate overlapping shapes, so every place a stem met
  the beam or a head picked up a rounded notch instead of a sharp junction.
  That is what made it look cheap. Mike's SVG is one continuous outline with
  sharp armpits and only the outer corners rounded.
- `tools/build_icon.py` no longer knows anything about the shape of the note.
  It owns **placement**, which is the part that differs per asset and is easy to
  get wrong: 41% of the 108dp canvas for the adaptive icon (so no launcher mask
  can clip it), 62% for the splash, 92% for the legacy tile, 81% for the
  Windows `.ico`. Every fraction measured off the asset it replaces.
- It also refuses a source it cannot faithfully convert — strokes, transforms,
  gradients, filters, masks, `<image>` — rather than silently dropping the
  effect and shipping a wrong icon. Same for path commands it cannot transform.
- Transforms are **baked into the path data** rather than carried as a
  VectorDrawable `<group>`: a group applies scale, then rotation, then
  translation, and getting that order backwards is a bug that only appears on a
  device.

## Build 2026-07-29--2040 (superseded by the above)

### Changes

- **The icon is geometry now, not pixels** — and that is what fixes the soft
  splash. Every asset used to be upscaled from one 96×96 PNG whose note
  occupied 72×76 pixels. `tools/build_icon.py` is the single source: it emits
  the SVG, three Android VectorDrawables, the legacy launcher bitmaps and the
  Windows `.ico`.
- **The splash is sharp.** The Android 12 splash draws its icon at 288dp, so
  the system was enlarging a 76px note. It is a VectorDrawable now, rasterised
  by the system at whatever size it wants. Size deliberately unchanged: the
  viewport is set so the note fills the same 62% of the canvas the old PNGs
  did — measured 123dp on the tablet against 119dp before.
- **The Windows `.ico` had exactly one 32px frame**, which is why it looked
  rough anywhere Windows shows a large icon. Now seven frames, 16 → 256, each
  rasterised from the vector at its own size rather than resampled down from
  one big one.
- **A redraw is allowed to differ, not to become a different icon**, so the
  geometry was measured off the old 432px bitmap and the result is checked
  against it: `--verify` reports 0.957 silhouette agreement and 0.935 on the
  shaded face. It does not reach 1.0 because the old art was itself an upscale
  of 96px source, so its own edges are soft by about a pixel.
- Two things that were easy to get wrong and are now pinned in the tool: the
  beam is a **parallelogram** (vertical ends flush with the stems), not a
  rotated rectangle, which would splay its ends out past them; and the shaded
  underside is drawn **only between the stems**, which is the whole depth cue —
  running it the full width flattens the note (shaded-face agreement 0.71 that
  way, 0.93 this way).
- Deleted what the vectors replace: five `drawable-*/splash_icon.png`, five
  `mipmap-*/ic_launcher_foreground.png`, five `mipmap-*/ic_launcher_monochrome.png`.

> [!warning] Testing Checklist
> - [ ] Tablet: cold-start the app — the splash note has clean edges
>   - Notes:
> - [ ] Tablet: launcher/app-drawer icon still looks right, no clipping
>   - Notes:
> - [ ] Windows: close fooplayer, rebuild, check the taskbar and Explorer icon
>       at large and small sizes
>   - Notes:

## Build 2026-07-29--1810

### Changes

- **Multi-select now offers only "Add to queue".** Both items are the same
  operation — put these in the queue — differing only in where: directly after
  what is playing, or at the end. That distinction is real for one track and
  vacuous for ten, because ten songs can't all play next. So on a selection the
  menu was showing two names for one action with nothing to choose between
  them. A single row still gets both. Right-clicking outside the selection
  collapses it to that row, so "Play next" comes back.

> [!warning] Testing Checklist
> - [ ] Select 10 rows, right-click → only "Add to queue (10 tracks)"
>   - Notes:
> - [ ] Right-click a single row → both "Play next" and "Add to queue"
>   - Notes:

## Build 2026-07-29--1715

### Changes

- **Scrolling the library selected a track on every flick.** Selection fired
  on pointer DOWN — right for a mouse (Explorer and foobar2000 both do it, and
  it is what removed a 300ms double-click-window stutter), but every finger
  flick begins with a pointer-down on whatever row is under the finger. So
  browsing constantly changed the selection, and with it the sidebar's cover
  preview.
  A finger now selects on LIFT, and only if it stayed within `kTouchSlop` —
  the same threshold the enclosing scrollable uses to decide it is being
  dragged, so "the list would have scrolled" and "that was not a tap" are the
  same question by construction. **A distance test rather than a timed pause**:
  a deliberate tap still selects the instant the finger lifts, with no hold to
  sit through. A mouse is untouched — still selects on press.

> [!warning] Testing Checklist
> - [ ] Tablet: flick through the library — nothing gets selected, no cover
>       appears in the sidebar
>   - Notes:
> - [ ] Tablet: tap a row — it selects immediately, cover appears
>   - Notes:
> - [ ] Tablet: double-tap still plays; long-press still opens the menu
>   - Notes:
> - [ ] Desktop: click still selects the moment the button goes down
>   - Notes:

## Build 2026-07-29--1640

### Changes

- **A tablet now gets the desktop layout.** The Galaxy Tab S9+ was running the
  phone UI on a 2800px screen — one track per row and an ocean of white beside
  it. It gets the real thing now: sidebar with playlists and actions, the
  Folder/Artist/Album filter panels, the sortable seven-column track list, the
  full now-playing bar, the footer. A phone keeps the compact shell.
- **The breakpoint is the device, not the window width.** Measured on the
  device: 1318×824 logical pixels (1752×2800 physical at density 340). Any
  width-based threshold lands between those two numbers, so the tablet would
  have shown panels in landscape and the phone UI in portrait — the app
  changing identity every time you turned it over. Keyed to the shortest side
  instead (≥700), which is orientation-independent: tablet gets panels both
  ways, phone gets compact both ways. 700 sits in a wide gap — biggest phones
  are ~480, a 10-inch tablet is 800+.
- **Three things the panel layout assumed about having a mouse:**
  - *A right-click.* The row context menu now also opens on a long press
    (`onLongPressStart`, so it opens at the row — the position can't come from
    the earlier pointer-down, because selecting the row rebuilds it). Added
    unconditionally: it costs a mouse user nothing.
  - *A held Ctrl* for multi-select in the filter panels. Long-press toggles a
    value now, so picking three artists at once — half the point of those
    panels — is reachable on touch.
  - *Being on Windows.* "View in folder" shells out to `explorer.exe`, so it
    is hidden where there isn't one rather than sitting in the menu doing
    nothing.
- **Window insets.** The panel layout painted from pixel zero, which is right
  for a window with a title bar and wrong on a tablet: the Android status bar
  covered the sidebar and search field, and the gesture pill covered the track
  count. `SafeArea` plus dark status-bar icons; a no-op on desktop, where all
  those insets are zero.
- **A dead breadcrumb step** in the desktop Folder panel: with a single root it
  showed `↑ All / Music` where "All" was a step to nowhere. Now just `Music`,
  with no up-arrow at the top.
- Seeding a root from the desktop Settings dialog asks for storage access
  first, the same as the phone page — that dialog runs on the tablet now.

> [!warning] Testing Checklist
> - [ ] Tablet landscape: sidebar + filter panels + column list, nothing under
>       the status bar or the gesture pill
>   - Notes:
> - [ ] Tablet portrait: same layout, columns truncate rather than overflow
>   - Notes:
> - [ ] Long-press a track row → menu opens at the row, no "View in folder"
>   - Notes:
> - [ ] Double-tap a row → it plays
>   - Notes:
> - [ ] Long-press two artists → "2 selected", list shows both
>   - Notes:
> - [ ] Desktop: right-click, Ctrl+click and "View in folder" all unchanged
>   - Notes:

## Build 2026-07-29--1429

### Changes

- **Android could not read the music folder at all.** The app held no storage
  permission whatsoever, so a folder with 474 tracks and a manifest sitting in
  it showed an empty library. Added `READ_MEDIA_AUDIO` + all-files access
  (the manifest and artwork sidecars are not media files, so media-scoped
  permission can never read them), a permission request at startup, and a
  **Set up** button on any root that has no manifest — on a phone there is no
  CLI, so "seed with foolib" was a dead end.
- **Setting up a folder reset every download date to today.** Found on the
  tablet: the music had been copied over as one folder, so every file's mtime
  was the copy's timestamp and the real 2019–2026 dates survived only in the
  `.library.json` that travelled with it. Seeding `/Music` above it minted a
  fresh date for all 467 tracks. Seeding now **adopts** dates from any manifest
  already inside the folder, keyed by content ID, earliest wins. Durations come
  across too.
- **Folders opened on a list of one.** With a single library root the pane
  showed one row, "Music", that you had to tap before you could see anything.
  A list of one is not a choice, it is a tap tax on every visit. A lone root
  is now the top level: the pane opens inside it, subfolders and loose tracks
  visible straight away, no back arrow and no "All ›" prefix. With several
  roots (the desktop's five) the root list is a real choice and nothing
  changes. Sitting at that implicit top deliberately does not count as a
  folder *selection*, so a one-album library still renders as a library.
- **The same bug on the rescan path**, which is the one that matters going
  forward: dropping `monthly/` into an already-set-up root would have dated
  those tracks today. Now they keep what their manifest says. The walk only
  runs when a scan actually turns up something new, so the five-minute tick
  costs nothing extra.

> [!warning] Testing Checklist
> - [ ] Tablet: Library shows all 474 tracks, newest first
>   - Notes:
> - [ ] Tablet: Folders opens straight inside Music — no "Music" row to tap
>       first — and `loose tracks - 2020 and later` is right there
>   - Notes:
> - [ ] Tablet: drilling in then back returns to Music, and the back arrow
>       disappears there
>   - Notes:
> - [ ] Desktop: Folder pane still lists all five roots at the top
>   - Notes:
> - [ ] Tablet: dates are the real ones (oldest track is Jan 2019, not today)
>   - Notes:
> - [ ] Copy another folder (e.g. `monthly`) onto the tablet with its
>       `.library.json`, wait for a rescan, confirm its dates survive
>   - Notes:
> - [ ] Desktop: unchanged — no root re-seeded, no dates moved
>   - Notes:

## 2026-07-29 — tags become editable, the phone becomes a music player, and the queue becomes real

The long session after the artwork work. Roughly half of it was features and
half was live use finding things that were quietly wrong.

### Tag editing, end to end

Right-click → **Edit tags…** on one track or a hundred. Written into the
files themselves, so foobar2000, Kodi and a phone all see the correction —
and until now the only way to do this was Mp3tag, which is what destroyed
every download date in this library and started the project.

Multi-select follows the rule every tag editor uses: a field the selection
disagrees on shows `(various)` and stays untouched unless you type in it, so
"give these twenty the right album" doesn't also give them all one title.
Blanking a field clears it, which is how `2012-11` comes out of an album
frame.

**FLAC too**, via Vorbis comments — a different format from ID3, with
little-endian lengths inside big-endian block headers. Two of the three FLACs
here carry no tags at all and were the files that most needed it.

**And a matcher**: *Find correct tags…* asks MusicBrainz and offers what it
finds, ranked, with a confidence word. It proposes into the form and never
writes — the artwork pass may auto-apply a confident cover because a wrong
cover is embarrassing, but a wrong title rewrites the file. Duration carries a
fifth of the score, being the only field a database can check that a human
cannot eyeball. Verified live on *El Manana*: MusicBrainz returns *El mañana*
— with the tilde the file is missing — across seven releases, all matching its
3:50.

Every write keeps the two guarantees the embed pass established: audio copied
verbatim so the content ID cannot move, and the file's dates restored and
read back. Proven against real library bytes on copies, then read back through
the app's own reader rather than the writer's idea of what it wrote.

### The phone stops being a toy

**Background audio (Plan 2c).** A foreground service with a media session:
lock screen, notification, headset buttons. Audio focus is handled separately
because libmpv plays to an audio track without asking Android for focus at
all, so a phone call would have played over the top. A call pauses and hands
playback back; another app taking over for good pauses and does *not* come
back; a navigation prompt ducks; headphones out pauses and never resumes by
itself.

Measured on the emulator: `PLAYING`, correct metadata through the umlauts in
*RÜFÜS du Sol*, media keys driving it, still playing after HOME.

**Tapping a song goes full screen into it**, which is what tapping a song
means on a phone. The full-screen player already existed and was reachable
only by noticing the strip at the bottom.

**Back unwinds exactly one level.** The drawer switched views by setting state
rather than pushing a route, so Back found nothing to pop and closed the whole
app — from Albums, from Settings, from anywhere but the feed. At the root it
now backgrounds instead of finishing the activity: same pid, instant resume,
playback uninterrupted, rather than a cold start that re-reads the library.

**Installed on the Galaxy Tab S9+** and seeded with eight tracks whose content
IDs and download dates were carried across from the NAS manifest — a
hand-rolled, eight-file preview of what Plan 3 will do properly.

### The queue becomes a scratch playlist

`QueueController` could only be replaced wholesale — there was no way to
insert anything, so "add to queue" was a missing capability rather than a
missing menu item. It now has play-next / append / remove / reorder / clear,
a **Queue** view on both platforms, and *Play next* / *Add to queue* in the
phone sheet and the desktop menu.

Two orders are tracked — the play order and the order to return to when
shuffle goes off — and anything added lands in both. Adding only to the play
order is the obvious version and it is wrong: toggling shuffle rebuilds from
the source list and the track you just queued vanishes.

Removing the playing track is refused outright: the audio carries on
regardless, so the list would name one track while another was audible.

### Things live use found

**Playlists could not be created during a scan.** The manifest lock was held
across the whole per-root scan — a walk-and-hash of every file, minutes over
SMB — while a playlist write waits five seconds. Only the manifest
read-modify-write needed protecting, and that is local JSON in milliseconds.
The scan isolate no longer touches the manifest, and a rescan that finds
nothing no longer rewrites it at all. Reproduced on the old build first: with
"Scanning monthly…" showing, a delete never reached the manifest.

**"Scanning…" showed more or less permanently.** The model's `quiet` flag
worked and a test proved it — but `main.dart`'s timer never passed it. The
comment explaining that a timer "must not narrate a scan nobody asked for" was
sitting on the launch rescan, which was already quiet. Nothing covered the
wiring, which is where the mistake was.

**Tag edits took ten seconds to appear**; a batch of ten took over a minute.
Timing each phase showed the work is not slow — rebuild tens of ms, meta cache
53 ms, compilation pass 13–45 ms, a full read-rebuild-write over SMB
0.2–1.2 s. All of it ran on the UI path, in series, behind whatever the
background scan was doing. The library is now updated the instant you press
Save, before a byte is written, with the writes backgrounded four at a time; a
file that refuses reverts that track alone.

**The search box lied.** It only ever pushed text into the model, never read
back — and clicking Library or a playlist resets the model's search along with
the other filters. Result: "sheepy" sitting in the box with all 5,470 tracks
listed under it.

**Artwork did not survive retagging.** Covers are filed under a key built from
the artist and album *tags*, so retagging twelve Mr Suicide Sheep mixes to
share one album collapsed every key onto the same string: three separately
chosen covers became one shared cover and two orphans. A hand-picked cover is
now also pinned to the track's content ID, which no tag edit can move — both
keys, so a pinned track keeps its own cover while album-mates without a pick
still inherit. `tools/repair_orphaned_art.py` recovered the covers chosen
before that existed.

**Compilations were one album per track.** `alternative times` — 119 folders,
2,398 tracks — produced 2,394 separate artwork entries, each asking providers
for a release nobody made ("Anberlin — Alternative Times Vol 110"). They key
on folder + title now, with no artist. Enrichment then found nothing for them,
which is a real answer: those bootleg comps have no cover anywhere.

### Interface

Now playing sits **above** the footer and the footer is always the last thing
in the window; the hairline between them is gone. The strip can be
**dismissed** — and while it is, the footer carries the transport as text:

    Like It Or Not — Bob Moses    1:04 / 6:20            5,470 tracks

Clicking anywhere along it opens the player again. Dismissing also brings back
the sidebar's selected-track cover, which is the entire point of dismissing:
click through the library and look at artwork without playing anything.

Dialog corners are a theme now rather than one hand-tuned picker and a dozen
Material defaults.

### Android icon, and a limit worth recording

The launcher circle cannot be removed. Since Android 8 every adaptive icon is
masked to the launcher's shape and filled with the background layer —
transparent gives a **black** circle, and dropping the adaptive icon entirely
gives a white one anyway. Measured all three on a Pixel 7. Two real defects
did turn up: the legacy bitmaps had no alpha channel at all, and the adaptive
foreground ignored the 72-of-108dp safe zone. A `monochrome` layer was added
for themed icons, where the note had been rendering as an empty circle.

The splash is Android 12's system one, scaling the launcher icon up. It has
its own asset at every density now, but the ceiling is the source art:
`music.png` is 96×96 and the note within it is 72×76 pixels. Truly crisp needs
a vector redraw.

## 2026-07-28 — evening: artwork embedded across the library, and the app stops lying about it

The covers are in the files now, not just in a sidecar only fooplayer can
read. Along the way three things turned out to be reporting bugs rather than
the failures they looked like.

**The library view got a footer.** The track count moved out of the sidebar,
where it competed with the button stack and the art preview for a narrow
column, down to the bottom right of the window. It shares that strip with
background work — what is running on the left, how much is in view on the
right — and the strip is permanent, because one that appeared and vanished
under the now-playing bar jumped the whole layout every time a pass started.

**"El Manana appears to have artwork, but it is not embedded" was the app
misreporting its own work.** Both that file and the Echos *Euphoria* track
had their covers on disk the whole time; the Art/Emb columns read a flag
captured when a file's tags were last read, and nothing re-reads them after a
write. Re-reading library-wide costs minutes over SMB, so the pass now names
the tracks it wrote and the model marks exactly those. The same
rebuild-the-whole-record bug was already live in the duration write-back,
which silently dropped the flag from any track that got its duration by being
played.

**The end-of-pass report was a six-second SnackBar closing a fifteen-minute
job.** Miss the moment and the entire outcome was gone — which is how a run
that skipped 4,047 files for a mundane reason ("no artwork chosen for this
album") read as a run that had failed. It is a dialog now, listing each
reason with its count, biggest first, and a file whose dates didn't survive
gets its own red block with the paths named.

**"notMpeg: no MPEG frame sync where the audio should start" was right once
and wrong 28 times.** Of the 29 mp3-named files library-wide that fail that
check, 28 are ordinary MP3s carrying 42–1,035 bytes of junk between their
tag's declared end and the first audio frame — the whole *Passafire —
Submersible* album, the *Streets — all got our runnins EP*, three Gym Class
Heroes singles, two DJ Invasion mixes, a Tony Hawk OST track, a Kid Cudi one.
Players resync past that; the guard stopped at the first non-zero byte. The
twenty-ninth is `MrSuicideSheep - Best of 2025.mp3`, an MP4 container wearing
an `.mp3` name — the file that doesn't play, and the reason the guard exists.

The scan now continues through up to 8 KB of junk under two conditions that
keep the sheep refused: the file must have opened with a real ID3v2 tag (one
every player already skips, so rewriting it cannot make things worse), and
the far side of the junk must be a header that could actually *decode* —
version, layer, bitrate and sample rate all outside their reserved values. A
bare `FF Ex` sync pattern matches roughly one byte pair in 2,048, which is
fine when checking the single position audio must start at and useless when
scanning hundreds of bytes forward.

**Coverage, measured by reading the files rather than asking the app:**

| Root | Files | Carry a cover | Bare |
|---|---|---|---|
| albums | 685 | 684 | 1 |
| monthly | 1,904 | 1,746 | 158 |
| loose tracks — 2020 and later | 474 | 430 | 44 |
| loose tracks — old | 92 | 49 | 43 |
| alternative times | 2,398 | 375 | 2,023 |
| **total** | **5,553** | **3,284** | **2,269** |

The bare files are overwhelmingly the `alternative times` VA bootleg
compilations, where no provider has a cover and no loose image sits in the
folder — nothing was skipped in error. The final pass wrote 1,423 covers with
zero failures and zero disturbed dates, and its report no longer lists
`notMpeg` at all.

**And 66 download dates were quietly wrong.** An independent check of every
file against its manifest — not trusting the embed pass's own self-report —
found 66 disagreements, none touched that day. Every one was the *second*
path of a two-path manifest entry: `stamp_dates_from_manifest.py` iterated
`paths[0]` only, so where the same audio is filed in two places one copy was
corrected and its twin left on whatever date the copy event gave it
(2012-11-22 and friends). Invisible unless you happened to open the second
folder. Fixed, applied, and re-verified: **5,553 of 5,553 files now match
their manifest date.**

Also: a raw NUL byte had been written into `artwork_embed_pass.dart` as a
cache-key separator, which made ripgrep classify the file as binary and skip
it entirely — a search for anything in it silently returned nothing.

## 2026-07-28 — every download date in the library is now accounted for

The `monthly` root was re-derived from its folder names (1,841 tracks, canon by
construction). `alternative times` split cleanly into the 2024-06 Soulseek bulk
(101 volumes) and 18 older volumes left at 2010-08. In `albums` — the root
where albums had been moved out of `monthly/` and retagged, destroying the only
record — 24 folders were confirmed as one backlog download spree, 15 as real
acquisitions, and **13 were placed individually**.

Two of those came from evidence rather than memory. A sweep of the *whole*
music directory, including the folders that are not fooplayer roots
(`albums [no scrape]`, `iTunes`, `xmas`, `_to dl`), found an untouched second
Rehab collection. Scoring each candidate date by how many folders in the
collection share it separates a real download from a copy event:

| Date | Folders sharing it | Verdict |
|---|---|---|
| **2007-11-11** | **3 — all Rehab** | real download |
| 2012-11-21 | 523 | bulk copy |
| 2013-01-14 | 115 | bulk copy |
| 2012-07-22 | 27 | bulk copy |

One evening in November 2007, three Rehab folders and nothing else in 5,500
tracks — the band being discovered and its back catalogue pulled down at once.
So *Graffiti The World* and *Southern Discomfort* went there. The Streets got
no such gift; every copy of theirs outside the roots sits on a bulk date, so
2009-02 is inference from the canon `monthly` burst.

**Zero folders remain on an unexplained stamp, and zero files in the library
disagree with their manifest date.**

Also this session: the library view gained **Art** and **Emb** columns at the
far right (accent-blue circled checks — the app has a cover / the file carries
one), the sidebar shows a square full-width cover of the selected track while
nothing is playing, and the status line stopped twitching — the periodic
rescan was narrating itself through five roots every tick, and now says
nothing unless it finds something.

## 2026-07-28 — artwork embedding, merged into the app

The engine proven on the FLACs and the converted m4a is now a feature: a
sidebar entry, **Embed art in files**, that copies each album's chosen cover
into the tracks' own tags so foobar2000, Kodi, Explorer and a phone can all
see it.

Mike's condition — "so long as it doesn't touch the date downloaded of any of
the songs" — is now doubly load-bearing, because as of this morning the
filesystem dates *are* the download dates. It is enforced three ways and said
plainly in the confirmation dialog: only tag blocks are rewritten (never
audio, so no content ID moves and no manifest date can be orphaned); every
file's timestamps are restored and read back, with the writer refusing to
report success if they didn't survive; and the pass counts any such file
separately as "WITH DATE CHANGES" instead of folding it into the total.

`.m4a` is excluded deliberately — its content ID hashes the whole file, so
embedding anything would change its identity — along with everything the
engine refuses (an MP4 or RIFF wearing an `.mp3` name, unsynchronised tags, a
non-image payload). Each skip is counted with its reason.

The entry is not gated on the library being idle: the pass touches neither the
manifests nor the tag cache, and this library rescans on a timer, which would
otherwise leave it greyed out most of the time. It is gated on itself instead,
so it can't be started twice. 733 tests.

## 2026-07-28 — "date downloaded" finally correct everywhere

The issue this whole project started from, resolved on Mike's go-ahead
(option 1 from the writeup).

A probe of the share settled the design: **Samba here reports creation time as
equal to modified time**, so stamping the modified time corrects *both* columns
Explorer shows and the field foobar2000 sorts on — the NAS config change that
option 2 required buys nothing, and creation time needs no special handling
anywhere in this project.

`tools/stamp_dates_from_manifest.py` re-derives each file's date from its
manifest `date_added` — dry-run by default, verifying every write by reading it
back, and recording each previous value so the whole operation can be reverted.
Over all five roots: **5,483 tracks, 3,759 already correct, 1,724 re-stamped, 0
failures, 7 seconds.** Kanye's "Stronger" went from a filesystem date of
2026-01-12 to its real 2024-07-10; "&ME - After Dark" from 2024-07-02 to
2020-12-16; "Above & Beyond - Alone Tonight" from 2024-07-11 to 2012-04-26.

Audio bytes were never touched, so no content ID moved and the manifest that
supplied the dates is untouched. The standing trade-off: "Date modified" now
means "downloaded" rather than "last edited", and a future tag-editing session
re-clobbers whatever it touches — one re-run of the script repairs it, since a
tagger can't reach the manifest. fooplayer's own tag writing already preserves
both dates.

Also: the Zero 7 "Destiny" folder held both FLAC and MP3 copies of the same
three tracks. The MP3s were ~180 kbps transcodes whose `date_added` said
2024-07-11 while the FLAC originals carried 2009-12-03 / 2012-11-22 — keeping
them would have mis-dated the tracks. FLACs kept, MP3s removed (backed up),
manifest entries dropped: 1,844 -> 1,841 with nothing left pointing at a
missing file.

## 2026-07-28 — the metadata pipeline stops lying

A night of Mike finding real defects in live use. Every one was reproduced and
root-caused before it was touched.

**Tags that were there all along.** Five fully-tagged albums showed no artist —
Tha Carter III, Dummy, Treats, Becoming X, Keystone State Of Mind (57 tracks).
Dumping their ID3 frames found three separate upstream-parser failures: frames
after a large embedded picture are never reached (Tha Carter III keeps `TPE1`
*after* a 307 KB `APIC`), ID3v2.2's 3-character frame IDs aren't mapped at all,
and stacked tags — a v2.3 immediately followed by a v2.4 — make it give up.
`id3_text.dart` now reads ID3 text frames ourselves: every leading tag, every
frame, any size, all four encodings. It only fills gaps the upstream parser
left, so FLAC/MP4/OGG stay its job.

**Artist was reading the wrong frame.** `TPE2` (band / album artist) was
preferred over `TPE1` (lead performer). 2,231 files carry both and **359
disagree** — mostly compilation tracks displaying "Various Artists" instead of
the band that played them. "The Life" showed RÜFÜS instead of RÜFÜS du Sol,
which is how Mike spotted it.

**Durations were the most expensive thing to compute and the least durably
stored.** They lived only in the local tag cache, so any cache loss blanked the
Time column for the whole library and forced a full re-read over SMB. The
manifest — which already holds `date_added` — now carries an optional
`duration_ms` beside it (omitted when null; existing manifests and older
readers unaffected). 5,453 durations persisted. Twenty tracks had no duration
at all despite ffprobe reading them fine: their tag read timed out before the
estimator ever ran, and 15 of them carry stacked ID3 tags the estimator's
single-tag skip walked straight into. Now zero.

**A refresh must never blank the library, and must never lie about finishing.**
Bumping the cache revision used to discard every entry — ten minutes of empty
columns to correct one field. Stale entries are now kept and served while a
background pass corrects them in place. The first version of that shipped with
a bug of its own: `save()` stamped every entry with the current revision,
including ones it had only served, so within ~1,000 files the whole library was
marked refreshed and the tracks needing work were never revisited. Staleness
now survives a save. A read that times out also falls through to our own reader
instead of leaving an entry uncorrected forever, and the per-file retry path
runs 8 at a time rather than one — a bad 200-file batch was over an hour of
apparent stall.

**UI, from live use:** row selection fires on pointer-down (it hung off
`InkWell.onTap`, which Flutter withholds for the full ~300 ms double-tap window
— the model work behind a selection measures ~5 ms, so the wait *was* the
stutter); the now-playing cover opens the artwork picker for what's playing;
"Album artwork…" moved to the top of the row context menu; the empty-cover
placeholder is the app's own music-note icon in grey inside an outlined tile
instead of an icon floating under a drop shadow; and the column-header hover
tint is gone.

723 tests, analyze clean, Windows release verified live.

## 2026-07-27 — artwork goes into the files themselves

- **Cover art is now embedded in the audio files' own tags**, so foobar2000, Kodi, Explorer thumbnails and any phone player see it — no `folder.jpg` litter. MP3 gets an ID3v2 APIC frame, FLAC a PICTURE metadata block.
- **Neither identity nor dates move.** The content ID hashes only the audio byte range (leading ID3v2 and trailing ID3v1/APEv2 are skipped, as are FLAC metadata blocks), so the rewrite copies every audio byte verbatim and *proves* the range is unchanged before writing. Dart can't set file times, so timestamps are restored through `SetFileTime` and read back to confirm — measured on this share, Samba reports creation time as equal to modified time, so restoring the write time fixes both.
- **Files that can't be proven safe are refused untouched**: audio not starting with an MPEG frame sync (an MP4 or RIFF wearing an `.mp3` name — exactly what made one file unplayable), unsynchronised/extended/footer tags, non-image payloads.
- **1,643 files were one step from losing their tags.** Of 1,644 MP3s with no ID3v2, all but one carry an ID3v1 tag — giving them a v2 tag containing only a picture would have made every player that prefers v2 show them as untitled. Those fields are now promoted into the new tag first (title/artist/album/year/genre); the v1 block stays put.
- **The 13 `.m4a` files became MP3s without losing their date-added.** The core hashes an `.m4a` whole, so nothing can be embedded in one without changing its identity. Converting re-encodes the audio, which changes the ID by definition — so each conversion is paired with a manifest migration: the new ID inherits the old entry's `date_added`, the path is updated, playlist references are rewritten. Encoded at LAME V2 (~190 kbps) against ~135 kbps AAC sources; originals kept in `L:\BACKUPSooplayer-file-fixes\pre-mp3-conversion`. Verified afterwards: no `.m4a` left, zero manifest entries pointing at a missing file, dates identical to their untouched neighbours.
- **The 3 FLACs were NOT converted** — deliberately. FLAC carries a PICTURE block natively with no identity change, so re-encoding lossless to lossy would have cost quality for nothing.
- Proven on sandbox copies first (`testdata/embed-test`, `testdata/convert-sandbox`, `testdata/flac-sandbox`) across every tag shape in the library: no tag, v2.2, v2.3, v2.3-with-art, v2.4, and the MP4-as-MP3 pathology. 695 tests.

## 2026-07-27 — playlists that actually take, and the iTunes-style playlist view

- **The silent "add to playlist" failure is fixed, and it wasn't what it looked like.** Every playlist mutation gated on the library's `busy` flag — which stays set for the *whole* of a load, including the background tag-reading pass. On the real 5443-track library over SMB that pass runs for most of a session, so the write was refused; and because the refusal only surfaced after a 5-second retry deadline, it looked like the click did nothing at all. Reproduced end to end in the running app (the toast, when you wait for it, says "The library is busy (scanning)"). The lock is now scoped to the phases that genuinely touch a `.library.json`, so tag reading no longer blocks anything. Verified live: tracks added mid-enrichment, confirmed on disk, removed again through the same menu.
- **Playlist view got its header**: the first track's cover shown large, the playlist name, and a "N tracks · MM min" summary above the four columns — matching the reference layout. The duration half is omitted while any track still lacks a duration, so a partially-enriched library never shows a total that quietly grows.
- **Four-column playlist layout**: #, Song (36px thumbnail + title with the artist beneath), Album, Time — playlist headers are plain labels, since curator order isn't something you sort away.
- **Right-click menus open instantly** — the default scale/fade is gone from the row menu, its nested add-to-playlist menu, and the sidebar's playlist menu.
- Regression test pinned to the real failure window (a write that lands *during* enrichment), proven to fail against the old gate. 682/682 tests, analyze clean, Windows release built.

## 2026-07-25 — Album artwork lookup (Plan 4, ultracode round)

- **Every album can now get a cover.** Three keyless providers (iTunes Search, Deezer, Cover Art Archive via MusicBrainz — no API keys, no signup) are queried for albums that show no art, scored by a deterministic normalizer + similarity scorer, and the winner is applied automatically **only** when it scores ≥ 75 and beats the runner-up by ≥ 10. Anything ambiguous is left alone: a wrong cover silently applied is worse than none.
- **Picker on both platforms** — desktop track right-click → "Album artwork…", phone long-press → "Album artwork": one shared grid (thumbnail, source, resolution, current selection marked) plus **Choose file…**, **Paste URL…**, **Search again** (bypasses *and* clears the negative cache) and **Remove artwork**.
- **Sidecar storage** `.artwork.json` + `.artwork/` per library root, written atomically (tmp → `.bak` → rename, same discipline as the manifest), so artwork travels with the music folder. A read-only root falls back to the app data dir and flags the entry `external`. **Nothing is ever written inside an album directory** and `.library.json` is never touched.
- **One resolution chain** for the desktop bar, phone mini-player and Now Playing: embedded tag art → sidecar choice → `folder/cover/front.jpg` beside the file → placeholder; async, album-keyed, bounded LRU, in-flight dedupe, and the existing stale-request/flicker guards kept intact. An explicit user pick outranks embedded art (otherwise the picker looks broken on well-tagged albums).
- **Manners**: MusicBrainz rate-limited to 1 req/s with the project User-Agent, at most 3 concurrent album lookups and 4 concurrent image fetches, per-album in-flight guard, negative results cached for 14 days, whole pass cancellable and cancelled on reload/exit. Every provider failure mode degrades to "no candidates", never an exception to the UI.
- Built as three parallel worktrees against injected seams, then merged and wired: one shared normalizer (the picker's placeholder and the scorer's copy were collapsed onto it), one `ArtworkQuery` type, and one `ArtworkWiring` object that is the only place the production HTTP implementations are selected. 536/536 tests, `flutter analyze` clean, Windows release build green — **and no test can open a socket**: every network path is an injected seam whose fakes are all the tests ever see.

## 2026-07-25 — album artwork, and a real phone library

- **Automatic artwork enrichment**: albums with no embedded cover are looked up in the background across three keyless providers (iTunes, Deezer, Cover Art Archive), scored, and applied only when the match is unambiguous (score ≥75 and ≥10 clear of the runner-up) — a near-tie waits for you rather than attaching the wrong sleeve. Covers land in `<root>/.artwork/` with a `.artwork.json` sidecar, so they travel with the music folder and never touch audio files or the manifest schema.
- **Artwork picker** (desktop right-click → "Album artwork…", phone long-press): candidate grid with source + resolution labels, current pick marked, plus Choose file / Paste URL / Search again / Remove artwork.
- **Adversarial review paid for itself twice**: the first pass caught a multi-root backfill blind spot, a synchronous filesystem probe on the UI thread, and a non-durable "Remove artwork"; a rerun (the original died on a transient API error) caught four more, each proven with a live probe — backfill never re-running after a rescan, interactive picker searches starving behind the background queue, a resolver cache that could hand back stale art right after you picked a new cover, and orphaned image files on replace. All fixed, plus download size caps and image-format validation so a pasted non-image URL degrades to the placeholder instead of poisoning the cache. 592 tests.
- **Phone library seeded for real**: the emulator's data partition was too small for a real library, so it was rebuilt at 16 GB and loaded with the full "loose tracks - 2020 and later" folder (444 files) instead of three sample tracks.
- **Old repo retired**: `L:\PROJECTSoobar` deleted; verified nothing references it (no processes, services, scheduled tasks, or git plumbing — both build worktrees re-pointed at the fooplayer repo).
- **Polish from live use**: metro glyphs lost their hairline boxes (a runtime tint forced an offscreen layer the emulator outlined — the color is baked into the assets now), shuffle turns accent blue when active, an explicit ↑ up-one-level control with clickable blue breadcrumbs in the Folder pane, no volume slider on phone (hardware keys own it), sharper launcher icon, and both apps now identify as "fooplayer" rather than the project id.

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
