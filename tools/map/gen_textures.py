#!/usr/bin/env python3
"""Generate procedural textures for the generated maps (facades with
windows, asphalt, grass, roof): the fallback where no photo of a wall exists.
osm2gltf.py reads them from its --textures folder.
"""
import argparse
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 256

# Facade palette inspired by the pastel plaster common in small towns of
# Rio Grande do Sul (cream, ochre, light blue, pink, white, mint).
FACADE_COLORS = [
    (232, 220, 190), (226, 190, 120), (170, 200, 220), (225, 170, 170),
    (240, 240, 235), (180, 215, 190), (210, 160, 110), (200, 200, 210),
]


def noise_fill(img, base, amount, rng):
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            d = rng.randint(-amount, amount)
            px[x, y] = tuple(max(0, min(255, c + d)) for c in base)


def facade(color, rng, storefront=False):
    """Two storeys (128 px each = 3 m) and two window bays (6 m wide)."""
    img = Image.new("RGB", (SIZE, SIZE))
    noise_fill(img, color, 6, rng)
    d = ImageDraw.Draw(img)
    trim = tuple(int(c * 0.75) for c in color)
    for storey in range(2):
        top = storey * 128
        d.rectangle([0, top + 118, SIZE, top + 127], fill=trim)  # cornice / floor line
        for bay in range(2):
            cx = 64 + bay * 128
            if storefront and storey == 1:
                d.rectangle([cx - 52, top + 30, cx + 52, top + 118], fill=(60, 70, 80))
                d.rectangle([cx - 52, top + 30, cx + 52, top + 40], fill=trim)
                d.line([cx, top + 40, cx, top + 118], fill=(30, 30, 30), width=3)
            else:
                d.rectangle([cx - 28, top + 26, cx + 28, top + 94], fill=(240, 240, 240))
                d.rectangle([cx - 24, top + 30, cx + 24, top + 90], fill=(70, 95, 120))
                d.line([cx, top + 30, cx, top + 90], fill=(240, 240, 240), width=3)
                d.line([cx - 24, top + 55, cx + 24, top + 55], fill=(240, 240, 240), width=3)
                d.rectangle([cx - 32, top + 94, cx + 32, top + 99], fill=trim)  # sill
    return img.filter(ImageFilter.SMOOTH)


def surface(base, amount, rng, speckle=None):
    img = Image.new("RGB", (SIZE, SIZE))
    noise_fill(img, base, amount, rng)
    if speckle:
        d = ImageDraw.Draw(img)
        for _ in range(400):
            x, y = rng.randrange(SIZE), rng.randrange(SIZE)
            d.point((x, y), fill=speckle)
    return img.filter(ImageFilter.SMOOTH_MORE)


def roof(rng):
    img = surface((150, 75, 55), 14, rng)
    d = ImageDraw.Draw(img)
    for y in range(0, SIZE, 16):
        d.line([0, y, SIZE, y], fill=(110, 55, 40), width=2)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    args.outdir.mkdir(parents=True, exist_ok=True)

    for i, color in enumerate(FACADE_COLORS):
        facade(color, rng, storefront=(i % 2 == 0)).save(args.outdir / f"facade{i}.png")
    surface((70, 70, 72), 12, rng, speckle=(110, 110, 110)).save(args.outdir / "asphalt.png")
    surface((70, 120, 50), 20, rng, speckle=(90, 150, 60)).save(args.outdir / "grass.png")
    roof(rng).save(args.outdir / "roof.png")
    print(f"wrote {len(FACADE_COLORS) + 3} textures to {args.outdir}")


if __name__ == "__main__":
    main()
