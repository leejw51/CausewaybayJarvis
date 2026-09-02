#!/usr/bin/env python3
"""Bake 80 unique agent sprites from the 20 painted bodies.

Each extra type gets its own palette and a silhouette kit (ears, wings,
scarf, jets...) so the tower is not twenty robots in different hats.
"""
from __future__ import annotations

import math
import os
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_fly import make_fly

ROOT = Path(__file__).resolve().parents[1] / "assets"
SIZE = 256

BASES = [
    "jarvis", "neon", "jade", "typhoon", "dragon", "ferry",
    "volt", "ghost", "razor", "nova", "nitro", "onyx", "echo",
    "pulse", "wraith", "mason", "blaze", "talon", "pivot", "glitch",
]

NAMES = [
    "ion", "fury", "venom", "cobra", "striker", "tally", "orbit", "quasar",
    "spark", "vector", "byte", "chrome", "vixen", "kairo", "ronin", "shadow",
    "storm", "frost", "pyro", "titan", "finale", "zero", "cipher", "pixel",
    "comet", "drift", "flare", "havoc", "jet", "knife", "lynx", "maverick",
    "radar", "pike", "quill", "rogue", "sable", "torch", "umbra", "vortex",
    "latch", "xenon", "masque", "zephyr", "bolt", "crash", "dusk", "ember",
    "fang", "grit", "hush", "iris", "jinx", "kestrel", "lumen", "mirage",
    "eclipse", "obsidian", "prism", "quake", "riot", "vox", "ultra", "sentry",
    "wolf", "xray", "axon", "nebula", "ash", "bravo", "clash", "dash",
    "edge", "flux", "gale", "hook", "ivy", "jolt", "kite", "loom",
]

KITS = [
    "bolts", "horns", "bunny", "wings", "scarf", "mohawk", "crown", "visor",
    "dish", "cape", "jets", "katana", "array", "fin", "fox", "plume",
    "goggles", "spikes", "orb", "blades",
]


def hsv(h: float, s: float, v: float) -> tuple[int, int, int]:
    i = int(h * 6)
    f = h * 6 - i
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    i %= 6
    if i == 0:
        r, g, b = v, t, p
    elif i == 1:
        r, g, b = q, v, p
    elif i == 2:
        r, g, b = p, v, t
    elif i == 3:
        r, g, b = p, q, v
    elif i == 4:
        r, g, b = t, p, v
    else:
        r, g, b = v, p, q
    return int(r * 255), int(g * 255), int(b * 255)


def palette(i: int) -> dict[str, tuple[int, int, int]]:
    specials = [
        dict(dark=(18, 22, 32), mid=(210, 214, 230), light=(245, 248, 255),
             glow=(90, 230, 255), core=(255, 170, 40), trim=(70, 200, 220)),
        dict(dark=(28, 8, 22), mid=(255, 40, 150), light=(255, 170, 220),
             glow=(80, 255, 230), core=(255, 230, 80), trim=(255, 80, 200)),
        dict(dark=(8, 28, 16), mid=(40, 200, 90), light=(180, 255, 200),
             glow=(255, 230, 70), core=(255, 120, 40), trim=(30, 160, 80)),
        dict(dark=(12, 16, 36), mid=(40, 90, 255), light=(170, 200, 255),
             glow=(255, 80, 180), core=(255, 200, 60), trim=(80, 140, 255)),
        dict(dark=(32, 10, 8), mid=(230, 50, 40), light=(255, 170, 140),
             glow=(255, 200, 40), core=(255, 90, 40), trim=(180, 30, 30)),
        dict(dark=(10, 12, 18), mid=(40, 48, 62), light=(200, 210, 230),
             glow=(180, 90, 255), core=(255, 60, 160), trim=(90, 100, 130)),
        dict(dark=(28, 18, 6), mid=(230, 170, 40), light=(255, 230, 140),
             glow=(255, 90, 40), core=(255, 60, 40), trim=(200, 140, 30)),
        dict(dark=(8, 24, 28), mid=(30, 200, 190), light=(170, 255, 240),
             glow=(255, 80, 200), core=(255, 200, 60), trim=(20, 160, 150)),
    ]
    if i < len(specials):
        return specials[i]
    h = (i * 0.381966 + 0.07) % 1.0
    h2 = (h + 0.42 + (i % 5) * 0.03) % 1.0
    h3 = (h + 0.12) % 1.0
    sat = 0.48 + (i % 4) * 0.08
    return dict(
        dark=hsv(h, 0.45, 0.16 + (i % 3) * 0.03),
        mid=hsv(h, sat, 0.58 + (i % 5) * 0.05),
        light=hsv(h, 0.18, 0.94),
        glow=hsv(h2, 0.75, 1.0),
        core=hsv(h3, 0.85, 0.95),
        trim=hsv((h + 0.06) % 1.0, 0.55, 0.72),
    )


