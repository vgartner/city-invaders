#!/usr/bin/env python3
"""OpenStreetMap city loader shared by the map tools: projection to local
metres, building footprints (ways and multipolygons) with heights, eroded
and de-overlapped so neighbours never share walls, parks, streets and water.

Walls are identified by "keys": their two end points in integer key units
(UNITS_PER_M per metre, y pointing south), as written in the facade files
(facades.json, facades_user.json). The unit is kept for those files.
"""
import json
import math
from pathlib import Path

from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import unary_union

UNITS_PER_M = 320          # wall-key units per metre
STOREY_M = 3.2
ERODE_M = 0.3              # shrink every building by this much
MIN_GAP_M = 0.4            # extra clearance against already placed buildings
MIN_AREA_M2 = 8.0
SIMPLIFY_M = 0.3
EDGE_MARGIN_M = 3.0


def project(lat0, lon0):
    kx = 111320.0 * math.cos(math.radians(lat0))
    ky = 110540.0

    def f(lat, lon):
        return ((lon - lon0) * kx, (lat - lat0) * ky)  # metres, y north
    return f


def way_polygon(el, proj):
    pts = [proj(p["lat"], p["lon"]) for p in el.get("geometry", [])]
    if len(pts) < 4 or pts[0] != pts[-1]:
        return None
    poly = Polygon(pts)
    if not poly.is_valid:
        poly = poly.buffer(0)
    return poly if not poly.is_empty else None


def relation_polygon(rel, ways, proj):
    """Multipolygon relation (e.g. a building drawn as outer/inner rings
    from several ways) -> polygon, or None if its rings don't close."""
    from shapely.ops import polygonize
    rings = {"outer": [], "inner": []}
    for m in rel.get("members", []):
        w = ways.get(m["ref"]) if m["type"] == "way" else None
        if w and len(w.get("geometry", [])) >= 2:
            rings["inner" if m.get("role") == "inner" else "outer"].append(
                LineString([proj(p["lat"], p["lon"]) for p in w["geometry"]]))
    if not rings["outer"]:
        return None
    outer = unary_union(list(polygonize(unary_union(rings["outer"]))))
    if outer.is_empty:
        return None
    if rings["inner"]:
        holes = unary_union(list(polygonize(unary_union(rings["inner"]))))
        outer = outer.difference(holes)
    outer = outer.buffer(0)
    return outer if not outer.is_empty else None


def parts(geom):
    if geom.is_empty:
        return []
    if isinstance(geom, Polygon):
        return [geom]
    if isinstance(geom, MultiPolygon):
        return list(geom.geoms)
    return [g for g in getattr(geom, "geoms", []) if isinstance(g, Polygon)]


def building_height(tags, area=None):
    try:
        if "height" in tags:
            return max(3.0, float(tags["height"].split()[0].replace(",", ".")))
        if "building:levels" in tags:
            return max(1, float(tags["building:levels"])) * STOREY_M + 0.6
    except ValueError:
        pass
    kind = tags.get("building", "yes")
    # A kiosk (a newsstand on a pavement, 2 x 5 m) or any footprint too
    # small for a room behind a shop front is one low storey: at the
    # downtown default it stood as a 7 m slab, a piece of wall.
    if kind == "kiosk" or tags.get("shop") in ("kiosk", "newsagent") or tags.get("amenity") == "kiosk" \
            or (area is not None and area < 15.0):
        return 3.0
    if kind in ("house", "residential", "garage", "shed", "roof"):
        return STOREY_M + 0.8
    if kind in ("church", "cathedral"):
        return 14.0
    return 2 * STOREY_M + 0.6  # downtown default: two storeys


def water_polygon(data, proj, extent):
    """Water (lakes, rivers) inside `extent`, from natural=water multipolygon
    relations. Only the member ways near the map are in an OSM extract, so
    the relation can't be closed: the shoreline instead cuts `extent` into
    pieces, and the pieces crossed by a navigation fairway (or containing a
    tagged water way) are the water side."""
    from shapely.ops import split, linemerge
    ways = {el["id"]: el for el in data["elements"] if el["type"] == "way"}
    shore = []
    for el in data["elements"]:
        if el["type"] == "relation" and el.get("tags", {}).get("natural") == "water":
            for m in el.get("members", []):
                w = ways.get(m["ref"]) if m["type"] == "way" else None
                if w and len(w.get("geometry", [])) >= 2:
                    shore.append(LineString([proj(p["lat"], p["lon"]) for p in w["geometry"]]))
    seeds = [LineString([proj(p["lat"], p["lon"]) for p in w["geometry"]]) for w in ways.values()
             if w.get("tags", {}).get("waterway") == "fairway" and len(w.get("geometry", [])) >= 2]
    land = [LineString([proj(p["lat"], p["lon"]) for p in w["geometry"]]) for w in ways.values()
            if (w.get("tags", {}).get("highway") or w.get("tags", {}).get("building"))
            and w.get("tags", {}).get("highway") != "ferry" and len(w.get("geometry", [])) >= 2]
    if not shore:
        return None
    merged = linemerge(unary_union(shore))
    # the shore pieces in an extract may stop short of a big extent (horizon):
    # carry the open ends on in their last direction so the line cuts it through
    cut = []
    for ln in getattr(merged, "geoms", [merged]):
        c = list(ln.coords)
        if len(c) >= 2 and not ln.is_ring:
            def ext(a, b):
                dx, dy = a[0] - b[0], a[1] - b[1]
                k = 5000.0 / max(math.hypot(dx, dy), 1e-6)
                return (a[0] + dx * k, a[1] + dy * k)
            c = [ext(c[0], c[1])] + c + [ext(c[-1], c[-2])]
        cut.append(LineString(c))
    try:
        pieces = split(extent, unary_union(cut))
    except Exception:
        return None
    # water side: crossed by a navigation fairway, or (no fairway in the
    # extract) a sizeable piece without any street or building in it
    land_u = unary_union(land) if land else None
    def is_water(piece):
        if any(piece.intersects(s) for s in seeds):
            return True
        if seeds or piece.area < 2000:
            return False
        return land_u is None or land_u.intersection(piece).length < 1.0
    water = [p for p in getattr(pieces, "geoms", [pieces]) if is_water(p)]
    return unary_union(water).intersection(extent) if water else None


