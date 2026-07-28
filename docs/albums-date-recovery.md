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

## Done — all 13 albums dated, 2026-07-28

Applied to the manifest and stamped onto the files; every step reversible via
the logs in `L:\BACKUPSooplayer-file-fixes\date-stamping\`.

| Artist — Album | Was | Now | Basis |
|---|---|---|---|
| Blaqk Audio — Cexcells | 2010-08 | **2007-09** | canon Blaqk Audio month, matches release |
| Citizen Cope — Citizen Cope | 2010-08 | **2008-01** | Mike |
| Citizen Cope — Clarence Greenwood Recordings | 2010-08 | **2008-01** | Mike |
| Kanye West — College Dropout | 2026-01 | **2007-09** | Mike |
| Kanye West — Freshmen Adjustment | 2026-01 | **2007-09** | Mike |
| Kanye West — Late Registration | 2010-08 | **2007-09** | Mike |
| Rehab — Welcome Home | 2026-01 | **2010-11** | canon Rehab month, matches release |
| Dead Confederate — Wrecking Ball | 2026-01 | **2008-01** | release year, no other evidence |
| Just Jack — All Night Cinema | 2026-01 | **2015-08** | when Mike moved to California |
| Rehab — Graffiti The World | 2026-01 | **2007-11** | **evidence** — see below |
| Rehab — Southern Discomfort | 2026-01 | **2007-11** | **evidence** — see below |
| The Streets — Everything Is Borrowed | 2010-08 | **2009-02** | canon Streets burst |
| The Streets — all got our runnins EP | 2010-08 | **2009-02** | canon Streets burst |

Left deliberately: `Everclear — Return To Santa Monica` at 2026-01 (accepted),
and the four genuinely-recent 2026-01 downloads (Echos ×2, Little Miss
Sunshine, Swim Surreal).

**Zero folders in `albums` remain on an unexplained bulk stamp, and zero files
in the library disagree with their manifest date.**

## How the Rehab date was recovered

A full sweep of `L:\music (original structure)` — including the folders that
are NOT fooplayer roots (`albums [no scrape]`, `iTunes`, `xmas`, `_to dl`) —
turned up a second, untouched Rehab collection. Those files were never
retagged and never stamped by any of this work, so their filesystem dates are
original.

To tell a real download from a copy event, each candidate date was scored by
how many distinct folders in the whole collection share it:

| Date | Folders | Verdict |
|---|---|---|
| **2007-11-11** | **3** | real download — and all three are Rehab |
| 2009-12-30 | 4 | real download (Rehab — To Whom It May Consume) |
| 2008-02-03 | 23 | bulk copy |
| 2012-07-22 | 27 | bulk copy |
| 2012-11-21 | 523 | bulk copy |
| 2013-01-14 | 115 | bulk copy |
| 2021-11-04 | 20 | bulk copy |

One evening in November 2007, three Rehab folders and nothing else in the
entire library. That is the band being discovered and its back catalogue
pulled down in one go — so *Graffiti The World* (2005) and *Southern
Discomfort* (2000) belong there too.

The Streets got no such gift: every copy outside the roots sits on one of the
bulk dates above. 2009-02 is inference from the canon `monthly` burst, not a
surviving timestamp.
