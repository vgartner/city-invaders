#!/usr/bin/env python3
"""Export an OSM city extract as a textured glTF scene (for Godot).

Buildings come from osmcity.load(); every street-facing wall gets its
Mapillary / Commons / user photo (facades.json files), a neighbouring wall's
photo, or a tinted procedural facade.

Coordinates: Godot/glTF Y-up; X = east, -Z = north, 1 unit = 1 metre.
Also writes <name>.spawn.json with a free street spawn point.
"""
import argparse
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

import mapbox_earcut as earcut
import numpy as np
import trimesh

import logging
logging.getLogger("trimesh").setLevel(logging.ERROR)  # scipy-less normal fallback is fine
from PIL import Image
from shapely.geometry import LineString, Point, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.prepared import prep

sys.path.insert(0, str(Path(__file__).parent))
import osmcity  # noqa: E402

U = osmcity.UNITS_PER_M
GEN_W_M, GEN_H_M = 6.0, 6.4      # procedural facade tile: 2 bays x 2 storeys
REAL_PX_PER_M = 40
GROUND_TILE_M = 12.8
INHERIT_MAX_M = 6.0
MIN_PASSAGE_M = 2.5          # narrower openings are filled in
INFILL_OVERLAP_M = 0.08          # only short walls (corners, recesses) reuse a neighbour's photo
SIDEWALK_M = 3.0
WATER_Y = -1.4               # water surface below street level (quay height)
CURB_M = 0.15
LAMP_SPACING_M = 25.0
LAMP_MIN_GAP_M = 14.0          # no two street lamps closer (the two kerbs of a street are ~10-15 m apart)
LAMP_MIN_WALK_M2 = 40.0        # sidewalk scraps smaller than this get no lamp
RAMP_M = 0.35               # collision ramp width replacing the curb step


class Terrain:
    """Ground height grid from tools/map/terrain.py (metric x east, y north)."""

    def __init__(self, path):
        t = json.loads(Path(path).read_text())
        self.x0, self.y0, self.step = t["x0"], t["y0"], t["step"]
        self.nx, self.ny = t["nx"], t["ny"]
        self.h = np.asarray(t["h"], float).reshape(self.ny, self.nx)

    PLATFORM_BLEND = 30.0   # metres over which a flat platform meets the natural ground
    PAD_CELL = 10.0

    def add_platforms(self, polys):
        """Places that are flat in reality although the elevation model (30 m,
        smoothed) slopes them: a landmark's lot (the Usina, the Mercado), a
        square, a small park, a pitch, a playground. Each becomes level at the
        median of the ground under it and meets the natural slope over
        PLATFORM_BLEND metres - streets and pavements run through gently,
        no mound. Everything else keeps the terrain as it is."""
        self.pads, self.cells = [], {}
        for poly in polys:
            level = None
            if isinstance(poly, tuple):
                poly, level = poly                       # a level given (a landmark lot: its street's)
            if level is None:
                x0, y0, x1, y1 = poly.bounds
                hs = [self._raw(x, y) for x in np.arange(x0, x1 + 0.1, 5.0) for y in np.arange(y0, y1 + 0.1, 5.0)
                      if poly.contains(Point(x, y))] or [self._raw(*poly.centroid.coords[0])]
                level = float(np.median(hs))
            k = len(self.pads)
            self.pads.append((poly, level))
            bx0, by0, bx1, by1 = poly.buffer(self.PLATFORM_BLEND).bounds
            for cx in range(int(math.floor(bx0 / self.PAD_CELL)), int(math.floor(bx1 / self.PAD_CELL)) + 1):
                for cy in range(int(math.floor(by0 / self.PAD_CELL)), int(math.floor(by1 / self.PAD_CELL)) + 1):
                    self.cells.setdefault((cx, cy), []).append(k)

    def street_level(self, poly, car_lines, reach=30.0):
        """The natural ground on the car streets running past a footprint
        (within `reach` metres), or None when no street is that close."""
        hs = []
        for ln in car_lines:
            if ln.distance(poly) > reach:
                continue
            for d in np.arange(0.0, ln.length + 0.01, 4.0):
                p = ln.interpolate(d)
                if p.distance(poly) <= reach:
                    hs.append(self._raw(p.x, p.y))
        return float(np.median(hs)) if hs else None

    def __call__(self, x, y):
        h = self._raw(x, y)
        best_w, best_h = 0.0, h
        for k in getattr(self, "cells", {}).get((int(math.floor(x / self.PAD_CELL)), int(math.floor(y / self.PAD_CELL))), ()):
            poly, flat = self.pads[k]
            d = poly.distance(Point(x, y))
            if d >= self.PLATFORM_BLEND:
                continue
            t = d / self.PLATFORM_BLEND
            w = 1.0 - t * t * (3 - 2 * t)                 # 1 inside, smoothstep down to 0 at the blend's edge
            if w > best_w:
                best_w, best_h = w, flat
        h = h + (best_h - h) * best_w
        road = getattr(self, "road", None)
        if road is not None:
            rx0, ry0, nx, ny, H, W = road
            fx = (x - rx0) / self.ROAD_CELL
            fy = (y - ry0) / self.ROAD_CELL
            if 0.0 <= fx < nx - 1 and 0.0 <= fy < ny - 1:
                i, j = int(fx), int(fy)
                a, b = fx - i, fy - j
                wq = [W[j, i], W[j, i + 1], W[j + 1, i], W[j + 1, i + 1]]
                cw = [(1 - a) * (1 - b), a * (1 - b), (1 - a) * b, a * b]
                w = sum(c * q for c, q in zip(cw, wq))
                if w > 0.0:
                    hr = sum(c * q * hq for c, q, hq in zip(cw, wq, [H[j, i], H[j, i + 1], H[j + 1, i], H[j + 1, i + 1]])) / max(w, 1e-6)
                    h = h + (hr - h) * w
        return h

    ROAD_FLAT_M = 9.0      # from a street's centre line: level across, at the street's own height
    ROAD_BLEND_M = 18.0    # ...then back to the ground around over this distance
    ROAD_CELL = 2.0
    PARALLEL_M = 22.0      # side-by-side ways closer than this are one street's carriageways

    @staticmethod
    def _smooth(hs):
        """A street profile (samples every 4 m) smoothed: gaussian, sigma 12 m;
        the ends padded by odd reflection so a street climbing away from a
        junction keeps the junction's height (an edge pad would pull it up the
        hill, a step against the crossing street)."""
        if len(hs) <= 2:
            return hs
        k = np.exp(-0.5 * ((np.arange(-15, 16) * 4.0) / 12.0) ** 2)
        pad = np.pad(hs, 15, mode="reflect", reflect_type="odd") if len(hs) > 15 else np.pad(hs, 15, mode="edge")
        return np.convolve(pad, k / k.sum(), mode="same")[15:-15]

    def add_roads(self, lines, box):
        """Streets are level from kerb to kerb and climb or fall smoothly along
        their length, whatever the 10 m elevation grid does under them: each
        street gets a height profile (the ground along its centre line,
        smoothed over ~40 m), and the ground within ROAD_FLAT_M of it takes
        that height, blending back to the terrain by ROAD_BLEND_M. Pavements,
        kerbs and the buildings' feet follow, so the street is never a
        switchback of bumps."""
        from shapely.strtree import STRtree
        profiles, ranks = [], []
        for ln in lines:
            rank = 2
            if isinstance(ln, tuple):
                ln, rank = ln            # 2 car street, 1 service way, 0 footway / path
            if ln.length < 2.0:
                continue
            ranks.append(rank)
            ds = np.arange(0.0, ln.length + 0.01, 4.0)
            hs = np.array([self(*ln.interpolate(d).coords[0]) for d in ds])
            profiles.append((ln, ds, self._smooth(hs)))
        if not profiles:
            return
        tree = STRtree([p[0] for p in profiles])
        # the two carriageways of an avenue (ways running side by side within
        # PARALLEL_M) share one height: the asphalt is level across the median
        level = []
        for a, (la, ds, hs) in enumerate(profiles):
            acc = [[h] for h in hs]
            for b in tree.query(la.buffer(self.PARALLEL_M)):
                b = int(b)
                lb, dsb, hsb = profiles[b]
                if b == a or ranks[b] != ranks[a]:
                    continue
                for i, d in enumerate(ds):
                    p = la.interpolate(d)
                    if lb.distance(p) > self.PARALLEL_M:
                        continue
                    q = la.interpolate(min(d + 2.0, la.length)).coords[0]
                    p0 = la.interpolate(max(d - 2.0, 0.0)).coords[0]
                    db = lb.project(p)
                    r = lb.interpolate(min(db + 2.0, lb.length)).coords[0]
                    r0 = lb.interpolate(max(db - 2.0, 0.0)).coords[0]
                    u = np.subtract(q, p0)
                    v = np.subtract(r, r0)
                    nu, nv = np.linalg.norm(u), np.linalg.norm(v)
                    if nu > 0 and nv > 0 and abs(np.dot(u, v)) / (nu * nv) > 0.9:
                        acc[i].append(float(np.interp(db, dsb, hsb)))
            level.append(self._smooth(np.array([float(np.mean(v)) for v in acc])))   # no step where a partner starts
        profiles = [(ln, ds, hs) for (ln, ds, _), hs in zip(profiles, level)]
        # streets that meet agree on the crossing's height: each crossing takes
        # the mean of its streets' profiles there, and every street is bent
        # (linearly between its crossings) to meet those heights
        crossings = []                         # [point, [(profile index, distance along)]]
        for a, (la, _, _) in enumerate(profiles):
            for b in tree.query(la):
                b = int(b)
                if b <= a:
                    continue
                cut = la.intersection(profiles[b][0])
                for g in getattr(cut, "geoms", [cut]):
                    if g.geom_type == "Point":
                        crossings.append([g, [(a, la.project(g)), (b, profiles[b][0].project(g))]])
        # a street mapped ending a few metres short of the one it joins still joins it
        for a, (la, _, _) in enumerate(profiles):
            for end in (Point(la.coords[0]), Point(la.coords[-1])):
                for b in tree.query(end.buffer(6.0)):
                    b = int(b)
                    lb = profiles[b][0]
                    if b != a and 0.01 < lb.distance(end) < 6.0:
                        crossings.append([end, [(a, la.project(end)), (b, lb.project(end))]])
        for _ in range(3):
            fix = {}
            for pt, members in crossings:
                # the busier street decides: a footway crossing an avenue takes the
                # avenue's height, never pulls a dent into it
                top = max(ranks[k] for k, _ in members)
                level = float(np.mean([np.interp(d, profiles[k][1], profiles[k][2]) for k, d in members if ranks[k] == top]))
                for k, d in members:
                    fix.setdefault(k, []).append((d, level - float(np.interp(d, profiles[k][1], profiles[k][2]))))
            for k, pairs in fix.items():
                pairs.sort()
                ln, ds, hs = profiles[k]
                profiles[k] = (ln, ds, hs + np.interp(ds, [p[0] for p in pairs], [p[1] for p in pairs]))
        self.profiles = profiles
        x0, y0, x1, y1 = box.bounds
        x0, y0, x1, y1 = x0 - 40, y0 - 40, x1 + 40, y1 + 40
        nx = int((x1 - x0) / self.ROAD_CELL) + 1
        ny = int((y1 - y0) / self.ROAD_CELL) + 1
        H = np.zeros((ny, nx))
        W = np.zeros((ny, nx))
        for j in range(ny):
            for i in range(nx):
                pt = Point(x0 + i * self.ROAD_CELL, y0 + j * self.ROAD_CELL)
                # every street close by, weighted by nearness: two parallel ways of
                # one street (or a street beside another) blend instead of a step
                acc = wsum = wmax = 0.0
                for k in tree.query(pt.buffer(self.ROAD_BLEND_M)):
                    ln, ds, hs = profiles[int(k)]
                    d = ln.distance(pt)
                    if d >= self.ROAD_BLEND_M:
                        continue
                    t = 0.0 if d <= self.ROAD_FLAT_M else (d - self.ROAD_FLAT_M) / (self.ROAD_BLEND_M - self.ROAD_FLAT_M)
                    w = 1.0 / (1.0 + d) ** 2
                    acc += w * float(np.interp(ln.project(pt), ds, hs))
                    wsum += w
                    wmax = max(wmax, 1.0 - t * t * (3 - 2 * t))
                if wsum > 0.0:
                    H[j, i] = acc / wsum
                    W[j, i] = wmax
        self.road = (x0, y0, nx, ny, H, W)

    def front(self, poly, streets):
        """The ground at a footprint's street side (the middle of its edge
        nearest a street): where its door is, at the pavement's level."""
        if streets is None or streets.is_empty:
            return self(*poly.centroid.coords[0])
        cs = list(poly.exterior.coords)
        best = min(zip(cs[:-1], cs[1:]), key=lambda e: streets.distance(Point((e[0][0] + e[1][0]) / 2, (e[0][1] + e[1][1]) / 2)))
        (ax, ay), (bx, by) = best
        return float(np.mean([self(ax + (bx - ax) * f, ay + (by - ay) * f) for f in (0.25, 0.5, 0.75)]))

    def _raw(self, x, y):
        fx = min(max((x - self.x0) / self.step, 0.0), self.nx - 1.001)
        fy = min(max((y - self.y0) / self.step, 0.0), self.ny - 1.001)
        i, j = int(fx), int(fy)
        a, b = fx - i, fy - j
        h = self.h
        return float(h[j, i] * (1 - a) * (1 - b) + h[j, i + 1] * a * (1 - b)
                     + h[j + 1, i] * (1 - a) * b + h[j + 1, i + 1] * a * b)

    def lowest(self, geom):
        """Lowest ground under a footprint (its ring vertices and centre)."""
        pts = [geom.centroid.coords[0]] + [c for g in getattr(geom, "geoms", [geom]) for c in g.exterior.coords]
        return min(self(x, y) for x, y in pts)


TERRAIN = None        # set from --terrain: every ground-relative vertex follows it
TESSELLATE_M = 6.0    # ground polygons are cut on this grid so they bend with the terrain
# the city's meshes split on this grid (0: one mesh per material). Measured on
# the Centro (279 materials): 80 m cells drew ~30% slower, 200 m ~10% - the map
# is bound by objects drawn, not triangles, and cells multiply the objects. Kept
# for maps with few materials and many triangles: CITY_CELL_M=<metres>.
CITY_CELL_M = float(__import__("os").environ.get("CITY_CELL_M", 0.0))
OCCLUDER_MIN_H = 6.0  # buildings this tall and up block the view (occlusion culling)


def ground(x, y):
    return TERRAIN(x, y) if TERRAIN else 0.0


def to_godot(x, y, up, absolute=False):
    """Map metres -> Godot. `up` is above the ground there, unless absolute."""
    return (x, up if absolute else up + ground(x, y), -y)


def _grid_pieces(poly, cell):
    """Cut a polygon on a world-aligned square grid (neighbouring polygons get
    the same cut points along shared edges, so the terrain-bent surfaces meet)."""
    from shapely.geometry import box as _box
    minx, miny, maxx, maxy = poly.bounds
    out = []
    for gx in np.arange(math.floor(minx / cell) * cell, maxx, cell):
        for gy in np.arange(math.floor(miny / cell) * cell, maxy, cell):
            piece = poly.intersection(_box(gx, gy, gx + cell, gy + cell))
            out += parts_of(piece)
    return out


