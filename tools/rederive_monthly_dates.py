#!/usr/bin/env python3
"""Re-derive `date_added` for the `monthly` root from its folder names.

Why
---
`monthly/` is filed BY DOWNLOAD MONTH -- `monthly/2010-07/Dr Dre - 2001/...`
means that album arrived in July 2010.  That filing is an undamaged record:
Mike made it at download time and no tag editor has ever touched it.

The manifest's own dates for this root are not trustworthy.  The Oct 2025
foobar2000 backup, which supplied true dates elsewhere, never covered
`monthly` at all -- so seeding fell through to "file creation time at seed
date", which by then Mp3tag had already overwritten.  The result: of 1,841
tracks, only 85 had a `date_added` matching the folder they are filed in.
Dr. Dre's *2001*, filed under `2010-07`, claimed 2024-07-11.

So the folder wins.  Precision drops to the month -- every track in
`2010-07/` becomes 2010-07-01 -- which is honest about what is actually
known, and vastly better than a wrong year.

Tracks whose existing `date_added` already falls inside their folder's month
are LEFT ALONE: those 85 have a real day-of-month worth keeping.

Safety
------
* --dry-run is the default.
* The manifest is written tmp-then-rename with a `.bak`, and every previous
  value is recorded to a reversal log first.
* Only `date_added` changes.  Content IDs, paths and playlists are untouched,
  so nothing can be orphaned.
* Afterwards, run stamp_dates_from_manifest.py to push the corrected dates
  onto the filesystem.

Usage:
  python rederive_monthly_dates.py            # dry run
  python rederive_monthly_dates.py --apply
  python rederive_monthly_dates.py --revert <logfile>
"""

import argparse
import collections
import datetime
import json
import os
import re
import shutil
import sys
import time

ROOT = r"L:\music (original structure)\monthly"
LOG_DIR = r"L:\BACKUPS\fooplayer-file-fixes\date-stamping"

FOLDER_MONTH = re.compile(r"^(\d{4})-(\d{2})(?:/|$)")


def month_of(rel_path):
    """('2010', '07') for a track filed under monthly/2010-07/, else None."""
    m = FOLDER_MONTH.match(rel_path.replace("\\", "/"))
    return (m.group(1), m.group(2)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--revert", metavar="LOGFILE")
    ap.add_argument("--root", default=ROOT)
    args = ap.parse_args()

    manifest_path = os.path.join(args.root, ".library.json")
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)

    if args.revert:
        with open(args.revert, encoding="utf-8") as f:
            log = json.load(f)
        restored = 0
        for cid, previous in log["dates"].items():
            entry = manifest["tracks"].get(cid)
            if entry:
                entry["date_added"] = previous
                restored += 1
        _save(manifest, manifest_path)
        print(f"restored date_added for {restored} track(s)")
        return 0

    changes = {}          # contentId -> (previous, new)
    kept = unfiled = 0
    for cid, entry in manifest["tracks"].items():
        rel = entry["paths"][0]
        ym = month_of(rel)
        if ym is None:
            unfiled += 1
            continue
        year, month = ym
        if entry["date_added"][:7] == f"{year}-{month}":
            # Already inside its folder's month. The one exception is the
            # midnight-UTC form this script itself used to write, which
            # displays as the previous day locally -- correct those.
            if not entry["date_added"].endswith("-01T00:00:00.000Z"):
                kept += 1
                continue
        # Midday UTC, not midnight: the stamping step converts to LOCAL
        # time, and midnight UTC lands on the previous evening anywhere west
        # of Greenwich -- which showed Dr. Dre's 2001, filed under 2010-07,
        # as 2010-06-30 in Explorer. Midday is safe for any zone in +/-12h.
        changes[cid] = (entry["date_added"], f"{year}-{month}-01T12:00:00.000Z")

    print(f"tracks in {os.path.basename(args.root)}      : {len(manifest['tracks'])}")
    print(f"  already match their folder : {kept}")
    print(f"  to be re-derived           : {len(changes)}")
    print(f"  not filed under YYYY-MM    : {unfiled}")

    spread = collections.Counter(old[:7] for old, _ in changes.values())
    if spread:
        print("\nthe wrong dates being replaced came from:")
        for k, v in spread.most_common(8):
            print(f"   {k} : {v:5d} tracks")

    if not args.apply:
        print("\nDRY RUN -- nothing written. Sample:\n")
        for cid, (old, new) in list(changes.items())[:12]:
            rel = manifest["tracks"][cid]["paths"][0]
            print(f"   {old[:10]} -> {new[:10]}   {rel[:66]}")
        print(f"\n{len(changes)} track(s) would change. Re-run with --apply.")
        return 0

    os.makedirs(LOG_DIR, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d--%H%M")
    log_path = os.path.join(LOG_DIR, f"monthly-dates-{stamp}.json")
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump({"stamped": stamp,
                   "dates": {cid: old for cid, (old, _) in changes.items()}}, f)

    for cid, (_old, new) in changes.items():
        manifest["tracks"][cid]["date_added"] = new
    _save(manifest, manifest_path)

    print(f"\nre-derived {len(changes)} date(s)")
    print(f"reversal log: {log_path}")
    print("\nNext: python stamp_dates_from_manifest.py --apply")
    return 0


def _save(manifest, path):
    tmp, bak = path + ".tmp", path + ".bak"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False)
    if os.path.exists(bak):
        os.remove(bak)
    shutil.copy2(path, bak)
    os.replace(tmp, path)


if __name__ == "__main__":
    sys.exit(main())
