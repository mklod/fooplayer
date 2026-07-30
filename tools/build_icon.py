#!/usr/bin/env python3
"""Generates every fooplayer icon asset from one SVG.

The icon used to be a 96x96 PNG, and every asset -- five launcher densities,
five splash densities, the Windows .ico -- was upscaled from it. The Android 12
splash draws its icon at 288dp, so the system was enlarging a 76px note by
nearly 4x. That is why the splash looked soft, and resampling cannot fix it.

The source is now app/assets/icon/fooplayer_icon.svg. Edit THAT (or replace it
outright) and re-run this; nothing here knows anything about the shape of the
note. An earlier version of this script reconstructed the geometry by measuring
the old bitmap, which was a mistake twice over: it hard-coded a drawing in
Python, and it drew the note as separate overlapping shapes, so every place a
stem met the beam or a head got a rounded notch instead of a sharp junction.
Mike supplied a proper single-outline SVG and that problem went away.

What this script actually owns is PLACEMENT, which differs per asset and is
easy to get wrong:

  - the adaptive icon must leave the launcher's safe zone clear, so the note
    fills only ~41% of its 108dp canvas and no mask can ever clip it;
  - the splash slot has a further inset applied by the system on top;
  - the legacy launcher bitmap and the Windows .ico have no safe zone at all,
    so there the note fills nearly the whole tile, as it always did.

Every fill fraction below was measured off the asset being replaced, so
swapping in the vector changes sharpness and not size. Getting one wrong is
invisible in a test and obvious on a taskbar.

Usage:
    python tools/build_icon.py
    python tools/build_icon.py --source path/to/other.svg

Last modified: 2026-07-29--2215
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
RES = APP / "android" / "app" / "src" / "main" / "res"
SOURCE = APP / "assets" / "icon" / "fooplayer_icon.svg"

# Android adaptive icons are authored on a 108dp canvas whose middle 72dp is
# the only part guaranteed to survive the launcher's mask.
ADAPTIVE_CANVAS = 108.0

# How much of each canvas the note fills, measured off what it replaces.
ADAPTIVE_FILL = 0.41  # old foreground: 176px of a 432px canvas
SPLASH_FILL = 0.62  # old splash PNGs: 119px of a 192dp canvas
LEGACY_FILL = 0.92  # old mipmap-*/ic_launcher.png: 44px of a 48px tile
ICO_FILL = 0.81  # old app_icon.ico: 26px of its single 32px frame

CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


# ---------------------------------------------------------------------------
# Reading the source
# ---------------------------------------------------------------------------
def parse_svg(text: str) -> tuple[float, list[tuple[str, str]]]:
    """(viewBox side, [(fill, pathData), ...]) from a plain SVG.

    Deliberately strict rather than a real SVG parser. This has one job -- feed
    an Android VectorDrawable -- and VectorDrawable supports a subset of SVG:
    no strokes, no transforms, no gradients-with-stops, no <image>, no filters.
    A source using any of those must be flattened before it gets here, so the
    checks below refuse it loudly instead of silently dropping the effect and
    shipping a wrong icon.
    """
    m = re.search(r'viewBox\s*=\s*"([^"]+)"', text)
    if not m:
        raise SystemExit("source SVG has no viewBox")
    parts = [float(v) for v in m.group(1).replace(",", " ").split()]
    if len(parts) != 4 or parts[0] or parts[1]:
        raise SystemExit(f"expected a viewBox starting at 0 0, got {m.group(1)!r}")
    if abs(parts[2] - parts[3]) > 1e-6:
        raise SystemExit(f"expected a square viewBox, got {parts[2]}x{parts[3]}")

    body = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    for banned in ("<image", "<filter", "<mask", "clip-path", "<use", "transform="):
        if banned in body:
            raise SystemExit(
                f"source SVG contains {banned!r}, which an Android "
                "VectorDrawable cannot represent -- flatten it first"
            )
    if "<linearGradient" in body or "<radialGradient" in body:
        raise SystemExit(
            "source SVG uses a gradient; VectorDrawable needs it expressed as "
            "android:fillColor stops, so flatten it or extend this script"
        )

    paths: list[tuple[str, str]] = []
    for tag in re.findall(r"<path\b[^>]*/?>", body):
        d = re.search(r'\bd\s*=\s*"([^"]+)"', tag)
        if not d:
            continue
        fill = re.search(r'\bfill\s*=\s*"([^"]+)"', tag)
        if not fill:
            raise SystemExit(f"a <path> has no explicit fill: {tag[:80]}")
        if fill.group(1).strip().lower() in ("none", "transparent"):
            continue
        if "stroke" in tag:
            raise SystemExit("a <path> is stroked; VectorDrawable fills only")
        paths.append((fill.group(1).strip(), d.group(1).strip()))
    if not paths:
        raise SystemExit("source SVG has no filled <path> elements")
    return parts[2], paths


_TOKEN = re.compile(r"([MLAZmlaz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")


def transform_path(d: str, scale: float, tx: float, ty: float) -> str:
    """Bakes a uniform scale + translate into path data.

    Baked rather than carried as a VectorDrawable <group> transform on purpose:
    a group applies scale, then rotation, then translation, and getting that
    order backwards is a mistake that only shows up on a device. Numbers in the
    path leave nothing to reason about.

    Handles the absolute M/L/A/Z the source uses, and refuses anything else
    rather than guessing -- a relative command or a curve would need different
    handling and silently mishandling one would ship a mangled icon.
    """
    out: list[str] = []
    cmd: str | None = None
    nums: list[float] = []

    def flush() -> None:
        if cmd is None:
            return
        if cmd == "Z":
            out.append("Z")
        elif cmd in ("M", "L"):
            for i in range(0, len(nums), 2):
                x = nums[i] * scale + tx
                y = nums[i + 1] * scale + ty
                out.append(f"{cmd if i == 0 else 'L'}{x:.4f},{y:.4f}")
        elif cmd == "A":
            for i in range(0, len(nums), 7):
                rx, ry, rot, large, sweep, x, y = nums[i : i + 7]
                out.append(
                    f"A{rx * scale:.4f},{ry * scale:.4f} {rot:g} "
                    f"{int(large)} {int(sweep)} "
                    f"{x * scale + tx:.4f},{y * scale + ty:.4f}"
                )
        nums.clear()

    for letter, number in _TOKEN.findall(d):
        if letter:
            if letter.islower():
                raise SystemExit(
                    f"path uses the relative command {letter!r}; this script "
                    "only transforms absolute M/L/A/Z"
                )
            flush()
            cmd = letter
        else:
            nums.append(float(number))
    flush()
    if any(c in d for c in "CcSsQqTtHhVv"):
        raise SystemExit("path uses curve or H/V commands; extend transform_path")
    return "".join(out)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def render_png(svg_text: str, px: int, out: Path) -> None:
    """Rasterises via headless Chrome -- the renderer this project already
    relies on, and the only one installed here.

    An isolated --user-data-dir is REQUIRED: without it chrome.exe hands its
    arguments to an already-running instance and exits having done nothing.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        html = tmp / "icon.html"
        html.write_text(
            "<!doctype html><html><head><style>"
            "html,body{margin:0;padding:0;background:transparent;}"
            "svg{display:block;width:%dpx;height:%dpx;}"
            "</style></head><body>%s</body></html>" % (px, px, svg_text),
            encoding="utf-8",
        )
        subprocess.run(
            [
                str(CHROME),
                "--headless",
                "--disable-gpu",
                "--hide-scrollbars",
                "--default-background-color=00000000",
                "--user-data-dir=%s" % (tmp / "profile"),
                "--window-size=%d,%d" % (px, px),
                "--screenshot=%s" % (tmp / "shot.png"),
                str(html),
            ],
            check=True,
            capture_output=True,
        )
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes((tmp / "shot.png").read_bytes())