class Batch:
    """Geometry grouped by texture -> one glTF primitive per material."""

    def __init__(self):
        self.v, self.uv, self.f = defaultdict(list), defaultdict(list), defaultdict(list)

    def quad(self, key, a, b, c, d, uva, uvb, uvc, uvd):
        base = len(self.v[key])
        self.v[key] += [a, b, c, d]
        self.uv[key] += [uva, uvb, uvc, uvd]
        self.f[key] += [(base, base + 1, base + 2), (base, base + 2, base + 3)]

    def polygon(self, key, poly, height, tile_m, absolute=False, cell=None):
        """Up-facing polygon with holes (earcut). Ground-relative polygons are
        tessellated so they follow the terrain."""
        if TERRAIN and not absolute:
            c = cell or TESSELLATE_M
            minx, miny, maxx, maxy = poly.bounds
            if maxx - minx > c or maxy - miny > c:
                for piece in _grid_pieces(poly, c):
                    self._polygon(key, piece, height, tile_m, False)
                return
        self._polygon(key, poly, height, tile_m, absolute)

    def _polygon(self, key, poly, height, tile_m, absolute):
        poly = orient(poly, 1.0)
        rings = [np.asarray(poly.exterior.coords[:-1], float)]
        rings += [np.asarray(r.coords[:-1], float) for r in poly.interiors]
        rings = [r for r in rings if len(r) >= 3]
        verts = np.concatenate(rings)
        ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
        tris = earcut.triangulate_float64(verts, ends).reshape(-1, 3)
        base = len(self.v[key])
        self.v[key] += [to_godot(x, y, height, absolute) for x, y in verts]
        self.uv[key] += [(x / tile_m, y / tile_m) for x, y in verts]
        for t in tris:
            a, b, c = verts[t[0]], verts[t[1]], verts[t[2]]
            ccw = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 0
            self.f[key].append(tuple(base + t) if ccw else (base + t[0], base + t[2], base + t[1]))

    def poly(self, key, ring_xy, height, tile_m, up=True, absolute=False):
        if TERRAIN and not absolute and up:
            from shapely.geometry import Polygon as _P
            pg = _P(ring_xy).buffer(0)
            for piece in parts_of(pg):
                self.polygon(key, piece, height, tile_m)
            return
        pts = np.asarray(ring_xy[:-1] if ring_xy[0] == ring_xy[-1] else ring_xy, float)
        if len(pts) < 3:
            return
        tris = earcut.triangulate_float64(pts, np.array([len(pts)], np.uint32)).reshape(-1, 3)
        base = len(self.v[key])
        self.v[key] += [to_godot(x, y, height, absolute) for x, y in pts]
        self.uv[key] += [(x / tile_m, -y / tile_m) for x, y in pts]
        for t in tris:
            # earcut keeps the ring's orientation; make every face point up
            a, b, c = pts[t[0]], pts[t[1]], pts[t[2]]
            ccw = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 0
            self.f[key].append(tuple(base + t) if ccw == up else (base + t[0], base + t[2], base + t[1]))


LEISURE_MODELS = {
    # kind: (model, size along its X and Z in metres, smallest OSM area that takes it)
    "pitch": ("res://assets/rio_grande_do_sul/sport/campo_futebol7.glb", (34.0, 54.0), (18.0, 28.0)),
    "playground": ("res://assets/rio_grande_do_sul/park/parquinho.glb", (14.0, 10.0), (9.0, 7.0)),
}


def _leisure_models(osm, proj, area, assets, models=None):
    """Landmarks for OSM's soccer pitches and playgrounds: the model where the
    area is, turned along its long side, when the area is big enough for it."""
    from shapely.geometry import Polygon
    out = []
    for el in osm:
        t = el.get("tags", {})
        sport = t.get("sport", "")
        kind = "playground" if t.get("leisure") == "playground" else \
            "pitch" if t.get("leisure") == "pitch" and (sport in ("", "multi") or "soccer" in sport) else None
        if not kind or el["type"] != "way" or len(el.get("geometry", [])) < 4:
            continue
        if (models or {}).get(f"way/{el['id']}") == "@gone":
            continue                                     # turned off in the map's edits
        model, size, least = LEISURE_MODELS[kind]
        if not (assets / model.removeprefix("res://assets/")).exists():
            continue
        poly = Polygon([proj(p["lat"], p["lon"]) for p in el["geometry"]])
        if not poly.is_valid or not area.contains(poly.centroid):
            continue
        rect = poly.minimum_rotated_rectangle
        xs, ys = rect.exterior.coords.xy
        e1 = (xs[1] - xs[0], ys[1] - ys[0])
        e2 = (xs[2] - xs[1], ys[2] - ys[1])
        long_e, short_e = (e1, e2) if math.hypot(*e1) >= math.hypot(*e2) else (e2, e1)
        if math.hypot(*long_e) < max(least) or math.hypot(*short_e) < min(least):
            continue                                     # too small for the model
        # the model's long side along the area's: its Z for the pitch, its X for the playground
        along = long_e if size[1] >= size[0] else short_e
        yaw = math.atan2(along[0], -along[1])
        # a society pitch is smaller than the model: shrink it to fit (not below 0.6)
        scale = min(1.0, math.hypot(*long_e) / max(size), math.hypot(*short_e) / min(size))
        if scale < 0.6:
            continue
        c = poly.centroid
        lm = {"id": f"way/{el['id']}", "model": model, "leisure": kind,
              "pos": [round(c.x, 3), round(TERRAIN(c.x, c.y) if TERRAIN else 0.0, 3), round(-c.y, 3)],
              "yaw": round(yaw, 4), "solid": True}
        if scale < 0.99:
            lm["scale"] = round(scale, 3)
        out.append((lm, poly))
    if out:
        print("leisure models:", {k: sum(1 for lm, _ in out if lm["leisure"] == k) for k in LEISURE_MODELS})
    return out


def _road_lines(osm_path, lat, lon, cars_only=False, ranked=False):
    """The centre lines of the streets cars and pedestrians use (for the terrain's street profiles)."""
    proj = osmcity.project(lat, lon)
    out = []
    for el in json.loads(Path(osm_path).read_text())["elements"]:
        t = el.get("tags", {})
        kinds = (VEHICLE_ROADS - {"service"}) if cars_only else VEHICLE_ROADS | PEDESTRIAN_ROADS | {"service"}
        if el["type"] == "way" and t.get("highway") in kinds \
                and len(el.get("geometry", [])) >= 2 and t.get("area") != "yes":
            ln = LineString([proj(p["lat"], p["lon"]) for p in el["geometry"]])
            out.append((ln, 2 if t["highway"] in VEHICLE_ROADS - {"service"} else 1 if t["highway"] == "service" else 0)
                       if ranked else ln)
    return out


CARRIAGEWAY_M = {"motorway": 14.0, "trunk": 14.0, "primary": 14.0, "secondary": 12.0, "tertiary": 9.0,
                 "primary_link": 7.0, "secondary_link": 7.0, "tertiary_link": 7.0,
                 "unclassified": 7.0, "residential": 7.0, "living_street": 6.0, "service": 4.5}


def _carriageway(osm, proj):
    """Where the cars drive: every motor street as wide as OSM says (its
    `width`, else its `lanes` at 3.2 m, else a width by its kind - narrower
    when one-way), plus the car parks. This is the asphalt; nothing else is."""
    from shapely.geometry import Polygon
    parts = []
    for el in osm:
        t = el.get("tags", {})
        if el["type"] != "way" or len(el.get("geometry", [])) < 2:
            continue
        if t.get("amenity") == "parking" and t.get("parking", "surface") == "surface" and len(el["geometry"]) >= 4:
            poly = Polygon([proj(p["lat"], p["lon"]) for p in el["geometry"]])
            if poly.is_valid:
                parts.append(poly)
            continue
        kind = t.get("highway")
        if kind not in CARRIAGEWAY_M or car_free(t) or t.get("area") == "yes":
            continue
        try:
            w = float((str(t.get("width", "")).split() or ["0"])[0].replace(",", "."))
        except ValueError:
            w = 0.0
        if not w:
            try:
                w = 3.2 * int(t.get("lanes", "0"))
            except ValueError:
                w = 0.0
        if not w:
            w = CARRIAGEWAY_M[kind] * (0.6 if t.get("oneway") == "yes" else 1.0)
        # round ends: where two ways of a street meet at an angle no wedge of grass is left
        parts.append(LineString([proj(p["lat"], p["lon"]) for p in el["geometry"]]).buffer(max(w, 3.0) / 2))
    return unary_union(parts) if parts else Point(9e9, 9e9).buffer(0.1)


def _squares(osm, proj):
    """Paved open spaces: squares and pedestrian areas."""
    from shapely.geometry import Polygon
    out = []
    for el in osm:
        t = el.get("tags", {})
        if el["type"] == "way" and len(el.get("geometry", [])) >= 4 and (
                t.get("place") == "square" or (t.get("highway") == "pedestrian" and t.get("area") == "yes")
                or t.get("amenity") == "marketplace"):
            poly = Polygon([proj(p["lat"], p["lon"]) for p in el["geometry"]])
            if poly.is_valid:
                out.append(poly)
    return unary_union(out) if out else Point(9e9, 9e9).buffer(0.1)


def _flat_areas(osm_path, lat, lon):
    """OSM areas that are level in reality: pitches, playgrounds, squares, plazas."""
    proj = osmcity.project(lat, lon)
    out = []
    for el in json.loads(Path(osm_path).read_text())["elements"]:
        t = el.get("tags", {})
        if el["type"] != "way" or len(el.get("geometry", [])) < 4:
            continue
        # (parks and parking lots follow the slope in a hilly centre: not these)
        if t.get("leisure") in ("pitch", "playground") or t.get("place") == "square" \
                or (t.get("highway") == "pedestrian" and t.get("area") == "yes"):
            from shapely.geometry import Polygon
            poly = Polygon([proj(p["lat"], p["lon"]) for p in el["geometry"]])
            if poly.is_valid and 50 < poly.area < 20000:
                out.append(poly)
    return out


def _ring_roads(roads, map_box, margin=15.0):
    """The map is ringed by roads: of the faces the car roads enclose, those
    well inside the map make up the city; its outer edge is a loop of roads
    to drive round. The traffic's car roads are cut where they leave that
    loop (no route dead-ends into the border); footpaths stay as they are."""
    from shapely.geometry import Polygon
    from shapely.ops import polygonize
    car = [ln for k, _one, ln in roads if k in VEHICLE_ROADS and k != "service"]
    inner = map_box.buffer(-margin, join_style=2)
    faces = [f for f in polygonize(unary_union(car)) if inner.contains(f)]
    if not faces:
        print("ring: no closed road loop inside the map - roads left as they are")
        return roads
    # blocks a park or a square apart still make one city: close the gaps,
    # fill the holes, and keep every piece
    city = unary_union(faces).buffer(30.0, join_style=2).buffer(-30.0, join_style=2)
    pieces = [Polygon(g.exterior) for g in getattr(city, "geoms", [city]) if g.area > 2000]
    if not pieces:
        return roads
    biggest = unary_union(pieces)
    if biggest.area < 0.25 * map_box.area:
        # the loops close round too little of the map: extend its bounds to
        # the next road loop out (re-import) - until then traffic stays as it was
        print(f"ring: road loops round only {biggest.area / 1e4:.1f} ha of {map_box.area / 1e4:.1f} - roads left as they are")
        return roads
    loop = biggest.buffer(1.0, join_style=2)
    out, cut = [], 0
    for k, one, ln in roads:
        if k not in VEHICLE_ROADS:
            out.append((k, one, ln))
            continue
        kept = ln.intersection(loop)
        for piece in getattr(kept, "geoms", [kept]):
            if piece.geom_type == "LineString" and piece.length > 2.0:
                out.append((k, one, piece))
        if kept.length < ln.length - 0.5:
            cut += 1
    print(f"ring: road loops round {biggest.area / 1e4:.1f} ha of {map_box.area / 1e4:.1f}, {cut} roads cut at them")
    return out


def _chimney(batch, key, poly, h, tile_wh, sides=24, taper=0.68):
    """Round industrial chimney (OSM man_made=chimney): a tapered brick tube
    on the footprint's centre with the footprint's equivalent radius, a
    thicker cap ring at the top. Walls go clockwise so they face outward."""
    c = poly.centroid
    base = TERRAIN.lowest(poly) if TERRAIN else 0.0
    rb = max(0.8, math.sqrt(poly.area / math.pi))
    rt = rb * taper
    tw, th = tile_wh
    ring = lambda r, k: (c.x + r * math.cos(-k * math.tau / sides), c.y + r * math.sin(-k * math.tau / sides))
    circ = math.tau * rb
    for k in range(sides):
        a0, a1 = ring(rb, k), ring(rb, k + 1)
        b0, b1 = ring(rt, k), ring(rt, k + 1)
        u0, u1 = k * circ / sides / tw, (k + 1) * circ / sides / tw
        top = base + h
        A, B = to_godot(*a0, -0.5), to_godot(*a1, -0.5)
        C, D = to_godot(*b1, top, True), to_godot(*b0, top, True)
        batch.quad(key, A, B, C, D, (u0, 0), (u1, 0), (u1, h / th), (u0, h / th))
        # cap: a short wider band, then the rim
        e0, e1 = ring(rt * 1.12, k), ring(rt * 1.12, k + 1)
        g = lambda q, z: to_godot(*q, z, True)
        batch.quad(key, g(e0, top - 2.5), g(e1, top - 2.5), g(e1, top), g(e0, top),
                   (u0, 0), (u1, 0), (u1, 2.5 / th), (u0, 2.5 / th))
        batch.quad(key, g(e0, top), g(e1, top), g(b1, top), g(b0, top),
                   (u0, 0), (u1, 0), (u1, 0.1), (u0, 0.1))


def _short(path):
    """Texture key for a facade image: its folder and name (tex_clean/b1_w3.png)."""
    p = Path(path)
    return f"{p.parent.name}/{p.name}"


def car_free(tags):
    """Street closed to motor traffic (motor_vehicle/access no or private,
    unless motor vehicles are explicitly allowed)."""
    closed = ("no", "private")
    if tags.get("motor_vehicle") in ("yes", "designated", "destination") or tags.get("motorcar") == "yes":
        return False
    return tags.get("motor_vehicle") in closed or tags.get("vehicle") in closed \
        or tags.get("motorcar") in closed or tags.get("access") in closed


def parts_of(geom):
    return [g for g in getattr(geom, "geoms", [geom]) if not g.is_empty and g.geom_type == "Polygon"]


def covers_photo(a, b, photo_walls, gap=0.4):
    """True if wall a-b lies flush (within `gap` m, parallel) in front of a
    photographed wall: the opening/closing of the street space leaves thin
    infill skins along some buildings, which would hide their facades."""
    d = np.subtract(b, a)
    L = float(np.hypot(*d))
    if L < 0.3:
        return False
    mid = (np.asarray(a) + np.asarray(b)) / 2
    for p0, p1 in photo_walls:
        e = np.subtract(p1, p0)
        le = float(np.hypot(*e))
        if le < 0.1 or abs(d[0] * e[1] - d[1] * e[0]) / (L * le) > 0.1:
            continue                            # not parallel
        t = np.dot(mid - p0, e) / (le * le)
        if -0.05 <= t <= 1.05 and abs((mid[0] - p0[0]) * e[1] - (mid[1] - p0[1]) * e[0]) / le < gap:
            return True
    return False


