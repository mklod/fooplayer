#!/usr/bin/env python3
"""Re-pins artwork that a retag orphaned.

What happened
-------------
Artwork was filed under a key built from the artist and album TAGS
(`artist|album`, or `artist|title` when there is no album). Editing those
tags moves the key, so the art stays behind under a name nothing looks up
any more.

Twelve Mr Suicide Sheep mixes were retagged to share one album, "Sheepy
Mixes". Every one of their keys collapsed onto `mr suicide sheep|sheepy
mixes`, so three separately-chosen covers became one shared cover and two
orphans.

The app now also pins a hand-picked cover to the track's content id, which is
a hash of the audio and cannot be moved by editing tags. This re-pins the
covers that were chosen BEFORE that existed, by matching each orphaned entry
back to the track it was picked for.

Matching
--------
An entry is orphaned when no track in the library currently resolves to its
key. For each one, the old key's shape tells us what it was:

    artist|title   ->  the track whose artist and title normalize to those
    artist|album   ->  ambiguous, left alone

Only the unambiguous ones are re-pinned, and only when exactly one track
matches. Anything else is reported for a human to look at.

Safety
------
* --dry-run is the default.
* Only ADDS entries; nothing is deleted or overwritten.
* The sidecar is written tmp-then-rename with a .bak, matching the app.

Usage:
  python repair_orphaned_art.py            # dry run
  python repair_orphaned_art.py --apply
"""

import argparse
import json
import os
import re
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
CACHE = os.path.join(
    os.environ.get("APPDATA", ""), "fooplayer", "meta_cache.json"
)

#: Marks a key as belonging to one track rather than an album. Must match
#: `trackArtKey` in album_key.dart.
TRACK_MARK = "\x03"

#: Marks a folder-scoped compilation key (see artworkAlbumKey). Those are
#: built from the FOLDER, not from the tags, so a retag cannot orphan them --
#: and the "live keys" set below does not model them, so without this skip
#: every compilation entry looks orphaned.
COMPILATION_MARK = "\x02"


def normalize(s):
    """Mirrors normalizeArtworkText for the shapes that occur in real keys."""
    s = (s or "").lower().replace("&", " and ")
    while True:
        n = re.sub(r"\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}", " ", s)
        if n == s:
            break
        s = n
    s = re.sub(r"['\u2018\u2019\u02bc`]", "", s)
    s = re.sub(r"[^\w\s]", " ", s, flags=re.UNICODE)
    return re.sub(r"\s+", " ", s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    try:
        cache = json.load(open(CACHE, encoding="utf-8"))
    except OSError as exc:
        print(f"cannot read the tag cache ({exc})")
        return 1

    repinned = total_orphans = ambiguous = 0
    for root_name in ROOTS:
        root = os.path.join(LIBRARY, root_name)
        art_path = os.path.join(root, ".artwork.json")
        man_path = os.path.join(root, ".library.json")
        if not (os.path.exists(art_path) and os.path.exists(man_path)):
            continue

        sidecar = json.load(open(art_path, encoding="utf-8"))
        art = sidecar.get("art", {})
        manifest = json.load(open(man_path, encoding="utf-8"))

        # Every key the library currently resolves to, and an index from
        # artist|title back to the tracks that would produce it.
        live = set()
        by_artist_title = defaultdict(list)
        for cid, entry in manifest["tracks"].items():
            tags = cache.get(cid)
            if not isinstance(tags, dict):
                continue
            artist = normalize(tags.get("artist"))
            album = normalize(tags.get("album"))
            title = normalize(tags.get("title"))
            live.add(f"{artist}|{album}" if album else f"{artist}|{title}")
            by_artist_title[f"{artist}|{title}"].append(cid)

        additions = {}
        for key, entry in art.items():
            if (key.startswith(TRACK_MARK)
                    or key.startswith(COMPILATION_MARK)
                    or "|" not in key):
                continue
            if key in live:
                continue  # still reachable
            total_orphans += 1
            owners = by_artist_title.get(key, [])
            if len(owners) != 1:
                ambiguous += 1
                print(f"  ? {root_name}: {key!r} -> {len(owners)} candidates")
                continue
            pin = TRACK_MARK + owners[0]
            if pin in art:
                continue
            additions[pin] = dict(entry)
            print(f"  + {root_name}: {key!r} re-pinned to {owners[0][:12]}...")

        repinned += len(additions)
        if args.apply and additions:
            art.update(additions)
            sidecar["art"] = art
            tmp, bak = art_path + ".tmp", art_path + ".bak"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(sidecar, fh, ensure_ascii=False)
            if os.path.exists(bak):
                os.remove(bak)
            shutil.copy2(art_path, bak)
            os.replace(tmp, art_path)

    print()
    print(f"orphaned entries : {total_orphans}")
    print(f"re-pinned        : {repinned}{'' if args.apply else ' (would be)'}")
    print(f"ambiguous        : {ambiguous}")
    if not args.apply:
        print("\nDRY RUN -- re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
