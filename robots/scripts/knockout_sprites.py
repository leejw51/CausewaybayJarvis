#!/usr/bin/env python3
"""Punch solid black backgrounds out of generated agent sprites."""
from __future__ import annotations

import os
from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / "assets"

NEW = [
    "volt", "ghost", "razor", "nova", "nitro", "onyx", "echo",
    "pulse", "wraith", "mason", "blaze", "talon", "pivot", "glitch",
]


def is_bg(r: int, g: int, b: int, a: int) -> bool:
    if a < 40:
        return True
    # generated sheets sit on (0,0,0)..(2,2,1); charcoal joints are much brighter
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    return lum < 14


def knockout(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    w, h = im.size
    pix = im.load()
    seen = bytearray(w * h)
    q = deque()

    def push(x: int, y: int) -> None:
        if x < 0 or y < 0 or x >= w or y >= h:
            return
        k = y * w + x
        if seen[k]:
            return
        r, g, b, a = pix[x, y]
        if not is_bg(r, g, b, a):
            return
        seen[k] = 1
        q.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    n = 0
    while q:
        x, y = q.popleft()
        pix[x, y] = (0, 0, 0, 0)
        n += 1
        push(x + 1, y)
        push(x - 1, y)
        push(x, y + 1)
        push(x, y - 1)
    return im, n


def main() -> None:
    for name in NEW:
        path = ROOT / f"agent_{name}.png"
        if not path.exists():
            print(f"  skip {path.name}")
            continue
        im = Image.open(path)
        out, n = knockout(im)
        out.save(path, optimize=True)
        a = out.getchannel("A")
        hist = a.histogram()
        print(
            f"  {path.name:22} punched {n:7}  "
            f"transparent={hist[0]} opaque={hist[255]} partial={sum(hist[1:255])}"
        )


if __name__ == "__main__":
    os.chdir(ROOT.parent)
    main()
