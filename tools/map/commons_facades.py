#!/usr/bin/env python3
"""Facade textures for landmark buildings from Wikimedia Commons.

Buildings that OSM links to Wikidata (`wikidata=Q...`), to a Commons file
(`wikimedia_commons=File:...`) or to an image URL (`image=...`) usually have
a good frontal photo on Commons (Mercado Público, Usina do Gasômetro,
Prefeitura...). For each, the main image (Wikidata P18) is downloaded and
cropped to the proportions of the building's most street-exposed wall,
which then uses it instead of the Mapillary reconstruction.

Writes <outdir>/commons/<name>.jpg and <outdir>/facades_commons.json (same
format as facades.json, keyed by wall), with author and licence of every
photo for the credits. Pass it to osm2gltf after the Mapillary facades:

    tools/.venv/bin/python tools/map/commons_facades.py maps/poa/data/osm_centro.json \\
        --lat -30.0300 --lon -51.2290 --half 250 --outdir maps/poa/facades
    ~/.local/share/city-invaders-ml/bin/python tools/map/crop_landmarks.py maps/poa/facades/facades_commons.json
    tools/.venv/bin/python tools/map/osm2gltf.py ... \\
        --facades maps/poa/facades/facades_clean.json maps/poa/facades/facades_commons.json
"""
import argparse
import io
import json
import math
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image
from shapely.geometry import Point
from shapely.ops import unary_union
from shapely.prepared import prep

sys.path.insert(0, str(Path(__file__).parent))
import osmcity  # noqa: E402

UA = {"User-Agent": "CityInvaders-map-tool/0.1 (hobby game map builder; City Invaders)"}
PX_PER_M = 40
MAX_PX = 2048


def get(url, binary=False):
    """Polite fetch: Wikimedia rate-limits bursts (HTTP 429), so pause between
    requests and back off when told to."""
    import time
    for k in range(6):
        time.sleep(1.0)
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            return data if binary else json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code != 429 or k == 5:
                raise
            time.sleep(5 * 2 ** k)


def commons_file(tags):
    """Commons file name for an OSM element, or None."""
    wc = tags.get("wikimedia_commons", "")
    if wc.startswith("File:"):
        return wc[5:]
    img = tags.get("image", "")
    m = re.search(r"commons\.wikimedia\.org/wiki/File:([^?#]+)", img)
    if m:
        return urllib.parse.unquote(m.group(1))
    q = tags.get("wikidata", "")
    if re.fullmatch(r"Q\d+", q):
        ent = get(f"https://www.wikidata.org/wiki/Special:EntityData/{q}.json")["entities"][q]
        p18 = ent.get("claims", {}).get("P18", [])
        if p18:
            return p18[0]["mainsnak"]["datavalue"]["value"]
    return None


def file_info(name):
    """Author / licence / page of a Commons file."""
    q = urllib.parse.urlencode({"action": "query", "titles": "File:" + name, "prop": "imageinfo",
                                "iiprop": "extmetadata|url", "format": "json"})
    pages = get("https://commons.wikimedia.org/w/api.php?" + q)["query"]["pages"]
    info = next(iter(pages.values()))["imageinfo"][0]
    meta = info.get("extmetadata", {})
    strip = lambda v: re.sub(r"<[^>]+>", "", v.get("value", "")).strip()
    return {"author": strip(meta.get("Artist", {})), "licence": strip(meta.get("LicenseShortName", {})),
            "page": info.get("descriptionurl", "")}


def best_wall(poly, height, others, area):
    """(p0, p1, key) of the longest wall that faces open street."""
    U = osmcity.UNITS_PER_M
    pts = osmcity.ring_points(poly, outer=False)
    best, best_score = None, 0.0
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        p0, p1 = (a[0] / U, -a[1] / U), (b[0] / U, -b[1] / U)
        L = math.dist(p0, p1)
        if L < 6:
            continue
        nx, ny = (p1[1] - p0[1]) / L, -(p1[0] - p0[0]) / L        # street side normal
        free = 0
        for t in (0.25, 0.5, 0.75):
            mx, my = p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t
            for dist in (6, 12, 20):
                q = Point(mx + nx * dist, my + ny * dist)
                free += area.contains(q) and not others.contains(q)    # open street inside the map
        score = L * free / 9.0
        if score > best_score:
            best, best_score = (p0, p1, f"{a[0]},{a[1]},{b[0]},{b[1]}"), score
    return best


