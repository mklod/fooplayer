# fooplayer — CHANGELOG

*What shipped, when. Newest first. Status: [STATUS.md](STATUS.md) · Plan: [WORKPLAN.md](WORKPLAN.md).*

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