def bbox(im: Image.Image) -> tuple[int, int, int, int]:
    a = im.getchannel("A")
    ext = a.getbbox()
    return ext or (0, 0, im.size[0], im.size[1])


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def remap(im: Image.Image, pal: dict) -> Image.Image:
    out = im.copy()
    pix = out.load()
    w, h = out.size
    dark, mid, light = pal["dark"], pal["mid"], pal["light"]
    glow, core, trim = pal["glow"], pal["core"], pal["trim"]
    for y in range(h):
        for x in range(w):
            r, g, b, a = pix[x, y]
            if a < 18:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            sat = 0 if mx < 4 else (mx - mn) / mx
            if lum < 0.13:
                pix[x, y] = (*lerp((8, 10, 14), dark, 0.45), a)
                continue
            if sat > 0.28 and lum > 0.55:
                t = min(1.0, (lum - 0.55) / 0.45)
                pix[x, y] = (*lerp(glow, (255, 255, 255), t * 0.35), a)
                continue
            if sat > 0.35 and r > g + 20 and r > b + 10 and lum < 0.7:
                pix[x, y] = (*lerp(core, light, lum), a)
                continue
            if sat > 0.22 and lum < 0.55:
                pix[x, y] = (*lerp(trim, mid, lum / 0.55), a)
                continue
            if lum < 0.45:
                pix[x, y] = (*lerp(dark, mid, lum / 0.45), a)
            else:
                pix[x, y] = (*lerp(mid, light, (lum - 0.45) / 0.55), a)
    return out


def put(draw: ImageDraw.ImageDraw, xy, fill, outline=None):
    draw.polygon(xy, fill=fill, outline=outline)