def wall(batch, key, p0, p1, h, u1, v_top, v_bot, z0=0.0, top_abs=False, bot_abs=False):
    """Outward-facing wall quad from p0 to p1 (street on the right of p0->p1
    in Build space, i.e. normal (dy, -dx) in metric space). z0/h are above the
    ground unless bot_abs/top_abs; with terrain the wall is split into short
    pieces so a ground-relative edge follows the slope.
    UVs use trimesh's OpenGL convention (v=0 at the image bottom); trimesh
    flips V when writing glTF."""
    L = math.dist(p0, p1)
    n = max(1, int(math.ceil(L / TESSELLATE_M))) if TERRAIN and not (top_abs and bot_abs) else 1
    if n > 1:
        for k in range(n):
            t0, t1 = k / n, (k + 1) / n
            q0 = (p0[0] + (p1[0] - p0[0]) * t0, p0[1] + (p1[1] - p0[1]) * t0)
            q1 = (p0[0] + (p1[0] - p0[0]) * t1, p0[1] + (p1[1] - p0[1]) * t1)
            A, B = to_godot(*q0, z0, bot_abs), to_godot(*q1, z0, bot_abs)
            C, D = to_godot(*q1, h, top_abs), to_godot(*q0, h, top_abs)
            batch.quad(key, A, B, C, D, (u1 * t0, v_bot), (u1 * t1, v_bot), (u1 * t1, v_top), (u1 * t0, v_top))
        return
    A, B = to_godot(*p0, z0, bot_abs), to_godot(*p1, z0, bot_abs)
    C, D = to_godot(*p1, h, top_abs), to_godot(*p0, h, top_abs)
    batch.quad(key, A, B, C, D, (0, v_bot), (u1, v_bot), (u1, v_top), (0, v_top))


# ---- realistic materials (ambientCG, CC0) ------------------------------------
# key -> (folder under godot/assets/materials, tile width m, tile height m)
PBR = {
    "asphalt": ("Asphalt031", 5.0, 5.0),
    "paving": ("PavingStones138", 2.2, 2.2),
    "sidewalk": ("PavingStones138", 2.2, 2.2),     # same look, separate node: visual only (see collision glb)
    "curb": ("Concrete034", 2.0, 2.0),
    "concrete_roof": ("Concrete034", 4.0, 4.0),
    "tile_roof": ("RoofingTiles013A", 3.0, 3.0),
    "plaster": ("PaintedPlaster017", 3.0, 3.0),
    "grass": ("Grass004", 2.5, 2.5),
    "quay": ("Concrete034", 3.0, 3.0),
    "brick": ("Bricks059", 1.6, 1.6),
    "facade_brick": ("Facade018A", 16.0, 16.0),
    "facade_glass": ("Facade001", 20.0, 26.0),
    "facade_bands": ("Facade006", 20.0, 26.0),
    "facade_fins": ("Facade017", 20.0, 26.0),
}
# painted plaster variants of the low-rise brick facade (tools/map/facade_variants.py)
PAINTED = {"cream": (226, 212, 178), "ochre": (214, 172, 96), "salmon": (214, 150, 128),
           "mint": (168, 196, 170), "white": (236, 234, 226), "sky": (160, 186, 206),
           "rose": (206, 160, 170), "terracotta": (184, 108, 76)}
for _n in PAINTED:
    PBR[f"facade_{_n}"] = (f"Facade018A_{_n}", 16.0, 16.0)
# street level: doors and shop windows (tools/map/facade_variants.py), 8 m x 4 m tiles
GROUND_M = 4.0
for _n in list(PAINTED) + ["brick", "concrete"]:
    PBR[f"ground_{_n}"] = (f"GroundFloor_{_n}", 8.0, GROUND_M)


# facade tiles baked from the modular kit (tools/blender/bake_facades.py): key ->
# ("kit:<file prefix>", tile width m, tile height m); storeys per style
KIT_STOREY = {"antigo": 3.6, "residencial": 3.2, "contemporaneo": 3.2}
for _s, _st in KIT_STOREY.items():
    PBR[f"kit_{_s}_upper"] = (f"kit:{_s}_upper", 6.0, 2 * _st)
    PBR[f"kit_{_s}_ground"] = (f"kit:{_s}_ground", 6.0, _st)
    PBR[f"kit_{_s}_shop"] = (f"kit:{_s}_shop", 6.0, _st)
    PBR[f"kit_{_s}_top"] = (f"kit:{_s}_top", 6.0, 2.5)
KIT_BAND_M = 1.6      # the top tile's part drawn under the roof line: the cornice and the parapet


def kit_style(h, rng):
    """A generated building's style from its height: old sobrados up to
    12 m, 1960s residential blocks up to 24 m, contemporary above."""
    return "antigo" if h <= 12 else ("residencial" if h <= 24 else "contemporaneo")


def kit_wall(batch, pbr, kit, p0, p1, h, top):
    """A generated building's wall in the kit's facades: a whole number of
    3 m bays (stretched to the wall), the street storey, whole storeys of
    windows (stretched to the height) and the cornice band closing at the
    roof line - no window cut at a corner, no storey cut at the top."""
    style, ground_kind, k, (tint, strength) = kit
    st = KIT_STOREY[style]
    L = math.dist(p0, p1)
    u = max(1, round(L / 3.0)) / 2.0                  # tiles are two bays wide
    key = lambda part: pbr(f"kit_{style}_{part}@t{k}", tint=tint, tint_strength=strength)
    if h < st + 0.8:
        # a single storey: the street storey up to the roof
        wall(batch, key(ground_kind), p0, p1, top, u, 1.0, -0.6 / st, -0.6, top_abs=True)
        return
    wall(batch, key(ground_kind), p0, p1, st, u, 1.0, -0.6 / st, -0.6)
    rest = h - st
    n = max(0, round((rest - KIT_BAND_M) / st))
    if n == 0:
        # no room for a storey of windows: the band (stretched if taller than the tile)
        v_bot = max(0.0, 1.0 - rest / 2.5)
        wall(batch, key("top"), p0, p1, top, u, 1.0, v_bot, st, top_abs=True)
        return
    wall(batch, key("upper"), p0, p1, top - KIT_BAND_M, u, n / 2.0, 0.0, st, top_abs=True)
    wall(batch, key("top"), p0, p1, top, u, 1.0, 1.0 - KIT_BAND_M / 2.5, top - KIT_BAND_M, top_abs=True, bot_abs=True)


def ground_family(family):
    """The street-level facade under a building's family."""
    f = family.split("@")[0]
    if f.startswith("facade_") and f[7:] in PAINTED:
        return f"ground_{f[7:]}"
    return "ground_brick" if f == "facade_brick" else "ground_concrete"


def low_facade(tags, rng):
    """A low building's facade family: OSM's building:colour if given (the
    nearest painted one), else bare brick or one of the painted colours."""
    want = tags.get("building:colour", "")
    named = {"white": (240, 240, 235), "beige": (220, 205, 170), "yellow": (225, 190, 90),
             "orange": (220, 150, 80), "pink": (215, 160, 170), "red": (180, 80, 70),
             "green": (160, 195, 165), "blue": (155, 180, 210), "grey": (170, 170, 170), "gray": (170, 170, 170)}
    rgb = named.get(want.lower())
    if rgb is None and want.startswith("#") and len(want) == 7:
        rgb = tuple(int(want[i:i + 2], 16) for i in (1, 3, 5))
    if rgb is not None:
        if tags.get("building:material", "") == "brick":
            return "facade_brick"
        k = min(PAINTED, key=lambda n: sum((a - b) ** 2 for a, b in zip(PAINTED[n], rgb)))
        return f"facade_{k}"
    if tags.get("building:material", "") == "brick" or rng.random() < 0.3:
        return "facade_brick"
    return f"facade_{list(PAINTED)[rng.integers(len(PAINTED))]}"
TINTS = [(205, 195, 170), (190, 160, 120), (150, 150, 150), (225, 225, 220), (190, 140, 130), (140, 160, 175)]
TALL_FACADES = ["facade_glass", "facade_bands", "facade_fins", "facade_brick"]
VEHICLE_ROADS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
                 "primary_link", "secondary_link", "tertiary_link", "living_street"}
