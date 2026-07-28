# fooplayer — WORKPLAN

*Forward-looking queue. State: [STATUS.md](STATUS.md) · History: [CHANGELOG.md](CHANGELOG.md). Last update: 2026-07-28.*

## ✅ Completed since the last plan revision

- **Tag/metadata pipeline hardened** (2026-07-28): own ID3 reader for what the
  upstream parser drops, TPE1-before-TPE2 artist precedence, durations
  persisted in the manifest, refresh that never blanks the library and can't
  report itself finished without doing the work.
- **Artwork embedding into files** (MP3 APIC / FLAC PICTURE) with content ID and
  file dates provably unchanged; applied to the 3 FLACs and the 13 m4a that were
  converted to MP3 carrying their date-added across.
- Repo migration to `L:\PROJECTS\fooplayer`; old `foobar` dir deleted and verified clear.
- Android phone-native UI (Plan 2b) shipped and verified on the emulator; launcher icon + app label.
- Album artwork lookup (Plan 4) shipped on both platforms: auto-enrichment + picker, two adversarial-review passes' findings fixed.
- Emulator rebuilt at 16 GB and seeded with the real 444-file library.
- Live-use polish: metro glyph hairlines, blue shuffle, breadcrumb ↑ up-one-level, phone volume removal, uniform column typography.

## The immediate queue (2026-07-28)

1. **Run the artwork enrichment** — the real bottleneck. Of 3,616 distinct
   albums, only **40** have art in the sidecar; **1,526 have never been looked
   up at all** (3,052 tracks) and 2,050 were looked up with nothing found.
   Needs the app left open: 3 lookups at a time, 400ms apart, MusicBrainz
   capped at 1/sec. The new **Art** column shows the gaps at a glance.
2. **Then "Embed art in files"** — built, tested, one click. Pointless before
   step 1, since it can only write covers that exist.
3. **Then strip the 472 stray images** (34 MB) — see the queued section below.
   Strictly after step 2: the resolver still falls back to sibling
   `folder.jpg`/`cover.jpg`.

## Next milestones