def kit_draw(im: Image.Image, kit: str, pal: dict, rng: random.Random) -> None:
    draw = ImageDraw.Draw(im)
    x0, y0, x1, y1 = bbox(im)
    cx = (x0 + x1) / 2
    top, bot = y0, y1
    hh = y1 - y0
    ww = x1 - x0
    head_y = top + hh * 0.16
    sh_y = top + hh * 0.38
    glow, core, trim, light, dark, mid = (
        pal["glow"], pal["core"], pal["trim"], pal["light"], pal["dark"], pal["mid"],
    )
    jx = rng.randint(-4, 4)
    jy = rng.randint(-3, 3)
    cx += jx
    head_y += jy

    def ear(dx, dy, w, h, fill, tip=None):
        pts = [
            (cx + dx, head_y + dy + h),
            (cx + dx - w, head_y + dy),
            (cx + dx, head_y + dy - h * 0.2),
            (cx + dx + w, head_y + dy),
        ]
        draw.polygon(pts, fill=fill, outline=dark)
        if tip:
            draw.ellipse(
                [cx + dx - 5, head_y + dy - h * 0.25 - 5,
                 cx + dx + 5, head_y + dy - h * 0.25 + 5],
                fill=tip, outline=dark,
            )

    if kit == "bolts":
        for s in (-1, 1):
            pts = [
                (cx + s * 10, head_y - 8),
                (cx + s * 22, head_y - 28),
                (cx + s * 14, head_y - 26),
                (cx + s * 26, head_y - 48),
                (cx + s * 8, head_y - 22),
                (cx + s * 16, head_y - 24),
            ]
            draw.polygon(pts, fill=glow, outline=dark)
    elif kit == "horns":
        for s in (-1, 1):
            pts = [
                (cx + s * 12, head_y + 6),
                (cx + s * 28, head_y - 18),
                (cx + s * 38, head_y - 8),
                (cx + s * 18, head_y + 10),
            ]
            draw.polygon(pts, fill=core, outline=dark)
            draw.polygon(
                [(cx + s * 28, head_y - 18), (cx + s * 38, head_y - 8),
                 (cx + s * 32, head_y - 6)],
                fill=light,
            )
    elif kit == "bunny":
        for s in (-1, 1):
            ear(s * 16, -8, 9, 42, mid, glow)
    elif kit == "wings":
        for s in (-1, 1):
            pts = [
                (cx + s * 8, sh_y),
                (cx + s * 46, sh_y - 22),
                (cx + s * 58, sh_y + 8),
                (cx + s * 40, sh_y + 18),
                (cx + s * 22, sh_y + 10),
            ]
            draw.polygon(pts, fill=trim, outline=dark)
            draw.polygon(
                [(cx + s * 22, sh_y + 4), (cx + s * 46, sh_y - 16),
                 (cx + s * 36, sh_y + 2)],
                fill=glow,
            )
    elif kit == "scarf":
        pts = [
            (cx - 22, sh_y - 4), (cx + 22, sh_y - 8),
            (cx + 26, sh_y + 6), (cx + 8, sh_y + 36),
            (cx + 2, sh_y + 18), (cx - 10, sh_y + 8),
        ]
        draw.polygon(pts, fill=core, outline=dark)
        draw.polygon(
            [(cx + 8, sh_y + 8), (cx + 18, sh_y + 28), (cx + 10, sh_y + 30)],
            fill=glow,
        )
    elif kit == "mohawk":
        for i, h in enumerate((28, 40, 48, 40, 28)):
            x = cx - 16 + i * 8
            draw.polygon(
                [(x - 4, head_y), (x, head_y - h), (x + 4, head_y)],
                fill=glow if i % 2 == 0 else core, outline=dark,
            )
    elif kit == "crown":
        pts = [(cx - 22, head_y + 4), (cx + 22, head_y + 4)]
        for i in range(5):
            x = cx - 20 + i * 10
            h = 18 if i % 2 == 0 else 10
            pts.append((x + 5, head_y + 4))
            pts.append((x, head_y - h))
        draw.polygon(
            [(cx - 22, head_y + 6), (cx - 20, head_y - 16),
             (cx - 10, head_y + 2), (cx, head_y - 22),
             (cx + 10, head_y + 2), (cx + 20, head_y - 16),
             (cx + 22, head_y + 6)],
            fill=core, outline=dark,
        )
        draw.ellipse([cx - 4, head_y - 26, cx + 4, head_y - 18], fill=glow)
    elif kit == "visor":
        draw.rounded_rectangle(
            [cx - 28, head_y + 2, cx + 28, head_y + 16],
            radius=5, fill=glow, outline=dark,
        )
        draw.rectangle([cx - 24, head_y + 6, cx + 24, head_y + 10], fill=light)
    elif kit == "dish":
        draw.ellipse([cx - 16, top - 18, cx + 16, top + 10], fill=mid, outline=dark)
        draw.ellipse([cx - 8, top - 12, cx + 8, top + 4], fill=glow)
        draw.rectangle([cx - 2, top + 8, cx + 2, head_y + 4], fill=trim)
    elif kit == "cape":
        pts = [
            (cx - 18, sh_y - 6), (cx + 18, sh_y - 6),
            (cx + 34, bot - 8), (cx + 8, bot - 22),
            (cx - 6, bot - 10), (cx - 32, bot - 18),
        ]
        draw.polygon(pts, fill=core, outline=dark)
        draw.polygon(
            [(cx - 8, sh_y), (cx + 8, sh_y), (cx, sh_y + 40)],
            fill=glow,
        )
    elif kit == "jets":
        for s in (-1, 1):
            draw.rounded_rectangle(
                [cx + s * 28 - 8, sh_y + 8, cx + s * 28 + 8, sh_y + 36],
                radius=3, fill=dark, outline=trim,
            )
            draw.polygon(
                [(cx + s * 28 - 7, sh_y + 36), (cx + s * 28 + 7, sh_y + 36),
                 (cx + s * 28, sh_y + 58)],
                fill=core,
            )
            draw.polygon(
                [(cx + s * 28 - 4, sh_y + 36), (cx + s * 28 + 4, sh_y + 36),
                 (cx + s * 28, sh_y + 50)],
                fill=glow,
            )
    elif kit == "katana":
        draw.rectangle([cx + 30, top + 20, cx + 36, bot - 24], fill=light, outline=dark)
        draw.rectangle([cx + 28, bot - 30, cx + 38, bot - 18], fill=core)
        draw.ellipse([cx + 29, top + 14, cx + 37, top + 24], fill=glow)
    elif kit == "array":
        draw.rounded_rectangle(
            [cx - 18, top + 2, cx + 18, top + 10],
            radius=2, fill=dark, outline=trim,
        )
        for s in (-1, 0, 1):
            draw.ellipse(
                [cx + s * 10 - 3, top + 3, cx + s * 10 + 3, top + 9],
                fill=glow,
            )
    elif kit == "fin":
        draw.polygon(
            [(cx - 6, head_y + 4), (cx + 6, head_y + 4), (cx, head_y - 36)],
            fill=trim, outline=dark,
        )
        draw.polygon(
            [(cx - 2, head_y), (cx + 2, head_y), (cx, head_y - 24)],
            fill=glow,
        )
    elif kit == "fox":
        for s in (-1, 1):
            draw.polygon(
                [(cx + s * 8, head_y + 4), (cx + s * 26, head_y - 28),
                 (cx + s * 14, head_y + 8)],
                fill=mid, outline=dark,
            )
            draw.polygon(
                [(cx + s * 14, head_y), (cx + s * 24, head_y - 22),
                 (cx + s * 16, head_y + 2)],
                fill=core,
            )
    elif kit == "plume":
        for i, (dx, h) in enumerate(((-8, 34), (0, 48), (8, 36))):
            draw.polygon(
                [(cx + dx - 5, head_y), (cx + dx, head_y - h),
                 (cx + dx + 5, head_y)],
                fill=core if i != 1 else glow, outline=dark,
            )
    elif kit == "goggles":
        for s in (-1, 1):
            draw.ellipse(
                [cx + s * 14 - 12, head_y + 2, cx + s * 14 + 12, head_y + 22],
                fill=glow, outline=dark,
            )
            draw.ellipse(
                [cx + s * 14 - 6, head_y + 8, cx + s * 14 + 6, head_y + 18],
                fill=light,
            )
        draw.rectangle([cx - 6, head_y + 10, cx + 6, head_y + 14], fill=trim)
    elif kit == "spikes":
        for i in range(7):
            x = cx - 24 + i * 8
            h = 14 + (i % 3) * 8
            draw.polygon(
                [(x - 3, sh_y - 4), (x, sh_y - 4 - h), (x + 3, sh_y - 4)],
                fill=trim, outline=dark,
            )
    elif kit == "orb":
        ox, oy = cx + 36, head_y - 4
        draw.ellipse([ox - 12, oy - 12, ox + 12, oy + 12], fill=glow, outline=dark)
        draw.ellipse([ox - 5, oy - 7, ox + 3, oy + 1], fill=light)
        draw.line([cx + 18, head_y + 8, ox - 8, oy + 4], fill=trim, width=2)
    elif kit == "blades":
        for s in (-1, 1):
            draw.polygon(
                [(cx + s * 18, sh_y - 4), (cx + s * 48, sh_y - 18),
                 (cx + s * 44, sh_y + 2), (cx + s * 22, sh_y + 10)],
                fill=light, outline=dark,
            )
            draw.polygon(
                [(cx + s * 24, sh_y), (cx + s * 44, sh_y - 12),
                 (cx + s * 36, sh_y + 2)],
                fill=glow,
            )