def measure_bbox(svg_text: str, side: float) -> tuple[float, float, float, float]:
    """The note's bounding box in source units, measured by rendering.

    Measured rather than derived: the source is arbitrary path data including
    arcs, and its bounding box is not something to compute by hand when a
    rasteriser will answer exactly.
    """
    from PIL import Image

    probe = 512
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "probe.png"
        render_png(svg_text, probe, p)
        im = Image.open(p).convert("RGBA")
        px = im.load()
        xs, ys = [], []
        for y in range(probe):
            for x in range(probe):
                if px[x, y][3] > 128:
                    xs.append(x)
                    ys.append(y)
    if not xs:
        raise SystemExit("nothing visible in the source SVG")
    k = side / probe
    return (min(xs) * k, min(ys) * k, (max(xs) + 1) * k, (max(ys) + 1) * k)


def placed(paths, bbox, canvas: float, fill: float):
    """[(fill, pathData)] with the note scaled to `fill` of `canvas`, centred."""
    x0, y0, x1, y1 = bbox
    scale = (canvas * fill) / max(x1 - x0, y1 - y0)
    tx = canvas / 2 - (x0 + x1) / 2 * scale
    ty = canvas / 2 - (y0 + y1) / 2 * scale
    return [(f, transform_path(d, scale, tx, ty)) for f, d in paths]


def svg_of(paths, canvas: float, px: float) -> str:
    body = "\n".join('  <path fill="%s" d="%s"/>' % (f, d) for f, d in paths)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %g %g" '
        'width="%g" height="%g">\n%s\n</svg>\n' % (canvas, canvas, px, px, body)
    )


