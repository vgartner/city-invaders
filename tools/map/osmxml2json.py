#!/usr/bin/env python3
"""Convert an OSM API 0.6 /map XML response into the Overpass-style JSON
(`out body geom`) that osmcity.py reads: ways with inline geometry,
tagged nodes, and relations with their member references.

    tools/map/osmxml2json.py in.osm out.json"""
import json
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
nodes = {n.get("id"): (float(n.get("lat")), float(n.get("lon"))) for n in root.iter("node")}
elements = []
for w in root.iter("way"):
    refs = [nd.get("ref") for nd in w.iter("nd")]
    if not all(r in nodes for r in refs):
        continue
    tags = {t.get("k"): t.get("v") for t in w.iter("tag")}
    elements.append({"type": "way", "id": int(w.get("id")), "tags": tags,
                     "geometry": [{"lat": nodes[r][0], "lon": nodes[r][1]} for r in refs]})
for n in root.iter("node"):
    tags = {t.get("k"): t.get("v") for t in n.iter("tag")}
    if tags:
        elements.append({"type": "node", "id": int(n.get("id")), "lat": float(n.get("lat")),
                         "lon": float(n.get("lon")), "tags": tags})
# relations (members by reference): water multipolygons are assembled from
# their (untagged) member ways, which are exported above with geometry
for r in root.iter("relation"):
    tags = {t.get("k"): t.get("v") for t in r.iter("tag")}
    members = [{"type": m.get("type"), "ref": int(m.get("ref")), "role": m.get("role")} for m in r.iter("member")]
    elements.append({"type": "relation", "id": int(r.get("id")), "tags": tags, "members": members})
json.dump({"elements": elements}, open(sys.argv[2], "w"))
print(f"{len(elements)} elements")