def crop_to(photo, aspect):
    """Centre crop to width/height = aspect, biased below the middle: building
    photos usually carry sky above the facade."""
    W, H = photo.size
    if W / H > aspect:
        w = int(H * aspect)
        x0 = (W - w) // 2
        return photo.crop((x0, 0, x0 + w, H))
    h = int(W / aspect)
    y0 = int((H - h) * 0.65)
    return photo.crop((0, y0, W, y0 + h))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=150)
    ap.add_argument("--bounds", type=float, nargs=4)
    ap.add_argument("--outdir", type=Path, required=True)
    args = ap.parse_args()
    area, buildings, parks, streets = osmcity.load(args.osm, args.lat, args.lon, args.half, args.bounds)
    (args.outdir / "commons").mkdir(parents=True, exist_ok=True)
    footprints = [b[0] for b in buildings]
    # the Wikidata link is sometimes on the site, not the building (e.g. the
    # Mercado Público's marketplace outline): a building inside such an area
    # inherits it
    proj = osmcity.project(args.lat, args.lon)
    data = json.loads(Path(args.osm).read_text())
    linked_areas = []
    for el in data["elements"]:
        t = el.get("tags", {})
        if el["type"] == "way" and "building" not in t and any(k in t for k in ("wikidata", "wikimedia_commons")):
            pg = osmcity.way_polygon(el, proj)
            if pg is not None:
                linked_areas.append((pg, t))
    # keep what earlier runs fetched (Wikimedia rate-limits; rerun to fill gaps)
    out_json = args.outdir / "facades_commons.json"
    result = json.loads(out_json.read_text()) if out_json.exists() else {}
    have = {r.get("commons_file") for r in result.values()}
    credits, seen = [f"{r['commons_file']} - {r.get('author', '')} ({r.get('licence', '')}) {r.get('page', '')}"
                     for r in result.values()], set()
    for bi, (poly, height, tags) in enumerate(buildings):
        if not any(k in tags for k in ("wikidata", "wikimedia_commons", "image")):
            site = next((t for pg, t in linked_areas if pg.buffer(2.0).contains(poly.centroid)), None)
            if site is None:
                continue
            tags = {**site, **tags}
        if tags.get("wikidata") in seen:
            continue                     # one landmark photo per Wikidata item
        seen.add(tags.get("wikidata"))
        label = tags.get("name") or tags.get("wikidata") or f"building {bi}"
        try:
            name = commons_file(tags)
        except Exception as e:
            print(f"{label}: lookup failed ({e})")
            continue
        if not name:
            print(f"{label}: no Commons image")
            continue
        if name in have:
            print(f"{label}: already fetched")
            continue
        others = prep(unary_union([f for f in footprints if f is not poly]).buffer(0.5))
        wall = best_wall(poly, height, others, prep(area))
        if wall is None:
            print(f"{label}: no street-facing wall")
            continue
        p0, p1, key = wall
        L = math.dist(p0, p1)
        try:
            url = "https://commons.wikimedia.org/w/index.php?" + urllib.parse.urlencode(
                {"title": "Special:FilePath/" + name, "width": 1280})   # a standard thumbnail size
            photo = Image.open(io.BytesIO(get(url, binary=True))).convert("RGB")
            info = file_info(name)
        except Exception as e:
            print(f"{label}: download failed ({e})")
            continue
        (args.outdir / "commons" / "raw").mkdir(exist_ok=True)
        stem0 = re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_")[:40] or f"b{bi}"
        photo.save(args.outdir / "commons" / "raw" / f"{stem0}.jpg", quality=92)
        tex = crop_to(photo, L / height)   # refined to the building by tools/map/crop_landmarks.py
        w = min(MAX_PX, max(64, int(L * PX_PER_M / 8) * 8))
        h = min(MAX_PX, max(64, int(height * PX_PER_M / 8) * 8))
        tex = tex.resize((w, h), Image.LANCZOS)
        stem = re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_")[:40] or f"b{bi}"
        rel = f"commons/{stem}.jpg"
        tex.save(args.outdir / rel, quality=90)
        result[key] = {"file": rel, "raw": f"commons/raw/{stem}.jpg", "w_px": w, "h_px": h,
                       "height_m": height, "source": "commons",
                       "commons_file": name, **info}
        credits.append(f"{label}: {name} - {info['author']} ({info['licence']}) {info['page']}")
        print(f"{label}: {name} -> wall {L:.0f} m x {height:.0f} m ({info['licence']})")
    out_json.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    (args.outdir / "commons" / "CREDITS.txt").write_text("\n".join(credits) + "\n")
    print(f"{len(result)} landmark facades from Wikimedia Commons")


if __name__ == "__main__":
    main()
