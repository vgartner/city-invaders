#!/usr/bin/env python3
"""Put your own photos on the city's buildings and fix their heights.

Each map's build settings live in maps/<map>/build.json; your changes go to
maps/<map>/user/ (photos, buildings_user.json with height overrides,
facades_user.json with the rectified facade images) and are applied on top
of the Mapillary/Commons facades when the map is rebuilt.

    # which building/wall is at game position x, z (the DevAgent's
    # pick_building does this for the wall under the crosshair)
    tools/.venv/bin/python tools/map/building_photo.py pick gasometro 12.5 -40.2

    # photo of that wall: corners of the facade in the photo, in pixels,
    # clockwise from top-left (default: the whole photo)
    tools/.venv/bin/python tools/map/building_photo.py photo gasometro 'KEY' foto.jpg \\
        --corners 120,80 1890,140 1870,1300 100,1320

    tools/.venv/bin/python tools/map/building_photo.py height gasometro way/123456 14.5
    tools/.venv/bin/python tools/map/building_photo.py rebuild gasometro

Walls are keyed like the facade files: their two Build-space end points.
Looking at a wall from the street, its first point is on the left.
"""
import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import osmcity  # noqa: E402

U = osmcity.UNITS_PER_M
PX_PER_M = 100             # facade texture resolution for your photos
MAX_PX = 2048


def config(map_id):
    path = ROOT / "maps" / map_id / "build.json"
    if not path.exists():
        raise SystemExit(f"no {path}")
    return json.loads(path.read_text())


def user_dir(map_id):
    # maps cut from the same city data share one user/ folder ("user" in build.json)
    cfg = ROOT / "maps" / map_id / "build.json"
    shared = json.loads(cfg.read_text()).get("user") if cfg.exists() else None
    d = ROOT / shared if shared else ROOT / "maps" / map_id / "user"
    (d / "img").mkdir(parents=True, exist_ok=True)
    return d


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


_cache = {}


def buildings(map_id):
    """The map's buildings as the exporter places them (cached per process
    until buildings_user.json changes: the MCP server picks repeatedly)."""
    c = config(map_id)
    user = user_dir(map_id) / "buildings_user.json"
    stamp = (map_id, user.stat().st_mtime if user.exists() else 0)
    if stamp in _cache:
        return _cache[stamp]
    heights = {k: v["height"] for k, v in read_json(user).items() if not k.startswith("_") and v.get("height")}
    _, bl, _, _ = osmcity.load(ROOT / c["osm"], c["lat"], c["lon"], c.get("half", 150),
                                 c.get("bounds"), heights)
    terrain = None
    if c.get("terrain"):
        from osm2gltf import Terrain
        terrain = Terrain(ROOT / c["terrain"])
    _cache[stamp] = (bl, terrain)
    return bl, terrain


def seg_dist(p, a, b):
    ax, az = a
    bx, bz = b
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - az) * dz) / max(dx * dx + dz * dz, 1e-9)))
    return math.hypot(p[0] - ax - t * dx, p[1] - az - t * dz)


def pick(map_id, x, z):
    """The wall nearest to game point (x, z) and its building."""
    bl, terrain = buildings(map_id)
    best = None
    for poly, h, tags in bl:
        if tags.get("man_made") == "chimney":
            continue
        pts = osmcity.ring_points(poly, outer=False)
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            # Build units -> game metres (x east, z south)
            ga, gb = (a[0] / U, a[1] / U), (b[0] / U, b[1] / U)
            d = seg_dist((x, z), ga, gb)
            if best is None or d < best[0]:
                best = (d, poly, h, tags, i, a, b, ga, gb)
    if best is None:
        raise SystemExit("no buildings")
    d, poly, h, tags, i, a, b, ga, gb = best
    base = terrain.lowest(poly) if terrain else 0.0
    key = f"{a[0]},{a[1]},{b[0]},{b[1]}"
    user = read_json(user_dir(map_id) / "facades_user.json")
    info = {k: tags[k] for k in ("name", "addr:street", "addr:housenumber", "building", "building:levels",
                                 "height", "amenity", "historic", "wikidata") if k in tags}
    return {
        "map": map_id, "id": tags.get("@id"), "tags": info, "height_m": round(h, 2),
        "wall": key, "wall_index": i, "wall_length_m": round(math.dist(ga, gb), 2),
        "from": [round(ga[0], 2), round(ga[1], 2)], "to": [round(gb[0], 2), round(gb[1], 2)],
        "base_y": round(base, 2), "top_y": round(base + h, 2), "distance_m": round(d, 2),
        "has_user_photo": key in user,
        "osm_url": f"https://www.openstreetmap.org/{tags.get('@id')}" if tags.get("@id") else None,
    }