def vector_drawable(paths, canvas: float, size_dp: float, header: str,
                    tint: str | None = None) -> str:
    body = "\n".join(
        '    <path\n        android:fillColor="%s"\n        android:pathData="%s" />'
        % (tint or f, d)
        for f, d in paths
    )
    # XML forbids a double hyphen inside a comment and aapt2 fails the build
    # over it, which is easy to trip since these headers are prose. An em dash
    # is the right punctuation there anyway.
    safe = header.strip().replace("--", "—")
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n<!--\n%s\n-->\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="%gdp"\n    android:height="%gdp"\n'
        '    android:viewportWidth="%g"\n    android:viewportHeight="%g">\n'
        "%s\n</vector>\n" % (safe, size_dp, size_dp, canvas, canvas, body)
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, default=SOURCE)
    args = ap.parse_args()

    text = args.source.read_text(encoding="utf-8")
    side, paths = parse_svg(text)
    bbox = measure_bbox(text, side)
    print(
        "source %s: %g unit canvas, %d path(s), note %.2fx%.2f"
        % (args.source, side, len(paths), bbox[2] - bbox[0], bbox[3] - bbox[1])
    )

    (RES / "drawable").mkdir(parents=True, exist_ok=True)
    adaptive = placed(paths, bbox, ADAPTIVE_CANVAS, ADAPTIVE_FILL)

    (RES / "drawable" / "ic_launcher_foreground.xml").write_text(
        vector_drawable(
            adaptive,
            ADAPTIVE_CANVAS,
            ADAPTIVE_CANVAS,
            "The launcher icon's foreground layer.\n\n"
            "Generated by tools/build_icon.py from\n"
            "app/assets/icon/fooplayer_icon.svg. Edit the SVG, not this file.\n\n"
            "108dp canvas with the note inside the middle 72dp, the safe zone\n"
            "every launcher mask is guaranteed to keep.",
        ),
        encoding="utf-8",
    )
    (RES / "drawable" / "ic_launcher_monochrome.xml").write_text(
        vector_drawable(
            adaptive,
            ADAPTIVE_CANVAS,
            ADAPTIVE_CANVAS,
            "Silhouette for themed icons (Android 13+, and One UI's own icon\n"
            "theming). Those draw ONLY this layer, tinted, and ignore the other\n"
            "two: without it the launcher has no silhouette to tint and renders\n"
            "an empty circle.\n\n"
            "Flat white on purpose. The beam's darker underside would tint to a\n"
            "second shade of the theme colour and read as a seam.\n\n"
            "Generated by tools/build_icon.py.",
            tint="#FFFFFFFF",
        ),
        encoding="utf-8",
    )
    (RES / "drawable" / "splash_icon.xml").write_text(
        vector_drawable(
            placed(paths, bbox, ADAPTIVE_CANVAS, SPLASH_FILL),
            ADAPTIVE_CANVAS,
            288,
            "The Android 12+ splash icon.\n\n"
            "Was five PNG densities upscaled from 96px of source art, which is\n"
            "why the splash looked soft: the system draws this at 288dp and was\n"
            "enlarging a 76px note by nearly 4x. A vector has nothing to\n"
            "enlarge.\n\n"
            "The note fills the same 62% of the canvas the old PNGs did, so\n"
            "this changed sharpness and not size.\n\n"
            "Generated by tools/build_icon.py.",
        ),
        encoding="utf-8",
    )
    print("wrote drawable/{ic_launcher_foreground,ic_launcher_monochrome,splash_icon}.xml")

    from PIL import Image

    # Legacy launcher bitmaps, for pre-API-26 devices that know nothing about
    # adaptive icons: the note on the same white tile the background layer
    # paints, because those launchers do no masking of their own.
    tile_svg = svg_of(placed(paths, bbox, 48, LEGACY_FILL), 48, 48)
    for dens, mult in DENSITIES.items():
        px = int(round(48 * mult))
        with tempfile.TemporaryDirectory() as td:
            fg = Path(td) / "fg.png"
            render_png(tile_svg, px, fg)
            tile = Image.new("RGBA", (px, px), (255, 255, 255, 255))
            tile.alpha_composite(Image.open(fg).convert("RGBA"))
            out = RES / ("mipmap-%s" % dens) / "ic_launcher.png"
            out.parent.mkdir(parents=True, exist_ok=True)
            tile.save(out)
    print("wrote mipmap-*/ic_launcher.png (legacy, pre-API-26)")

    ico_svg = svg_of(placed(paths, bbox, 256, ICO_FILL), 256, 256)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    with tempfile.TemporaryDirectory() as td:
        frames = []
        for s in sizes:
            p = Path(td) / ("%d.png" % s)
            # Rendered at each size from the vector rather than resampled down
            # from one big raster, so the 16px frame gets its own clean
            # rasterisation instead of a blurred reduction.
            render_png(ico_svg, s, p)
            frames.append(Image.open(p).convert("RGBA"))
        out = APP / "windows" / "runner" / "resources" / "app_icon.ico"
        out.parent.mkdir(parents=True, exist_ok=True)
        frames[-1].save(out, format="ICO", sizes=[(s, s) for s in sizes])
    print("wrote windows/runner/resources/app_icon.ico (%d frames)" % len(sizes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
