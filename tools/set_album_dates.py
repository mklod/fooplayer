#!/usr/bin/env python3
"""Set download dates for individual albums in the `albums` root.

The last mile of the date recovery.  `monthly/` was re-derived from its folder
names and is canon; `alternative times` and most of `albums` were ruled
correct.  What is left are albums Mike moved out of `monthly/` and retagged,
destroying the only record of when they arrived -- so the dates come from his
memory, anchored by the release year (a hard floor) and by the canon months in
which the same artist appears under `monthly/`.

See docs/albums-date-recovery.md for the working table.

Values may be a month (`2007-09`) or a bare year (`2008`, taken as January).
Times are written at midday UTC so the calendar day survives conversion to
local time -- midnight UTC lands on the previous evening here.

Safety
------
* --dry-run is the default.
* Previous values go to a reversal log before anything is written, and the
  manifest is saved tmp-then-rename with a `.bak`.
* Only `date_added` changes; content IDs, paths and playlists are untouched.
* Follow with stamp_dates_from_manifest.py to push the dates to the files.
"""

import argparse
import json
import os
import shutil
import sys
import time

ROOT = r"L:\music (original structure)\albums"
LOG_DIR = r"L:\BACKUPS\fooplayer-file-fixes\date-stamping"

# folder name (exactly as on disk) -> download date, from Mike.
ASSIGNMENTS = {
    # 2026-07-28
    "Blaqk Audio - Cexcells": "2007-09",
    "Rehab - Welcome Home (2010)": "2010-11",
    "Kanye West - Late Registration": "2007-09",
    "Kanye West - College Dropout [2004]": "2007-09",
    "Kanye West - Freshmen Adjustment [2005]": "2007-09",
    "Citizen Cope - Citizen Cope": "2008",
    "Citizen Cope - The Clarence Greenwood Recordings": "2008",
}


def iso(value):
    """'2007-09' or '2008' -> an ISO timestamp at midday UTC."""
    parts = value.strip().split("-")
    year = parts[0]
    month = parts[1] if len(parts) > 1 else "01"
    return f"{year}-{month}-01T12:00:00.000Z"


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
        n = 0
        for cid, previous in log["dates"].items():
            entry = manifest["tracks"].get(cid)
            if entry:
                entry["date_added"] = previous
                n += 1
        _save(manifest, manifest_path)
        print(f"restored date_added for {n} track(s)")
        return 0

    by_folder = {}
    for cid, entry in manifest["tracks"].items():
        by_folder.setdefault(entry["paths"][0].split("/")[0], []).append(cid)

    planned, missing = [], []
    for folder, value in ASSIGNMENTS.items():
        cids = by_folder.get(folder)
        if not cids:
            missing.append(folder)
            continue
        target = iso(value)
        current = manifest["tracks"][cids[0]]["date_added"]
        planned.append((folder, cids, current, target))

    for folder in missing:
        print(f"!! no such folder in the manifest: {folder}")

    print(f"albums to set: {len(planned)}\n")
    for folder, cids, current, target in sorted(planned):
        print(f"   {current[:10]} -> {target[:10]}   {folder}  ({len(cids)} tracks)")

    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return 0

    os.makedirs(LOG_DIR, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d--%H%M")
    log_path = os.path.join(LOG_DIR, f"album-dates-{stamp}.json")
    previous = {}
    for _folder, cids, _current, _target in planned:
        for cid in cids:
            previous[cid] = manifest["tracks"][cid]["date_added"]
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump({"stamped": stamp, "dates": previous}, f)

    changed = 0
    for _folder, cids, _current, target in planned:
        for cid in cids:
            manifest["tracks"][cid]["date_added"] = target
            changed += 1
    _save(manifest, manifest_path)

    print(f"\nset {changed} track date(s) across {len(planned)} album(s)")
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
