#!/usr/bin/env python3
"""Re-file compilation artwork under its new folder-scoped name.

Why
---
Artwork used to be filed under `artist|album`, which on a various-artists
release produced one entry per track: a 23-track volume recorded the same
`Folder.jpg` twenty-three times, once per artist.  fooplayer now files a
compilation under `\\x02<folder>|<album>` instead -- one entry for the release.

Without this, every one of those old entries is orphaned: nothing looks them
up again, and the record of which cover was chosen is lost even though the
image is still sitting in `.artwork/`.

What counts as a compilation here
---------------------------------
The app infers it from the tracks (many artists sharing one album title in one
folder).  This script can't see tracks, so it infers the same thing from the
sidecar: three or more DIFFERENT artist parts sharing one album part, all
adopted from the same folder.  That is the same signature, and over-migrating
is harmless -- an extra entry nothing looks up costs a line of JSON.

Only entries adopted from a local file are migrated.  The handful that came
from an online provider matched on the artist alone (`Chris Cornell
Alternative Times Vol 1` is not a record anyone released), so promoting one to
be a whole volume's cover would spread a bad guess across every track on it.
Those are reported and left for the app to look up properly.

Safety
------
* --dry-run is the default.
* The sidecar is written tmp-then-rename with a .bak, matching the app.
* Old entries are kept, not deleted -- they cost nothing and mean a rollback
  is just restoring the .bak.

Usage:
  python migrate_compilation_art.py [--apply]
"""

import argparse
import json
import os
import shutil
import sys
from collections import defaultdict

LIBRARY = r"L:\music (original structure)"
ROOTS = [
    "monthly",
    "loose tracks - old",
    "loose tracks - 2020 and later",
    "alternative times",
    "albums",
]

MIN_ARTISTS = 3


def compilation_key(folder, album):
    """Mirrors artworkAlbumKey's compilation branch (album_key.dart)."""
    return "\x02" + folder.replace("\\", "/").lower() + "|" + album


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    total_new = total_skipped_online = 0
    for root_name in ROOTS:
        root = os.path.join(LIBRARY, root_name)
        path = os.path.join(root, ".artwork.json")
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except OSError:
            continue
        art = data.get("art", {})

        # (folder, album) -> {artist: key}
        groups = defaultdict(dict)
        online = defaultdict(set)
        for key, entry in art.items():
            if key.startswith("\x02") or "|" not in key:
                continue  # already migrated, or the untagged fallback
            artist, _, album = key.partition("|")
            if not album:
                continue
            origin = entry.get("origin") or ""
            if origin.startswith("http") or not origin:
                # Remember it so a whole group of online-only guesses can be
                # reported rather than silently dropped.
                online[album].add(artist)
                continue
            folder = os.path.relpath(os.path.dirname(origin), root)
            groups[(folder, album)][artist] = key

        new_entries = {}
        for (folder, album), by_artist in groups.items():
            if len(by_artist) < MIN_ARTISTS:
                continue  # a normal album: one artist, nothing to re-file
            key = compilation_key(folder, album)
            if key in art:
                continue
            # They all point at the same adopted image; take any one.
            source_key = sorted(by_artist.values())[0]
            new_entries[key] = dict(art[source_key])

        skipped = sum(len(v) for k, v in online.items() if len(v) >= MIN_ARTISTS)
        total_new += len(new_entries)
        total_skipped_online += skipped
        print(f"{root_name:<32} {len(art):>5} entries -> "
              f"{len(new_entries):>4} compilation entries"
              f"{f', {skipped} online guesses left alone' if skipped else ''}")

        if args.apply and new_entries:
            art.update(new_entries)
            data["art"] = art
            tmp, bak = path + ".tmp", path + ".bak"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False)
            if os.path.exists(bak):
                os.remove(bak)
            shutil.copy2(path, bak)
            os.replace(tmp, path)

    print(f"\n{total_new} compilation entries"
          f"{'' if args.apply else ' would be'} written"
          f"; {total_skipped_online} artist-only online guesses left for the "
          f"app to redo")
    if not args.apply:
        print("DRY RUN -- re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
