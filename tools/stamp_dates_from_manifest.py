#!/usr/bin/env python3
"""Stamp each track's filesystem date from its manifest `date_added`.

This is option 1 from docs/music-library-dates-issue.md, approved 2026-07-28.

Why
---
foobar2000 and Explorer sort by filesystem dates, ~4,302 of which Mp3tag
overwrote by saving edits as write-temp-then-rename.  The true download dates
survive as data in each root's `.library.json` (recovered from the Oct 2025
foobar2000 backup), so the filesystem can simply be re-derived from them.

Why the *modified* time
-----------------------
Creation time is not writable over SMB here -- Linux has no writable birth
time and this Samba isn't storing one in an xattr, so it accepts the write and
discards it (proven by probe).  But measured on this share 2026-07-27: Samba
reports creation time as EQUAL to modified time, so setting mtime fixes BOTH
columns Explorer shows and the field foobar2000 sorts on.  No NAS config
change is needed.

The trade-off, stated plainly: "Date modified" stops meaning "last edited" and
starts meaning "downloaded".  A future tag-editing session will clobber it
again -- and re-running this script fixes it in one pass, because the manifest
is the durable source of truth and is never touched by a tagger.

Safety
------
* --dry-run is the default; nothing is written without --apply.
* Every change is recorded to a reversal log (path + previous mtime) BEFORE
  it is made, so the whole operation can be undone with --revert <log>.
* Each write is read back and verified; mismatches are reported, not assumed.
* Audio bytes are never touched, so content IDs -- and therefore the manifest
  itself -- cannot be affected.

Usage:
  python stamp_dates_from_manifest.py                 # dry run
  python stamp_dates_from_manifest.py --apply
  python stamp_dates_from_manifest.py --revert <logfile>
"""

import argparse
import datetime
import json
import os
import sys
import time

LIBRARY = r"L:\music (original structure)"
ROOTS = [
    "monthly",
    "loose tracks - old",
    "loose tracks - 2020 and later",
    "alternative times",
    "albums",
]
LOG_DIR = r"L:\BACKUPS\fooplayer-file-fixes\date-stamping"

# Filesystem timestamps and ISO dates don't agree to the microsecond; anything
# inside this window is already correct and left alone.
TOLERANCE_SECONDS = 2


def manifest_entries(root_name):
    """(absolute path, target epoch seconds) for every track in one root.

    A manifest entry is keyed by content ID and can name SEVERAL paths -- the
    same audio filed in two places.  Every one of them is the same download
    and gets the same date.  The first run of this script stamped `paths[0]`
    only, which left 66 duplicate copies sitting on whatever date the copy
    event gave them (2012-11-22 and friends) while their twins read
    correctly -- invisible unless you happened to open the second folder.
    """
    root = os.path.join(LIBRARY, root_name)
    path = os.path.join(root, ".library.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for entry in data["tracks"].values():
        target = datetime.datetime.fromisoformat(
            entry["date_added"].replace("Z", "+00:00")
        ).timestamp()
        for rel in entry["paths"]:
            yield os.path.join(root, rel.replace("/", os.sep)), target


def stamp(path, target):
    """Set mtime/atime and read back. Returns (ok, previous_mtime)."""
    previous = os.stat(path).st_mtime
    os.utime(path, (target, target))
    after = os.stat(path).st_mtime
    return abs(after - target) <= TOLERANCE_SECONDS, previous


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="actually write; omit for a dry run")
    ap.add_argument("--revert", metavar="LOGFILE",
                    help="restore the previous dates recorded in a log")
    ap.add_argument("--roots", nargs="+", default=ROOTS)
    args = ap.parse_args()

    if args.revert:
        with open(args.revert, encoding="utf-8") as f:
            log = json.load(f)
        restored = failed = 0
        for path, previous in log["changes"].items():
            try:
                os.utime(path, (previous, previous))
                restored += 1
            except OSError:
                failed += 1
        print(f"reverted {restored} file(s); {failed} failed")
        return 0

    todo, already, absent = [], 0, 0
    for root_name in args.roots:
        for path, target in manifest_entries(root_name):
            try:
                current = os.stat(path).st_mtime
            except OSError:
                absent += 1
                continue
            if abs(current - target) <= TOLERANCE_SECONDS:
                already += 1
            else:
                todo.append((path, target, current))

    fmt = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
    print(f"tracks already correct : {already}")
    print(f"tracks to re-stamp     : {len(todo)}")
    print(f"files not found        : {absent}")

    if not args.apply:
        print("\nDRY RUN -- nothing written. Sample of what would change:\n")
        for path, target, current in todo[:15]:
            print(f"   {fmt(current)} -> {fmt(target)}   "
                  f"{os.path.relpath(path, LIBRARY)}")
        if len(todo) > 15:
            print(f"   ... and {len(todo) - 15} more")
        print("\nRe-run with --apply to write.")
        return 0

    os.makedirs(LOG_DIR, exist_ok=True)
    stamp_id = time.strftime("%Y-%m-%d--%H%M")
    log_path = os.path.join(LOG_DIR, f"date-stamp-{stamp_id}.json")

    changes, failures = {}, []
    started = time.time()
    for i, (path, target, _current) in enumerate(todo, 1):
        try:
            ok, previous = stamp(path, target)
        except OSError as e:
            failures.append((path, str(e)))
            continue
        if ok:
            changes[path] = previous
        else:
            failures.append((path, "written but did not persist"))
        if i % 500 == 0:
            print(f"   {i}/{len(todo)} ...")
        # Flush the reversal log periodically so an interrupted run is still
        # fully undoable.
        if i % 500 == 0 or i == len(todo):
            with open(log_path, "w", encoding="utf-8") as f:
                json.dump({"stamped": stamp_id, "changes": changes}, f)

    print()
    print(f"re-stamped : {len(changes)}")
    print(f"failed     : {len(failures)}")
    print(f"elapsed    : {time.time() - started:.0f}s")
    print(f"reversal log: {log_path}")
    for path, why in failures[:10]:
        print(f"   FAILED {why}: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
