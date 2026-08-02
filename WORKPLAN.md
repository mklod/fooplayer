# fooplayer — WORKPLAN

*Forward-looking queue. State: [STATUS.md](STATUS.md) · History: [CHANGELOG.md](CHANGELOG.md). Last update: 2026-07-31.*

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
- **Picker artwork scoped to the selection, not the album tag** (2026-07-29):
  a hand pick now writes only the track(s) explicitly selected when the
  picker was opened — never a shared album key nobody asked it to touch.
  Multi-select (Ctrl/Shift-click, right-click, "Album artwork... (N
  tracks)") applies to exactly that selection. The automatic best-guess
  pass is unchanged; it correctly still works album-wide.
- **The Queue is a real scratch playlist now, separate from ordinary
  playback** (2026-07-30): a normal play still continues through whatever
  list it was clicked from ("faux queue," unchanged), but the first
  explicit "Play next" / "Add to queue" discards that continuation down
  to just the current track and starts a real, small, user-built list —
  the only thing the Queue view ever shows. Moved from a bottom-of-sidebar
  popup dialog to a real destination right under Library, appearing only
  once there is something to show.
- **Folder panel never shows the sole root's own name**, at any depth —
  extends yesterday's "no tap to see subfolders" fix to the breadcrumb too.
- Emulator rebuilt at 16 GB and seeded with the real 444-file library.
- Live-use polish: metro glyph hairlines, blue shuffle, breadcrumb ↑ up-one-level, phone volume removal, uniform column typography.

## The immediate queue — ✅ cleared 2026-07-28 (evening)

1. ~~Run the artwork enrichment~~ — done.
2. ~~"Embed art in files"~~ — done, 1,423 covers written, zero failures, zero
   disturbed dates. Coverage 3,284 / 5,553 measured off the files.
3. ~~Strip the stray images~~ — done, 414 moved (28.9 MB), 57 kept because the
   audio beside them still has no cover of its own.
4. ~~Convert the MP4-named-.mp3~~ — done, `MrSuicideSheep - Best of 2025.mp3`
   is real MPEG now, date downloaded intact.

## The immediate queue — cleared 2026-07-29

0. ~~Vector app icon + sharp splash~~ — done. Every asset generated from one
   vector definition; the Android 12 splash is a VectorDrawable, and the
   Windows .ico went from a single 32px frame to seven.
0. ~~Responsive tablet layout~~ — done. A tablet gets the desktop panel
   layout in both orientations, keyed to the shortest side (device size)
   rather than width, so rotating never changes which app it is. Plus the
   three things that layout assumed about having a mouse.
1. ~~Compilation artwork keying~~ — done. 2,394 keys became 119; enrichment
   then found nothing for those volumes, which is a real answer.
2. ~~Metadata repair ("fix tags")~~ — done, and further than planned: manual
   editing on MP3 and FLAC, plus the MusicBrainz matcher.
3. ~~Plan 2c, background audio~~ — done and verified on the emulator.
4. ~~Queue actions~~ — done; the queue is an editable scratch playlist now.

## Next — starting point for the next session

0. **Plan 3 rollout** (the code is DONE and merged 2026-08-01 — see
   STATUS): tablet hardware pass off the CHANGELOG checklist; desktop
   daily-driver rebuild from `main` (first run migrates the real
   library's playlists to `.playlists/` — upgrade both devices the same
   day); then the post-merge cleanup list in CHANGELOG's TODO.

1. ~~**Plan 3 — phone library sync.**~~ **DONE 2026-08-01** — shipped
   with synced playlists folded in, exactly as scoped below; spec at
   `docs/superpowers/specs/2026-07-31-plan3-sync-design.md`, emulator
   live-verification against the real NAS complete. Original scoping
   kept for the record: One-button LAN pull of new files + manifests from the NAS.
   Content IDs make the diff trivial; the hard parts are Android storage scope
   and transfer resilience. There is now a hand-rolled eight-file precedent:
   the tablet was seeded with tracks whose content IDs and download dates were
   carried across from the NAS manifest, which is exactly what this has to do
   at scale.

   **Fold in while designing it — persistent, synced playlists (raised
   2026-07-31):** a playlist made on the tablet or phone should show up on
   desktop, and vice versa, with no account/login — the same reason all three
   see the same library at all: they're all pointed at the same music
   folder(s). The natural shape is a **playlist sidecar**, the same pattern
   `.artwork.json` and the library manifest already use — a file living
   inside the music root(s) themselves, read by whichever device is pointed
   at that root, no server involved. Open questions worth settling before
   writing code (not yet designed, just scoped):
   - **Where does the sidecar live** — one file per root (matches how
     manifests and `.artwork.json` are already scoped per-root), or one
     playlist file per playlist, or a single library-wide file? A playlist
     can span tracks from more than one of the five roots, which a
     per-root file doesn't cleanly capture — probably wants its own
     location, not bolted onto an existing per-root sidecar.
   - **Membership by content ID**, not path — the same reason everything
     else here is content-ID keyed: retag-proof, rescan-proof, and it
     already means "the same audio," which is exactly what "the same
     playlist across three libraries with three different folder layouts"
     needs.
   - **Conflict resolution** — if the same playlist is edited on two
     devices before either has seen the other's write (plausible: phone
     edits on the go, NAS not reachable until home Wi-Fi), what happens?
     Last-write-wins is simplest and matches how the manifest itself
     already handles concurrent writers, but silently dropping one
     device's edit is a real cost worth naming, not assuming away.
   - **Detecting a change from another device** — this reuses whatever
     Plan 3's own file-watching/diffing mechanism ends up being (the NAS
     pull already has to notice "something changed since last sync"), so
     design them together rather than as two separate polling systems.
