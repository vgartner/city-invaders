#!/usr/bin/env python3
"""Cut an area of a city into a grid of map tiles for the open world
(docs/OPEN_WORLD.md).

    tools/.venv/bin/python tools/map/tiles.py poa --name centro_world --bounds -350 -330 400 420
    tools/.venv/bin/python tools/map/far_view.py centro_world
    godot --headless --path godot --import

The area (metres from the source map's centre, y north - the same frame as
its build.json) is cut into square tiles of --size metres. Each tile becomes
a map of its own, `<name>_<column>_<row>` (column from the west, row from the
south), with the source map's data, photos and hand edits and `"tile": true`:
`maps/<id>/build.json` is written and the map built like any other
(building_photo.py rebuild). `godot/city/<name>.world.json` lists the tiles;
a round started on one of them (`start_solo map=<name>_1_1`, or the menu's
entry for the world, which starts on the middle tile) streams the others in
round the player.

A tile that does not build (all water, no street to start on) is left out.
"""
import argparse
import json
import math
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEEP = ("osm", "lat", "lon", "facades", "terrain", "textures", "kit_facades", "corridor")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="the map whose data the tiles are cut from (maps/<source>/build.json)")
    ap.add_argument("--name", required=True, help="the world's name: tiles are <name>_<column>_<row>")
    ap.add_argument("--bounds", type=float, nargs=4, required=True, metavar=("MIN_X", "MIN_Y", "MAX_X", "MAX_Y"))
    ap.add_argument("--size", type=float, default=250.0, help="a tile's side in metres (default 250)")
    ap.add_argument("--jobs", type=int, default=2, help="tiles built at the same time (each takes a few GB)")
    ap.add_argument("--label", help="the menu entry (default: '<Name> (open world, prototype)')")
    ap.add_argument("--start", help="the tile a round starts on (default: the one in the middle)")
    ap.add_argument("--no-build", action="store_true", help="write the settings and the list only")
    a = ap.parse_args()

    src = json.loads((ROOT / "maps" / a.source / "build.json").read_text())
    x0, y0, x1, y1 = a.bounds
    cols = max(1, math.ceil((x1 - x0) / a.size - 1e-6))
    rows = max(1, math.ceil((y1 - y0) / a.size - 1e-6))
    tiles = []
    for c in range(cols):
        for r in range(rows):
            tid = f"{a.name}_{c}_{r}"
            b = [x0 + c * a.size, y0 + r * a.size, x0 + (c + 1) * a.size, y0 + (r + 1) * a.size]
            cfg = {k: src[k] for k in KEEP if k in src}
            cfg.setdefault("kit_facades", "all")
            cfg.update(bounds=b, tile=True, shared_textures=f"{a.name}_tx", out=f"godot/city/{tid}.glb",
                       user=src.get("user", f"maps/{a.source}/user"),
                       start=[round((b[0] + b[2]) / 2), round(-(b[1] + b[3]) / 2)])     # x, z
            d = ROOT / "maps" / tid
            d.mkdir(parents=True, exist_ok=True)
            (d / "build.json").write_text(json.dumps(cfg, indent=1) + "\n")
            tiles.append({"id": tid, "col": c, "row": r, "bounds": [b[0], b[2], -b[3], -b[1]]})   # x0, x1, z0, z1

    def build(t):
        if a.no_build:
            return t, True, ""
        p = subprocess.run([sys.executable, str(ROOT / "tools" / "map" / "building_photo.py"), "rebuild", t["id"]],
                           cwd=ROOT, capture_output=True, text=True)
        return t, p.returncode == 0, (p.stderr.strip().splitlines() or [""])[-1]

    built = []
    with ThreadPoolExecutor(max(1, a.jobs)) as pool:
        for t, ok, why in pool.map(build, tiles):
            print(f"{t['id']}: {'built' if ok else 'left out - ' + why}", flush=True)
            if ok:
                built.append(t)
    if not a.no_build:                 # the images no tile draws with any more
        subprocess.run([sys.executable, str(ROOT / "tools" / "map" / "texture_imports.py"),
                        "--prune", f"{a.name}_tx"], cwd=ROOT)
    world = ROOT / "godot" / "city" / f"{a.name}.world.json"
    # a rebuild keeps what else the list says (the menu label, the far view, a goal)
    entry = json.loads(world.read_text()) if world.exists() else {}
    entry.update(size=a.size, source=a.source, tiles=built)
    if a.label:
        entry["label"] = a.label
    if a.start:
        entry["start"] = a.start
    world.write_text(json.dumps(entry, indent=1) + "\n")
    print(f"{len(built)} of {len(tiles)} tiles ({cols} x {rows}) in {world.relative_to(ROOT)}")
    print(f"next: tools/map/far_view.py {a.name} (the far view), then godot --headless --path godot --import")


if __name__ == "__main__":
    main()
