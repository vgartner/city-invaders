#!/usr/bin/env python3
"""Measure the wall colours of a map's photographed facades, to paint the
generated buildings in the colours the place really has (KIT_COLOURS in
osm2gltf.py, docs/MAP_PIPELINE.md "Kit facades").

    tools/.venv/bin/python tools/map/facade_colours.py maps/gasometro/facades/facades_clean.json [--swatch out.png]

Per photo: the wall is the most common colour of the lit part - glass,
shadow, sky and trees are left out (dark, very bright-blue and green
pixels), then the darker half of what is left (the wall in shade). A photo
whose wall is still dark is a facade in shadow: it says little about the
paint and is skipped. The photos'
wall colours are then grouped (k-means in Lab) for low buildings (up to
12 m) and for tall ones; each group prints as an RGB triple with the number
of facades in it.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

LOW_M = 12.0
SHADE_LUM = 125.0        # a wall darker than this is in shadow (or its photo is)


def lab(rgb):
    """sRGB 0..255 -> CIE Lab (D65)."""
    c = np.asarray(rgb, float) / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    xyz = c @ np.array([[0.4124, 0.2126, 0.0193], [0.3576, 0.7152, 0.1192], [0.1805, 0.0722, 0.9505]])
    xyz /= np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def wall_colour(path):
    """The photo's wall colour (RGB), or None if too little of it is wall."""
    a = np.asarray(Image.open(path).convert("RGB").resize((96, 96)), float).reshape(-1, 3)
    r, g, b = a.T
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    tree = (g > r * 1.08) & (g > b * 1.08) & (lum < 150)
    sky = (b > r * 1.25) & (lum > 170)
    ok = (lum > 85) & ~tree & ~sky
    if ok.sum() < 0.25 * len(a):
        return None
    keep = a[ok & (lum >= np.median(lum[ok]))]          # the lit half
    # the most common colour: the fullest cell of a coarse RGB grid, then the mean of its pixels
    cells = (keep // 24).astype(int)
    keys = cells[:, 0] * 10000 + cells[:, 1] * 100 + cells[:, 2]
    vals, counts = np.unique(keys, return_counts=True)
    c = keep[keys == vals[np.argmax(counts)]].mean(0)
    return c if c @ (0.299, 0.587, 0.114) >= SHADE_LUM else None


def groups(colours, k, rng):
    """k-means in Lab; returns [(rgb, count), ...], the biggest group first."""
    pts = lab(colours)
    centres = pts[rng.choice(len(pts), k, replace=False)]
    for _ in range(40):
        owner = np.argmin(((pts[:, None] - centres[None]) ** 2).sum(-1), 1)
        centres = np.array([pts[owner == i].mean(0) if np.any(owner == i) else centres[i] for i in range(k)])
    out = [(np.median(colours[owner == i], 0), int(np.sum(owner == i))) for i in range(k) if np.any(owner == i)]
    return sorted(out, key=lambda g: -g[1])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("facades", type=Path, nargs="+", help="facades.json files (mapillary_facades / clean_facades)")
    ap.add_argument("--groups", type=int, default=8)
    ap.add_argument("--swatch", type=Path, help="write the groups as an image")
    a = ap.parse_args()
    sets = {"low": [], "tall": []}
    for f in a.facades:
        data = json.loads(f.read_text())
        for rec in (data.values() if isinstance(data, dict) else data):
            if not isinstance(rec, dict) or "file" not in rec:
                continue
            p = f.parent / rec["file"]
            c = wall_colour(p) if p.exists() else None
            if c is not None:
                sets["low" if rec.get("height_m", 0) <= LOW_M else "tall"].append(c)
    rng = np.random.default_rng(3)
    rows = []
    for name, cols in sets.items():
        if len(cols) < a.groups:
            print(f"{name}: only {len(cols)} facades")
            continue
        g = groups(np.array(cols), a.groups, rng)
        rows.append(g)
        print(f"{name} ({len(cols)} facades):", ", ".join("(%d, %d, %d) x%d" % (*np.round(c).astype(int), n) for c, n in g))
    if a.swatch and rows:
        img = Image.new("RGB", (a.groups * 90, len(rows) * 90), "white")
        for j, g in enumerate(rows):
            for i, (c, _) in enumerate(g):
                img.paste(tuple(int(v) for v in np.round(c)), (i * 90, j * 90, i * 90 + 86, j * 90 + 86))
        img.save(a.swatch)


if __name__ == "__main__":
    main()
