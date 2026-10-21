#!/usr/bin/env python3
"""Fill in building footprints OpenStreetMap is missing, from Overture Maps
(which conflates OSM with Google Open Buildings and Microsoft ML Buildings
footprints detected in satellite imagery).

Small towns are often only partly mapped in OSM: the blocks of a map built
from OSM alone end up mostly empty. This fetches the Overture buildings in
the box, drops the ones that come from OSM or overlap an OSM building, and
appends the rest to the Overpass-style JSON as `building=yes` ways, with
the Overture height / floor count when known and otherwise a plausible,
deterministic number of storeys (2-4, more for large footprints).

Needs `duckdb` in the tools venv; behind a TLS-inspecting proxy pass --ext-dir
with httpfs/spatial extensions downloaded by hand (curl --cacert).

    tools/.venv/bin/python tools/map/overture_buildings.py maps/lajeado/data/osm_centro.json \\
        --lat -29.4675 --lon -51.9625 --half 280 --out maps/lajeado/data/osm_centro_plus.json
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path

RELEASE = "2026-09-23.1"
SOURCE = "s3://overturemaps-us-west-2/release/{rel}/theme=buildings/type=building/*"


def fetch(lat, lon, half, release, ext_dir=None, ca=None):
    import duckdb
    con = duckdb.connect()
    for e in ("httpfs", "spatial"):
        if ext_dir:
            con.execute(f"FORCE INSTALL '{Path(ext_dir) / (e + '.duckdb_extension')}'")
        else:
            con.execute(f"INSTALL {e}")
        con.execute(f"LOAD {e}")
    if ca:
        con.execute(f"SET ca_cert_file='{ca}'")
    con.execute("SET s3_region='us-west-2'")
    dlat = half / 110540
    dlon = half / (111320 * math.cos(math.radians(lat)))
    rows = con.execute(f"""
        SELECT id, height, num_floors, sources[1].dataset, ST_AsGeoJSON(geometry)
        FROM read_parquet('{SOURCE.format(rel=release)}', hive_partitioning=1)
        WHERE bbox.xmin > {lon - dlon} AND bbox.xmax < {lon + dlon}
          AND bbox.ymin > {lat - dlat} AND bbox.ymax < {lat + dlat}""").fetchall()
    return [{"id": r[0], "height": r[1], "floors": r[2], "src": r[3], "geom": json.loads(r[4])} for r in rows]


def storeys(oid, area_m2):
    """Deterministic storey guess for an untagged footprint (Brazilian town centre)."""
    u = int(hashlib.md5(oid.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    if area_m2 < 60:
        return 1 if u < 0.6 else 2
    base = 2 + int(u * 3)                       # 2-4
    if area_m2 > 600 and u > 0.6:
        base += 2 + int((u - 0.6) * 15)          # some larger buildings are taller
    return base


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm", type=Path, help="Overpass-style JSON (from osmxml2json.py)")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=280, help="half size of the box (m)")
    ap.add_argument("--release", default=RELEASE)
    ap.add_argument("--ext-dir", help="folder with httpfs/spatial .duckdb_extension files")
    ap.add_argument("--ca", default=os.environ.get("SSL_CERT_FILE") or os.environ.get("REQUESTS_CA_BUNDLE"),
                    help="CA bundle, behind a TLS-inspecting proxy (default: $SSL_CERT_FILE)")
    ap.add_argument("--cache", type=Path, help="Overture rows JSON (written on first fetch)")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    from shapely.geometry import Polygon, shape
    from shapely.strtree import STRtree

    if args.cache and args.cache.exists():
        rows = json.loads(args.cache.read_text())
    else:
        rows = fetch(args.lat, args.lon, args.half, args.release, args.ext_dir,
                     args.ca if args.ca and Path(args.ca).exists() else None)
        if args.cache:
            args.cache.write_text(json.dumps(rows))
    data = json.loads(args.osm.read_text())
    kx = 111320 * math.cos(math.radians(args.lat))

    def metric(g):
        return Polygon([((x - args.lon) * kx, (y - args.lat) * 110540) for x, y in g])

    osm_b = [metric([(p["lon"], p["lat"]) for p in el["geometry"]]) for el in data["elements"]
             if el["type"] == "way" and "building" in el.get("tags", {}) and len(el["geometry"]) >= 4]
    tree = STRtree(osm_b)
    added = skipped = 0
    next_id = -1
    for r in rows:
        if r["src"] == "OpenStreetMap":
            continue
        g = shape(r["geom"])
        for poly in getattr(g, "geoms", [g]):
            ring = list(poly.exterior.coords)
            m = metric(ring).buffer(0)
            if m.area < 12:
                continue
            if any(m.intersection(osm_b[i]).area > 0.3 * min(m.area, osm_b[i].area) for i in tree.query(m)):
                skipped += 1
                continue
            tags = {"building": "yes", "source": f"Overture ({r['src']})"}
            if r["height"]:
                tags["height"] = f"{r['height']:.1f}"
            else:
                tags["building:levels"] = str(int(r["floors"] or storeys(r["id"], m.area)))
            data["elements"].append({"type": "way", "id": next_id, "tags": tags,
                                     "geometry": [{"lat": y, "lon": x} for x, y in ring]})
            next_id -= 1
            added += 1
    args.out.write_text(json.dumps(data))
    print(f"Overture: {len(rows)} buildings, {added} added, {skipped} overlapping OSM skipped -> {args.out}")


if __name__ == "__main__":
    main()
