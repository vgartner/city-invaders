#!/usr/bin/env python3
"""The far view of an open world (docs/OPEN_WORLD.md): light models of the
city that stand in for the tiles that are not loaded, and for the city
beyond the world's edge.

    tools/.venv/bin/python tools/map/far_view.py centro_world
    godot --headless --path godot --import

For every tile of `godot/city/<world>.world.json` it writes
`godot/city/<tile>_far.glb`: the tile's buildings as light blocks (footprint,
ground, height - the same OSM data and hand-set heights the tile is built
from), walls one colour each from a few city tones with window bays the game
textures, roofs tiled and hipped on low small buildings, flat and darker on the
others, on a coarse ground that follows
the terrain, and the water. A ring of `--ring` tiles round the world goes
into one `godot/city/<world>_far_ring.glb`. The world list gets "far": the
ring's file. The game shows a tile's far model while the tile is not in and
the ring all the time (open_world.gd).

A tile's far model is ~1 % of the tile's glb: no textures, no props, no
collision.
"""
import argparse
import json
import math
import sys
import zlib
from pathlib import Path

import numpy as np
import trimesh
from shapely.geometry import Point, box
from shapely.geometry.polygon import orient
from shapely.prepared import prep

sys.path.insert(0, str(Path(__file__).resolve().parent))
import osmcity                                   # noqa: E402
from osm2gltf import Terrain, WATER_Y           # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
GROUND_STEP = 25.0                               # metres between the ground's vertices
SKIRT_M = 3000.0                                 # bare ground round the ring, out to the horizon
SKIRT_STEP = 250.0
# walls: weathered plaster, concrete, brick, cream, grey glass; roofs a shade darker
TONES = [(0.62, 0.58, 0.52), (0.55, 0.55, 0.53), (0.58, 0.42, 0.34), (0.72, 0.68, 0.58), (0.45, 0.49, 0.52)]
GROUND = (0.33, 0.33, 0.32)
WATER = (0.16, 0.27, 0.31)


def material(name, rgb):
    return trimesh.visual.material.PBRMaterial(name=name, baseColorFactor=[*rgb, 1.0],
                                               metallicFactor=0.0, roughnessFactor=0.95)


class Model:
    """Triangles by colour, one mesh per colour on export. The walls carry
    UVs in window bays (u along the wall, v up, BAY_M x FLOOR_M a unit): the
    game lays a window texture over them (open_world.gd, _far_windows)."""

    def __init__(self):
        self.parts = {}

    def add(self, name, rgb, mesh):
        self.tris(name, rgb, mesh.vertices, mesh.faces)

    def tris(self, name, rgb, verts, faces, uv=None):
        part = self.parts.setdefault(name, (rgb, [], [], [], [0]))
        part[1].append(np.asarray(verts, dtype=float))
        part[2].append(np.asarray(faces, dtype=np.int64) + part[4][0])
        if uv is not None:
            part[3].append(np.asarray(uv, dtype=float))
        part[4][0] += len(verts)

    def export(self, path):
        scene = trimesh.Scene()
        for name, (rgb, verts, faces, uvs, _n) in self.parts.items():
            m = trimesh.Trimesh(vertices=np.vstack(verts), faces=np.vstack(faces), process=False)
            m.visual = trimesh.visual.TextureVisuals(uv=np.vstack(uvs) if uvs else None,
                                                     material=material(name, rgb))
            scene.add_geometry(m, node_name=name, geom_name=name)
        path.parent.mkdir(parents=True, exist_ok=True)
        scene.export(path)


def to_godot(mesh):
    """trimesh's x, y, z (y north, z up) -> Godot's x, y up, z south."""
    v = mesh.vertices
    mesh.vertices = np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])     # a rotation: faces keep their side
    return mesh


BAY_M = 3.6                    # a window bay along a wall
FLOOR_M = 3.2                  # a storey
PITCHED_MAX_H = 9.0            # a building this low and small gets a tiled hip roof
PITCHED_MAX_M2 = 450.0
TILE_ROOF = (0.50, 0.29, 0.21)
ROOF_COLOURS = {"grey": (0.42, 0.42, 0.42), "gray": (0.42, 0.42, 0.42), "dimgray": (0.33, 0.33, 0.33),
                "saddlebrown": (0.45, 0.27, 0.12), "red": TILE_ROOF, "darkred": (0.42, 0.18, 0.14)}


def _up(a, b, c):
    """The triangle's normal (Godot frame, y up)."""
    return np.cross(np.subtract(b, a), np.subtract(c, a))


