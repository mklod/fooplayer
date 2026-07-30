#!/usr/bin/env python3
"""Generates every fooplayer icon asset from one vector definition.

The icon used to be a 96x96 PNG with the note occupying 72x76 pixels, and
every asset -- five launcher densities, five splash densities, the Windows
.ico -- was upscaled from that. The Android 12 splash draws its icon at
288dp, so it was enlarging 76px of art by nearly 4x. That is what made the
splash look soft and aliased, and no amount of resampling fixes it.

So the note is geometry now, not pixels. This script is the single source: it
emits the SVG, the Android VectorDrawables (sharp at any density the system
asks for, the splash included), and the raster fallbacks that still have to
exist -- legacy pre-API-26 launcher bitmaps and the Windows .ico.

It reproduces the original artwork rather than reinterpreting it. Every number
under "Geometry" was measured off the old 432px bitmap; `--verify` renders the
result and reports how much of it agrees. Do not expect 1.0: the old art was
itself an upscale of 96px source, so its edges are soft by about a pixel and
fitting past ~0.96 would be fitting to blur.

Usage:
    python tools/build_icon.py              # write every asset
    python tools/build_icon.py --verify     # also report agreement with the old art
    python tools/build_icon.py --svg-only   # just the SVG, for eyeballing

Last modified: 2026-07-29--1930
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
RES = APP / "android" / "app" / "src" / "main" / "res"

PINK = "#ED3675"  # the note
SHADE = "#CC1B4E"  # the beam's underside

# ---------------------------------------------------------------------------
# Geometry, in the 108x108 space Android adaptive icons use -- so these are dp
# and the launcher-safe zone is the middle 72. Measured off the old 432px
# foreground bitmap and divided by four:
#
#   left head   centre (156, 279) r 28.5   -> (39.00, 69.75) r 7.12
#   right head  centre (274, 270) r 28.5   -> (68.50, 67.50) r 7.12
#   left stem   x 167..184                 -> x 41.75..46.00  (w 4.25)
#   right stem  x 286..303                 -> x 71.37..75.62  (w 4.25)
#   beam top    (278,126)..(171,150)       -> slope -0.2243, i.e. 12.64 deg
#   beam depth  47 total, 25 of it lit     -> 11.75 total, 6.25 lit
#   shade spans x 186..290                 -> between the stems only
# ---------------------------------------------------------------------------
CANVAS = 108.0
HEAD_R = 7.12
LEFT_HEAD = (39.0, 69.75)
RIGHT_HEAD = (68.5, 67.5)
STEM_W = 4.25
# Each stem's RIGHT edge is tangent to its head's right edge, which is what
# makes the note read as a note rather than a lollipop on a stick.
LEFT_STEM_RIGHT = LEFT_HEAD[0] + HEAD_R
RIGHT_STEM_RIGHT = RIGHT_HEAD[0] + HEAD_R
BEAM_SLOPE = -0.2243
BEAM_THICK = 11.75  # vertical: top of the lit face to the bottom of the shade
BEAM_LIGHT = 6.25  # vertical: the lit top face alone
CORNER_R = 2.2
BEAM_ANCHOR = (69.5, 31.5)  # a measured point on the beam's top edge

# How much of each canvas the note fills. All three were measured off the assets
# being replaced, so this redraw changes sharpness and not size -- which matters
# because the three canvases are NOT the same shape of problem:
#
#   the adaptive icon must leave the launcher's safe zone clear, so the note
#   fills only ~43% of its 108dp canvas and the mask never clips it;
#   the splash slot has its own inset applied by the system on top;
#   the legacy launcher bitmap and the Windows .ico have no safe zone at all,
#   so there the note fills nearly the whole tile, as it always did.
#
# Getting this wrong is invisible in a test and obvious on a taskbar: rendering
# the .ico from the 108dp canvas made the note 43% of the tile against the 81%
# it had been, i.e. visibly shrunken.
SPLASH_FILL = 0.62  # old PNGs: 192dp canvas, 119dp note
LEGACY_FILL = 0.92  # old mipmap-*/ic_launcher.png: 48px tile, 44px note
ICO_FILL = 0.81  # old app_icon.ico: 32px frame, 26px note


def beam_top_y(x: float) -> float:
    return BEAM_ANCHOR[1] + BEAM_SLOPE * (x - BEAM_ANCHOR[0])


def fmt(v: float) -> str:
    """Trims float noise out of path data. Two decimals is far under a device
    pixel at every density, and keeps the XML readable."""
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def rect_path(x: float, y: float, w: float, h: float) -> str:
    """A plain rectangle -- the stems, whose ends are both hidden: the top by
    the beam, the bottom inside the note head. Nothing to round."""
    return (
        f"M{fmt(x)},{fmt(y)}L{fmt(x + w)},{fmt(y)}"
        f"L{fmt(x + w)},{fmt(y + h)}L{fmt(x)},{fmt(y + h)}Z"
    )


def circle_path(cx: float, cy: float, r: float) -> str:
    """A circle as two arcs. VectorDrawable has no <circle>."""
    return (
        f"M{fmt(cx - r)},{fmt(cy)}"
        f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(cx + r)},{fmt(cy)}"
        f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(cx - r)},{fmt(cy)}Z"
    )


def rounded_poly_path(pts, radii) -> str:
    """A polygon with per-vertex corner radii, as absolute path data.

    Needed because the beam is a PARALLELOGRAM, not a rotated rectangle: its
    top and bottom edges follow the slant while both ends stay vertical, flush
    with the outer edge of each stem (measured -- column 303 of the old art is
    a straight vertical run). A rotated rounded-rect splays those ends out past
    the stems instead.

    Corners are set back by r/tan(a/2) along each edge, the distance that makes
    an arc of radius r actually tangent to both. A fixed setback would leave
    visible kinks at the two non-right angles.
    """
    n = len(pts)
    out: list[str] = []
    started = False
    for i in range(n):
        v = pts[i]
        prv = pts[(i - 1) % n]
        nxt = pts[(i + 1) % n]
        a = (prv[0] - v[0], prv[1] - v[1])
        b = (nxt[0] - v[0], nxt[1] - v[1])
        la = math.hypot(*a) or 1.0
        lb = math.hypot(*b) or 1.0
        ua = (a[0] / la, a[1] / la)
        ub = (b[0] / lb, b[1] / lb)
        r = radii[i]
        if r <= 0:
            p0 = p1 = v
        else:
            ang = math.acos(max(-1.0, min(1.0, ua[0] * ub[0] + ua[1] * ub[1])))
            t = min(r / math.tan(ang / 2), la / 2, lb / 2)
            p0 = (v[0] + ua[0] * t, v[1] + ua[1] * t)
            p1 = (v[0] + ub[0] * t, v[1] + ub[1] * t)
        out.append(("M" if not started else "L") + f"{fmt(p0[0])},{fmt(p0[1])}")
        started = True
        if r > 0 and p0 != p1:
            cross = ua[0] * ub[1] - ua[1] * ub[0]
            sweep = 0 if cross > 0 else 1
            out.append(f"A{fmt(r)},{fmt(r)} 0 0 {sweep} {fmt(p1[0])},{fmt(p1[1])}")
    out.append("Z")
    return "".join(out)


def build_paths() -> list[tuple[str, str]]:
    """(fill, pathData) for the whole note, painted back to front."""
    left_x = LEFT_STEM_RIGHT - STEM_W
    right_x = RIGHT_STEM_RIGHT - STEM_W

    # The beam spans the stems' outer edges, so both stems are rooted in it.
    bx0, bx1 = left_x, RIGHT_STEM_RIGHT
    t0, t1 = beam_top_y(bx0), beam_top_y(bx1)
    beam = rounded_poly_path(
        [(bx0, t0), (bx1, t1), (bx1, t1 + BEAM_THICK), (bx0, t0 + BEAM_THICK)],
        [CORNER_R] * 4,
    )

    # The shaded underside, drawn ONLY BETWEEN THE STEMS -- the old art's dark
    # pixels span x 186..290, exactly the left stem's right edge to the right
    # stem's left edge. That is the whole depth cue: both stems stay light and
    # read as columns standing in front of the beam's shadowed underside.
    # Running the shade the full width of the beam loses it and the note goes
    # flat (measured: shaded-face agreement 0.71 that way, 0.93 this way).
    #
    # Square corners: every side is hidden, the top by the lit face and both
    # ends by the stems.
    sx0, sx1 = LEFT_STEM_RIGHT, right_x
    shade = rounded_poly_path(
        [
            (sx0, beam_top_y(sx0) + BEAM_LIGHT),
            (sx1, beam_top_y(sx1) + BEAM_LIGHT),
            (sx1, beam_top_y(sx1) + BEAM_THICK),
            (sx0, beam_top_y(sx0) + BEAM_THICK),
        ],
        [0, 0, 0, 0],
    )

    return [
        (PINK, rect_path(left_x, t0, STEM_W, LEFT_HEAD[1] - t0)),
        (
            PINK,
            rect_path(
                right_x,
                beam_top_y(right_x),
                STEM_W,
                RIGHT_HEAD[1] - beam_top_y(right_x),
            ),
        ),
        (PINK, circle_path(LEFT_HEAD[0], LEFT_HEAD[1], HEAD_R)),
        (PINK, circle_path(RIGHT_HEAD[0], RIGHT_HEAD[1], HEAD_R)),
        (PINK, beam),
        (SHADE, shade),
    ]


def note_bbox() -> tuple[float, float, float, float]:
    """(min_x, min_y, max_x, max_y) of the note, in the 108 space.

    The beam's highest point is its right end; the left head hangs lowest.
    """
    return (
        LEFT_HEAD[0] - HEAD_R,
        beam_top_y(RIGHT_STEM_RIGHT),
        RIGHT_STEM_RIGHT,
        LEFT_HEAD[1] + HEAD_R,
    )


def svg(paths, size: float = CANVAS, fill: float | None = None) -> str:
    """The note as an SVG.

    [fill] crops the viewBox around the note so it occupies that fraction of
    the canvas, for the assets with no launcher safe zone to respect. Omit it
    to keep the full 108dp adaptive-icon canvas.
    """
    body = "\n".join('  <path fill="%s" d="%s"/>' % (f, d) for f, d in paths)
    if fill is None:
        vx, vy, vw = 0.0, 0.0, size
    else:
        x0, y0, x1, y1 = note_bbox()
        vw = max(x1 - x0, y1 - y0) / fill
        vx = (x0 + x1) / 2 - vw / 2
        vy = (y0 + y1) / 2 - vw / 2
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s %s %s %s" '
        'width="%s" height="%s">\n%s\n</svg>\n'
        % (fmt(vx), fmt(vy), fmt(vw), fmt(vw), fmt(size), fmt(size), body)
    )


def vector_drawable(
    paths,
    viewport: float = CANVAS,
    size_dp: float = CANVAS,
    tint: str | None = None,
    header: str = "",
    translate: tuple[float, float] = (0.0, 0.0),
) -> str:
    shifted = bool(translate[0] or translate[1])
    ind = "        " if shifted else "    "
    body = "\n".join(
        '%s<path\n%s    android:fillColor="%s"\n%s    android:pathData="%s" />'
        % (ind, ind, tint or f, ind, d)
        for f, d in paths
    )
    if shifted:
        body = (
            '    <group\n        android:translateX="%s"\n'
            '        android:translateY="%s">\n%s\n    </group>'
            % (fmt(translate[0]), fmt(translate[1]), body)
        )
    # XML forbids a double hyphen inside a comment and aapt2 fails the build
    # over it, which is easy to trip since these headers are prose. An em dash
    # is the right punctuation there anyway, so substitute it here and no
    # caller has to remember.
    safe = header.strip().replace("--", "—")
    comment = "<!--\n" + safe + "\n-->\n" if header else ""
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        + comment
        + '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="%sdp"\n'
        '    android:height="%sdp"\n'
        '    android:viewportWidth="%s"\n'
        '    android:viewportHeight="%s">\n'
        "%s\n"
        "</vector>\n"
        % (fmt(size_dp), fmt(size_dp), fmt(viewport), fmt(viewport), body)
    )


# ---------------------------------------------------------------------------
# Rasterising, for the two assets that cannot be vectors.
# ---------------------------------------------------------------------------
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")


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


DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def write_legacy_launcher(paths) -> None:
    """The pre-API-26 launcher bitmap: the note on the same white tile the
    adaptive icon's background layer paints, because old launchers do no
    masking of their own."""
    from PIL import Image

    tile_svg = svg(paths, fill=LEGACY_FILL)
    for dens, scale in DENSITIES.items():
        px = int(round(48 * scale))
        with tempfile.TemporaryDirectory() as td:
            fg = Path(td) / "fg.png"
            render_png(tile_svg, px, fg)
            note = Image.open(fg).convert("RGBA")
            tile = Image.new("RGBA", (px, px), (255, 255, 255, 255))
            tile.alpha_composite(note)
            out = RES / ("mipmap-%s" % dens) / "ic_launcher.png"
            out.parent.mkdir(parents=True, exist_ok=True)
            tile.save(out)


def write_ico(paths, out: Path) -> None:
    from PIL import Image

    frame_svg = svg(paths, fill=ICO_FILL)

    sizes = [16, 24, 32, 48, 64, 128, 256]
    with tempfile.TemporaryDirectory() as td:
        frames = []
        for s in sizes:
            p = Path(td) / ("%d.png" % s)
            # Rendered at each size from the vector rather than resampled down
            # from one big raster, so the 16px frame gets its own clean
            # rasterisation instead of a blurred reduction.
            render_png(frame_svg, s, p)
            frames.append(Image.open(p).convert("RGBA"))
        out.parent.mkdir(parents=True, exist_ok=True)
        frames[-1].save(out, format="ICO", sizes=[(s, s) for s in sizes])


def verify(fg_png: Path) -> None:
    """Reports how closely the vector matches the old bitmap.

    A redraw may differ; it may not become a different icon. So this is
    measured rather than left to memory.
    """
    from PIL import Image

    old = RES / "mipmap-xxxhdpi" / "ic_launcher_foreground.png"
    if not old.exists():
        print("verify: the original bitmap is gone, nothing to compare against")
        return
    a = Image.open(old).convert("RGBA")
    b = Image.open(fg_png).convert("RGBA").resize(a.size, Image.LANCZOS)

    def masks(im):
        p = im.load()
        w, h = im.size
        solid, dark = set(), set()
        for y in range(h):
            for x in range(w):
                r, g, _, al = p[x, y]
                if al > 128:
                    solid.add((x, y))
                if al > 200 and r < 225 and g < 45:
                    dark.add((x, y))
        return solid, dark

    sa, da = masks(a)
    sb, db = masks(b)
    print("verify: silhouette agreement %.4f" % (len(sa & sb) / len(sa | sb)))
    print("verify: shaded-face agreement %.4f" % (len(da & db) / len(da | db)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--svg-only", action="store_true")
    args = ap.parse_args()

    paths = build_paths()
    icon_svg = svg(paths)

    svg_dir = APP / "assets" / "icon"
    svg_dir.mkdir(parents=True, exist_ok=True)
    (svg_dir / "fooplayer_icon.svg").write_text(icon_svg, encoding="utf-8")
    print("wrote app/assets/icon/fooplayer_icon.svg")
    if args.svg_only:
        return 0

    (RES / "drawable").mkdir(parents=True, exist_ok=True)

    (RES / "drawable" / "ic_launcher_foreground.xml").write_text(
        vector_drawable(
            paths,
            header=(
                "The note, as geometry. Generated by tools/build_icon.py --\n"
                "change the measurements in that script and re-run it rather\n"
                "than editing this file.\n\n"
                "108dp viewport with the note inside the middle 72dp, the\n"
                "adaptive-icon safe zone every launcher mask keeps."
            ),
        ),
        encoding="utf-8",
    )
    (RES / "drawable" / "ic_launcher_monochrome.xml").write_text(
        vector_drawable(
            paths,
            tint="#FFFFFFFF",
            header=(
                "Silhouette for themed icons (Android 13+, and One UI's own\n"
                "icon theming). Those draw ONLY this layer, tinted, and ignore\n"
                "the other two -- without it the launcher has no silhouette to\n"
                "tint and renders an empty circle.\n\n"
                "Flat white on purpose: the beam's darker underside would tint\n"
                "to a second shade of the theme colour and read as a seam.\n\n"
                "Generated by tools/build_icon.py."
            ),
        ),
        encoding="utf-8",
    )

    # The splash gets its own viewport, because the splash slot is not the
    # launcher slot.
    x0, y0, x1, y1 = note_bbox()
    span = max(x1 - x0, y1 - y0)
    sp_vp = span / SPLASH_FILL
    (RES / "drawable" / "splash_icon.xml").write_text(
        vector_drawable(
            paths,
            viewport=sp_vp,
            size_dp=288,
            translate=(sp_vp / 2 - (x0 + x1) / 2, sp_vp / 2 - (y0 + y1) / 2),
            header=(
                "The Android 12+ splash icon.\n\n"
                "Was five PNG densities upscaled from 96px of source art,\n"
                "which is why the splash looked soft: the system draws this at\n"
                "288dp and was enlarging a 76px note by nearly 4x. A vector\n"
                "has nothing to enlarge.\n\n"
                "The viewport is sized so the note fills the same 62% of the\n"
                "canvas the old PNGs did, so this changes sharpness, not size.\n\n"
                "Generated by tools/build_icon.py."
            ),
        ),
        encoding="utf-8",
    )
    print(
        "wrote drawable/{ic_launcher_foreground,ic_launcher_monochrome,"
        "splash_icon}.xml"
    )

    write_legacy_launcher(paths)
    print("wrote mipmap-*/ic_launcher.png (legacy, pre-API-26)")

    write_ico(paths, APP / "windows" / "runner" / "resources" / "app_icon.ico")
    print("wrote windows/runner/resources/app_icon.ico")

    if args.verify:
        with tempfile.TemporaryDirectory() as td:
            fg = Path(td) / "fg.png"
            render_png(icon_svg, 432, fg)
            verify(fg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