def bake_one(i: int, bases: dict[str, Image.Image]) -> Image.Image:
    name = NAMES[i]
    src_key = BASES[(i * 3 + 7) % len(BASES)]
    kit = KITS[i % len(KITS)]
    rng = random.Random(20260901 + i * 17)
    pal = palette(i)
    src = bases[src_key].copy()
    src = remap(src, pal)
    kit_draw(src, kit, pal, rng)
    return src, name, src_key, kit


def sheet(imgs: list[tuple[str, Image.Image]]) -> Image.Image:
    cols, rows = 10, 8
    cell = 96
    out = Image.new("RGBA", (cols * cell, rows * cell), (8, 10, 18, 255))
    for i, (name, im) in enumerate(imgs):
        r, c = divmod(i, cols)
        thumb = im.resize((cell, cell), Image.Resampling.NEAREST)
        out.paste(thumb, (c * cell, r * cell), thumb)
    return out


def main() -> None:
    bases = {}
    for key in BASES:
        path = ROOT / f"agent_{key}.png"
        if not path.exists():
            sys.exit(f"missing {path}")
        im = Image.open(path).convert("RGBA")
        bases[key] = im.resize((SIZE, SIZE), Image.Resampling.LANCZOS)

    done = []
    for i in range(len(NAMES)):
        im, name, src, kit = bake_one(i, bases)
        dest = ROOT / f"agent_{name}.png"
        im.save(dest, optimize=True)
        fly = make_fly(im, seed=20260901 + i * 13)
        fly.save(ROOT / f"agent_{name}_fly.png", optimize=True)
        a = im.getchannel("A").histogram()
        print(f"  {name:10} from {src:8} kit={kit:7}  opaque={a[255]:6}  {dest.name}")
        done.append((name, im))

    grid = sheet(done)
    grid.save(ROOT / "roster_sheet.png", optimize=True)
    print(f"  wrote {len(done)} sprites + roster_sheet.png")


if __name__ == "__main__":
    os.chdir(ROOT.parent)
    main()
