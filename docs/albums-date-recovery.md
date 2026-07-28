# The `albums` root — the 14 albums still needing a download date

*Updated 2026-07-28--0410 after Mike's rulings. Companion to
[music-library-dates-issue.md](music-library-dates-issue.md).*

## The rule that settles most of the library

> **Anything under `monthly/` is canon, 100%.**

`monthly/YYYY-MM/` was filed by download month at the time, and no tag editor has
ever touched a folder name. All 1,841 tracks there were re-derived from it on
2026-07-28 and are correct by construction. That is also why dates that *look*
right there are right — e.g. DJ Infamous & The Empire's *ATL* reads 2009-03 because
it sits in `monthly/2009-03/`, not because it survived Mp3tag. Nothing survived
Mp3tag; the folder tree did.

## Everything now considered settled

| Group | Folders | Tracks | Verdict |
|---|---|---|---|
| `monthly/` tree | — | 1,841 | **Canon** — folder-derived |
| `alternative times` — Soulseek bulk | 101 vols | 2,026 | Correct — one 2024-06 acquisition |
| `alternative times` — the older 18 | 18 vols | 372 | Left at 2010-08, the date they were grouped |
| `albums` — 2023-03 cluster | 24 | 269 | Correct — one big backlog download spree |
| `albums` — artist-coherent groups | 15 | 194 | Correct — real acquisitions |
| `albums` — Little Miss Sunshine, Swim Surreal, Echos ×2 | 4 | 33 | Correct — very new |

## Done — dates set 2026-07-28 (7 albums, 109 tracks)

From Mike's memory, anchored on the canon `monthly` months. Applied to the
manifest and stamped onto the files; reversal logs
`album-dates-2026-07-28--1413.json` and `date-stamp-2026-07-28--1413.json`.

| Artist — Album | Was | Now | Released |
|---|---|---|---|
| Blaqk Audio — Cexcells | 2010-08 | **2007-09** | 2007 |
| Citizen Cope — Citizen Cope | 2010-08 | **2008-01** | 2002 |
| Citizen Cope — The Clarence Greenwood Recordings | 2010-08 | **2008-01** | 2004 |
| Kanye West — College Dropout | 2026-01 | **2007-09** | 2004 |
| Kanye West — Freshmen Adjustment | 2026-01 | **2007-09** | 2005 |
| Kanye West — Late Registration | 2010-08 | **2007-09** | 2005 |
| Rehab — Welcome Home | 2026-01 | **2010-11** | 2010 |

*"2008" was taken as January 2008, per the bare-year convention. Say the word
if you'd rather have those two mid-year.*

## Still open — 7 albums, 80 tracks

| Artist — Album | Trk | Dated now | Released | Same artist in `monthly` (canon) | **Your date** |
|---|---|---|---|---|---|
| Dead Confederate — Wrecking Ball | 10 | 2026-01 | **2008** | — |  |
| Everclear — Return To Santa Monica | 12 | 2026-01 | **2011** | 2008-07 *(predates the album)* |  |
| Just Jack — All Night Cinema | 12 | 2026-01 | **2009** | — |  |
| Rehab — Graffiti The World | 12 | 2026-01 | **2005** | 2010-11 |  |
| Rehab — Southern Discomfort | 15 | 2026-01 | **2000** | 2010-11 |  |
| The Streets — Everything Is Borrowed | 11 | 2010-08 | **2008** | 2009-02, 2012-02 |  |
| The Streets — all got our runnins EP | 8 | 2010-08 | ? | 2009-02, 2012-02 |  |

The three you asked about all sit in the Mp3tag window, so their current
values carry no information at all:

- **Just Jack — All Night Cinema**: now `2026-01`, released **2009**
- **Everclear — Return To Santa Monica**: now `2026-01`, released **2011**
- **Dead Confederate — Wrecking Ball**: now `2026-01`, released **2008**

Two obvious candidates if you want them off the list without much thought:
the remaining **Rehab** pair could follow *Welcome Home* to 2010-11 (the only
canon Rehab month), and **The Streets** pair could take 2009-02, which fits
*Everything Is Borrowed*'s 2008 release.

## Ruled correct, left alone

`Echos — Quiet, In Your Service`, `Echos — Revival EP`, `Little Miss Sunshine`
and `Swim Surreal, Zero 7` still read 2026-01, and that is right — they are
genuinely recent downloads that happen to fall in the same window.

## Filling it in

A month (`2009-06`) or a bare year (`2009`, taken as January). Add them to
`ASSIGNMENTS` in `tools/set_album_dates.py`, then:

```
python tools/set_album_dates.py            # dry run
python tools/set_album_dates.py --apply
python tools/stamp_dates_from_manifest.py --apply
```