def photo(map_id, key, image, corners=None, height=None):
    """Rectify the facade in `image` and register it for wall `key`."""
    from PIL import Image
    bl, _ = buildings(map_id)
    found = None
    for poly, h, tags in bl:
        pts = osmcity.ring_points(poly, outer=False)
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            if f"{a[0]},{a[1]},{b[0]},{b[1]}" == key:
                found = (h, tags, i, math.dist(a, b) / U)
    if found is None:
        raise SystemExit(f"wall {key} not in {map_id}")
    h, tags, i, length = found
    h = height or h
    src = Image.open(image).convert("RGB")
    if corners:
        tl, tr, br, bl_ = corners
    else:
        w0, h0 = src.size
        tl, tr, br, bl_ = (0, 0), (w0, 0), (w0, h0), (0, h0)
    scale = min(PX_PER_M, MAX_PX / max(length, h))
    size = (max(16, round(length * scale)), max(16, round(h * scale)))
    # PIL QUAD: source corners upper-left, lower-left, lower-right, upper-right
    out = src.transform(size, Image.QUAD, data=(*tl, *bl_, *br, *tr), resample=Image.BICUBIC)
    d = user_dir(map_id)
    name = f"{tags['@id'].replace('/', '_')}_w{i}.png"
    out.save(d / "img" / name)
    facades = read_json(d / "facades_user.json")
    facades[key] = {"file": f"img/{name}", "w_px": size[0], "h_px": size[1], "height_m": h,
                    "source": str(Path(image).name), "building": tags["@id"]}
    (d / "facades_user.json").write_text(json.dumps(facades, indent=1) + "\n")
    if height:
        set_height(map_id, tags["@id"], height)
    return {"wall": key, "image": str(d / "img" / name), "size_px": size, "wall_m": [round(length, 2), h]}


def set_height(map_id, osm_id, metres):
    d = user_dir(map_id)
    b = read_json(d / "buildings_user.json")
    b.setdefault(osm_id, {})["height"] = float(metres)
    (d / "buildings_user.json").write_text(json.dumps(b, indent=1) + "\n")
    return {osm_id: b[osm_id]}


def set_model(map_id, osm_id, model):
    """Replace a building by a hand-made model (res:// path in the game)."""
    d = user_dir(map_id)
    b = read_json(d / "buildings_user.json")
    b.setdefault(osm_id, {})["model"] = model
    (d / "buildings_user.json").write_text(json.dumps(b, indent=1) + "\n")
    return {osm_id: b[osm_id]}


def rebuild(map_id):
    c = config(map_id)
    d = user_dir(map_id)
    facades = [str(ROOT / f) for f in c["facades"]]
    if (d / "facades_user.json").exists():
        facades.append(str(d / "facades_user.json"))     # last: yours win
    cmd = [sys.executable, str(ROOT / "tools" / "map" / "osm2gltf.py"), str(ROOT / c["osm"]),
           "--lat", str(c["lat"]), "--lon", str(c["lon"])]
    cmd += ["--bounds", *map(str, c["bounds"])] if c.get("bounds") else ["--half", str(c.get("half", 150))]
    if facades:                                          # a town without facade photos yet
        cmd += ["--facades", *facades]
    if c.get("terrain"):
        cmd += ["--terrain", str(ROOT / c["terrain"])]
    if c.get("ring"):
        cmd += ["--ring"]                                # car roads end at the outer road loop
    if c.get("kit_facades"):
        cmd += ["--kit-facades", ",".join(map(str, c["kit_facades"]))]     # the block (x, z) whose buildings get them
    cmd += ["--user", str(d / "buildings_user.json"), "--textures", str(ROOT / c["textures"]),
            "--materials", str(ROOT / "godot/assets/materials"), "--start", *map(str, c["start"]),
            "--out", str(ROOT / c["out"])]
    subprocess.run(cmd, check=True, cwd=ROOT)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pick")
    p.add_argument("map")
    p.add_argument("x", type=float)
    p.add_argument("z", type=float)
    p = sub.add_parser("photo")
    p.add_argument("map")
    p.add_argument("wall")
    p.add_argument("image", type=Path)
    p.add_argument("--corners", nargs=4, help="x,y of the facade corners: top-left top-right bottom-right bottom-left")
    p.add_argument("--height", type=float, help="also set the building's height (m)")
    p = sub.add_parser("height")
    p.add_argument("map")
    p.add_argument("id", help="OSM id, e.g. way/123456")
    p.add_argument("metres", type=float)
    p = sub.add_parser("model")
    p.add_argument("map")
    p.add_argument("id")
    p.add_argument("res", help="res://assets/rio_grande_do_sul/landmarks/<name>.glb")
    p = sub.add_parser("rebuild")
    p.add_argument("map")
    a = ap.parse_args()
    if a.cmd == "pick":
        out = pick(a.map, a.x, a.z)
    elif a.cmd == "photo":
        corners = [tuple(float(v) for v in c.split(",")) for c in a.corners] if a.corners else None
        out = photo(a.map, a.wall, a.image, corners, a.height)
    elif a.cmd == "height":
        out = set_height(a.map, a.id, a.metres)
    elif a.cmd == "model":
        out = set_model(a.map, a.id, a.res)
    else:
        rebuild(a.map)
        return
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
