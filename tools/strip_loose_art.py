#!/usr/bin/env python3
"""Move loose cover images out of the library once the audio carries its own.

Why
---
The library accumulated 471 stray images -- `folder.jpg`, `cover.jpg`, Windows
Media Player's `AlbumArt_{GUID}_Large.jpg` caches, scans, back covers, band
photos -- 32 MB of clutter that predates fooplayer.  Now that the embed pass
has written each album's chosen cover into the tracks' own tags, most of them
are redundant.

Which ones are safe
-------------------
fooplayer resolves a cover as: embedded tag -> sidecar choice -> a
folder/cover/front image beside the file -> placeholder.  So a loose image is
only redundant when the audio beside it carries its own cover.  This script
strips an image ONLY when EVERY audio file in its directory has an embedded
picture.  One bare track in the folder and the whole folder is left alone.

A sidecar copy is deliberately NOT accepted as sufficient.  The sidecar is
keyed by artist|album and the harvest adopts one image per key, so in a VA
compilation folder holding twenty-odd different artists a single adopted
entry would leave the other twenty relying on the very file being deleted.

Safety
------
* --dry-run is the default; nothing moves without --apply.
* Images are MOVED into a dated backup that mirrors the library's folder
  structure, never deleted, so the whole operation can be undone by copying
  the tree back.
* Audio files are never opened for writing, so no date and no content ID can
  be affected.

Usage:
  python strip_loose_art.py                 # dry run
  python strip_loose_art.py --apply
"""

import argparse
import json
import os
import shutil
import struct
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
BACKUP_ROOT = r"L:\BACKUPS\fooplayer-file-fixes\stripped-loose-art"

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"}
AUDIO_EXT = {".mp3", ".flac"}


def syncsafe(b):
    return (b[0] & 0x7F) << 21 | (b[1] & 0x7F) << 14 | (b[2] & 0x7F) << 7 | (b[3] & 0x7F)


def mp3_has_apic(fh):
    """Walks the whole leading tag chain -- this library stacks v2.3 + v2.4."""
    while True:
        head = fh.read(10)
        if len(head) < 10 or head[:3] != b"ID3":
            return False
        size = syncsafe(head[6:10])
        body = fh.read(size)
        if len(body) < size:
            return False
        if b"APIC" in body or (head[3] == 2 and b"PIC" in body):
            return True
        if head[5] & 0x10:
            fh.read(10)


def flac_has_picture(fh):
    if fh.read(4) != b"fLaC":
        return False
    while True:
        head = fh.read(4)
        if len(head) < 4:
            return False
        last = head[0] & 0x80
        if head[0] & 0x7F == 6:
            return True
        fh.seek(struct.unpack(">I", b"\x00" + head[1:4])[0], os.SEEK_CUR)
        if last:
            return False


def has_embedded_art(path):
    ext = os.path.splitext(path)[1].lower()
    try:
        with open(path, "rb") as fh:
            return flac_has_picture(fh) if ext == ".flac" else mp3_has_apic(fh)
    except OSError:
        return False


def survey():
    """(strippable images, kept images) across every root."""
    strip, keep = [], []
    for root_name in ROOTS:
        root = os.path.join(LIBRARY, root_name)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            images = [f for f in filenames
                      if os.path.splitext(f)[1].lower() in IMAGE_EXT]
            if not images:
                continue
            audio = [f for f in filenames
                     if os.path.splitext(f)[1].lower() in AUDIO_EXT]
            # An art-only folder proves nothing about what depends on it.
            covered = bool(audio) and all(
                has_embedded_art(os.path.join(dirpath, a)) for a in audio)
            (strip if covered else keep).extend(
                os.path.join(dirpath, i) for i in images)
    return strip, keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="actually move the files; omit for a dry run")
    args = ap.parse_args()

    strip, keep = survey()
    mb = sum(os.path.getsize(p) for p in strip) / 1048576

    print(f"images that can go : {len(strip)}  ({mb:.1f} MB)")
    print(f"images kept        : {len(keep)}  (audio beside them has no cover)")

    if not args.apply:
        print("\nDRY RUN -- nothing moved. Sample:\n")
        for p in strip[:15]:
            print("   " + os.path.relpath(p, LIBRARY))
        if len(strip) > 15:
            print(f"   ... and {len(strip) - 15} more")
        print("\nRe-run with --apply to move them.")
        return 0

    dest_root = os.path.join(BACKUP_ROOT, time.strftime("%Y-%m-%d--%H%M"))
    moved, failed = 0, []
    for p in strip:
        rel = os.path.relpath(p, LIBRARY)
        dest = os.path.join(dest_root, rel)
        try:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.move(p, dest)
            moved += 1
        except OSError as e:
            failed.append((p, str(e)))

    print(f"\nmoved   : {moved}")
    print(f"failed  : {len(failed)}")
    print(f"backup  : {dest_root}")
    for p, why in failed[:10]:
        print(f"   FAILED {why}: {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
