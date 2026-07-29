#!/usr/bin/env python3
"""Convert .m4a/.flac tracks to .mp3 without losing their date-added.

Why this exists
---------------
fooplayer embeds cover art as an ID3v2 APIC frame, which only MP3 carries.
The .m4a files have a second problem: the content ID hashes a .m4a file
WHOLE (the core only knows how to skip tag blocks in .mp3 and .flac), so
embedding anything into one changes its identity and silently resets its
date-added.  Converting sidesteps both.

The catch this script exists to handle: converting re-encodes the audio, so
the content ID necessarily changes.  That would make the track look like a
brand-new file -- today's date, playlists pointing at nothing.  So every
conversion is paired with a manifest migration: the new ID inherits the OLD
entry's date_added, the path is updated, and playlist references are
rewritten.

Dates: the new file is stamped with the original's mtime/atime.  On this NAS
share Samba reports creation time as equal to modified time (measured
2026-07-27), so restoring mtime restores what Explorer shows for both.

Safety
------
* --dry-run (default) writes nothing; it prints exactly what would happen.
* Originals are moved to a backup directory, never deleted outright.
* A conversion whose duration disagrees with the source by more than 1s is
  abandoned and that file is left completely alone.
* The manifest is only touched after its file's conversion has been verified,
  and is written tmp-then-rename with a .bak, matching the app's own
  discipline.

Files whose extension lies
--------------------------
`--files` converts named paths regardless of extension, for the case the
extension scan cannot see: a file called `.mp3` that is really an MP4.  There
is one in this library -- `MrSuicideSheep - Best of 2025.mp3`, 3h41m of AAC in
a mov/mp4 container -- and it is the file that would not play, the one the
embedder's `notMpeg` guard exists to refuse.  Since source and destination
name collide there, the encode goes to a temp file and is renamed into place
only after it has been verified.

Usage:
  python convert_to_mp3.py --roots <root> [<root> ...] [--apply] [--quality 0]
  python convert_to_mp3.py --root <root> --files <path> [...] [--apply]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

# FLAC is NOT converted by default: the content ID already skips FLAC
# metadata blocks, so a PICTURE block embeds with no identity change and no
# lossless->lossy re-encode. Only .m4a genuinely needs converting, because the
# core hashes an .m4a file whole.
DEFAULT_FORMATS = [".m4a"]
BACKUP_ROOT = r"L:\BACKUPS\fooplayer-file-fixes\pre-mp3-conversion"


def probe_duration(path):
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


def content_id(paths, repo_core):
    """Content IDs from the core's OWN hashing -- never a reimplementation.

    This used to invoke `tool_cid.dart`, which is not in the repository and
    may never have been: every call returned nothing, so the conversion of a
    file whose extension lies failed at the last step with "could not compute
    new content ID".  `core/bin/content_id.dart` is the committed equivalent.
    """
    if not paths:
        return {}
    r = subprocess.run(
        ["dart", "run", "bin/content_id.dart", *paths],
        cwd=repo_core, capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.strip().split("  ", 1)
        if len(parts) == 2 and len(parts[0]) == 64:
            out[parts[1]] = parts[0]
    if not out:
        # Say why, rather than leaving the caller to report a bare failure.
        print(f"        content_id: dart exited {r.returncode}: "
              f"{(r.stderr or r.stdout).strip()[:200]}")
    return out


def load_manifest(root):
    p = os.path.join(root, ".library.json")
    with open(p, encoding="utf-8") as f:
        return json.load(f), p


def save_manifest(data, path):
    tmp, bak = path + ".tmp", path + ".bak"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    if os.path.exists(bak):
        os.remove(bak)
    shutil.copy2(path, bak)
    os.replace(tmp, path)


def convert(src, dst, quality):
    return subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", src,
         "-map_metadata", "0", "-id3v2_version", "3",
         "-codec:a", "libmp3lame", "-q:a", str(quality), dst],
        capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roots", nargs="+", required=True)
    ap.add_argument("--apply", action="store_true",
                    help="actually convert; omit for a dry run")
    ap.add_argument("--quality", default="2",
                    help="LAME VBR quality; 2 (~190 kbps) gives a ~135 kbps "
                         "AAC source headroom without inflating it like 0 does")
    ap.add_argument("--core", default=r"L:\PROJECTS\fooplayer\core")
    ap.add_argument("--formats", nargs="+", default=DEFAULT_FORMATS,
                    help="extensions to convert (default: .m4a only -- FLAC "
                         "carries a cover natively and must not be re-encoded)")
    ap.add_argument("--files", nargs="+",
                    help="convert these exact paths whatever their extension "
                         "(for a file whose extension lies, e.g. an MP4 named "
                         ".mp3); requires --roots with the single owning root")
    args = ap.parse_args()

    total = converted = skipped = 0
    for root in args.roots:
        try:
            manifest, manifest_path = load_manifest(root)
        except Exception as e:
            print(f"!! {root}: cannot read manifest ({e}) -- skipped")
            continue
        tracks = manifest["tracks"]
        by_path = {}
        for cid, entry in tracks.items():
            for rel in entry.get("paths", []):
                by_path[rel.replace("/", "\\").lower()] = cid

        if args.files:
            targets = [f for f in args.files
                       if os.path.abspath(f).lower().startswith(
                           os.path.abspath(root).lower())]
        else:
            targets = []
            for dp, _, fs in os.walk(root):
                for fn in fs:
                    if os.path.splitext(fn)[1].lower() in set(args.formats):
                        targets.append(os.path.join(dp, fn))
        if not targets:
            continue

        print(f"\n=== {root}  ({len(targets)} file(s) to convert) ===")
        for src in sorted(targets):
            total += 1
            rel = os.path.relpath(src, root)
            dst = os.path.splitext(src)[0] + ".mp3"
            # A file whose extension already says .mp3 but whose contents are
            # not MPEG converts onto its own name. Encode beside it and rename
            # in only once the result is verified, so a failure leaves the
            # original exactly where it was.
            in_place = os.path.normcase(dst) == os.path.normcase(src)
            work = dst + ".converting.mp3" if in_place else dst
            old_cid = by_path.get(rel.lower())
            entry = tracks.get(old_cid) if old_cid else None
            date_added = entry.get("date_added") if entry else None

            if os.path.exists(dst) and not in_place:
                print(f"  SKIP  {rel}  (a .mp3 of the same name already exists)")
                skipped += 1
                continue
            if not entry:
                print(f"  SKIP  {rel}  (no manifest entry -- would lose its date)")
                skipped += 1
                continue

            st = os.stat(src)
            src_dur = probe_duration(src)
            if not args.apply:
                print(f"  PLAN  {rel}")
                print(f"        -> {os.path.basename(dst)}  keeps date_added "
                      f"{date_added}, mtime {time.strftime('%Y-%m-%d', time.localtime(st.st_mtime))}")
                continue

            t0 = time.time()
            r = convert(src, work, args.quality)
            if r.returncode != 0 or not os.path.exists(work):
                print(f"  FAIL  {rel}: ffmpeg: {r.stderr.strip()[:160]}")
                if os.path.exists(work):
                    os.remove(work)
                skipped += 1
                continue

            dst_dur = probe_duration(work)
            if src_dur and dst_dur and abs(src_dur - dst_dur) > 1.0:
                print(f"  FAIL  {rel}: duration drift {src_dur:.1f} -> {dst_dur:.1f}"
                      f" -- output discarded, original untouched")
                os.remove(work)
                skipped += 1
                continue

            if in_place:
                # Original out of the way first, so the rename can never
                # land on top of the only copy of the source.
                os.makedirs(BACKUP_ROOT, exist_ok=True)
                shutil.move(src, os.path.join(BACKUP_ROOT,
                                              os.path.basename(src)))
                os.replace(work, dst)

            os.utime(dst, (st.st_atime, st.st_mtime))

            new_cid = content_id([dst], args.core).get(os.path.basename(dst))
            if not new_cid:
                print(f"  FAIL  {rel}: could not compute new content ID")
                if in_place:
                    # The original is already in the backup; put it back
                    # rather than leaving the library short a file.
                    os.remove(dst)
                    shutil.move(os.path.join(BACKUP_ROOT,
                                             os.path.basename(src)), src)
                    print("        original restored")
                else:
                    os.remove(dst)
                skipped += 1
                continue

            # Manifest migration: the new ID inherits the old entry's date.
            new_rel = os.path.relpath(dst, root).replace("\\", "/")
            tracks.pop(old_cid, None)
            tracks[new_cid] = {"date_added": date_added, "paths": [new_rel]}
            for pl in manifest.get("playlists", []):
                pl["track_ids"] = [new_cid if t == old_cid else t
                                   for t in pl.get("track_ids", [])]

            if not in_place:  # the in-place path banked the original already
                os.makedirs(BACKUP_ROOT, exist_ok=True)
                shutil.move(src, os.path.join(BACKUP_ROOT,
                                              os.path.basename(src)))

            converted += 1
            print(f"  OK    {rel} -> {os.path.basename(dst)}  "
                  f"{st.st_size/1e6:.1f}MB -> {os.path.getsize(dst)/1e6:.1f}MB  "
                  f"{time.time()-t0:.1f}s  date_added kept ({date_added})")

        if args.apply:
            save_manifest(manifest, manifest_path)
            print(f"  manifest updated: {manifest_path}")

    print(f"\n{total} candidate(s); {converted} converted, {skipped} skipped"
          f"{'' if args.apply else '  (DRY RUN -- nothing written)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