1. **Real-device pass** — install the APK on the Pixel 7 over USB, exercise the phone UI on real hardware (touch targets, scroll feel, playback, artwork on a real network). Needs Mike to plug the phone in.
2. **Plan 2c — background audio**: `audio_service` integration so playback survives screen-off with lock-screen/notification controls and proper audio-focus handling. This is the gap between "a music app on a phone" and "a music app you'd actually use on a phone".
3. **Plan 3 — phone library sync**: one-button LAN pull of new files + manifests from the NAS to the phone. Manifests make the diff trivial (content IDs already identify what's missing); the hard parts are Android storage scope (app-private vs. shared media) and transfer resilience.
4. **Artwork polish (optional)**: batch "fix all missing artwork" view, artist images/fanart types, opt-in `folder.jpg` writing beside albums.

## Queued — strip the stray cover-image files

**Order matters: embed first, delete second.** The artwork resolver still
falls back to a sibling `folder.jpg` / `cover.jpg` / `front.jpg`, so deleting
those before the embed pass has run would lose covers for the albums relying
on them. Once art lives in the tags, the loose files are pure litter.

Surveyed 2026-07-28: **472 image files, 34 MB** scattered through the library
(monthly 329, alternative times 123, albums 19, loose-old 1). The bulk is
Windows Media Player cache junk -- `AlbumArt_{GUID}_Large.jpg`, often several
per folder and frequently the wrong art entirely -- plus 115 `folder.jpg` and
12 `cover.jpg`. Mike's call: embedded artwork only, everything else goes.

Wants the same discipline as every other destructive step here: a dry run
listing what would go, a backup or reversal path, and no touching audio files
or their dates.

## Queued — metadata repair ("fix tags")

**Gated. Do not start until, in this order:** (1) the full-library artwork
pass has run and Mike is happy with it, and (2) whatever decisions come out of
that. ~~(3) the file-dates issue~~ **— done 2026-07-28, gate cleared.**
Added 2026-07-27 at his request.

The shape of it: the same "don't touch the file's identity or its dates"
discipline the artwork embedding now has, applied to the rest of the metadata.

- Edit a track's artist / album / title (and the other common fields) from
  inside fooplayer, written into the file's own tags so every other player
  sees the correction.
- A lookup/match step — MusicBrainz or equivalent — that proposes corrected
  metadata for a track or album, the way the artwork picker proposes covers:
  a best guess with a confidence bar, and a picker when it isn't sure.
- Aimed squarely at overwriting nonsensical or plainly wrong tags. This
  library has plenty: 359 files where the artist frame disagreed with the
  album-artist frame, FLACs with no tags at all, "2012-11" as an album name,
  filename-derived placeholders.
- **Same invariants as the artwork embedding, non-negotiable:** the content
  ID must not change (tag blocks are outside the hashed range, so a rewrite
  is safe by construction — and must be proven per file, not assumed), and
  file modified/created dates must come back exactly as they were.
- The machinery already exists and is proven: `tag_embed.dart` rebuilds an
  ID3v2 tag preserving every frame it isn't changing, `win_file_times.dart`
  restores timestamps through SetFileTime, and both are verified per file
  before anything is written. Text-frame editing is a small extension of the
  same code path, not a new one.

## Decision gates (Mike only)

- ~~**File-dates fix**~~ — **done 2026-07-28**, all roots (option 1 + per-album placement; see the writeup's Outcome section and [docs/albums-date-recovery.md](docs/albums-date-recovery.md)).
- **Full-library artwork embedding** (~3,659 art-less MP3s) — engine built and proven, deliberately unrun. Review list: [docs/artwork-embed-review.md](docs/artwork-embed-review.md).
- **Metadata repair** — see the queued section above; blocked behind both of the gates above.

## Backlog (deferred minors, triaged non-blocking)

- "NN." dot-prefix track-number parse ("01. Gorilla Zoe")
- Fuzzy title matching for the 26 unmatched "alternative times" playlist lines
- Missing-file tracks not hidden from the feed (spec line-item; rescan's diff already knows)
- `visibleTracks` memoization (recomputes per player tick); gear-tap integration test; multi-format tagged-file fixtures (package-upgrade protection)
- Duration re-check on retag (the deeper probe landed 2026-07-28: header-only
  estimator on every give-up path, stacked-tag aware)
- `AB2G Cygnus.mp3` has no ID3 tag at all, so it shows no artist. Nothing to
  read — a candidate for the metadata-repair feature rather than a bug
- A second, larger collection sits OUTSIDE the configured roots:
  `albums [no scrape]`, `iTunes`, `xmas`, `_to dl`. Untouched by any of this
  work (which is what made the Rehab date recovery possible). Decide whether
  any of it should join the library
- ~~Zero 7 Destiny duplicate folder~~ — deduped 2026-07-28 (FLACs kept; the
  MP3 transcodes carried a wrong 2024 date-added)
- Empty-roots config restart quirk; `.bad` backup clobber on repeat corruption; sub-400px bar widths
- Artwork: late CAA results discarded after the picker's budget expires; noise-word normalizer can fold distinct album titles together (accepted fuzzy-matching trade-off)
- Workflow-script hygiene: reviewer severity labels are enum-locked now; keep it that way (a non-enum label once slipped a finding past a filter)

## Process (as agreed with Mike)

- UI iteration: no pausing to ask — implement the reasonable interpretation, screenshot, iterate.
- Parallel work: ultracode rounds (isolated branch worktrees → merge agent → integrity + adversarial review → single fixer); trivial fixes done inline by the orchestrator instead of spawning agents.
- Review rigor stays. It has caught, among others: a UI-freezing parser stall, two wrong-data races (duration, artwork), a silently broken explorer launcher, a dead launch-rescan, a biased shuffle, a file-handle leak, and a zombie isolate that could clobber a playlist write.
