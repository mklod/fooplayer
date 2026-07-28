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

## The 14 that are still wrong (189 tracks)

Two clusters, neither a download:

- **2010-08** — a grouping/copy event. Same stamp the 18 oldest Alternative Times
  volumes carry.
- **2026-01** — the Mp3tag housekeeping window. Kanye's *College Dropout* did not
  arrive in 2026.

`Released` is a hard floor — the download cannot predate it. `Same artist in
monthly` is the useful column: those months are canon, and an album usually
arrives near when you were listening to that artist.

| Artist — Album | Trk | Dated | Released | Art | Same artist in `monthly` (canon) | **Your date** |
|---|---|---|---|---|---|---|
| Blaqk Audio - Cexcells | 12 | 2010-08 | **2007** | yes | 2007-09 |  |
| Citizen Cope - Citizen Cope | 14 | 2010-08 | **2002** | yes | 2012-09, 2013-01 |  |
| Citizen Cope - The Clarence Greenwood Recordings | 11 | 2010-08 | **2004** | yes | 2012-09, 2013-01 |  |
| Kanye West - Late Registration | 21 | 2010-08 | **2005** | yes | 2007-09, 2008-07, 2008-12, 2009-04, 2009-10, 2010-11 |  |
| The Streets - all got our runnins EP | 8 | 2010-08 | **?** | yes | 2009-02, 2012-02 |  |
| The Streets - Everything Is Borrowed | 11 | 2010-08 | **2008** | yes | 2009-02, 2012-02 |  |
| Dead Confederate - Wrecking Ball (2008) | 10 | 2026-01 | **2008** | yes | — |  |
| Everclear - Return To Santa Monica (2011) | 12 | 2026-01 | **2011** | yes | 2008-07 |  |
| Just Jack - All Night Cinema | 12 | 2026-01 | **2009** | yes | — |  |
| Kanye West - College Dropout [2004] | 21 | 2026-01 | **2004** | yes | 2007-09, 2008-07, 2008-12, 2009-04, 2009-10, 2010-11 |  |
| Kanye West - Freshmen Adjustment [2005] | 20 | 2026-01 | **2005** | yes | 2007-09, 2008-07, 2008-12, 2009-04, 2009-10, 2010-11 |  |
| Rehab - Graffiti The World | 12 | 2026-01 | **2005** | yes | 2010-11 |  |
| Rehab - Southern Discomfort | 15 | 2026-01 | **2000** | yes | 2010-11 |  |
| Rehab - Welcome Home (2010) | 10 | 2026-01 | **2010** | yes | 2010-11 |  |

### Reading the anchors

- **Kanye West ×3** — you were on Kanye across 2007-09 → 2010-11. *Late
  Registration* (2005) and *College Dropout* (2004) are backlog, so they most
  likely came with one of those bursts rather than on release.
- **Rehab ×3** — the only Rehab in `monthly` is **2010-11**, and *Welcome Home*
  came out in 2010. A 2010-11 stamp for all three is a defensible guess.
- **The Streets ×2** — 2009-02 and 2012-02. *Everything Is Borrowed* released 2008,
  so 2009-02 fits.
- **Citizen Cope ×2** — 2012-09 / 2013-01.
- **Blaqk Audio** — 2007-09, and the album is 2007. Likely right on release.
- **Everclear** — the only Everclear month is 2008-07, but *Return To Santa Monica*
  is 2011, so that anchor cannot apply; needs your memory.
- **Dead Confederate**, **Just Jack** — nothing by them in `monthly`. Release years
  2008 and 2009 are the only floor.

## Filling it in

A month (`2009-06`) or a bare year (`2009`, taken as January) is enough —
approximate is the goal, so classics stop surfacing among recent downloads.
Anything left blank keeps what it has.

Then, reversibly:

```
python tools/set_album_dates.py --dry-run
python tools/set_album_dates.py --apply
python tools/stamp_dates_from_manifest.py --apply
```
