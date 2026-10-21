#!/usr/bin/env python3
"""Import a new city in one command: geocode it, download OpenStreetMap,
terrain and the Mapillary photo listing, build the facades and the maps,
import them into Godot and add them to the game's menu.

    tools/.venv/bin/python tools/map/new_city.py "Santa Cruz do Sul" --size 400 --phases 2

Each phase is a size x size map; phases run eastwards, overlapping by 60 m,
each one's exit leading to the next (godot/city/maps.json). All of a city's
maps share one data folder (maps/<city>/) and one folder of hand edits
(maps/<city>/user/). Needs MAPILLARY_TOKEN in .env for facade photos
(without it the buildings get procedural facades). The in-game map editor
runs this with --log.
"""
import argparse
import json
import shutil
import math
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = sys.executable
UA = {"User-Agent": "CityInvaders-map-tool/0.2 (open-source game; city import)"}
OVERLAP_M = 60.0
M_PER_DEG = 111320.0


def log(msg):
    print(f"[new_city] {msg}", flush=True)


def slug(name):
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "_", s).strip("_")[:24]


def get(url, params=None, timeout=120):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def geocode(place):
    res = json.loads(get("https://nominatim.openstreetmap.org/search", {"q": place, "format": "json", "limit": 1}))
    if not res:
        raise SystemExit(f"place not found: {place}")
    return float(res[0]["lat"]), float(res[0]["lon"]), res[0].get("display_name", place)


def to_deg(lat, x, y):
    """metres east / north of (lat, ...) -> degrees offset (lon, lat)."""
    return x / (M_PER_DEG * math.cos(math.radians(lat))), y / M_PER_DEG


def mapillary_listing(token, west, south, east, north, out):
    fields = ("id,computed_geometry,computed_compass_angle,computed_rotation,captured_at,is_pano,"
              "camera_type,camera_parameters,width,height,sequence")
    data, seen = [], set()
    nx = max(1, int(math.ceil((east - west) / 0.003)))
    ny = max(1, int(math.ceil((north - south) / 0.003)))
    for i in range(nx):
        for j in range(ny):
            w = west + (east - west) * i / nx
            s = south + (north - south) * j / ny
            e = west + (east - west) * (i + 1) / nx
            n = south + (north - south) * (j + 1) / ny
            try:
                page = json.loads(get("https://graph.mapillary.com/images",
                                      {"access_token": token, "bbox": f"{w},{s},{e},{n}", "fields": fields, "limit": 2000}))
            except Exception as ex:                      # one tile failing is not fatal
                log(f"  mapillary tile {i},{j} failed: {ex}")
                continue
            for im in page.get("data", []):
                if im["id"] not in seen:
                    seen.add(im["id"])
                    data.append(im)
    out.write_text(json.dumps({"data": data}))
    return len(data)


def run(args, **kw):
    log("$ " + " ".join(str(a) for a in args[:6]) + (" ..." if len(args) > 6 else ""))
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT, **kw)


def token():
    t = os.environ.get("MAPILLARY_TOKEN")
    env = ROOT / ".env"
    if not t and env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("MAPILLARY_TOKEN="):
                t = line.split("=", 1)[1].strip().strip("\"'")
    return t


