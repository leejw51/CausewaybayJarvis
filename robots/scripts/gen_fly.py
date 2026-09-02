#!/usr/bin/env python3
"""Build a flying pose for every agent that does not already have one.

The four original suits keep their painted fly sheets. Everyone else gets
the same language: lean, lift, twin thrusters. Flight is how this swarm
reads at a glance, so the pose has to be obvious at 26 world pixels.
"""
from __future__ import annotations

import os
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / "assets"
SIZE = 256


def bbox(im: Image.Image):
    box = im.getchannel("A").getbbox()
    return box or (0, 0, im.size[0], im.size[1])


def sample_glow(im: Image.Image) -> tuple[int, int, int]:
    pix = im.load()
    w, h = im.size
    best = (90, 220, 255)
    score = -1.0
    step = max(1, w // 64)
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b, a = pix[x, y]
            if a < 80:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            sat = 0 if mx < 8 else (mx - mn) / mx
            lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            s = sat * lum
            if s > score and lum > 0.35:
                score = s
                best = (r, g, b)
    return best


def chunk(c, t=1.0):
    return tuple(max(0, min(255, int(v * t))) for v in c)


def draw_jets(im: Image.Image, cx: float, fy: float, glow, rng: random.Random) -> None:
    draw = ImageDraw.Draw(im)
    dark = (10, 12, 18, 255)
    gold = (255, 210, 70, 255)
    white = (255, 255, 255, 255)
    tip = (*glow, 230)
    for s in (-1, 1):
        nx = int(cx + s * 16)
        length = rng.randint(72, 96)
        wob = rng.randint(-4, 4)
        # nozzle
        draw.rounded_rectangle(
            [nx - 9, fy - 14, nx + 9, fy + 4],
            radius=2, fill=(28, 32, 44, 255), outline=dark,
        )
        draw.rectangle([nx - 5, fy - 10, nx + 5, fy], fill=(*glow, 255))
        # outer plasma
        draw.polygon(
            [(nx - 16, fy + 1), (nx + 16, fy + 1), (nx + wob, fy + length)],
            fill=tip,
        )
        # gold core
        draw.polygon(
            [(nx - 10, fy + 1), (nx + 10, fy + 1), (nx + wob // 2, fy + int(length * 0.78))],
            fill=gold,
        )
        # white hot
        draw.polygon(
            [(nx - 4, fy + 1), (nx + 4, fy + 1), (nx, fy + int(length * 0.5))],
            fill=white,
        )
        # sparks
        for _ in range(12):
            sx = nx + rng.randint(-18, 18)
            sy = fy + rng.randint(12, length + 8)
            draw.point([(sx, sy), (sx + 1, sy)], fill=tip)


def make_fly(stand: Image.Image, seed: int = 0) -> Image.Image:
    rng = random.Random(seed)
    im = stand.convert("RGBA")
    x0, y0, x1, y1 = bbox(im)
    char = im.crop((x0, y0, x1, y1))
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cw, ch = char.size
    scale = min(188 / max(1, cw), 128 / max(1, ch))
    nw, nh = max(8, int(cw * scale)), max(8, int(ch * scale))
    char = char.resize((nw, nh), Image.Resampling.LANCZOS)
    char = char.rotate(-14, resample=Image.Resampling.BICUBIC, expand=True, fillcolor=(0, 0, 0, 0))
    px = (SIZE - char.size[0]) // 2
    py = 6
    canvas.alpha_composite(char, (px, py))
    bx0, by0, bx1, by1 = bbox(canvas)
    glow = sample_glow(canvas)
    draw_jets(canvas, (bx0 + bx1) / 2, by1 - 1, glow, rng)
    return canvas


def main() -> None:
    stands = sorted(
        p for p in ROOT.glob("agent_*.png")
        if not p.name.endswith("_fly.png")
    )
    n = 0
    skipped = 0
    for path in stands:
        key = path.name[len("agent_"):-4]
        dest = ROOT / f"agent_{key}_fly.png"
        if dest.exists() and key in ("jarvis", "neon", "jade", "typhoon"):
            skipped += 1
            continue
        stand = Image.open(path)
        fly = make_fly(stand, seed=20260901 + n * 13)
        fly.save(dest, optimize=True)
        a = fly.getchannel("A").histogram()
        print(f"  {dest.name:28} opaque={a[255]:6}")
        n += 1
    print(f"  wrote {n} fly sprites (kept {skipped} originals)")


if __name__ == "__main__":
    os.chdir(ROOT.parent)
    main()
