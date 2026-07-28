# Artwork embedding — manual review list

*Generated 2026-07-27--2348. Everything below has been
verified as content-ID-identical and date-identical to before the change,
except where noted. Nothing here is irreversible: backups are listed per section.*

## 1. The 3 FLAC tracks — art embedded natively, NOT converted

`L:\music (original structure)\monthly\2009-12\Zero 7 - Destiny CD Single (2001)`

Cover source: `Album Cover.jpg` (500×500) already present in that folder.
Backups: `L:\BACKUPS\fooplayer-file-fixes\pre-embed-flac\`
ooplayer-file-fixes\pre-embed-flac\`

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `01 - Zero 7 - Destiny (Radio edit).flac` | 24.9 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | yes | — |
| `02 - Zero 7 - Destiny (Photek remix).flac` | 42.6 MB | 2009-12-03 13:01 | 2009-12-03 13:01 | yes | Zero 7 |
| `03 - Zero 7 - End Theme (Roni Size remix).flac` | 51.5 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | yes | — |

> Two of the three have no artist/album tags at all (they read as `—` above). fooplayer still shows them correctly because it falls back to the filename. Candidates for the tag-fixing feature.

## 2. The 3 MP3 duplicates in that same folder — also embedded

**Broader than you asked for.** My tool processes a whole directory, so the
MP3 copies of the same three tracks got the same cover. Verified identical in
content ID and dates, but they were **not backed up** — flagging that plainly.

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `01 - Zero 7 - Destiny (Radio edit).mp3` | 5.2 MB | 2024-07-10 18:35 | 2024-07-10 18:35 | yes | Zero 7 |
| `02 - Zero 7 - Destiny (Photek remix).mp3` | 8.8 MB | 2024-07-10 18:36 | 2024-07-10 18:36 | yes | Zero 7 |
| `03 - Zero 7 - End Theme (Roni Size remix).mp3` | 9.6 MB | 2024-07-10 18:36 | 2024-07-10 18:36 | yes | Zero 7 |

> This folder holds both a FLAC and an MP3 of all three tracks — 6 library
> entries for 3 songs. Pre-existing, not something I introduced, but worth
> deciding about.

## 3. The 13 converted M4A → MP3

Encoded LAME V2 (~190 kbps) from ~135 kbps AAC sources. Each conversion
migrated the manifest so the new content ID inherited the old `date_added`.
Originals: `L:\BACKUPS\fooplayer-file-fixes\pre-mp3-conversion\`
ooplayer-file-fixes\pre-mp3-conversion\`

`L:\music (original structure)\albums\Rehab - Graffiti The World` (12 files)

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `01 Wht Do U Wnt Frm Me.mp3` | 5.9 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `02 Bump.mp3` | 5.9 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `03 Chest Pain.mp3` | 5.1 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `04 Red Water.mp3` | 7.8 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `05 Graffiti The World.mp3` | 7.4 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `06 Last Tattoo.mp3` | 6.1 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `07 Bottles & Cans.mp3` | 4.9 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `08 We Live.mp3` | 5.4 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `09 This Town.mp3` | 6.4 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `10 Walk Away.mp3` | 5.8 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `11 This I Know Featuring Demun Jones.mp3` | 6.9 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |
| `12 Running Out Of Time.mp3` | 5.9 MB | 2026-01-13 03:16 | 2026-01-13 03:16 | yes | Rehab |

`L:\music (original structure)\monthly\2008-07` (1 file)

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `Jay-Z - Guns & Roses (Featuring Lenny Kravitz).mp3` | 5.9 MB | 2024-07-10 17:11 | 2024-07-10 17:11 | **no** | Jay-Z |

> Covers on these came from the original M4A files — ffmpeg carried the
> `covr` atoms across as APIC frames. I did not choose them.

## 4. Sandbox test copies — in the repo, gitignored, NOT part of your library

These are throwaway copies used to prove the mechanism before touching
anything real. Delete the three folders whenever you like.

### `L:\PROJECTS\fooplayer\testdata\embed-test`

*every tag shape: no tag / v2.3 / v2.3+art / v2.2, plus the m4a, flac and MP4-as-MP3 refusal cases*

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `case1-notag.mp3` | 5.6 MB | 2008-03-09 20:52 | 2008-03-09 20:52 | yes | The White Stripes |
| `case2-v23-noart.mp3` | 7.2 MB | 2024-07-10 15:42 | 2024-07-10 15:42 | yes | Akon |
| `case3-v23-withart.mp3` | 3.9 MB | 2012-07-16 10:15 | 2012-07-16 10:15 | yes | Keny Arkana |
| `case4-v22.mp3` | 5.4 MB | 2024-07-10 17:03 | 2024-07-10 17:03 | yes | Lil Wayne |
| `case5-converted.mp3` | 8.1 MB | 2024-07-10 17:11 | 2024-07-10 17:11 | **no** | Jay-Z |
| `case5.m4a` | 4.3 MB | 2024-07-10 17:11 | 2024-07-10 17:11 | **no** | Jay-Z |
| `case6-converted.mp3` | 7.1 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | **no** | Zero 7 |
| `case6.flac` | 24.9 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | **no** | — |
| `case7-mp4-as-mp3.mp3` | 4.3 MB | 2024-07-10 17:11 | 2024-07-10 17:11 | **no** | — |

### `L:\PROJECTS\fooplayer\testdata\convert-sandbox`

*conversion + manifest migration rehearsal*

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `Jay-Z - Guns & Roses.mp3` | 8.2 MB | 2024-07-10 17:11 | 2024-07-10 17:11 | yes | Jay-Z |
| `Zero 7 - Destiny.mp3` | 7.2 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | yes | Zero 7 |

### `L:\PROJECTS\fooplayer\testdata\flac-sandbox`

*FLAC PICTURE embedding rehearsal*

| File | Size | Modified | Created | Cover | Artist tag |
|---|---|---|---|---|---|
| `01 - Zero 7 - Destiny (Radio edit).flac` | 24.9 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | yes | — |
| `02 - Zero 7 - Destiny (Photek remix).flac` | 42.6 MB | 2009-12-03 13:01 | 2009-12-03 13:01 | yes | Zero 7 |
| `03 - Zero 7 - End Theme (Roni Size remix).flac` | 51.5 MB | 2012-11-21 21:57 | 2012-11-21 21:57 | yes | — |

### Where the sandbox copies came from (these originals are untouched)

| Copy | Source in the library |
|---|---|
| `case1-notag.mp3` | `L:\music (original structure)\monthly\2008-03\The White Stripes - Seven Nation Army.mp3` |
| `case2-v23-noart.mp3` | `L:\music (original structure)\monthly\2007-08\Akon - Sorry, Blame It on Me.mp3` |
| `case4-v22.mp3` | `L:\music (original structure)\monthly\2008-07\Lil Wayne - Tha Carter III (2008)\05 Comfortable (Featuring Babyfac.mp3` |
| `case5.m4a` | `L:\music (original structure)\monthly\2008-07\Jay-Z - Guns & Roses (Featuring Lenny Kravitz).m4a` |
| `case6.flac` | `L:\music (original structure)\monthly\2009-12\Zero 7 - Destiny CD Single (2001)\01 - Zero 7 - Destiny (Radio edit).flac` |
| `case3-v23-withart.mp3` | `L:\music (original structure)\monthly\2007-08\Keny Arkana - Le missile est lancé.mp3` |

## Not yet touched

The ~3,659 art-less MP3s across the library. The full pass is built and
proven but deliberately unrun, pending your decision.