PEDESTRIAN_ROADS = {"pedestrian"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=150)
    ap.add_argument("--bounds", type=float, nargs=4, metavar=("MIN_X", "MIN_Y", "MAX_X", "MAX_Y"),
                    help="rectangular map in metres from the centre (y north); overrides --half")
    ap.add_argument("--facades", type=Path, nargs="+",
                    help="facades.json files (mapillary_facades/clean_facades, commons_facades); later ones override")
    ap.add_argument("--user", type=Path,
                    help="buildings_user.json from tools/map/building_photo.py: height overrides per OSM id")
    ap.add_argument("--terrain", type=Path, help="ground height grid from tools/map/terrain.py")
    ap.add_argument("--textures", type=Path, required=True, help="gen_textures.py output folder")
    ap.add_argument("--materials", type=Path, required=True, help="godot/assets/materials (ambientCG)")
    ap.add_argument("--start", type=float, nargs=2, default=(0, 0))
    ap.add_argument("--kit-facades", default="",
                    help="x,z (game metres): the block round that point gets the facades baked from the modular kit "
                         "(godot/assets/common/facades_kit) on its generated buildings; \"all\" for every block")
    ap.add_argument("--ring", action="store_true",
                    help="traffic keeps inside the outermost road loop of the map (no car route runs into the border)")
    ap.add_argument("--out", type=Path, required=True, help="output .glb")
    args = ap.parse_args()
    global TERRAIN
    TERRAIN = Terrain(args.terrain) if args.terrain else None

    heights, models, films, fits = {}, {}, {}, {}
    if args.user and args.user.exists():
        user = json.loads(args.user.read_text())
        blds = {k: v for k, v in user.items() if not k.startswith("_")}      # "_props" etc. are not buildings
        heights = {k: v["height"] for k, v in blds.items() if v.get("height")}
        models = {k: v["model"] for k, v in blds.items() if v.get("model")}
        fits = {k: v for k, v in blds.items() if v.get("model")}
        films = {k: v["film"] for k, v in blds.items() if v.get("film")}
    area, buildings, parks, streets = osmcity.load(args.osm, args.lat, args.lon, args.half, args.bounds, heights)
    if TERRAIN:
        # flat in reality: the hand-made landmarks' lots, squares, small parks, pitches, playgrounds
        # a landmark's lot is level with the car street in front of it (the Usina with
        # its avenue): the slope down to the lower ground is taken by the lawn beyond,
        # never by the asphalt
        car = _road_lines(args.osm, args.lat, args.lon, cars_only=True)
        flat = [(poly, TERRAIN.street_level(poly, car)) for poly, _h, t in buildings
                if t.get("@id") in models and models[t["@id"]] not in ("@gone", "@shell")]
        flat += _flat_areas(args.osm, args.lat, args.lon)
        TERRAIN.add_platforms(flat)
        TERRAIN.add_roads(_road_lines(args.osm, args.lat, args.lon, ranked=True),
                          box(*(args.bounds or (-args.half, -args.half, args.half, args.half))))
        import os
        for probe in filter(None, os.environ.get("TERRAIN_PROBE", "").split(";")):
            px, pz = map(float, probe.split(","))
            print("probe (%.1f, %.1f): raw %.2f, final %.2f" % (px, pz, TERRAIN._raw(px, -pz), TERRAIN(px, -pz)))
    real = {}
    for fpath in args.facades or []:
        # file paths are relative to each facades file's folder
        for k, r in json.loads(fpath.read_text()).items():
            real[k] = dict(r, file=str((fpath.parent / r["file"]).resolve()))
    proj = osmcity.project(args.lat, args.lon)
    osm = json.loads(Path(args.osm).read_text())["elements"]
    # a generated building stops at the kerb: OSM footprints a little off the
    # street line (or a street a little off its own) must not reach into the
    # lanes. Hand-made models keep their footprint.
    carriageway = _carriageway(osm, proj)
    cw_prep = prep(carriageway)
    clipped, dropped, kept = 0, 0, []
    kerb_zone = prep(carriageway.buffer(1.5, join_style=2))

    def anonymous(t):
        # nothing but "a building" (or one under construction) and where the
        # outline came from: no name, address, shop, description, history - a
        # newsstand becomes the banca model, a part of a landmark stays
        return all(k.startswith("@") or k == "source" or (k == "building" and v in ("yes", "construction"))
                   for k, v in t.items())

    for poly, h, t in buildings:
        if t.get("@id") not in models and poly.area < 60.0 and anonymous(t) \
                and kerb_zone.intersects(poly) and not cw_prep.intersects(poly):
            # a small structure on the kerb itself, no room left for the sidewalk
            # (a 17 m2 block on the Rua Demétrio Ribeiro's curve; parking huts):
            # it goes, like the small ones standing in the lanes below
            dropped += 1
            continue
        if t.get("@id") not in models and cw_prep.intersects(poly):
            cut = poly.difference(carriageway.buffer(0.3, join_style=2))
            cut = max(parts_of(cut), key=lambda g: g.area) if not cut.is_empty else None
            if cut is None or cut.area < 0.4 * poly.area or cut.area < 12.0:
                if poly.area < 60.0 and anonymous(t):
                    # a small structure standing in the lanes (parking huts mapped
                    # across the street line): it goes
                    dropped += 1
                    continue
                kept.append((poly, h, t))            # mostly in the street: the street map is off, leave it
                continue
            if cut.area < poly.area - 0.5:
                clipped += 1
            poly = cut
        kept.append((poly, h, t))
    buildings = kept
    print("buildings cut back to the kerb:", clipped, "- small ones in the lanes or on the kerb left out:", dropped)
    # ---- places: what OSM says a spot is (godot/assets/place_kinds.json) ----
    kinds_file = Path(__file__).resolve().parents[2] / "godot" / "assets" / "place_kinds.json"
    rules = {k: v for k, v in json.loads(kinds_file.read_text()).items() if not k.startswith("_")} \
        if kinds_file.exists() else {}
    # the Studio's import window can switch kinds off for a city ("_place_kinds_off")
    off = json.loads(args.user.read_text()).get("_place_kinds_off", []) if args.user and args.user.exists() else []
    rules = {k: v for k, v in rules.items() if k not in off}
    places = _places(osm, proj, area, buildings, unary_union([ln for _, ln in streets]) if streets else None, rules)
    named_ids = {b[2].get("@id", ""): b[2].get("name", "") for b in buildings}
    by_id = {b[2].get("@id", ""): b for b in buildings}
    # a small shop building gets a generic storefront model (common/storefronts)
    # as wide as its street side allows; the rest of its footprint stays a building
    street_union = unary_union([ln for _, ln in streets]) if streets else None
    storefronts = []
    for pl in places:
        sf = rules[pl["kind"]].get("storefront")
        bid = pl["building"]
        if not sf or not bid or bid in models or bid not in by_id or street_union is None:
            continue
        poly, h, t = by_id[bid]
        if not (30.0 <= poly.area <= 450.0 and h <= 9.0):
            # a shop on the ground floor of a bigger building: a street-level
            # module in front of its facade (the building stays as it is)
            if sf.get("module"):
                got = _storefront_fit(poly, street_union, {"widths": sf.get("module_widths", [4, 6, 8]), "depth": 8.0})
                if got:
                    rect, cx, cy, nx, ny, w = got
                    cx, cy = cx + nx * 0.25, cy + ny * 0.25          # its front just outside the wall
                    door_y = TERRAIN(cx + nx * 4.0, cy + ny * 4.0) if TERRAIN else 0.0     # at the pavement in front
                    storefronts.append({"id": bid + "#module", "model": sf["module"] % w, "place": pl["kind"],
                                        "pos": [round(cx, 3), round(float(door_y), 3), round(-cy, 3)],
                                        "yaw": round(math.atan2(-nx, ny), 4), "solid": True,
                                        "caption": pl["name"] or rules[pl["kind"]].get("caption", "")})
                    pl["model"] = sf["module"] % w
            continue
        got = _storefront_fit(poly, street_union, sf)
        if not got:
            continue
        rect, cx, cy, nx, ny, w = got
        rest = poly.difference(rect.buffer(0.05))
        parts = [g for g in getattr(rest, "geoms", [rest]) if g.geom_type == "Polygon" and g.area > 6.0]
        idx = next(i for i, b in enumerate(buildings) if b[2].get("@id") == bid)
        if parts:
            buildings[idx] = (max(parts, key=lambda g: g.area), h, t)
        else:
            buildings.pop(idx)
        by_id.pop(bid, None)
        door_y = TERRAIN(cx + nx * float(sf.get("depth", 12)) / 2.0, cy + ny * float(sf.get("depth", 12)) / 2.0) if TERRAIN else 0.0
        storefronts.append({"id": bid, "model": sf["shop"] % w, "place": pl["kind"],
                            "pos": [round(cx, 3), round(float(door_y), 3), round(-cy, 3)],
                            "yaw": round(math.atan2(-nx, ny), 4),        # its front (-Z) to the street
                            "solid": True, "caption": pl["name"] or rules[pl["kind"]].get("caption", "")})
        pl["model"] = sf["shop"] % w
    shell_of = {}       # building id -> place: a small shop the game builds as a walk-in shell
    for pl in places:
        rule = rules[pl["kind"]]
        bid = pl["building"]
        if not rule.get("interior") or not bid or bid in models or bid not in by_id or pl.get("model"):
            continue
        poly, h, _t = by_id[bid]
        if 25.0 <= poly.area <= 260.0 and h <= 7.5:
            models[bid] = "@shell"
            shell_of[bid] = pl
            pl["shell"] = True
    for pl in places:
        model = rules[pl["kind"]].get("model")
        bid = pl["building"]
        if not model or not bid or bid in models:
            continue
        if named_ids.get(bid):
            continue          # a named building (a real shop of its own) keeps its walls
        # the forecourt's little shop or canopy: the hand-made model takes its place
        models[bid] = model
        fits[bid] = {"at": pl["at"], "yaw": math.degrees(pl["yaw"]),
                     "caption": pl["name"] or rules[pl["kind"]].get("caption", "")}
        pl["model"] = model
    # a landmark in parts (site.json) stands on its own outline: generated
    # buildings it covers for the most part go (OSM often maps a porch or an
    # annex as a building of its own)
    user_all = json.loads(args.user.read_text()) if args.user and args.user.exists() else {}
    site_rects = []
    spots = [(bid, f["at"][0], f["at"][1], float(f.get("yaw", 0.0)), f["model"]) for bid, f in fits.items()
             if str(f.get("model", "")).endswith("site.json") and "at" in f]
    spots += [(None, p["x"], p["z"], float(p.get("yaw", 0.0)), p["model"]) for p in user_all.get("_props", [])
              if str(p.get("model", "")).endswith("site.json") and not p.get("parts")]
    for bid, gx, gz, yaw_deg, model in spots:
        f = Path(__file__).resolve().parents[2] / "godot" / model.replace("res://", "")
        if not f.exists():
            continue
        site = json.loads(f.read_text())
        sx, _sy, sz = site.get("size_m", [0, 0, 0])
        y = math.radians(yaw_deg)
        ax, az = (math.cos(y), math.sin(y)), (math.sin(y), -math.cos(y))     # the model's X and Z in map metres
        cx, cy = gx, -gz
        corners = [(cx + ax[0] * sx / 2 * i + az[0] * sz / 2 * j, cy + ax[1] * sx / 2 * i + az[1] * sz / 2 * j)
                   for i, j in ((1, 1), (-1, 1), (-1, -1), (1, -1))]
        from shapely.geometry import Polygon as _P
        e = site.get("entry", [0, 0, 0])
        # the entrance in map metres (az is the model's local +Z; its front is -Z)
        entry = Point(cx + ax[0] * e[0] + az[0] * e[2], cy + ax[1] * e[0] + az[1] * e[2])
        site_rects.append((bid, _P(corners), entry))
    n_cleared = n_cut = 0
    for i, (poly, h, t) in enumerate(buildings):
        bid = t.get("@id", "")
        if bid in models:
            continue
        for own, rect, entry in site_rects:
            if bid != own and poly.distance(entry) < 3.0:
                models[bid] = "@gone"           # in front of the landmark's door
                n_cleared += 1
                break
            if bid == own or not poly.intersects(rect):
                continue
            cut = poly.difference(rect.buffer(0.3, join_style=2))
            cut = max(parts_of(cut), key=lambda g: g.area) if not cut.is_empty else None
            if cut is None or cut.area < 0.6 * poly.area or cut.area < 12.0 or cut.buffer(-1.5).is_empty:
                models[bid] = "@gone"           # mostly under the landmark, or only a sliver left of it
                n_cleared += 1
                break
            if cut.area < poly.area - 0.5:
                poly = cut                      # trimmed back to the landmark's wall
                buildings[i] = (poly, h, t)
                n_cut += 1
    if site_rects:
        print(f"landmarks in parts: {len(site_rects)}; generated buildings under them: {n_cleared} cleared, {n_cut} trimmed")
    # a placed model takes its whole lot: small unnamed buildings on it go
    for pl in places:
        model = rules[pl["kind"]].get("model")
        if not model or not pl.get("model") and pl["building"]:
            continue
        lot = Point(pl["at"][0], -pl["at"][1]).buffer(float(rules[pl["kind"]].get("clear_m", 12)))
        for poly, h, t in buildings:
            bid = t.get("@id", "")
            if bid in models or t.get("name") or poly.area > 600 or not poly.intersects(lot):
                continue
            if poly.intersection(lot).area > 0.25 * poly.area:
                models[bid] = "@gone"
    # a newsstand mapped as a building (shop=newsagent / kiosk, a few m² on a
    # pavement) is the game's banca: the box goes, the model stands in its place
    kiosks = []
    for poly, h, t in buildings:
        bid = t.get("@id", "")
        if bid in models or poly.area > 30 or not (t.get("building") == "kiosk" or t.get("amenity") == "kiosk"
                                                  or t.get("shop") in ("kiosk", "newsagent")):
            continue
        models[bid] = "@gone"
        c = poly.centroid
        kiosks.append((c.x, c.y))
    if kiosks:
        print(f"newsstands mapped as buildings, now the banca model: {len(kiosks)}")
    roads = []          # (kind, oneway, LineString)
    named = []          # (name, LineString) of streets that get corner name signs
    for el in osm:
        t = el.get("tags", {})
        if el["type"] == "way" and "highway" in t and len(el.get("geometry", [])) >= 2:
            from shapely.geometry import LineString
            ln = LineString([proj(p["lat"], p["lon"]) for p in el["geometry"]])
            # calçadões are often mapped as ordinary streets closed to motor
            # traffic: render and treat them as pedestrian promenades
            kind = "pedestrian" if car_free(t) and t["highway"] in VEHICLE_ROADS else t["highway"]
            roads.append((kind, t.get("oneway") == "yes", ln))
            if t.get("name") and t["highway"] in VEHICLE_ROADS | PEDESTRIAN_ROADS:
                named.append((t["name"], ln))
    # with --ring the traffic keeps to the outer road loop and what is inside it
    # (no car drives into a street that ends at the border); the streets are
    # still all drawn
    traffic_roads = _ring_roads(roads, box(*(args.bounds or (-args.half, -args.half, args.half, args.half))))\
        if args.ring else roads
    batch = Batch()
    images = {}        # key -> PIL base colour
    normals = {}       # key -> PIL normal map (glTF/OpenGL)
    roughs = {}        # key -> PIL roughness (grey)

    def tex(key, path):
        if key not in images:
            images[key] = Image.open(path).convert("RGB")
        return key

    def pbr(key, tint=None, tint_strength=0.4):
        """Register an ambientCG material (optionally tinted) and return its key."""
        folder, _, _ = PBR[key.split("@")[0]]
        if key not in images:
            if folder.startswith("kit:"):
                kit = args.materials.parent / "common" / "facades_kit" / folder[4:]
                paths = (f"{kit}_basecolor.png", f"{kit}_normal.png", f"{kit}_roughness.png")
            else:
                paths = (args.materials / folder / "color.jpg", args.materials / folder / "normalgl.jpg",
                         args.materials / folder / "roughness.jpg")
            base = Image.open(paths[0]).convert("RGB")
            if tint is not None:
                arr = np.asarray(base, float)
                mean = arr.reshape(-1, 3).mean(0)
                tinted = arr * (np.asarray(tint) / np.maximum(mean, 1))
                base = Image.fromarray((arr * (1 - tint_strength) + tinted * tint_strength).clip(0, 255).astype(np.uint8))
            images[key] = base
            normals[key] = Image.open(paths[1]).convert("RGB")
            roughs[key] = Image.open(paths[2]).convert("L")
        return key

    def tile(key):
        _, w, h = PBR[key.split("@")[0]]
        return w, h

    rng = np.random.default_rng(1)
    n_real = n_inherit = n_kit = 0
    occluders = []      # (footprint inset, base, top) of the solid buildings
    # the block (or the whole map) whose generated buildings get the kit's facades
    # (its own random choices: the other buildings look as they did)
    kit_area = None
    kit_rng = np.random.default_rng(11)
    if args.kit_facades == "all":
        kit_area = area
    elif args.kit_facades:
        from shapely.ops import polygonize
        kx, kz = map(float, args.kit_facades.split(","))
        street_lines = [ln for k, _, ln in roads if k in VEHICLE_ROADS | PEDESTRIAN_ROADS]
        kit_area = next((f for f in polygonize(unary_union(street_lines)) if f.contains(Point(kx, -kz))), None)
        print("kit facades: block of %.0f m2 round (%.0f, %.0f)" % (kit_area.area if kit_area else 0, kx, kz))
    photo_walls = []    # (p0, p1) of walls showing a real photo
    # every building with its OSM identity, for the in-game editor (pick a
    # building, change it, send the change back to OpenStreetMap)
    building_index = []
    for poly, h, tags in buildings:
        ring = list(poly.simplify(0.3).exterior.coords)[:-1]
        building_index.append({
            "id": tags.get("@id", ""), "name": tags.get("name", ""), "height": round(float(h), 2),
            "base": round(float(TERRAIN.lowest(poly)) if TERRAIN else 0.0, 2),
            "levels": tags.get("building:levels", ""), "osm_height": tags.get("height", ""),
            "street": tags.get("addr:street", ""), "number": tags.get("addr:housenumber", ""),
            "ring": [[round(x, 2), round(-y, 2)] for x, y in ring]})
    landmarks = []
    landmark_polys = []     # their footprints: infill must not poke into them (interiors)
    shells = []
    landmarks.extend(storefronts)
    # pitches and playgrounds OSM maps: a five-a-side pitch, a playground
    for lm, poly in _leisure_models(osm, proj, area, args.materials.parent, models):
        landmarks.append(lm)
        landmark_polys.append(poly)
    for bi, (poly, h, tags) in enumerate(buildings):
        if models.get(tags.get("@id")) == "@gone":
            continue                             # cleared (for a hand-made model next to it)
        if models.get(tags.get("@id")) == "@shell":
            # a small shop: the game builds its walls, window, door and sign
            # around the interior set (main.gd _shells); only its outline here
            pl = shell_of[tags["@id"]]
            ring = list(poly.simplify(0.2).exterior.coords)[:-1]
            if poly.exterior.is_ccw:
                ring = ring[::-1]
            shells.append({"id": tags["@id"], "kind": pl["kind"], "name": pl["name"],
                           "ring": [[round(x, 2), round(-y, 2)] for x, y in ring],
                           "base": round(float(TERRAIN.front(poly, street_union)) if TERRAIN else 0.0, 3),
                           "height": round(float(min(max(h, 3.6), 5.0)), 2),
                           "interior": rules[pl["kind"]]["interior"],
                           "caption": pl["name"] or rules[pl["kind"]].get("caption", "")})
            landmark_polys.append(poly)
            continue
        if tags.get("@id") in models:
            # a hand-made model stands here (tools/blender/landmarks.py): only
            # record where and how it is turned; the footprint still counts
            # as built-up for the infill and the streets
            rect = poly.minimum_rotated_rectangle
            xs, ys = rect.exterior.coords.xy
            ex, ey = xs[1] - xs[0], ys[1] - ys[0]
            c = rect.centroid
            landmarks.append({"id": tags["@id"], "model": models[tags["@id"]],
                              "pos": [round(c.x, 3), round(TERRAIN.front(poly, street_union) if TERRAIN else 0.0, 3), round(-c.y, 3)],
                              "yaw": round(math.atan2(ey, ex), 4)})
            fit = fits.get(tags["@id"], {})
            if "at" in fit:
                # a model built in map coordinates: its own spot (x, z) and turn (degrees)
                landmarks[-1]["pos"][0], landmarks[-1]["pos"][2] = float(fit["at"][0]), float(fit["at"][1])
                landmarks[-1]["yaw"] = round(math.radians(float(fit.get("yaw", 0.0))), 4)
            if tags["@id"] in films:
                landmarks[-1]["film"] = films[tags["@id"]]
            for key in ("scale", "yaw_offset", "caption"):   # fitting a model to its footprint; its sign
                if key in fits.get(tags["@id"], {}):
                    landmarks[-1][key] = fits[tags["@id"]][key]
            landmark_polys.append(poly)
            continue
        if tags.get("man_made") == "chimney":
            _chimney(batch, pbr("brick"), poly, h, tile("brick"))
            continue
        pts = osmcity.ring_points(poly, outer=False)
        base = TERRAIN.lowest(poly) if TERRAIN else 0.0
        top = base + h
        walls = []
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            p0, p1 = (a[0] / U, -a[1] / U), (b[0] / U, -b[1] / U)
            walls.append((p0, p1, real.get(f"{a[0]},{a[1]},{b[0]},{b[1]}")))
        donors = [w[2] for w in walls if w[2]]
        donor = max(donors, key=lambda r: r["w_px"]) if donors else None
        # facade for unphotographed walls: brick for low/old buildings, glass or
        # concrete for towers; tinted with the building's real colour if known
        family = low_facade(tags, rng) if h <= 12 else TALL_FACADES[rng.integers(len(TALL_FACADES))]
        if donor:
            colour = np.asarray(Image.open(Path(donor["file"])).convert("RGB"), float).reshape(-1, 3).mean(0)
            # a handful of shared tints keeps the scene small (one texture set each)
            k = int(np.argmin([np.sum((colour - np.asarray(c)) ** 2) for c in TINTS]))
            gkey = pbr(f"{family}@t{k}", tint=TINTS[k], tint_strength=0.45)
        else:
            gkey = pbr(family)
        tw, th = tile(gkey)
        kit = None
        if kit_area is not None and kit_area.contains(poly.centroid):
            style = kit_style(h, kit_rng)
            k = int(kit_rng.integers(len(TINTS)))
            tint = (TINTS[k], 0.3 if style != "contemporaneo" else 0.15)
            ground_kind = "shop" if (tags.get("shop") or tags.get("amenity") or kit_rng.random() < 0.4) else "ground"
            kit = (style, ground_kind, k, tint)
            n_kit += 1
        for p0, p1, r in walls:
            L = math.dist(p0, p1)
            if r:
                key = tex(_short(r["file"]), Path(r["file"]))
                wall(batch, key, p0, p1, top, 1.0, 1.0, 0.0, -0.6, top_abs=True)
                photo_walls.append((p0, p1))
                n_real += 1
            elif donor and L <= INHERIT_MAX_M:
                key = tex(_short(donor["file"]), Path(donor["file"]))
                wall(batch, key, p0, p1, top, L * REAL_PX_PER_M / donor["w_px"], 1.0, 0.0, -0.6, top_abs=True)
                n_inherit += 1
            elif kit:
                kit_wall(batch, pbr, kit, p0, p1, h, top)
            else:
                # the street level gets doors and shop windows; the facade starts above it
                gk = pbr(ground_family(family))
                if h >= GROUND_M + 1.0:
                    wall(batch, gk, p0, p1, GROUND_M, L / 8.0, 1.0, -0.6 / GROUND_M, -0.6)
                    wall(batch, gkey, p0, p1, top, L / tw, (h - GROUND_M) / th, 0.0, GROUND_M, top_abs=True)
                else:
                    wall(batch, gk, p0, p1, top, L / 8.0, h / GROUND_M, -0.6 / GROUND_M, -0.6, top_abs=True)
        roof = pbr("tile_roof") if h <= 6 else pbr("concrete_roof")
        batch.poly(roof, list(poly.exterior.coords), top, tile(roof)[0], absolute=True)
        if h >= OCCLUDER_MIN_H and poly.area > 40.0:
            core = poly.buffer(-0.6, join_style=2)
            for piece in parts_of(core):
                if piece.area > 20.0:
                    occluders.append((piece.simplify(0.5), base + 0.3, top - 0.5))

    # Walkable space = the connected street network at least MIN_PASSAGE_M
    # wide. Everything else that is not a building (slits left by the Build
    # erosion, alleys too narrow to use, enclosed courtyards) becomes solid
    # infill as tall as its lowest neighbour. Courtyards would otherwise be
    # navmesh islands where the director could spawn robots that shoot
    # through cracks. Infill overlaps the buildings slightly: an exact or
    # gapped seam shows as a see-through crack.
    # a building removed by hand (@gone) is open ground, not built-up; so is the
    # lot of a landmark in parts (site.json): its model is often smaller than the
    # OSM outline (the Piratini's annexes, the Catedral's steps), and the ground
    # round it must be there - the model stands on it
    footprint0 = unary_union([b[0] for b in buildings if models.get(b[2].get("@id")) != "@gone"
                              and not str(models.get(b[2].get("@id"), "")).endswith("site.json")])
    open_space = area.difference(footprint0)
    opened = open_space.buffer(-MIN_PASSAGE_M / 2, join_style=2).buffer(MIN_PASSAGE_M / 2, join_style=2)
    streets_open = max(parts_of(opened), key=lambda g: g.area).intersection(open_space)
    closed = area.difference(streets_open)            # buildings + infill
    infill = closed.difference(footprint0)
    n_fill = 0
    plaster = pbr("plaster")
    for gap in parts_of(infill):
        if gap.area < 0.02:
            continue
        near = [h for poly, h, _ in buildings if poly.distance(gap) < 0.2]
        # lowest neighbour: above it there is no slit any more, only the taller
        # building's own side wall; the tallest one made thin slabs stick out
        # high above the roofs
        fh = min(near) if near else 6.0
        # infill reads as a building of its own: same facade families as the
        # real ones (plain plaster only on short returns)
        fam = low_facade({}, rng) if fh <= 12 else TALL_FACADES[rng.integers(len(TALL_FACADES))]
        fam_key = pbr(fam)
        ftw, fth = tile(fam_key)
        solid = gap.buffer(INFILL_OVERLAP_M, join_style=2).intersection(area)
        if landmark_polys:
            solid = solid.difference(unary_union(landmark_polys).buffer(0.05, join_style=2))
        for piece in parts_of(solid):
            fbase = TERRAIN.lowest(piece) if TERRAIN else 0.0
            ftop = fbase + fh
            cs = list(orient(piece, 1.0).exterior.coords)
            for a2, b2 in zip(cs[:-1], cs[1:]):
                L = math.dist(a2, b2)
                if covers_photo(a2, b2, photo_walls):
                    continue        # a sliver skin over a photographed facade: leave the photo visible
                if L < 1.5:
                    wall(batch, plaster, a2, b2, ftop, L / 3.0, fh / 3.0, 0.0, -0.6, top_abs=True)
                else:
                    wall(batch, fam_key, a2, b2, ftop, L / ftw, fh / fth, 0.0, -0.6, top_abs=True)
            batch.polygon(pbr("concrete_roof"), piece, ftop + 0.01, 4.0, absolute=True)
            n_fill += 1
    print("infill pieces:", n_fill)
    if kit_area is not None:
        print("buildings with kit facades:", n_kit)

    # ---- street surfaces: asphalt, pedestrian promenades, sidewalks, grass ----
    # asphalt only where cars drive (the carriageway), paving on footways,
    # squares and plazas, a raised sidewalk only where a building faces a
    # street; every other open piece - gaps between buildings, the backs of
    # lots, verges - is grass at the ground's own level
    footprint = closed
    street_surface = area.difference(closed.buffer(-0.05, join_style=2))
    walk_lines = [ln for k, _, ln in roads if k in VEHICLE_ROADS | PEDESTRIAN_ROADS | {"service", "footway"}]
    near_street = unary_union([carriageway.buffer(SIDEWALK_M + 1.5, join_style=2)]
                              + [ln.buffer(SIDEWALK_M + 3.0) for ln in walk_lines])
    blocks = footprint.buffer(SIDEWALK_M, join_style=2).intersection(area.buffer(-0.5)).intersection(near_street)
    pedestrian = unary_union([ln.buffer(6.0, cap_style=2) for k, _, ln in roads if k in PEDESTRIAN_ROADS] or [Point(9e9, 9e9).buffer(0.1)])
    pedestrian = pedestrian.intersection(street_surface).difference(blocks)
    # open space far from any carriageway (esplanades, big squares, open
    # lots) is a paved plaza rather than asphalt
    lanes = [ln for k, _, ln in roads if k in VEHICLE_ROADS]
    roadway = unary_union([ln.buffer(16.0) for ln in lanes]) if lanes else Point(9e9, 9e9).buffer(0.1)
    plaza = street_surface.difference(pedestrian).difference(roadway).intersection(_squares(osm, proj))
    # buildings_user.json "_asphalt": [[x, z], ...] game points; the paved
    # piece (plaza or footway strip) under each one is laid as asphalt instead
    to_asphalt = [Point(x, -z) for x, z in (json.loads(args.user.read_text()).get("_asphalt", [])
                                            if args.user and args.user.exists() else [])]
    if to_asphalt:
        def keep_paved(geom):
            parts = [g for g in parts_of(geom) if not any(g.buffer(0.5).contains(pt) for pt in to_asphalt)]
            return unary_union(parts) if parts else Point(9e9, 9e9).buffer(0.1)
        plaza, pedestrian = keep_paved(plaza), keep_paved(pedestrian)
    pedestrian = unary_union([pedestrian, plaza]).intersection(street_surface)
    tarmac = carriageway.union(unary_union([Point(p.x, p.y).buffer(4.0) for p in to_asphalt]) if to_asphalt else carriageway)
    asphalt_area = street_surface.intersection(tarmac)          # a footway crossing the street does not cut it
    pedestrian = pedestrian.difference(asphalt_area)
    # the gap between the kerb line and the footprint's sidewalk, too narrow for
    # grass, is part of the street
    # in town the asphalt's edge is a pavement, not grass: a SIDEWALK_M strip along
    # every car street where buildings are near (a street narrower in OSM than
    # the gap between its buildings left a lawn between kerb and facade); parks
    # and squares away from buildings keep their grass to the kerb
    kerb_walk = carriageway.buffer(SIDEWALK_M, join_style=2).difference(carriageway) \
        .intersection(footprint.buffer(25.0)).intersection(street_surface).difference(pedestrian)
    blocks = unary_union([blocks, kerb_walk])
    sidewalks0 = blocks.difference(footprint.buffer(0.05))
    lawn = street_surface.difference(asphalt_area).difference(pedestrian).difference(sidewalks0)
    slivers = [g for g in parts_of(lawn) if g.area < 4.0 or g.buffer(-0.6).is_empty]
    if slivers:
        asphalt_area = asphalt_area.union(unary_union(slivers).intersection(near_street))
        lawn = lawn.difference(asphalt_area)
    asphalt_area = unary_union([g for g in parts_of(asphalt_area) if g.geom_type == "Polygon"])   # no stray lines
    for piece in parts_of(asphalt_area):
        batch.polygon(pbr("asphalt"), piece, 0.0, tile("asphalt")[0])
    for piece in parts_of(pedestrian):
        batch.polygon(pbr("paving"), piece, 0.0, tile("paving")[0])
    for piece in parts_of(lawn):
        if piece.area > 0.5:
            batch.polygon(pbr("grass"), piece, 0.0, tile("grass")[0])
    print("ground: asphalt %.0f m2, paving %.0f m2, grass %.0f m2" % (asphalt_area.area, pedestrian.area, lawn.area))

    sidewalks = blocks.difference(footprint.buffer(0.05))
    sw_key, curb_key = pbr("sidewalk"), pbr("curb")
    # Collision for sidewalks is exported separately: the 15 cm curb becomes a
    # 35 cm ramp (about 23 degrees) so capsules walk up without jumping; the
    # visual curb stays a sharp step. A trimesh curb edge sits between two
    # triangles and is reported as a vertical wall, which blocks capsules.
    col = Batch()
    col_key = "collision"
    images.setdefault(col_key, Image.new("RGB", (4, 4), (128, 128, 128)))
    lamps, curb_lines = [], []
    near_kerb = prep(carriageway.buffer(1.5)) if carriageway is not None and not carriageway.is_empty else prep(box(0, 0, 0, 0))
    for part in parts_of(sidewalks):
        if part.area < 1:
            continue
        batch.polygon(sw_key, part, CURB_M, tile("paving")[0])
        ring = orient(part, 1.0).exterior
        if TERRAIN:
            ring = ring.segmentize(TESSELLATE_M)
        cs = list(ring.coords)
        for a, b in zip(cs[:-1], cs[1:]):
            wall(batch, curb_key, a, b, CURB_M, math.dist(a, b) / 2.0, 0.075, 0.0)
            _ramp(col, col_key, a, b, RAMP_M, CURB_M)
        for inset in parts_of(part.buffer(-RAMP_M + 0.05, join_style=2)):
            col.polygon(col_key, inset, CURB_M, 1.0)
        curb_lines.append(ring)
        # lamps 0.5 m in from the curb - on the street side only (the ring also
        # runs along the fronts, round corner scraps and islands: half the lamps
        # of a map stood within 8 m of another); spacing evened out below
        if part.area < LAMP_MIN_WALK_M2:
            continue
        for inset in parts_of(part.buffer(-0.5)):
            line = inset.exterior
            for dd in np.arange(LAMP_SPACING_M / 2, line.length, LAMP_SPACING_M / 5):
                q = line.interpolate(dd)
                if near_kerb.contains(q):
                    lamps.append((q.x, q.y))
    for park in parks:
        batch.poly(pbr("grass"), list(park.exterior.coords), 0.03, tile("grass")[0])

    # ---- water (lake/river shore): surface below the quay, quay wall, and a
    # collision parapet so nobody walks off the edge -------------------------
    map_box = box(*(args.bounds or (-args.half, -args.half, args.half, args.half)))
    water = osmcity.water_polygon({"elements": osm}, proj, map_box)
    n_quay = 0
    if water is not None and not water.is_empty:
        images.setdefault("water", Image.new("RGB", (8, 8), (40, 70, 80)))
        shore_ground = min(ground(*c) for g in parts_of(water) for c in g.exterior.coords)
        water_level = shore_ground + WATER_Y
        for piece in parts_of(water):
            batch.polygon("water", piece, water_level, 20.0, absolute=True)
            ring = orient(piece, -1.0).exterior            # clockwise: the water is on the right
            cs = list(ring.coords)
            bx0, by0, bx1, by1 = map_box.bounds
            for a, b in zip(cs[:-1], cs[1:]):
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                if min(abs(mx - bx0), abs(mx - bx1), abs(my - by0), abs(my - by1)) < 0.5:
                    continue                                  # map border, not the shore
                L = math.dist(a, b)
                wall(batch, pbr("quay"), a, b, 0.0, L / 3.0, 1.0, 0.0, water_level - 0.3, bot_abs=True)
                wall(col, col_key, a, b, 1.3, 1.0, 1.0, 0.0, -0.5)      # invisible parapet
                wall(col, col_key, b, a, 1.3, 1.0, 1.0, 0.0, -0.5)
                n_quay += 1
    print(f"water: {round(water.area) if water is not None else 0} m2, {n_quay} quay segments")

    # ---- road markings (Brazilian style) --------------------------------------
    paint_ok = asphalt_area.buffer(-0.35, join_style=2)
    white = tex("paint_white", _paint(args.textures, "paint_white.png", (235, 235, 230)))
    yellow = tex("paint_yellow", _paint(args.textures, "paint_yellow.png", (235, 185, 40)))
    from shapely.geometry import LineString
    from shapely.ops import substring
    n_marks = 0
    vehicle = [(one, ln) for k, one, ln in roads if k in VEHICLE_ROADS]
    for one, ln in vehicle:
        if one:      # one-way: white dashed lane line on the centre
            for d0 in np.arange(2.0, ln.length - 3.0, 8.0):
                seg = substring(ln, d0, min(d0 + 3.0, ln.length))
                n_marks += _paint_poly(batch, white, seg.buffer(0.07, cap_style=2).intersection(paint_ok))
        else:        # two-way: double solid yellow centre line
            for off in (-0.12, 0.12):
                try:
                    side = ln.parallel_offset(off, "left")
                except Exception:
                    continue
                n_marks += _paint_poly(batch, yellow, side.buffer(0.06, cap_style=2).intersection(paint_ok))
    # zebra crossings where OpenStreetMap has them (highway=crossing nodes on
    # a road, unless "unmarked"); a map without that data gets one near every
    # junction of vehicle roads instead
    def _zebra_at(ln, d):
        nonlocal n_marks, n_cross
        d = max(0.5, min(ln.length - 0.5, d))
        p = ln.interpolate(d)
        q = ln.interpolate(min(ln.length, d + 0.5))
        r = ln.interpolate(max(0.0, d - 0.5))
        tx, ty = q.x - r.x, q.y - r.y
        tl = math.hypot(tx, ty) or 1.0
        tx, ty = tx / tl, ty / tl
        nx, ny = -ty, tx
        stripes = []
        for k in range(-12, 13):
            cx, cy = p.x + nx * k * 1.0, p.y + ny * k * 1.0
            stripes.append(LineString([(cx - tx * 1.5, cy - ty * 1.5), (cx + tx * 1.5, cy + ty * 1.5)]).buffer(0.25, cap_style=2))
        n_cross += 1
        zebras.append([round(p.x, 2), round(-p.y, 2), round(nx, 3), round(-ny, 3)])
        n_marks += _paint_poly(batch, white, unary_union(stripes).intersection(paint_ok))

    n_cross = 0
    zebras = []          # [x, z, across_x, across_z] in game coordinates: pedestrians cross here
    osm_cross = []
    for el in osm:
        t = el.get("tags", {})
        if el["type"] == "node" and t.get("highway") == "crossing" and t.get("crossing") not in ("unmarked", "no") \
                and t.get("crossing:markings") != "no":
            osm_cross.append(Point(proj(el["lat"], el["lon"])))
    ends = defaultdict(list)
    for idx, (one, ln) in enumerate(vehicle):
        for c in (ln.coords[0], ln.coords[-1]):
            ends[(round(c[0], 1), round(c[1], 1))].append(idx)
    junctions = []
    for pt, ids in ends.items():
        touching = {i for i in ids} | {i for i, (_, ln) in enumerate(vehicle) if ln.distance(Point(pt)) < 0.5}
        if len(touching) >= 2:
            junctions.append(Point(pt))
    if len(osm_cross) >= 3:
        taken = []
        for c in osm_cross:
            best = min(vehicle, key=lambda v: v[1].distance(c), default=None)
            if best is None or best[1].distance(c) > 4.0:
                continue
            ln = best[1]
            if any(c.distance(o) < 6.0 for o in taken):
                continue                     # one node per lane pair, not two zebras on top of each other
            taken.append(c)
            _zebra_at(ln, ln.project(c))
    else:
        for j in junctions:
            for _, ln in vehicle:
                if ln.distance(j) > 0.5 or ln.length < 14:
                    continue
                d_j = ln.project(j)
                _zebra_at(ln, d_j + 7.0 if d_j < ln.length / 2 else d_j - 7.0)
    print(f"road markings: {n_marks} pieces, {n_cross} crossings")

    # ---- horizon: ground out to 600 m and a ring of distant towers -------------
    sky = Batch()
    from shapely.geometry import box as sbox
    mx0, my0, mx1, my1 = map_box.bounds
    far = sbox(mx0 - 600, my0 - 600, mx1 + 600, my1 + 600)
    far_water = osmcity.water_polygon({"elements": osm}, proj, far)
    ring = far.difference(map_box.buffer(-0.2, join_style=2))
    if far_water is not None and not far_water.is_empty:
        for piece in parts_of(far_water.difference(map_box)):
            images.setdefault("water", Image.new("RGB", (8, 8), (40, 70, 80)))
            sky.polygon("water", piece, (water_level if water is not None and not water.is_empty else WATER_Y), 40.0, absolute=True)
        ring = ring.difference(far_water)
    for piece in parts_of(ring):
        sky.polygon(pbr("asphalt"), piece, -0.02, 12.0, cell=25.0)
    srng = np.random.default_rng(11)
    half = max(abs(mx0), abs(my0), mx1, my1)
    n_sky = 0
    for k in range(140):
        ang = srng.uniform(0, math.tau)
        dist = srng.uniform(half + 25, half + 260)
        cx, cy = math.cos(ang) * dist, math.sin(ang) * dist
        if mx0 - 15 < cx < mx1 + 15 and my0 - 15 < cy < my1 + 15:
            continue
        if far_water is not None and far_water.buffer(25).contains(Point(cx, cy)):
            continue                                          # no towers in the lake
        w, d = srng.uniform(14, 34), srng.uniform(14, 34)
        hh = float(srng.choice([srng.uniform(12, 30), srng.uniform(30, 75)], p=[0.6, 0.4]))
        rot = srng.uniform(0, math.pi)
        corners = [(cx + math.cos(rot) * sx * w / 2 - math.sin(rot) * sy * d / 2,
                    cy + math.sin(rot) * sx * w / 2 + math.cos(rot) * sy * d / 2)
                   for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        fam = pbr("facade_brick" if hh <= 20 else TALL_FACADES[srng.integers(len(TALL_FACADES))])
        ftw, fth = tile(fam)
        tbase = min(ground(*c) for c in corners) if TERRAIN else 0.0
        for a2, b2 in zip(corners, corners[1:] + corners[:1]):
            wall(sky, fam, a2, b2, tbase + hh, math.dist(a2, b2) / ftw, hh / fth, -1.0, top_abs=True)
        sky.poly(pbr("concrete_roof"), corners + corners[:1], tbase + hh, 6.0, absolute=True)
        n_sky += 1
    _export(sky, images, normals, roughs, args.out.with_name(args.out.stem + "_horizon.glb"))
    _export(col, images, normals, roughs, args.out.with_name(args.out.stem + "_collision.glb"))
    print("horizon towers:", n_sky)

    if ATLAS_PX:
        _atlas_photos(batch, images, normals)
    scene = trimesh.Scene()
    n_pieces = 0
    for key in batch.v:
        mat_kwargs = dict(name=Path(key).stem, baseColorTexture=images[key], metallicFactor=0.0, roughnessFactor=0.9)
        if key in normals:
            # glTF packs roughness in G and metallic in B
            r = roughs[key]
            zero = Image.new("L", r.size, 0)
            mat_kwargs.update(normalTexture=normals[key],
                              metallicRoughnessTexture=Image.merge("RGB", (zero, r, zero)),
                              roughnessFactor=1.0)
        mat = trimesh.visual.material.PBRMaterial(**mat_kwargs)
        V = np.array(batch.v[key])
        F = np.array(batch.f[key])
        UV = np.array(batch.uv[key])
        # one mesh per CITY_CELL_M square of the map (the material shared by
        # all): the renderer leaves out the cells off screen or hidden, which
        # one map-wide mesh per material never let it do
        cent = V[F].mean(axis=1)
        cells = np.floor(cent[:, [0, 2]] / CITY_CELL_M).astype(int) if CITY_CELL_M > 0 else np.zeros((len(F), 2), int)
        for cell in np.unique(cells, axis=0):
            sel = np.all(cells == cell, axis=1)
            used = np.unique(F[sel])
            remap = np.full(len(V), -1)
            remap[used] = np.arange(len(used))
            mesh = trimesh.Trimesh(vertices=V[used], faces=remap[F[sel]],
                                   visual=trimesh.visual.TextureVisuals(uv=UV[used], material=mat), process=False)
            keep = mesh.area_faces > 1e-6            # degenerate triangles give NaN normals (invalid glTF JSON)
            if not keep.all():
                mesh.update_faces(keep)
            if len(mesh.faces) == 0:
                continue
            # computing normals makes trimesh export NORMAL; without it Godot gets no sun shading
            mesh.vertex_normals = np.nan_to_num(mesh.vertex_normals, nan=0.0) + np.where(
                np.isnan(mesh.vertex_normals).any(1, keepdims=True), [0, 1, 0], 0)
            name = f"{Path(key).stem}__c{cell[0]}_{cell[1]}"
            scene.add_geometry(mesh, node_name=name, geom_name=name)
            n_pieces += 1
    args.out.parent.mkdir(parents=True, exist_ok=True)
    scene.export(args.out)
    print(f"city meshes: {len(batch.v)} materials in {n_pieces} pieces" + (f" of {CITY_CELL_M:.0f} m" if CITY_CELL_M > 0 else ""))
    # the solid buildings, for the game's occluders (walls set a little inside
    # the facade so a building never hides itself): [ring x/z, base, top]
    (args.out.with_name(args.out.stem + ".occluders.json")).write_text(json.dumps(
        [[[[round(x, 2), round(-y, 2)] for x, y in r.exterior.coords[:-1]], round(b, 2), round(t, 2)] for r, b, t in occluders]))
    print("occluders:", len(occluders))

    # ---- spawn on a free street point closest to --start ----------------------
    solid = prep(unary_union([b[0] for b in buildings]).buffer(2.5))
    best = None
    for _, line in streets:
        for dd in range(0, int(line.length), 4):
            p = line.interpolate(dd)
            if area.buffer(-5).contains(p) and not solid.contains(p):
                dist = p.distance(Point(*args.start))
                if best is None or dist < best[0]:
                    best = (dist, p)
    spawn = to_godot(best[1].x, best[1].y, 1.0)
    # crowd points: promenades draw more pedestrians (Godot x/z)
    crowd = []
    if not pedestrian.is_empty:
        pp = prep(pedestrian.buffer(-1.0))
        bx0, by0, bx1, by1 = pedestrian.bounds
        for gx in np.arange(bx0, bx1, 5.0):
            for gy in np.arange(by0, by1, 5.0):
                if pp.contains(Point(gx, gy)):
                    crowd.append([round(float(gx), 1), round(float(-gy), 1), round(ground(gx, gy), 2)])
    elev = [0.0, 0.0]
    if TERRAIN:
        hs = [ground(x, y) for x in np.arange(map_box.bounds[0], map_box.bounds[2] + 1, 10.0)
              for y in np.arange(map_box.bounds[1], map_box.bounds[3] + 1, 10.0)]
        elev = [round(min(hs), 2), round(max(hs), 2)]
    bx = map_box.bounds   # Godot x/z: x east, z = -north
    args.out.with_suffix(".spawn.json").write_text(json.dumps({
        "spawn": spawn, "half": args.half, "crowd": crowd, "elev": elev,
        "bounds": [bx[0], bx[2], -bx[3], -bx[1]]}))     # [min_x, max_x, min_z, max_z]

    # ---- road graph for traffic ---------------------------------------------
    graph = _road_graph([(one, ln) for k, one, ln in traffic_roads if k in VEHICLE_ROADS], area)
    graph["crossings"] = zebras
    # named streets for the street-name label and the GPS map: [name, [[x, z], ...]]
    graph["streets"] = []
    for nm, ln in named:
        clipped = ln.intersection(area)
        for part in getattr(clipped, "geoms", [clipped]):
            if part.geom_type == "LineString" and part.length > 5:
                graph["streets"].append([nm, [[round(x, 1), round(-y, 1)] for x, y in part.coords]])
    args.out.with_suffix(".roads.json").write_text(json.dumps(graph))

    # ---- street furniture ---------------------------------------------------
    props = _street_props(osm, proj, area, footprint, sidewalks, parks, asphalt_area, pedestrian,
                          vehicle, junctions, lamps, curb_lines, named,
                          [ln for k, _, ln in roads if k in PEDESTRIAN_ROADS], places, kiosks)
    # buildings_user.json "_remove": [[x, z], ...] game points; the generated
    # prop (tree, lamp, bench...) within 1 m of each is left out
    gone = json.loads(args.user.read_text()).get("_remove", []) if args.user and args.user.exists() else []
    if gone:
        props = [p for p in props if not any(math.hypot(p["pos"][0] - x, p["pos"][2] - z) < 1.0 for x, z in gone)]
    # nothing generated stands in a model placed by hand (a newsstand in the
    # skate pieces, a tree in the pitch): its footprint from the model's size
    hand = json.loads(args.user.read_text()).get("_props", []) if args.user and args.user.exists() else []
    reach = []
    for p in hand:
        r = _model_radius(p.get("model", ""), p.get("parts"))
        if r:
            reach.append((p["x"], p["z"], r * float(p.get("scale", 1.0)) + 0.8))
    if site_rects:
        # nor inside a landmark in parts: its lot is open ground now, its model on it
        inside_sites = prep(unary_union([r.buffer(1.0) for _, r, _ in site_rects]))
        props = [p for p in props if not inside_sites.contains(Point(p["pos"][0], -p["pos"][2]))]
    if reach:
        n0 = len(props)
        props = [p for p in props if p["type"] in ("lamp", "street_sign", "manhole")
                 or not any(math.hypot(p["pos"][0] - x, p["pos"][2] - z) < r + BULK.get(p["type"], 0.0)
                            for x, z, r in reach)]
        print(f"generated props inside hand-placed models: {n0 - len(props)} left out")
    # free-standing pieces placed by hand (monuments, a farroupilha camp):
    # buildings_user.json "_props": [{model, x, z, yaw}], set on the ground -
    # or at an absolute "y" (a boat afloat on the river)
    standing = []                        # (x, z, radius, y) of the pieces placed so far
    for p in (json.loads(args.user.read_text()).get("_props", []) if args.user and args.user.exists() else []):
        if "type" in p:
            # a street-furniture kind placed by hand (e.g. a repair shop where OSM has none)
            gy = TERRAIN(p["x"], -p["z"]) if TERRAIN else 0.0
            props.append({"type": p["type"], "pos": [p["x"], round(float(gy), 3) + 0.15, p["z"]],
                          "yaw": math.radians(p.get("yaw", 0.0))})
            continue
        if not area.contains(Point(p["x"], -p["z"])):
            continue                     # one edits file serves several maps of a city: not on this one
        r = _model_radius(p["model"], p.get("parts")) * float(p.get("scale", 1.0))
        under = next(((sx, sz, sr, sy) for sx, sz, sr, sy in reversed(standing)
                      if math.hypot(p["x"] - sx, p["z"] - sz) < sr * 0.9), None) if p.get("y_offset") else None
        if "y" in p:
            y = p["y"]
        elif under:
            # standing on a piece placed before it (a musician on the stage): its
            # height is the base, not the lawn beneath (a slope sank the guitarist)
            y = under[3] + p["y_offset"]
        else:
            # on a slope a piece with a footprint stands on its lowest point (a
            # stage set by its centre floated on the downhill side)
            lawn_y = (lambda x, z: TERRAIN(x, -z)) if TERRAIN else (lambda x, z: 0.0)
            ring = min(r * 0.7, 6.0)
            y = min([lawn_y(p["x"], p["z"])] + [lawn_y(p["x"] + math.cos(a) * ring, p["z"] + math.sin(a) * ring)
                                                for a in np.linspace(0, math.tau, 8, endpoint=False)] if ring > 0.5 else
                    [lawn_y(p["x"], p["z"])]) + p.get("y_offset", 0.0)
        if r > 0.5:
            standing.append((p["x"], p["z"], r, float(y)))
        landmarks.append({"id": "prop", "model": p["model"], "pos": [p["x"], round(float(y), 3), p["z"]],
                          "yaw": math.radians(p.get("yaw", 0.0)), "solid": p.get("solid", "box"),
                          **({"label": p["label"]} if p.get("label") else {}),
                          **{k: p[k] for k in ("leisure", "scale", "parts") if k in p}})     # a pitch placed by hand gets its players
    # places without a building (a forecourt): the model stands on its own;
    # every place gets its door on the nearest sidewalk
    from shapely.ops import nearest_points
    walk = sidewalks.buffer(-0.5, join_style=2) if not sidewalks.is_empty else sidewalks
    for pl in places:
        x, z = pl["at"]
        if not walk.is_empty:
            d = nearest_points(walk, Point(x, -z))[0]
            pl["door"] = [round(d.x, 2), round(-d.y, 2)]
        rule = rules[pl["kind"]]
        if not rule.get("model") or pl["building"] or pl.get("model"):
            continue
        # one there already (placed by hand, or a landmark)? then not twice
        if any(l["model"] == rule["model"] and math.hypot(l["pos"][0] - x, l["pos"][2] - z) < 40 for l in landmarks):
            continue
        gy = TERRAIN(x, -z) if TERRAIN else 0.0
        landmarks.append({"id": pl["id"], "model": rule["model"], "pos": [x, round(float(gy), 3), z],
                          "yaw": pl["yaw"], "solid": True, "place": pl["kind"],
                          "caption": pl["name"] or rule.get("caption", "")})
        pl["model"] = rule["model"]
    # a shell's front: the wall (at least 3.2 m) that looks onto the nearest
    # street - its outside, a few metres out, closest to a road's centre line
    # (not just any paving: yards and squares are paved too)
    road = unary_union([ln for k, _, ln in roads if k in VEHICLE_ROADS]) if roads else asphalt_area
    for sh in shells:
        r = sh["ring"]
        cx = sum(q[0] for q in r) / len(r)
        cz = sum(q[1] for q in r) / len(r)
        def score(i):
            a, b = r[i], r[(i + 1) % len(r)]
            L = math.dist(a, b)
            if L < 3.2:
                return 1e9
            mx, mz = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
            nx, nz = -(b[1] - a[1]) / L, (b[0] - a[0]) / L
            if nx * (mx - cx) + nz * (mz - cz) < 0:
                nx, nz = -nx, -nz                      # outward
            out = Point(mx + nx * 3.0, -(mz + nz * 3.0))  # shapely y = -z
            return (road.distance(out) if not road.is_empty else 0.0) - 0.05 * L
        sh["front"] = min(range(len(r)), key=score)
    args.out.with_suffix(".shells.json").write_text(json.dumps(shells, ensure_ascii=False))
    for pl in places:
        if pl.get("model"):
            r = float(rules[pl["kind"]].get("clear_m", 12))
            props = [p for p in props if math.hypot(p["pos"][0] - pl["at"][0], p["pos"][2] - pl["at"][1]) > r]
    args.out.with_suffix(".places.json").write_text(json.dumps(places, ensure_ascii=False))
    print("places:", {k: sum(1 for p in places if p["kind"] == k) for k in sorted({p["kind"] for p in places})},
          "models placed:", sum(1 for p in places if p.get("model")))
    args.out.with_suffix(".props.json").write_text(json.dumps(props))
    args.out.with_suffix(".landmarks.json").write_text(json.dumps(landmarks))
    args.out.with_suffix(".buildings.json").write_text(json.dumps(building_index))
    print("props:", {k: sum(1 for p in props if p["type"] == k) for k in sorted({p["type"] for p in props})})
    size = args.out.stat().st_size / 1e6
    print(f"{args.out.name}: {len(buildings)} buildings, {len(batch.v)} materials, "
          f"{n_real} real + {n_inherit} inherited facade walls, {size:.1f} MB; spawn {np.round(spawn, 1)}")


def _storefront_fit(poly, street_union, sf):
    """Where a storefront model goes in a shop's footprint: on the side that
    looks onto the street, centred on it, as wide as fits. Returns (rect,
    centre x, y, outward normal x, y, width) in projected metres, or None."""
    ring = list(poly.simplify(0.2).exterior.coords)[:-1]
    c = poly.centroid
    best = None
    for i in range(len(ring)):
        a, b = ring[i], ring[(i + 1) % len(ring)]
        L = math.dist(a, b)
        if L < 5.5:
            continue
        tx, ty = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        nx, ny = -ty, tx
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        if nx * (mx - c.x) + ny * (my - c.y) < 0:
            nx, ny = -nx, -ny
        d = street_union.distance(Point(mx + nx * 3, my + ny * 3)) - 0.05 * L
        if best is None or d < best[0]:
            best = (d, mx, my, tx, ty, nx, ny, L)
    if best is None:
        return None
    _, mx, my, tx, ty, nx, ny, L = best
    widths = [w for w in sf.get("widths", [6]) if w <= L + 0.3]
    depth = float(sf.get("depth", 12))
    # how deep the footprint reaches behind that side
    reach = max(-(nx * (x - mx) + ny * (y - my)) for x, y in ring)
    if not widths or reach < depth - 1.0:
        return None
    w = max(widths)
    cx, cy = mx - nx * depth / 2, my - ny * depth / 2
    hw, hd = w / 2, depth / 2
    corners = [(cx + tx * sx * hw - nx * sz * hd, cy + ty * sx * hw - ny * sz * hd) for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    from shapely.geometry import Polygon
    return Polygon(corners), cx, cy, nx, ny, w


def _places(osm, proj, area, buildings, street_lines, rules):
    """Shops, pharmacies, fuel stations...: [{id, kind, name, at [x, z], door
    [x, z], yaw, building}] in game coordinates. A point inside a building is
    that building's place; yaw turns a model's front (-Z) to the nearest street."""
    from shapely.ops import nearest_points
    polys = [(b[0], b[2].get("@id", "")) for b in buildings]
    out, seen = [], set()
    for el in osm:
        tags = el.get("tags", {})
        kind = next((k for k, r in rules.items()
                     if any(tags.get(tag) in vals for tag, vals in r.get("match", {}).items())), None)
        if not kind:
            continue
        if el["type"] == "node":
            x, y = proj(el["lat"], el["lon"])
        elif el.get("geometry"):
            pts = [proj(p["lat"], p["lon"]) for p in el["geometry"]]
            x, y = sum(a for a, _ in pts) / len(pts), sum(b for _, b in pts) / len(pts)
        else:
            continue
        pt = Point(x, y)
        if not area.contains(pt):
            continue
        bid = f"{el['type']}/{el['id']}" if "building" in tags else ""
        if not bid:
            for poly, pid in polys:
                if poly.buffer(1.0).contains(pt):
                    bid = pid
                    break
        key = (kind, bid) if bid else (kind, round(x), round(y))
        if key in seen:
            continue
        seen.add(key)
        q = nearest_points(street_lines, pt)[0] if street_lines is not None else Point(x, y - 1)
        yaw = math.atan2(-(q.x - x), (q.y - y))
        out.append({"id": f"{el['type']}/{el['id']}", "kind": kind, "name": tags.get("name", ""),
                    "at": [round(x, 2), round(-y, 2)], "door": [round(x, 2), round(-y, 2)],
                    "yaw": round(yaw, 4), "building": bid})
    return out


def _ramp(batch, key, a, b, width, height):
    """Up-facing quad from the curb line (y=0) to `width` inside the sidewalk
    (y=height). The ring is CCW, so the sidewalk lies on the left of a->b."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L = math.hypot(dx, dy)
    if L < 0.05:
        return
    nx, ny = -dy / L * width, dx / L * width
    pa, pb = to_godot(a[0], a[1], 0.0), to_godot(b[0], b[1], 0.0)
    qb, qa = to_godot(b[0] + nx, b[1] + ny, height), to_godot(a[0] + nx, a[1] + ny, height)
    base = len(batch.v[key])
    batch.v[key] += [pa, pb, qb, qa]
    batch.uv[key] += [(0, 0), (1, 0), (1, 1), (0, 1)]
    # winding: make the normal point up
    import numpy as _np
    n = _np.cross(_np.subtract(pb, pa), _np.subtract(qb, pa))
    if n[1] > 0:
        batch.f[key] += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    else:
        batch.f[key] += [(base, base + 2, base + 1), (base, base + 3, base + 2)]


ATLAS_PX = int(__import__("os").environ.get("ATLAS_PX", 4096))   # 0: one material per facade photo
ATLAS_PAD = 8


def _atlas_photos(batch, images, normals):
    """The photographed facades (one image each, laid once across their wall:
    UVs within 0..1) packed into a few atlas pages, ATLAS_PX square: one
    material per page instead of one per photo - the same pixels, a fraction
    of the draw calls. Each photo gets ATLAS_PAD pixels of its own edge
    around it so the mipmaps do not bleed the neighbour in. Photos repeated
    across a wall (UVs past 1) and the PBR materials keep their own."""
    photos = []
    for key in list(batch.v):
        if key in normals or not batch.uv[key]:
            continue
        uv = np.asarray(batch.uv[key], float)
        if uv.min() < -0.002 or uv.max() > 1.002:
            continue
        photos.append(key)
    if len(photos) < 2:
        return
    # shelf packing, tallest first
    photos.sort(key=lambda k: -images[k].height)
    pages, place = [], {}
    x = y = shelf = 0
    page = None
    for key in photos:
        im = images[key]
        w, h = im.width + 2 * ATLAS_PAD, im.height + 2 * ATLAS_PAD
        if w > ATLAS_PX or h > ATLAS_PX:
            continue                               # too big for a page: stays on its own
        if page is None or x + w > ATLAS_PX:
            x, y, shelf = 0, y + shelf, 0
        if page is None or y + h > ATLAS_PX:
            page = Image.new("RGB", (ATLAS_PX, ATLAS_PX), (128, 128, 128))
            pages.append(page)
            x = y = shelf = 0
        # the photo with its edge pixels stretched into the padding
        padded = im.resize((im.width, im.height)).crop((-ATLAS_PAD, -ATLAS_PAD, im.width + ATLAS_PAD, im.height + ATLAS_PAD))
        arr = np.asarray(padded).copy()
        p = ATLAS_PAD
        arr[:p, :] = arr[p:p + 1, :]
        arr[-p:, :] = arr[-p - 1:-p, :]
        arr[:, :p] = arr[:, p:p + 1]
        arr[:, -p:] = arr[:, -p - 1:-p]
        page.paste(Image.fromarray(arr), (x, y))
        place[key] = (len(pages) - 1, x + p, y + p, im.width, im.height)
        x += w
        shelf = max(shelf, h)
    for key, (pi, px, py, w, h) in place.items():
        akey = f"atlas_{pi}"
        uv = np.asarray(batch.uv[key], float)
        # trimesh UVs: v = 0 at the image bottom; the page's y runs down
        u2 = (px + uv[:, 0] * w) / ATLAS_PX
        v2 = 1.0 - (py + (1.0 - uv[:, 1]) * h) / ATLAS_PX
        base = len(batch.v[akey])
        batch.v[akey] += batch.v[key]
        batch.uv[akey] += list(zip(u2, v2))
        batch.f[akey] += [(a + base, b + base, c + base) for a, b, c in batch.f[key]]
        for d in (batch.v, batch.uv, batch.f):
            del d[key]
    for i, pg in enumerate(pages):
        images[f"atlas_{i}"] = pg
    print(f"facade atlas: {len(place)} of {len(photos)} photos in {len(pages)} pages of {ATLAS_PX} px")


def _export(batch, images, normals, roughs, path):
    scene = trimesh.Scene()
    for key in batch.v:
        kw = dict(name=Path(key).stem, baseColorTexture=images[key], metallicFactor=0.0, roughnessFactor=0.95)
        if key in normals:
            r = roughs[key]
            zero = Image.new("L", r.size, 0)
            kw.update(normalTexture=normals[key], metallicRoughnessTexture=Image.merge("RGB", (zero, r, zero)),
                      roughnessFactor=1.0)
        mesh = trimesh.Trimesh(vertices=np.array(batch.v[key]), faces=np.array(batch.f[key]),
                               visual=trimesh.visual.TextureVisuals(uv=np.array(batch.uv[key]),
                                                                    material=trimesh.visual.material.PBRMaterial(**kw)),
                               process=False)
        keep = mesh.area_faces > 1e-6
        if not keep.all():
            mesh.update_faces(keep)
        mesh.vertex_normals = np.nan_to_num(mesh.vertex_normals, nan=0.0) + np.where(
            np.isnan(mesh.vertex_normals).any(1, keepdims=True), [0, 1, 0], 0)
        scene.add_geometry(mesh, node_name=Path(key).stem, geom_name=Path(key).stem)
    scene.export(path)


def _road_graph(vehicle, area):
    """Vehicle roads split at junctions: nodes and edges (Godot x/z) with
    the one-way flag, clipped to the playable area."""
    inner = area.buffer(-4.0)
    lines = []
    for one, ln in vehicle:
        clipped = ln.intersection(inner)
        for part in getattr(clipped, "geoms", [clipped]):
            if part.geom_type == "LineString" and part.length > 3:
                lines.append((one, list(part.coords)))
    key = lambda c: (round(c[0] * 2) / 2, round(c[1] * 2) / 2)
    count = defaultdict(int)
    for _, cs in lines:
        for c in {key(c) for c in cs}:
            count[c] += 1
    nodes, edges = {}, []

    def node_id(c):
        k = key(c)
        if k not in nodes:
            nodes[k] = len(nodes)
        return nodes[k]

    for one, cs in lines:
        start = 0
        for i in range(1, len(cs)):
            if i == len(cs) - 1 or count[key(cs[i])] > 1:
                seg = cs[start:i + 1]
                if len(seg) >= 2:
                    edges.append({"a": node_id(seg[0]), "b": node_id(seg[-1]), "oneway": one,
                                  "pts": [[round(x, 2), round(-y, 2), round(ground(x, y), 2)] for x, y in seg]})
                start = i
    node_xz = [None] * len(nodes)
    for (x, y), i in nodes.items():
        node_xz[i] = [x, -y]
    print(f"road graph: {len(node_xz)} nodes, {len(edges)} edges")
    return {"nodes": node_xz, "edges": edges}


def _paint(folder, name, rgb):
    path = folder / name
    if not path.exists():
        img = Image.new("RGB", (64, 64), rgb)
        px = img.load()
        r = np.random.default_rng(len(name))
        for y in range(64):
            for x in range(64):
                v = int(r.integers(-18, 10))
                px[x, y] = tuple(max(0, min(255, c + v)) for c in rgb)
        img.save(path)
    return path


def _paint_poly(batch, key, geom):
    n = 0
    for piece in parts_of(geom):
        if piece.area > 0.01:
            batch.polygon(key, piece, 0.012, 1.0)
            n += 1
    return n


def _street_props(osm, proj, area, footprint, sidewalks, parks, asphalt_area, pedestrian,
                  vehicle, junctions, lamps, curb_lines, named=(), ped_lines=(), places=(), kiosks=()):
    """Positions (Godot coords) and facing of street furniture."""
    rng = np.random.default_rng(7)
    props = []
    taken = []

    def free(x, y, r):
        return all((x - a) ** 2 + (y - b) ** 2 > (r + c) ** 2 for a, b, c in taken)

    def add(kind, x, y, up=CURB_M, yaw=None, r=0.6):
        if not free(x, y, r):
            return False
        taken.append((x, y, r))
        p = {"type": str(kind), "pos": [float(v) for v in to_godot(x, y, up)]}
        p["yaw"] = float(rng.uniform(0, math.tau)) if yaw is None else float(yaw)
        props.append(p)
        return True

    inside = prep(area.buffer(-1))
    blocked = prep(footprint.buffer(0.5))
    # the newsstands OSM maps as buildings, first so nothing takes their spot;
    # where OSM has them, turned to the street but not moved
    on_walk = prep(sidewalks) if sidewalks is not None and not sidewalks.is_empty else None
    for x, y in kiosks:
        up = CURB_M if on_walk and on_walk.contains(Point(x, y)) else 0.0
        if add("stall", x, y, up=up, yaw=0.0, r=2.5):
            props[-1]["stall"] = "newspaper_kiosk"
            props[-1]["osm"] = True
    kinds = {("natural", "tree"): "tree", ("highway", "traffic_signals"): "traffic_signals",
             ("highway", "bus_stop"): "bus_stop", ("amenity", "waste_basket"): "waste_basket",
             ("highway", "street_lamp"): "lamp",
             # Porto Alegre street furniture (rio_grande_do_sul/street_furniture)
             ("amenity", "bicycle_parking"): "bike_rack", ("amenity", "bicycle_rental"): "bike_rack",
             ("amenity", "telephone"): "orelhao", ("amenity", "clock"): "clock",
             ("amenity", "fountain"): "fountain", ("amenity", "recycling"): "container",
             ("amenity", "waste_disposal"): "container",
             # electronics shops become the game's repair shops (robot parts for gadgets)
             ("shop", "electronics"): "repair_shop", ("shop", "mobile_phone"): "repair_shop",
             ("shop", "computer"): "repair_shop", ("shop", "repair"): "repair_shop",
             ("craft", "electronics_repair"): "repair_shop"}
    # OSM puts many of these nodes on the carriageway (signals on the junction,
    # bus stops and trees on the road line): anything landing on asphalt moves
    # to the nearest sidewalk point (up to 10 m away) or is dropped
    from shapely.ops import nearest_points
    on_road = prep(asphalt_area.buffer(-0.3))
    walk = sidewalks.buffer(-0.6, join_style=2)
    road_edge = asphalt_area.boundary
    raised = prep(sidewalks)          # curb height; promenades and squares are at street level
    moved = dropped = 0
    phones = []
    wall_line = footprint.buffer(0.9, join_style=2).boundary if not footprint.is_empty else None
    for el in osm:
        kind = next((v for (k, val), v in kinds.items() if el.get("tags", {}).get(k) == val), None)
        if el["type"] != "node" and kind != "repair_shop":
            continue
        if kind:
            if el["type"] == "node":
                x, y = proj(el["lat"], el["lon"])
            elif el.get("geometry"):
                pts_ = [proj(p["lat"], p["lon"]) for p in el["geometry"]]
                x, y = sum(a for a, _ in pts_) / len(pts_), sum(b for _, b in pts_) / len(pts_)
            else:
                continue
            pt = Point(x, y)
            if kind == "repair_shop" and any(pl["kind"] == "repair_shop" and pl.get("building")
                                             and Point(pl["at"][0], -pl["at"][1]).distance(pt) < 25.0 for pl in places):
                continue                             # a real shop (a storefront, its counter inside), no stall
            if kind == "repair_shop" and not walk.is_empty and inside.contains(pt):
                pt = nearest_points(walk, pt)[0]     # a shop inside its building: its counter on the sidewalk outside
            elif not inside.contains(pt) or blocked.contains(pt):
                continue
            if on_road.contains(pt):
                if not walk.is_empty and walk.distance(pt) <= 10.0:
                    pt = nearest_points(walk, pt)[0]
                else:
                    # no sidewalk there (an avenue through a park): the verge beside the street
                    verge = asphalt_area.buffer(1.2, join_style=2).boundary
                    q = nearest_points(verge, pt)[0]
                    if q.distance(pt) > 12.0 or blocked.contains(q):
                        dropped += 1
                        continue
                    pt = q
                moved += 1
            yaw = None
            if kind == "orelhao":
                # one every 40 m at most (OSM maps every booth of a row), and on a
                # promenade or a square against the nearest front, its back to the
                # wall, not in the middle of the way
                if any(math.hypot(pt.x - a, pt.y - b) < 40.0 for a, b in phones):
                    continue
                if not raised.contains(pt) and wall_line is not None:
                    q = nearest_points(wall_line, pt)[0]
                    if q.distance(pt) <= 10.0 and not on_road.contains(q):
                        w = nearest_points(footprint.boundary, q)[0]
                        pt = q
                        yaw = math.atan2(w.x - q.x, (q.y - w.y))      # the hood opens to the model's -z: away from the wall
                phones.append((pt.x, pt.y))
            add(kind, pt.x, pt.y, CURB_M if raised.contains(pt) else 0.0, yaw=yaw, r=1.0)
    print(f"OSM street furniture on the road: {moved} moved to the sidewalk, {dropped} dropped")
    # one lamp every LAMP_SPACING_M along a kerb at most, OSM's own street
    # lamps (placed above) counted too
    lit = [(p["pos"][0], -p["pos"][2]) for p in props if p["type"] == "lamp"]
    for x, y in lamps:
        if any(math.hypot(x - a, y - b) < LAMP_MIN_GAP_M for a, b in lit):
            continue
        if add("lamp", x, y, r=0.5):
            lit.append((x, y))

    on_sidewalk = prep(sidewalks.buffer(-0.3))
    hydrants = []
    # a parked car leaves the traffic lanes free (car.gd drives 1.7 m right of a
    # two-way street's centre line, 0.9 m on a one-way one; a car is ~2 m wide)
    lane_tree = [(ln, 1.7 if not one else 0.9) for one, ln in vehicle]

    def clear_of_lanes(x, y):
        pt = Point(x, y)
        return all(ln.distance(pt) > off + 2.3 for ln, off in lane_tree if ln.distance(pt) < 8.0)
    # things along the curb (0.6-0.9 m inside the sidewalk), aligned with it
    for ring in curb_lines:
        L = ring.length
        for d in np.arange(3.0, L, 6.0):
            p = ring.interpolate(d)
            q = ring.interpolate(min(L, d + 0.5))
            tx, ty = q.x - p.x, q.y - p.y
            tl = math.hypot(tx, ty) or 1.0
            nx, ny = -ty / tl, tx / tl          # ring is CCW: left normal points into the sidewalk
            yaw = math.atan2(tx / tl, -ty / tl)
            roll = rng.random()
            ix, iy = p.x + nx * 0.8, p.y + ny * 0.8
            if not on_sidewalk.contains(Point(ix, iy)):
                continue
            if roll < 0.05 and all(math.hypot(ix - hx, iy - hy) > 40 for hx, hy in hydrants):
                if add("hydrant", ix, iy, yaw=yaw, r=0.5):
                    hydrants.append((ix, iy))
            elif roll < 0.13:
                add("waste_basket", ix, iy, r=0.5)
            elif roll < 0.145:
                add("container", ix, iy, yaw=yaw, r=1.0)     # the orange 1000 L bin at the kerb
                if rng.random() < 0.4:
                    add("trashbag", ix + tx / tl * 0.7, iy + ty / tl * 0.7, r=0.4)
            elif roll < 0.33:
                add("tree", p.x + nx * 1.1, p.y + ny * 1.1, r=1.5)
            # parked cars on the asphalt next to the curb of vehicle streets
            cx, cy = p.x - nx * 1.3, p.y - ny * 1.3
            if rng.random() < 0.22 and asphalt_area.buffer(-1.0).contains(Point(cx, cy)) \
                    and all(Point(cx, cy).distance(j) > 12 for j in junctions) and clear_of_lanes(cx, cy):
                add("car", cx, cy, up=0.0, yaw=yaw, r=2.6)
    # things against the building side of wide sidewalks
    for part in parts_of(sidewalks):
        inner = part.buffer(-1.9)
        for sub in parts_of(inner):
            for d in np.arange(4.0, sub.exterior.length, 11.0):
                p = sub.exterior.interpolate(d)
                roll = rng.random()
                if roll < 0.12:
                    add(rng.choice(["planter", "potted_plant"]), p.x, p.y, r=0.7)
                elif roll < 0.18:
                    add(rng.choice(["crate", "barrel", "plastic_crate"]), p.x, p.y, r=0.6)
                elif roll < 0.22:
                    add("bench", p.x, p.y, r=1.2)
    # manholes on the road
    for one, ln in vehicle:
        for d in np.arange(10.0, ln.length, 38.0):
            p = ln.interpolate(d)
            if asphalt_area.contains(Point(p.x, p.y)):
                add("manhole", p.x + 1.6, p.y, up=0.0, r=0.6)
    # concrete barriers at a few junctions, cones of work
    for j in rng.permutation(len(junctions))[:4] if junctions else []:
        jp = junctions[j]
        for k in range(3):
            a = rng.uniform(0, math.tau)
            x, y = jp.x + math.cos(a) * 6, jp.y + math.sin(a) * 6
            if asphalt_area.buffer(-0.8).contains(Point(x, y)):
                add("barrier", x, y, up=0.0, r=1.2)
    # parks: benches, shrubs, ferns, weeds
    for park in parks:
        inner = park.buffer(-1.5)
        minx, miny, maxx, maxy = park.bounds
        pin = prep(inner)
        for _ in range(int(park.area / 12)):
            x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
            if pin.contains(Point(x, y)):
                add(rng.choice(["shrub", "shrub2", "fern", "weed", "bench", "tree"],
                               p=[0.25, 0.2, 0.2, 0.15, 0.1, 0.1]), x, y, up=0.03, r=0.9)
    # street name signs: a pole on the sidewalk corner of every crossing of two
    # differently named streets, one plate parallel to each street
    corners = []
    for i, (na, la) in enumerate(named):
        for nb, lb in named[i + 1:]:
            if na == nb or not la.intersects(lb):
                continue
            hit = la.intersection(lb)
            for pt in getattr(hit, "geoms", [hit]):
                if pt.is_empty:
                    continue
                pt = pt.centroid
                if all(pt.distance(c) > 10.0 for c, _ in corners):
                    corners.append((pt, {na, nb}))
                else:
                    next(names for c, names in corners if pt.distance(c) <= 10.0).update((na, nb))
    from shapely.ops import nearest_points
    walk_in = sidewalks.buffer(-0.5)
    n_signs = 0
    for pt, names in corners:
        if walk_in.is_empty or walk_in.distance(pt) > 12.0 or not inside.contains(pt):
            continue
        plates = []
        for name in sorted(names)[:2]:
            ln = min((ln for nm, ln in named if nm == name), key=lambda l: l.distance(pt))
            d = ln.project(pt)
            a, b = ln.interpolate(max(0.0, d - 2.0)), ln.interpolate(min(ln.length, d + 2.0))
            tx, ty = b.x - a.x, b.y - a.y
            # Godot yaw that turns the plate's long (local X) axis along its street:
            # map (x, y) is Godot (x, -z), and yaw t maps X to (cos t, 0, -sin t)
            plates.append({"name": name, "yaw": float(math.atan2(ty, tx))})
        if len(plates) < 2:
            continue
        spot = nearest_points(walk_in, pt)[0]
        for k in range(8):
            ox, oy = (0.0, 0.0) if k == 0 else (math.cos(k * 0.8) * 0.9, math.sin(k * 0.8) * 0.9)
            if add("street_sign", spot.x + ox, spot.y + oy, yaw=0.0, r=0.3):
                props[-1]["plates"] = plates
                n_signs += 1
                break
    print(f"street signs: {n_signs} of {len(corners)} named crossings")

    # street vendors' stalls on promenades and squares (each gets its vendor in
    # the game), and the historic tram parked on the longest promenade
    stall_kinds = ["newspaper_kiosk", "popcorn_cart", "churros_cart", "mate_thermos_stall"]
    open_ped = pedestrian.buffer(-2.5, join_style=2)
    ped_in = prep(open_ped) if not open_ped.is_empty else None
    stalls = 0
    if ped_in:
        bx0, by0, bx1, by1 = pedestrian.bounds
        cands = [(gx, gy) for gx in np.arange(bx0, bx1, 7.0) for gy in np.arange(by0, by1, 7.0)
                 if ped_in.contains(Point(gx, gy))]
        rng.shuffle(cands)
        placed = []
        for gx, gy in cands:
            if stalls >= 5:
                break
            if any(math.hypot(gx - a, gy - b) < 55.0 for a, b in placed):
                continue
            if add("stall", float(gx), float(gy), up=0.0, yaw=float(rng.integers(4)) * math.pi / 2, r=2.5):
                props[-1]["stall"] = stall_kinds[stalls % len(stall_kinds)]
                placed.append((gx, gy))
                stalls += 1
    trams = 0
    if ped_in and ped_lines:
        axis = max(ped_lines, key=lambda l: l.intersection(open_ped).length)
        inside_axis = axis.intersection(open_ped)
        if inside_axis.length > 40.0:
            seg = max(getattr(inside_axis, "geoms", [inside_axis]), key=lambda g: g.length)
            # the first spot along the promenade with room for the 10 m car
            for f in (0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8):
                mid = seg.interpolate(f, normalized=True)
                q = seg.interpolate(min(seg.length, seg.project(mid) + 2.0))
                tx, ty = q.x - mid.x, q.y - mid.y
                if add("tram", mid.x, mid.y, up=0.0, yaw=math.atan2(-tx, ty), r=3.5):
                    trams = 1
                    break
    print(f"vendor stalls: {stalls}, tram: {trams}")
    # street furniture with a front (its `faces` in godot/assets/**/*.def.json):
    # turned towards its street or walk, and kept off the asphalt
    walk_lines = [ln for _, ln in vehicle] + list(ped_lines)
    for el in osm:
        t = el.get("tags", {})
        if el["type"] == "way" and t.get("highway") in ("footway", "path", "pedestrian", "living_street", "cycleway") \
                and len(el.get("geometry", [])) >= 2:
            walk_lines.append(LineString([proj(q["lat"], q["lon"]) for q in el["geometry"]]))
    targets = {"street": unary_union([ln for _, ln in vehicle]) if vehicle else None,
               "walk": unary_union(walk_lines) if walk_lines else None}
    faced = 0
    for pr in props:
        rule = FACES.get(pr["type"] + (":" + pr["stall"] if pr.get("stall") else "")) or FACES.get(pr["type"])
        if not rule:
            continue
        x, y = pr["pos"][0], -pr["pos"][2]
        if pr.pop("osm", False):
            rule = {"front": rule.get("front", "+z"), "towards": "street"}
        x, y, yaw = _face(rule, x, y, targets.get(rule.get("towards", "street")), asphalt_area, on_road, blocked)
        if yaw is None:
            continue
        pr["pos"][1] = float(pr["pos"][1] - ground(pr["pos"][0], -pr["pos"][2]) + ground(x, y))   # same height above the ground
        pr["pos"][0], pr["pos"][2] = float(x), float(-y)
        pr["yaw"] = float(yaw)
        faced += 1
    print(f"street furniture turned to its street or walk: {faced}")
    return props


_RADIUS = {}
BULK = {"stall": 4.0, "tram": 6.0, "bus_stop": 2.5, "car": 2.5, "container": 1.0}   # their own size, roughly


def _model_radius(res_path, parts=None):
    """Half the larger side of a model's ground footprint (metres), 0 if unknown.
    A landmark in parts (site.json) with `parts` chosen: those parts' extent."""
    key = (res_path, tuple(parts or ()))
    if key in _RADIUS:
        return _RADIUS[key]
    r = 0.0
    f = Path(__file__).resolve().parents[2] / "godot" / res_path.replace("res://", "")
    if res_path.endswith("site.json") and f.exists():
        site = json.loads(f.read_text())
        if parts:
            for k in parts:
                b = site["parts"].get(k, {}).get("bounds")
                if b:
                    r = max(r, *(abs(v) for v in (b["min"][0], b["min"][2], b["max"][0], b["max"][2])))
        else:
            size = site.get("size_m", [0, 0, 0])
            r = float(max(size[0], size[2])) / 2.0
    elif res_path.endswith((".glb", ".gltf")) and f.exists():
        try:
            ext = trimesh.load(str(f), force="scene").extents
            r = float(max(ext[0], ext[2])) / 2.0
        except Exception:
            r = 0.0
    _RADIUS[key] = r
    return r


def _load_faces():
    """prop type -> `faces` rule, from the entity definitions (docs/ENTITIES.md)."""
    out = {}
    for f in (Path(__file__).resolve().parents[2] / "godot" / "assets").rglob("*.def.json"):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if d.get("prop") and d.get("faces"):
            out[d["prop"]] = d["faces"]
    return out


FACES = _load_faces()


def _face(rule, x, y, target, asphalt, on_road, blocked):
    """A model's position and yaw with its front (rule "front": +z, -z, +x, -x
    in the model) towards the nearest point of `target`, at least rule "gap"
    metres off the asphalt. (x, y) metric; yaw for Godot. None: no target."""
    from shapely.ops import nearest_points
    if target is None or target.is_empty:
        return x, y, None
    pt = Point(x, y)
    gap = float(rule.get("gap", 0.0))
    edge = asphalt.boundary if asphalt is not None and not asphalt.is_empty else None
    if edge is not None and gap > 0:
        q = nearest_points(edge, pt)[0]
        d = pt.distance(q)
        if on_road.contains(pt) or d < gap:
            # out of the street, on the side the point is on
            away = (x - q.x, y - q.y) if not on_road.contains(pt) and d > 0.01 else None
            if away is None:
                q2 = nearest_points(edge, pt)[0]
                away = (q2.x - x, q2.y - y)
                d0 = math.hypot(*away) or 1.0
                q = q2
                away = (away[0] / d0, away[1] / d0)
            else:
                away = (away[0] / d, away[1] / d)
            back = Point(q.x + away[0] * gap, q.y + away[1] * gap)
            if not blocked.contains(back) and not on_road.contains(back):
                pt = back
    q = nearest_points(target, pt)[0]
    dx, dz = q.x - pt.x, -(q.y - pt.y)          # Godot direction (z = -y)
    if math.hypot(dx, dz) < 0.05:
        return pt.x, pt.y, None
    front = rule.get("front", "+z")
    yaw = {"+z": math.atan2(dx, dz), "-z": math.atan2(-dx, -dz),
           "+x": math.atan2(-dz, dx), "-x": math.atan2(dz, -dx)}[front]
    return pt.x, pt.y, yaw


if __name__ == "__main__":
    main()
