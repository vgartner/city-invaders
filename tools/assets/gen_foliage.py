#!/usr/bin/env python3
"""Build a foliage-card texture for the Godot street trees from a real leaf
set (ambientCG LeafSet, 3x3 leaves on one sheet, with an opacity map).

Hundreds of individual leaves are stamped, rotated and shaded inside a
ragged crown silhouette: darker leaves underneath, lit ones on top, so a
crossed-card tree reads as a leafy canopy instead of a flat blob.
"""
import argparse
import math
import random
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter


def leaves_from_sheet(color_path, opacity_path, grid=3):
    col = Image.open(color_path).convert("RGB")
    alpha = Image.open(opacity_path).convert("L")
    w, h = col.size
    cw, ch = w // grid, h // grid
    out = []
    for gy in range(grid):
        for gx in range(grid):
            box = (gx * cw, gy * ch, (gx + 1) * cw, (gy + 1) * ch)
            leaf = col.crop(box).convert("RGBA")
            leaf.putalpha(alpha.crop(box))
            bb = leaf.getbbox()
            if bb:
                out.append(leaf.crop(bb))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leafset", type=Path, required=True, help="folder with color.jpg and opacity.jpg")
    ap.add_argument("--bark", type=Path, required=True, help="bark color.jpg")
    ap.add_argument("--out", type=Path, required=True, help="output folder (leaves.png, bark.png)")
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--count", type=int, default=4200)
    ap.add_argument("--seed", type=int, default=4)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    leaves = leaves_from_sheet(args.leafset / "color.jpg", args.leafset / "opacity.jpg")
    S = args.size
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cx, cy = S / 2, S * 0.52
    # ragged crown silhouette: radius modulated by a few sine lobes
    lobes = [(rng.uniform(0.04, 0.09), rng.randint(3, 9), rng.uniform(0, math.tau)) for _ in range(4)]

    def crown_r(a):
        return S * 0.44 * (1 + sum(amp * math.sin(k * a + ph) for amp, k, ph in lobes))

    for i in range(args.count):
        depth = i / args.count                      # back (dark) to front (lit)
        a = rng.uniform(0, math.tau)
        r = crown_r(a) * math.sqrt(rng.random())
        x, y = cx + r * math.cos(a), cy + r * math.sin(a) * 0.85
        leaf = rng.choice(leaves)
        size = rng.uniform(0.018, 0.032) * S
        scale = size / max(leaf.size)
        lf = leaf.resize((max(2, int(leaf.width * scale)), max(2, int(leaf.height * scale))), Image.LANCZOS)
        lf = lf.rotate(rng.uniform(0, 360), expand=True, resample=Image.BICUBIC)
        bright = 0.45 + 0.75 * depth + rng.uniform(-0.1, 0.1)
        # light comes from the top: upper leaves brighter
        bright *= 1.05 - 0.25 * ((y - cy) / (S * 0.45))
        rgb = ImageEnhance.Brightness(lf.convert("RGB")).enhance(max(0.25, bright))
        rgb = ImageEnhance.Color(rgb).enhance(rng.uniform(0.85, 1.15))
        lf = Image.merge("RGBA", (*rgb.split(), lf.split()[3]))
        canvas.alpha_composite(lf, (int(x - lf.width / 2), int(y - lf.height / 2)))
    args.out.mkdir(parents=True, exist_ok=True)
    canvas.filter(ImageFilter.SMOOTH).save(args.out / "leaves.png")
    bark = Image.open(args.bark).convert("RGB").resize((512, 512), Image.LANCZOS)
    bark.save(args.out / "bark.png")
    print("wrote", args.out / "leaves.png", args.out / "bark.png")


if __name__ == "__main__":
    main()
