#!/usr/bin/env python3
"""See-through test for the Godot city, via the DevAgent.

Samples pairs of street points whose straight line crosses a building block
(in the 2D model) and casts the same ray in the running game at several
heights. A ray that gets through is a leak: something you could see or
shoot through. Prints leak count and locations; exit code 1 if any.
"""
import argparse
import json
import random
import sys
from pathlib import Path

from shapely.geometry import LineString, Point
from shapely.ops import unary_union
from shapely.prepared import prep

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "map"))     # osmcity
import osmcity  # noqa: E402
from devagent import DevAgent  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=150)
    ap.add_argument("--pairs", type=int, default=1500)
    ap.add_argument("--heights", type=float, nargs="+", default=[1.5, 6.0, 12.0])
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()

    area, buildings, _, _ = osmcity.load(args.osm, args.lat, args.lon, args.half)
    fp = unary_union([b[0] for b in buildings])
    opened = area.difference(fp).buffer(-1.25, join_style=2).buffer(1.25, join_style=2)
    street = max(getattr(opened, "geoms", [opened]), key=lambda g: g.area).buffer(-1.0)
    blocks = area.difference(street.buffer(1.0))
    street_p, blocks_p = prep(street), prep(blocks)
    minx, miny, maxx, maxy = street.bounds
    rng = random.Random(args.seed)
    agent = DevAgent()
    tested = leaks = 0
    found = []
    while tested < args.pairs:
        a = Point(rng.uniform(minx, maxx), rng.uniform(miny, maxy))
        b = Point(rng.uniform(minx, maxx), rng.uniform(miny, maxy))
        if not (street_p.contains(a) and street_p.contains(b)) or a.distance(b) > 80:
            continue
        seg = LineString([a, b])
        if not blocks_p.intersects(seg) or seg.intersection(blocks).length < 2.0:
            continue
        tested += 1
        for h in args.heights:
            hits = [bb for bb in buildings if bb[1] > h + 0.5]
            if not any(bb[0].intersects(seg) for bb in hits):
                continue          # nothing that tall in the way at this height
            r = agent.call("raycast", **{"from": [a.x, h, -a.y], "to": [b.x, h, -b.y]})
            if not r["hit"]:
                leaks += 1
                mid = seg.intersection(blocks).centroid
                found.append({"x": round(mid.x, 1), "z": round(-mid.y, 1), "h": h,
                              "from": [round(a.x, 1), h, round(-a.y, 1)], "to": [round(b.x, 1), h, round(-b.y, 1)]})
                break
    # Targeted check: shoot along every former slit (infill piece) whose two
    # ends open onto the street. Random lines almost never thread a slit.
    infill = area.difference(street.buffer(1.0)).difference(fp)
    axis_tested = axis_leaks = 0
    for gap in getattr(infill, "geoms", [infill]):
        if gap.geom_type != "Polygon" or gap.area < 0.05:
            continue
        rect = list(gap.minimum_rotated_rectangle.exterior.coords)[:4]
        e = sorted([(Point(rect[i]).distance(Point(rect[(i + 1) % 4])), i) for i in range(4)])
        i = e[-1][1]                       # long side direction
        (x0, y0), (x1, y1) = rect[i], rect[(i + 1) % 4]
        c = gap.centroid
        dx, dy = x1 - x0, y1 - y0
        L = (dx * dx + dy * dy) ** 0.5
        if L < 1.0:
            continue
        ux, uy = dx / L, dy / L
        a2 = Point(c.x - ux * (L / 2 + 3), c.y - uy * (L / 2 + 3))
        b2 = Point(c.x + ux * (L / 2 + 3), c.y + uy * (L / 2 + 3))
        if not (street_p.contains(a2) and street_p.contains(b2)):
            continue
        axis_tested += 1
        roof = max([bh for bp, bh, _ in buildings if bp.distance(gap) < 0.5] or [0])
        for h in args.heights:
            if h > roof - 0.5:
                continue          # above the neighbouring roofs: open sky is expected
            r = agent.call("raycast", **{"from": [a2.x, h, -a2.y], "to": [b2.x, h, -b2.y]})
            if not r["hit"]:
                axis_leaks += 1
                found.append({"x": round(c.x, 1), "z": round(-c.y, 1), "h": h, "kind": "slit-axis"})
                break
    leaks += axis_leaks
    print(json.dumps({"pairs": tested, "slit_axes": axis_tested, "slit_axis_leaks": axis_leaks,
                      "leaks": leaks, "examples": found[:15]}, indent=1))
    sys.exit(1 if leaks else 0)


if __name__ == "__main__":
    main()
