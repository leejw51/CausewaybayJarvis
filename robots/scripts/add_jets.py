#!/usr/bin/env python3
"""Same standing sprite, plus rocket flames under the boots. No redraw."""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / "assets"


def bbox(im: Image.Image):
    return im.getchannel("A").getbbox() or (0, 0, im.size[0], im.size[1])


def punch_black(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    pix = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = pix[x, y]
            if a < 8:
                continue
            if r + g + b < 18:
                pix[x, y] = (0, 0, 0, 0)
    return im


def jet(draw: ImageDraw.ImageDraw, x: int, y: int, length: int, width: int) -> None:
    # white core -> gold -> cyan, jarvis-fly language
    outer = (70, 210, 255, 255)
    mid = (255, 220, 70, 255)
    core = (255, 255, 255, 255)
    tip = (40, 90, 220, 230)
    half = width // 2
    draw.polygon(
        [(x - half - 10, y), (x + half + 10, y), (x, y + length)],
        fill=outer,
    )
    draw.polygon(
        [(x - half - 2, y), (x + half + 2, y), (x, y + int(length * 0.82))],
        fill=tip,
    )
    draw.polygon(
        [(x - half + 4, y), (x + half - 4, y), (x, y + int(length * 0.62))],
        fill=mid,
    )
    draw.polygon(
        [(x - max(4, half // 3), y), (x + max(4, half // 3), y), (x, y + int(length * 0.38))],
        fill=core,
    )
    for i, (dx, dy) in enumerate(((-18, 0.55), (16, 0.7), (-8, 0.88), (10, 0.92))):
        px = x + dx
        py = y + int(length * dy)
        draw.point([(px, py), (px + 1, py), (px, py + 1)], fill=outer)


def add_flames(stand: Image.Image, lift: int = 160, length: int = 220) -> Image.Image:
    src = punch_black(stand.convert("RGBA"))
    w, h = src.size
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.alpha_composite(src, (0, -lift))
    x0, y0, x1, y1 = bbox(canvas)
    cx = (x0 + x1) // 2
    fy = y1 - 4
    span = max(48, int((x1 - x0) * 0.18))
    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    width = max(28, span)
    jet(draw, cx - span, fy, length, width)
    jet(draw, cx + span, fy, length, width)
    canvas.alpha_composite(overlay)
    return canvas


def main() -> None:
    name = sys.argv[1] if len(sys.argv) > 1 else "volt"
    src = ROOT / f"agent_{name}.png"
    dest = ROOT / f"agent_{name}_fly_sample.png"
    if not src.exists():
        sys.exit(f"missing {src}")
    out = add_flames(Image.open(src))
    out.save(dest, optimize=True)
    print(f"wrote {dest} {out.size}")


if __name__ == "__main__":
    main()