2. **The second collection** outside the roots — `albums [no scrape]`,
   `iTunes`, `xmas`, `_to dl`. Still untouched, which is what made the 2007-11
   Rehab date recovery possible. Mike's call whether any of it joins.

## Reference — compilation artwork keying (done 2026-07-29)

**This is where the remaining artwork gap lives, and it is one bug.**
`artworkAlbumKey` is `normalizedArtist|normalizedAlbum` off the TRACK artist,
with no notion of an album artist or a compilation. So a 23-track VA volume
becomes 23 separate "albums":

```
anberlin|alternative times vol 110
cavo|alternative times vol 110
chevelle|alternative times vol 110   ... x23
```

Measured across the `alternative times` root: **119 folders, 2,398 tracks,
2,394 distinct artwork keys** — very nearly one per track. Each fires its own
lookup, asking providers for `"Anberlin Alternative Times Vol 110"`, a release
that has never existed. That is the entire explanation for 375/2,398 coverage
there: not obscurity, just the wrong question asked 2,394 times.

It also wastes the sidecar. Because each of those 23 names resolves through a
track in the same folder, the harvest adopts the SAME `folder.jpg` 23 times
under 23 different names — 370 of the 373 entries in that root's sidecar are
the same handful of images, recorded over and over. (An earlier note here
claimed the opposite, that only one name got the image and the other 22 tracks
depended on the loose file. That was wrong: all 23 get it. The image strip's
strict rule — every track in the folder must carry its own embedded cover —
remains correct and is what ran, but it was more conservative than that
reasoning implied, not a near-miss.)

**Fix**: detect a compilation — one album title spanning many artists in a
folder, or a `TCMP` flag / `TPE2` album-artist tag — and key those tracks by
the album alone. 2,394 lookups collapse to 119, the query becomes
`"Alternative Times Vol 110"`, and one folder image embeds into all 23 tracks.
Contained change, but it alters how EVERY album is keyed, so it needs Mike's
go-ahead and a re-run of enrich → harvest → embed afterwards.

## Milestones — where they landed

1. ~~**Real-device pass**~~ — done 2026-07-29 on a Galaxy Tab S9+ rather than the Pixel: installed, seeded with eight tracks carrying their real content IDs and download dates, played, media session confirmed. The Pixel itself is still unplugged.
2. ~~**Plan 2c — background audio**~~ — done 2026-07-29.
3. ~~**Plan 3 — phone library sync**~~ — **done 2026-08-01**, NAS-direct SMB rather than the originally-sketched desktop-serves-HTTP; synced playlists shipped with it. Tablet hardware pass + desktop rollout pending (STATUS's Next section).
4. **Artwork polish (optional)**: batch "fix all missing artwork" view, artist images/fanart types, opt-in `folder.jpg` writing beside albums.

## Reference — strip the stray cover-image files (done 2026-07-28)

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

## Reference — metadata repair ("fix tags") (done 2026-07-29)

~~**Gated. Do not start until, in this order:**~~ (1) the full-library artwork
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

## Deliberately parked

- **UI reskin (buttons moved, visual pass) — punted 2026-07-31.** Mostly
  skinning and rearranging existing controls, not new functionality. Mike
  wants to run a dedicated Claude-design pass on it rather than iterate it
  live alongside functional work; **do not start this without that pass
  happening first, and do not fold small "while I'm in there" visual
  tweaks into unrelated functional changes in the meantime** — keep the
  surface stable so the design pass has a clean, unchanged baseline to
  work from.

## Decision gates (Mike only)

- ~~**Queue semantics**~~ — settled 2026-07-29: "Play next" IS "add to the
  queue, at the front", so it is a single-track action; a multi-selection gets
  "Add to queue" alone.
- ~~**Vector icon redraw**~~ — done 2026-07-29. One vector source
  (`tools/build_icon.py`) behind every asset; silhouette checked against the
  old art at 0.957 so it is the same icon, not a reinterpretation.

- ~~**File-dates fix**~~ — **done 2026-07-28**, all roots (option 1 + per-album placement; see the writeup's Outcome section and [docs/albums-date-recovery.md](docs/albums-date-recovery.md)). Independently re-verified: 5,553/5,553 files match their manifest date.
- ~~**Full-library artwork embedding**~~ — **run 2026-07-28**, 1,423 covers written, zero failures, zero disturbed dates.
- **Compilation artwork keying** — see the section above. Changes how every album is keyed; wants a yes before it is touched.
- **Metadata repair** — both blocking gates are now clear, so this is startable. See the queued section below.

## Backlog (deferred minors, triaged non-blocking)

- **Tag lookup ranks releases badly** (raised 2026-07-29, queued in CHANGELOG's
  TODO): every release of a recording scores identically on title/artist/
  duration, so the original album and a later Various-Artists compilation are
  indistinguishable to the matcher — and the 10-point album term breaks the tie
  by similarity to the *current, wrong* tag. Needs a release-preference term
  (`secondary-types`, Various-Artists credit, `first-release-date`) and the
  album term decoupled from the existing tag. Matters for artwork too: the
  chosen album is what the cover lookup queries.

- "NN." dot-prefix track-number parse ("01. Gorilla Zoe")
- Fuzzy title matching for the 26 unmatched "alternative times" playlist lines
- Missing-file tracks not hidden from the feed (spec line-item; rescan's diff already knows)
- `visibleTracks` memoization (recomputes per player tick); gear-tap integration test; multi-format tagged-file fixtures (package-upgrade protection)
- Duration re-check on retag (the deeper probe landed 2026-07-28: header-only
  estimator on every give-up path, stacked-tag aware)
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