def load(osm_path, lat0, lon0, half_m, bounds=None, heights=None):
    """bounds: (min_x, min_y, max_x, max_y) in metres (y north), else a square
    of half size half_m. Water inside the bounds is cut out of the area.
    heights: {"way/123": metres} overrides (tools/map/building_photo.py); every
    building's tags carry its OSM id as "@id"."""
    proj = project(lat0, lon0)
    data = json.loads(Path(osm_path).read_text())
    area = box(*bounds) if bounds else box(-half_m, -half_m, half_m, half_m)
    water = water_polygon(data, proj, area)
    if water is not None and not water.is_empty:
        area = area.difference(water)
    inner = area.buffer(-EDGE_MARGIN_M, join_style=2)
    buildings, parks, streets = [], [], []
    ways = {el["id"]: el for el in data["elements"] if el["type"] == "way"}
    for el in data["elements"]:
        tags = el.get("tags", {})
        if el["type"] == "relation" and tags.get("type") == "multipolygon" and "building" in tags:
            poly = relation_polygon(el, ways, proj)
            for p in parts(poly) if poly is not None else []:
                buildings.append((p, dict(tags, **{"@id": f"relation/{el['id']}"})))
            continue
        if el["type"] != "way":
            continue
        if "highway" in tags:
            line = [proj(p["lat"], p["lon"]) for p in el.get("geometry", [])]
            if len(line) >= 2:
                streets.append((tags.get("name", ""), LineString(line)))
            continue
        poly = way_polygon(el, proj)
        if poly is None:
            continue
        if "building" in tags:
            buildings.append((poly, dict(tags, **{"@id": f"way/{el['id']}"})))
        elif tags.get("leisure") == "park" or tags.get("place") == "square":
            parks.append(poly)

    # Largest buildings first so small overlapping fragments yield to them.
    buildings.sort(key=lambda b: -b[0].area)
    placed, placed_union = [], []
    for poly, tags in buildings:
        poly = Polygon(poly.exterior).intersection(inner)
        poly = poly.buffer(-ERODE_M, join_style=2)
        if placed_union:
            poly = poly.difference(unary_union(placed_union).buffer(MIN_GAP_M, join_style=2))
        for p in parts(poly):
            p = Polygon(p.exterior).simplify(SIMPLIFY_M, preserve_topology=True)
            if p.area < MIN_AREA_M2 or p.minimum_rotated_rectangle.length < 1:
                continue
            # reject slivers: thinner than ~1.2 m
            if p.area / max(p.length, 1e-6) < 0.3:
                continue
            h = (heights or {}).get(tags["@id"]) or building_height(tags, p.area)
            placed.append((p, float(h), tags))
            placed_union.append(p)

    park_sectors = []
    for park in parks:
        park = park.intersection(inner)
        crossing = [b for b, _, _ in placed if b.intersects(park) and not park.contains(b)]
        if crossing:
            park = park.difference(unary_union(crossing).buffer(MIN_GAP_M, join_style=2))
        for p in parts(park):
            p = Polygon(p.exterior).simplify(SIMPLIFY_M, preserve_topology=True)
            if p.area > 50:
                park_sectors.append(p)
    return area, placed, park_sectors, streets


def to_build(pt):
    return (int(round(pt[0] * UNITS_PER_M)), int(round(-pt[1] * UNITS_PER_M)))


def ring_points(poly, outer):
    """Integer key-space ring (y down); outer loops clockwise (positive
    shoelace), inner loops counter-clockwise."""
    pts = []
    for p in list(poly.exterior.coords)[:-1]:
        q = to_build(p)
        if not pts or pts[-1] != q:
            pts.append(q)
    while len(pts) > 1 and pts[0] == pts[-1]:
        pts.pop()
    s = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1]
            for i in range(len(pts)))
    if (s > 0) != outer:
        pts.reverse()
    return pts
