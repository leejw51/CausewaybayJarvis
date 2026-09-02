#!/usr/bin/env python3
"""Bake extra fly sheets from the unique Grok fly sprites (palette only)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_roster import BASES, NAMES, palette, remap
from knockout_sprites import knockout

ROOT = Path(__file__).resolve().parents[1] / "assets"
SIZE = 512


def main() -> None:
    flies = {}
    for key in BASES:
        path = ROOT / f"agent_{key}_fly.png"
        im, n = knockout(Image.open(path))
        im.save(path, optimize=True)
        flies[key] = im.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
        print(f"  unique {path.name:28} punched {n}")

    for i, name in enumerate(NAMES):
        src_key = BASES[(i * 3 + 7) % len(BASES)]
        pal = palette(i)
        im = remap(flies[src_key].copy(), pal)
        dest = ROOT / f"agent_{name}_fly.png"
        im.save(dest, optimize=True)
        print(f"  extra  {dest.name:28} from {src_key}")


if __name__ == "__main__":
    os.chdir(ROOT.parent)
    main()
