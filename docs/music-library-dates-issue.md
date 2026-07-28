# Music Library "Date Downloaded" — the Problem, What's Fixed, and the Options

*2026-07-24 — status writeup for the sort-by-newest-downloads issue*
*2026-07-28 — **RESOLVED**: option 1 applied. See "Outcome" at the bottom.*

## TL;DR

- **The new player app already sorts correctly, permanently.** Its `.library.json` manifest stores every track's original download date as real data, recovered from the Oct 2025 foobar2000 database backup. No tag editor can ever break it again.
- **foobar2000 and Explorer sorted wrong too** — they use filesystem dates, ~4,302 of which Mp3tag overwrote. **Fixed 2026-07-28**, see Outcome.

## What "date downloaded" actually is

Windows stamps every file with a **creation time** when it first appears on a disk. foobar2000 (via the File Date Time component) and Explorer's "Date created" column sort by it. It has always been a fragile stand-in for "date downloaded":

- It describes *this copy on this disk* — copying the library to a new drive resets it.
- Any program that saves by "write temp file, rename over the original" replaces it with today's date.

## How it broke

**Mp3tag saves edits exactly that way** (write-temp-then-rename). Every retagging session made the edited files look brand-new. Example (real data):

```
Arctic Monkeys — Secret Door (Humbug)
  true download date : 2023-04-04   (from the foobar2000 DB backup)
  file creation time : 2024-07-02   (the day it was retagged)
```

**4,302 files** are affected out of 4,947 covered by the backup; 523 were already correct; 122 files in the backup no longer exist. Files downloaded *after* the Oct 2025 backup and retagged since have no recoverable original date, from any source.

## What is already permanently fixed

The new player's manifest (`.library.json` in the library root, 10,600+ tracks) was seeded with dates using this priority:

1. **Oct 2025 foobar2000 `metadb.sqlite` backup** (true download dates) — 4,800 tracks
2. File creation time at seed date (correct for everything never retagged) — 6,046 tracks

Track identity in the manifest is a hash of the *audio data only* — retagging, renaming, or moving files changes nothing. The date lives in data, not filesystem metadata. **This is the durable source of truth going forward**, and any filesystem stamping (below) can be regenerated from it at any time.

## Why the filesystem can't just be fixed

The restore script (`restore_ctimes.py`, verified by dry run: 4,825/4,947 matchable, zero ambiguity) sets creation times via the Windows API. It reports success — but a controlled probe shows the write does not persist:

```
before ctime: 2024-07-02 22:45:08     (wrong)
SetFileTime:  no exception            (server says OK)
after  ctime: 2024-07-02 22:45:08     (unchanged)
```

Reason: the library now lives on murkyserver (`L:` → `\\murkyserver\drop`). Linux filesystems have no writable "birth time," so Samba can only emulate one by storing it in an extended attribute — and murkyserver's Samba is not configured to do so. It accepts the request and discards it. **From Windows, creation times on L: are effectively read-only.** (The script worked as designed back when the library was on local disk.)

## The options

| | Option | What it does | Pros | Cons |
|---|---|---|---|---|
| 1 | **Modified-time route** | Stamp each file's *modified* time with its download date (from the manifest); sort by "Date modified" everywhere | Writable over SMB today; survives copies (incl. to phone later); every app on every platform sorts by it; repeatable — a small script can re-stamp all times from the manifest anytime, making future Mp3tag damage a 30-second fix | "Modified" stops meaning "last edited"; a future retag session clobbers it again until re-stamped |
| 2 | **Fix Samba on murkyserver** | Add `store dos attributes = yes` to smb.conf + restart; then re-run the existing creation-time restore | foobar's current sort config works unchanged; creation times become writable and persistent | Requires NAS config change; creation times stay inherently clobber-prone to future retags (same trap, re-armed); stored in xattrs that don't travel off the NAS |
| 3 | **Both 1 + 2** | Correct creation times *and* download-date mtimes | Every tool sorts right by either field | Both cons above, minus none |
| 4 | **Do nothing to the filesystem** | Rely on the new player's manifest sort only | Zero risk, zero work | foobar2000/Explorer stay wrong until the new app fully replaces them |

## Recommendation

**Option 1** (modified-time), with the manifest-driven re-stamp script kept in the repo as permanent insurance. It is the only route where the fix travels with the files to every future disk, phone, and OS, and where recovery from future tag-editor damage is trivial. Option 2 can be added later any time murkyserver's config is being touched anyway.

## Current state / next step

- Manifest: seeded and correct (the new app sorts right today).
- Filesystem: unchanged — awaiting a decision between the options above.
- `restore_ctimes.py`: path-updated, dry-run verified, blocked only by the Samba behavior (option 2 would unblock it).

---

## Outcome (2026-07-28)

**Option 1 applied**, on Mike's explicit go-ahead.

One measurement changed the picture and made option 2 unnecessary. Probing the
share directly:

```
fresh file             created=2026-07-27 19:26:21  modified=2026-07-27 19:26:21
after utime->2019      created=2019-03-04 11:22:33  modified=2019-03-04 11:22:33
after in-place write   created=2026-07-27 19:26:21  modified=2026-07-27 19:26:21
after restoring mtime  created=2019-03-04 11:22:33  modified=2019-03-04 11:22:33
after rename           created=2019-03-04 11:22:33  modified=2019-03-04 11:22:33
```

**This Samba reports creation time as EQUAL to modified time.** Setting the
modified time therefore corrects *both* columns Explorer shows and the field
foobar2000 sorts on — so the NAS config change (option 2) buys nothing here,
and creation times need no separate handling anywhere in this project.

What was done:

- `tools/stamp_dates_from_manifest.py` stamps every track's mtime/atime from
  its manifest `date_added`, dry-run by default, verifying each write by
  reading it back.
- Run over all five roots: **5,483 tracks — 3,759 already correct, 1,724
  re-stamped, 0 failures, 7 seconds.** A second dry run afterwards reports 0
  remaining.
- Reversal log at
  `L:\BACKUPS
ooplayer-file-fixes\date-stamping\date-stamp-2026-07-28--0122.json`
  (every changed path with its previous mtime); `--revert <log>` undoes the
  whole operation.

Examples of what moved:

| Track | Filesystem said | True download date |
|---|---|---|
| Kanye West — Stronger | 2026-01-12 | 2024-07-10 |
| &ME — After Dark | 2024-07-02 | 2020-12-16 |
| 3LAU HAUS #52 (Miami) | 2024-07-03 | 2022-02-10 |
| Above & Beyond — Alone Tonight | 2024-07-11 | 2012-04-26 |

Audio bytes were never touched, so no content ID changed and the manifest —
the source these dates came from — is unaffected.

**The standing trade-off:** "Date modified" now means "downloaded", not "last
edited". A future tag-editing session will clobber it again for the files it
touches; re-running the script fixes that in one pass, because the manifest is
never touched by a tagger. fooplayer's own tag writing (artwork embedding, and
the metadata repair to come) already preserves both dates, verified per file.