def building(model, poly, height, base, tag, tags=None):
    """Walls with window bays, and a roof: a hip of tiles on a low, small
    building (or one OSM says is pitched), else a flat one a shade darker."""
    tags = tags or {}
    poly = orient(poly.simplify(0.5))
    if poly.is_empty or poly.area < 2.0 or poly.geom_type != "Polygon":
        return False
    k = zlib.crc32(tag.encode()) % len(TONES)
    top = base + height
    c = poly.representative_point()
    cx, cy = c.x, c.y
    # walls: a quad per edge, facing away from the inside
    v, f, uv = [], [], []
    for ring in [poly.exterior, *poly.interiors]:
        pts = list(ring.coords)
        u = 0.0
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            L = math.hypot(x1 - x0, y1 - y0)
            if L < 0.05:
                continue
            n = len(v)
            v += [(x0, base, -y0), (x1, base, -y1), (x1, top, -y1), (x0, top, -y0)]
            uv += [(u / BAY_M, 0.0), ((u + L) / BAY_M, 0.0), ((u + L) / BAY_M, height / FLOOR_M), (u / BAY_M, height / FLOOR_M)]
            # outward: shapely's oriented exterior runs anticlockwise (y north),
            # so the outside is on the right of the way; holes run clockwise
            out = np.array([y1 - y0, 0.0, x1 - x0])        # right of (dx, dy), in the Godot frame (z = -y)
            tri = [(n, n + 1, n + 2), (n, n + 2, n + 3)]
            if np.dot(_up(v[n], v[n + 1], v[n + 2]), out) < 0:
                tri = [(a, cc, b) for a, b, cc in tri]
            f += tri
            u += L
    if not f:
        return False
    model.tris(f"far_wall_{k}", TONES[k], v, f, uv)
    # the roof
    shape = str(tags.get("roof:shape", ""))
    cname = str(tags.get("roof:colour", "")).lower()
    colour = ROOF_COLOURS.get(cname)
    pitched = shape in ("hipped", "gabled", "pyramidal", "half-hipped") or \
        (shape in ("", "None") and height <= PITCHED_MAX_H and poly.area <= PITCHED_MAX_M2 and not poly.interiors)
    if pitched and poly.contains(c):
        rise = min(0.45 * math.sqrt(poly.area), 5.0) * 0.5
        apex = (cx, top + rise, -cy)
        pts = list(poly.exterior.coords)
        v, f = [apex], []
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            n = len(v)
            v += [(x0, top, -y0), (x1, top, -y1)]
            tri = (0, n, n + 1)
            if _up(v[0], v[n], v[n + 1])[1] < 0:
                tri = (0, n + 1, n)
            f.append(tri)
        model.tris("far_roof_tile" if colour is None else f"far_roof_{cname}", colour or TILE_ROOF, v, f)
        return True
    verts2, faces = trimesh.creation.triangulate_polygon(poly)
    v = [(x, top, -y) for x, y in verts2]
    faces = [tuple(t) if _up(v[t[0]], v[t[1]], v[t[2]])[1] > 0 else (t[0], t[2], t[1]) for t in faces]
    rgb = colour or tuple(x * 0.72 for x in TONES[k])
    model.tris(f"far_roof_{k}" if colour is None else f"far_roof_{cname}", rgb, v, faces)
    return True


