#!/usr/bin/env python3
"""Ground elevation for a map from the Copernicus GLO-30 DEM (30 m, free,
on AWS: copernicus-dem-30m). The DEM is a surface model - in a city centre
it includes the buildings - so a bare-earth estimate is made: a grey-scale
opening (minimum then maximum filter, ~130 m wide) removes building blocks
while keeping broad landforms such as the Centro Histórico ridge, then a
Gaussian smooths the result.

Writes a JSON grid in the map's metric frame (x east, y north, metres from
the centre) covering the map plus a margin for the horizon, normalised so
the lowest land inside the map is at 0:

    tools/.venv/bin/python tools/map/terrain.py --lat -30.0300 --lon -51.2290 --half 250 \\
        --out maps/poa/data/terrain.json

osm2gltf --terrain <file> then lifts every vertex by the ground height.
"""
import argparse
import json
import math
import urllib.request
from pathlib import Path

import numpy as np

CACHE = Path.home() / ".cache" / "city-invaders-dem"
URL = "https://copernicus-dem-30m.s3.amazonaws.com/{t}/{t}.tif"
STEP_M = 10.0


def tile_name(lat, lon):
    la, lo = math.floor(lat), math.floor(lon)
    ns = f"{'N' if la >= 0 else 'S'}{abs(la):02d}_00"
    ew = f"{'E' if lo >= 0 else 'W'}{abs(lo):03d}_00"
    return f"Copernicus_DSM_COG_10_{ns}_{ew}_DEM"


def load_tile(name):
    import tifffile
    path = CACHE / f"{name}.tif"
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print("downloading", name)
        urllib.request.urlretrieve(URL.format(t=name), path)
    with tifffile.TiffFile(path) as tf:
        page = tf.pages[0]
        a = page.asarray().astype(np.float32)
        tie = page.tags["ModelTiepointTag"].value
        scale = page.tags["ModelPixelScaleTag"].value
    return a, tie[3], tie[4], scale[0], scale[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=150)
    ap.add_argument("--bounds", type=float, nargs=4, metavar=("MIN_X", "MIN_Y", "MAX_X", "MAX_Y"))
    ap.add_argument("--margin", type=float, default=700.0, help="extra metres around the map (horizon)")
    ap.add_argument("--open-m", type=float, default=130.0, help="width of the building-removing opening")
    ap.add_argument("--smooth-m", type=float, default=30.0)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    from scipy import ndimage
    bx = args.bounds or (-args.half, -args.half, args.half, args.half)
    x0, y0 = bx[0] - args.margin, bx[1] - args.margin
    x1, y1 = bx[2] + args.margin, bx[3] + args.margin
    kx = 111320 * math.cos(math.radians(args.lat))
    xs = np.arange(x0, x1 + STEP_M, STEP_M)
    ys = np.arange(y0, y1 + STEP_M, STEP_M)
    lons = args.lon + xs / kx
    lats = args.lat + ys / 110540
    grid = np.zeros((len(ys), len(xs)), np.float32)
    tiles = {}
    for j, la in enumerate(lats):
        for i, lo in enumerate(lons):
            name = tile_name(la, lo)
            if name not in tiles:
                tiles[name] = load_tile(name)
            a, lon0, lat0, dx, dy = tiles[name]
            c = (lo - lon0) / dx - 0.5
            r = (lat0 - la) / dy - 0.5
            c0, r0 = int(np.floor(c)), int(np.floor(r))
            fc, fr = c - c0, r - r0
            c0, r0 = np.clip(c0, 0, a.shape[1] - 2), np.clip(r0, 0, a.shape[0] - 2)
            v = (a[r0, c0] * (1 - fc) * (1 - fr) + a[r0, c0 + 1] * fc * (1 - fr)
                 + a[r0 + 1, c0] * (1 - fc) * fr + a[r0 + 1, c0 + 1] * fc * fr)
            grid[j, i] = v
    size = max(3, int(args.open_m / STEP_M) | 1)
    bare = ndimage.grey_opening(grid, size=(size, size))
    bare = ndimage.gaussian_filter(bare, args.smooth_m / STEP_M)
    # lowest ground inside the map -> 0 (the water / quay level stays near 0)
    inside = (xs[None, :] >= bx[0]) & (xs[None, :] <= bx[2]) & (ys[:, None] >= bx[1]) & (ys[:, None] <= bx[3])
    base = float(bare[inside].min())
    bare = np.maximum(bare - base, 0.0)
    args.out.write_text(json.dumps({"x0": float(xs[0]), "y0": float(ys[0]), "step": STEP_M,
                                    "nx": len(xs), "ny": len(ys), "base_m": base,
                                    "h": [round(float(v), 2) for v in bare.ravel()]}))
    print(f"terrain {len(xs)}x{len(ys)} @ {STEP_M:.0f} m; inside the map {bare[inside].min():.1f}"
          f"..{bare[inside].max():.1f} m (sea level offset {base:.1f} m) -> {args.out}")


if __name__ == "__main__":
    main()