def apply_setup(city, setup):
    """The Studio's choices for a new city: which collection's objects, which
    item plays each role, which kinds of places get their models, and the
    opening film. Kept in maps/<city>/user/buildings_user.json (the map editor
    and the game read them there)."""
    ud = ROOT / "maps" / city / "user"
    ud.mkdir(parents=True, exist_ok=True)
    uf = ud / "buildings_user.json"
    user = json.loads(uf.read_text()) if uf.exists() else {}
    for k in ("_collection", "_roles", "_place_kinds_off"):
        if setup.get(k):
            user[k] = setup[k]
    uf.write_text(json.dumps(user, indent=1, ensure_ascii=False) + "\n")
    intro = setup.get("intro", "")
    if intro.startswith("res://"):
        src = ROOT / "godot" / intro[len("res://"):]
        dst = ROOT / "godot" / "assets" / "rio_grande_do_sul" / "video" / "cities" / city / "intro.ogv"
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            log(f"opening film: {intro} -> {dst.relative_to(ROOT)}")
    log(f"setup: collection {user.get('_collection', 'default')}, roles {user.get('_roles', {})}, "
        f"places off {user.get('_place_kinds_off', [])}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("place", help='e.g. "Santa Cruz do Sul" or "Pelotas, Centro"')
    ap.add_argument("--name", help="map id (default: from the place name)")
    ap.add_argument("--title", help='name in the menu (default: the first part of the place, e.g. "Pelotas")')
    ap.add_argument("--size", type=float, default=400.0, help="side of each phase map in metres")
    ap.add_argument("--phases", type=int, default=1)
    ap.add_argument("--goal", type=int, default=25, help="robots to destroy per phase")
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lon", type=float)
    ap.add_argument("--no-photos", action="store_true", help="skip Mapillary (procedural facades only)")
    ap.add_argument("--clean", action="store_true", help="paint people/cars out of the photos (ML venv)")
    ap.add_argument("--no-overture", action="store_true", help="don't add Overture footprints missing from OSM")
    ap.add_argument("--osm-file", help="build from this OSM JSON (tools/map/gen_city.py) instead of downloading: "
                    "a generated town - flat, no photos")
    ap.add_argument("--setup", help="JSON from the Studio's import window: _collection, _roles, "
                    "_place_kinds_off (kept in the city's user edits) and intro (a film for its opening)")
    ap.add_argument("--no-audit", action="store_true", help="skip the street audit (tools/map/street_audit.py) after the build")
    a = ap.parse_args()

    if a.osm_file:
        gen = json.loads(Path(a.osm_file).read_text())
        lat, lon, label = gen.get("lat", -29.7), gen.get("lon", -53.1), a.place
        a.no_photos = True
    elif a.lat is None:
        lat, lon, label = geocode(a.place)
    else:
        lat, lon, label = a.lat, a.lon, a.place
    city = a.name or slug(a.place.split(",")[0])
    log(f"{label}: {lat:.5f}, {lon:.5f} -> maps/{city}/")
    d = ROOT / "maps" / city
    (d / "data").mkdir(parents=True, exist_ok=True)
    (d / "mapillary").mkdir(exist_ok=True)
    if a.setup:
        apply_setup(city, json.loads(Path(a.setup).read_text()))

    # the whole strip of phases, centred on the place
    S, N = a.size, max(1, a.phases)
    total = S * N - OVERLAP_M * (N - 1)
    x0 = -total / 2
    bounds_all = [x0, -S / 2, x0 + total, S / 2]
    phases = []
    for k in range(N):
        bx = x0 + k * (S - OVERLAP_M)
        phases.append([bx, -S / 2, bx + S, S / 2])

    # 1. OpenStreetMap (100 m margin), as Overpass-style JSON
    m = 100.0
    (dw, ds), (de, dn) = to_deg(lat, bounds_all[0] - m, bounds_all[1] - m), to_deg(lat, bounds_all[2] + m, bounds_all[3] + m)
    bbox = f"{lon + dw:.6f},{lat + ds:.6f},{lon + de:.6f},{lat + dn:.6f}"
    osm_xml = d / "data" / "osm.osm"
    osm_json = d / "data" / "osm.json"
    if a.osm_file:
        shutil.copyfile(a.osm_file, osm_json)
        log("generated town: no download, no Overture, flat ground")
    else:
        log(f"downloading OpenStreetMap {bbox}")
        osm_xml.write_bytes(get("https://api.openstreetmap.org/api/0.6/map", {"bbox": bbox}, timeout=300))
        run([PY, "tools/map/osmxml2json.py", osm_xml, osm_json])
    # many Brazilian towns are only partly mapped: fill the missing footprints
    # from Overture (Google / Microsoft ML buildings, storeys estimated)
    if not a.no_overture and not a.osm_file:
        half = max(abs(v) for v in bounds_all) + 20.0
        try:
            run([PY, "tools/map/overture_buildings.py", osm_json, "--lat", lat, "--lon", lon, "--half", half,
                 "--cache", d / "data" / "overture_buildings.json", "--out", d / "data" / "osm_plus.json"])
            osm_json = d / "data" / "osm_plus.json"
        except subprocess.CalledProcessError:
            log("Overture step failed (duckdb / network): OSM buildings only")
    osm_rel = str(osm_json.relative_to(ROOT))

    # 2. terrain
    if not a.osm_file:
        run([PY, "tools/map/terrain.py", "--lat", lat, "--lon", lon, "--bounds", *bounds_all, "--out", d / "data" / "terrain.json"])

    # 3. facades from Mapillary
    facades = []
    tok = token()
    if tok and not a.no_photos:
        (w, s), (e, n) = to_deg(lat, bounds_all[0], bounds_all[1]), to_deg(lat, bounds_all[2], bounds_all[3])
        count = mapillary_listing(tok, lon + w, lat + s, lon + e, lat + n, d / "mapillary" / "images.json")
        log(f"{count} Mapillary photos in the area")
        if count:
            run([PY, "tools/map/mapillary_facades.py", osm_json, "--images", d / "mapillary" / "images.json",
                 "--lat", lat, "--lon", lon, "--bounds", *bounds_all, "--outdir", d / "facades"])
            facades.append(f"maps/{city}/facades/facades.json")
            ml = Path.home() / ".local/share/city-invaders-ml/bin/python"
            if a.clean and ml.exists():
                run([ml, "tools/map/clean_facades.py", d / "facades" / "facades.json"])
                facades[-1] = f"maps/{city}/facades/facades_clean.json"
    else:
        log("no MAPILLARY_TOKEN (or --no-photos): procedural facades only")

    # 4. procedural textures, then one map per phase
    run([PY, "tools/map/gen_textures.py", d / "out" / f"{city}_tex"])
    ids = [city if N == 1 else f"{city}_{k + 1}" for k in range(N)]
    for k, (mid, b) in enumerate(zip(ids, phases)):
        md = ROOT / "maps" / mid
        md.mkdir(parents=True, exist_ok=True)
        cfg = {"osm": osm_rel, "lat": lat, "lon": lon, "bounds": b, "facades": facades,
               "terrain": "" if a.osm_file else f"maps/{city}/data/terrain.json", "textures": f"maps/{city}/out/{city}_tex",
               "start": [b[0] + 40.0, 0.0], "out": f"godot/city/{mid}.glb", "user": f"maps/{city}/user",
               "ring": True}                    # car roads end at the outer road loop
        (md / "build.json").write_text(json.dumps(cfg, indent=1) + "\n")
        run([PY, "tools/map/building_photo.py", "rebuild", mid])

    # 5. import into Godot and register in the menu
    godot = os.environ.get("GODOT", "godot")
    try:
        run([godot, "--headless", "--path", "godot", "--import"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        log("could not run Godot's import; open the project once in Godot")
    reg_path = ROOT / "godot" / "city" / "maps.json"
    reg = json.loads(reg_path.read_text()) if reg_path.exists() else []
    reg = [r for r in reg if r[0] not in ids]
    name = a.title or a.place.split(",")[0].strip()
    for k, mid in enumerate(ids):
        label_k = name if N == 1 else f"{name} · Phase {k + 1}"
        nxt = ids[k + 1] if k + 1 < N else ""
        reg.append([mid, label_k, nxt, a.goal if N > 1 else 0, "east"])
    reg_path.write_text(json.dumps(reg, indent=1, ensure_ascii=False) + "\n")
    log(f"done: {', '.join(ids)} in the menu")
    # 6. drive every street in a test instance: level, drivable, nothing on the lanes
    if not a.no_audit:
        for mid in ids:
            try:
                subprocess.run([PY, "tools/map/street_audit.py", mid], cwd=ROOT, env=dict(os.environ, DEVAGENT_PORT="24691"))
            except OSError as e:
                log(f"street audit skipped: {e}")


if __name__ == "__main__":
    main()