def ground(model, terrain, cell, water, level, step=GROUND_STEP):
    x0, y0, x1, y1 = cell.bounds
    nx = max(1, int(math.ceil((x1 - x0) / step)))
    ny = max(1, int(math.ceil((y1 - y0) / step)))
    xs = np.linspace(x0, x1, nx + 1)
    ys = np.linspace(y0, y1, ny + 1)
    wet = prep(water) if water is not None and not water.is_empty else None
    v, f = [], []
    for j, y in enumerate(ys):
        for i, x in enumerate(xs):
            v.append((x, -0.3 + (terrain._raw(x, y) if terrain else 0.0), -y))   # Godot frame; under the kerbs
    for j in range(ny):
        for i in range(nx):
            mid = Point((xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2)
            if (wet and wet.contains(mid)) or not cell.contains(mid):
                continue
            a, b, c, d = j * (nx + 1) + i, j * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i
            f += [(a, b, c), (a, c, d)]                    # counter-clockwise from above
    if f:
        model.add("far_ground", GROUND, trimesh.Trimesh(vertices=np.array(v), faces=np.array(f), process=False))
    if wet:
        for piece in osmcity.parts(water.intersection(cell)):
            try:
                m = trimesh.creation.extrude_polygon(piece, 0.05)
            except (ValueError, IndexError):
                continue
            m.apply_translation([0, 0, level - 0.05])
            model.add("far_water", WATER, to_godot(m))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("world", help="godot/city/<world>.world.json")
    ap.add_argument("--ring", type=int, default=2, help="tiles of far view round the world (default 2)")
    a = ap.parse_args()

    wpath = ROOT / "godot" / "city" / f"{a.world}.world.json"
    world = json.loads(wpath.read_text())
    src = json.loads((ROOT / "maps" / world["source"] / "build.json").read_text())
    size = float(world["size"])
    # the world's extent in metres, y north (tile bounds are Godot x0, x1, z0, z1)
    wx0 = min(t["bounds"][0] for t in world["tiles"])
    wx1 = max(t["bounds"][1] for t in world["tiles"])
    wy0 = min(-t["bounds"][3] for t in world["tiles"])
    wy1 = max(-t["bounds"][2] for t in world["tiles"])
    m = a.ring * size
    ext = (wx0 - m, wy0 - m, wx1 + m, wy1 + m)

    heights = {}
    user = ROOT / src.get("user", f"maps/{world['source']}/user") / "buildings_user.json"
    gone = set()
    if user.exists():
        for k, v in json.loads(user.read_text()).items():
            if k.startswith("_"):
                continue
            if v.get("height"):
                heights[k] = v["height"]
            if v.get("model") == "@gone":
                gone.add(k)
    _area, placed, _parks, _streets = osmcity.load(ROOT / src["osm"], src["lat"], src["lon"], 0, ext, heights, whole=True)
    placed = placed + list(osmcity.load.foreign)
    terrain = Terrain(ROOT / src["terrain"]) if src.get("terrain") else None
    proj = osmcity.project(src["lat"], src["lon"])
    osm = json.loads((ROOT / src["osm"]).read_text())
    water = osmcity.water_polygon(osm, proj, box(*ext))
    level = WATER_Y
    if water is not None and not water.is_empty and terrain:
        level = min(terrain._raw(*c) for g in osmcity.parts(water) for c in g.exterior.coords) + WATER_Y

    def base_of(poly):
        if not terrain:
            return 0.0
        pts = [poly.centroid.coords[0]] + list(poly.exterior.coords)
        return min(terrain._raw(x, y) for x, y in pts)

    cells = {}                                   # tile id or "ring" -> (model, cell box)
    for t in world["tiles"]:
        b = t["bounds"]
        cells[t["id"]] = (Model(), box(b[0], -b[3], b[1], -b[2]))
    world_box = box(wx0, wy0, wx1, wy1)
    ring_box = box(*ext).difference(world_box)
    cells["ring"] = (Model(), ring_box)

    counts = {k: 0 for k in cells}
    for poly, h, tags in placed:
        if tags.get("@id") in gone:
            continue
        p = poly.representative_point()
        for k, (model, cell) in cells.items():
            if cell.contains(p) or (k != "ring" and cell.touches(p)):
                if building(model, poly, float(h), base_of(poly), tags.get("@id", ""), tags):
                    counts[k] += 1
                break
    for k, (model, cell) in cells.items():
        if k == "ring":
            for piece in osmcity.parts(cell):
                ground(model, terrain, piece, water, level)
            # beyond the ring, bare ground (and the water) to the horizon: no gap
            # between the city and the sky seen from a roof
            skirt = box(ext[0] - SKIRT_M, ext[1] - SKIRT_M, ext[2] + SKIRT_M, ext[3] + SKIRT_M).difference(box(*ext))
            far_water = osmcity.water_polygon(osm, proj, skirt.envelope)
            ground(model, terrain, skirt, far_water, level, SKIRT_STEP)
            out = ROOT / "godot" / "city" / f"{a.world}_far_ring.glb"
        else:
            ground(model, terrain, cell, water, level)
            out = ROOT / "godot" / "city" / f"{k}_far.glb"
        model.export(out)
        print(f"{out.relative_to(ROOT)}: {counts[k]} buildings, {out.stat().st_size / 1e3:.0f} kB", flush=True)
    world["far"] = f"{a.world}_far_ring"
    wpath.write_text(json.dumps(world, indent=1) + "\n")
    print("next: godot --headless --path godot --import")


if __name__ == "__main__":
    main()
