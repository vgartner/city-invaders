#!/usr/bin/env python3
"""Street audit: are a map's streets level and drivable?

Opens a test instance of the game (DevAgent on port 24691, never the
player's own game), starts the map and drives every street of its traffic
graph in thought (dev_agent.gd `audit_streets`): every 2 m along each lane,
rays down find the street surface and anything standing on it.

    tools/map/street_audit.py gasometro             # report, worst first
    tools/map/street_audit.py gasometro --json out.json

It reports steps and dents in the surface, too steep or leaning streets,
holes, and buildings, props or landmarks standing on a lane - with the
street's name and the place, so a hand-placed model can be moved in the map
editor (F2) and the terrain settings in tools/map/osm2gltf.py tuned. The report
is also written to maps/<map>/out/street_audit.json. Exit code 1 when a
lane is blocked or has a hole (tools/map/new_city.py runs it after a build).
"""
import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("DEVAGENT_PORT", "24691")
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "devagent"))
import devagent  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map")
    ap.add_argument("--json", type=Path, help="also write the report here")
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--keep", action="store_true", help="leave the test instance running")
    args = ap.parse_args()
    if devagent.PORT == 24690:
        sys.exit("refusing to audit on port 24690 (the player's game): set DEVAGENT_PORT")
    started = not devagent.reachable()
    devagent.launch(wait=120)
    agent = devagent.DevAgent(timeout=600)
    try:
        agent.call("start_solo", map=args.map)
        time.sleep(4)                                   # the map's physics settles
        rep = agent.call("audit_streets", limit=args.limit)
    finally:
        if started and not args.keep:
            try:
                agent.call("quit")
            except Exception:
                pass
    rep["furniture"] = furniture(args.map)
    out = ROOT / "maps" / args.map / "out" / "street_audit.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(rep, indent=1, ensure_ascii=False))
    if args.json:
        args.json.write_text(json.dumps(rep, indent=1, ensure_ascii=False))
    if rep.get("error"):
        sys.exit(rep["error"])
    print(f"{args.map}: {rep['metres']} m of lanes on {rep['edges']} street pieces")
    print("totals:", rep["totals"] or "nothing found")
    unit = {"step": "m", "dent": "m", "steep": "", "tilt": "", "hole": "", "blocked": "m high"}
    for f in rep["findings"]:
        x, y, z = f["pos"]
        size = f"{f['size'] * 100:.0f}%" if f["kind"] in ("steep", "tilt") else f"{f['size']:.2f} {unit[f['kind']]}"
        print(f"  {f['kind']:8} {size:>12}  at ({x:7.1f}, {z:7.1f})  {f['street'] or '-':32} {f['what']}")
    for f in rep["furniture"]:
        print(f"  {f['kind']:8} {f['what']:>12}  at ({f['pos'][0]:7.1f}, {f['pos'][1]:7.1f})  {f['detail']}")
    print("report:", out.relative_to(ROOT))
    sys.exit(1 if rep["totals"].get("blocked") or rep["totals"].get("hole") or rep["furniture"] else 0)


def _faces():
    """prop type or model -> its `faces` rule (the entity definitions)."""
    by = {}
    for f in (ROOT / "godot" / "assets").rglob("*.def.json"):
        try:
            d = json.loads(f.read_text())
        except ValueError:
            continue
        if d.get("faces"):
            for k in (d.get("prop"), d.get("model")):
                if k:
                    by[k] = d["faces"]
    return by


def furniture(map_id):
    """Street furniture with a front (`faces`) that turns its back on its street
    (more than 60 degrees off), or stands on a lane: the map's props and the
    models placed by hand."""
    city = ROOT / "godot" / "city"
    roads = json.loads((city / f"{map_id}.roads.json").read_text())
    segs = []
    for e in roads["edges"]:
        pts = e["pts"]
        segs += [((a[0], a[1]), (b[0], b[1]), 0.9 if e["oneway"] else 1.7) for a, b in zip(pts[:-1], pts[1:])]
    rules = _faces()
    things = []
    for p in json.loads((city / f"{map_id}.props.json").read_text()):
        key = p["type"] + (":" + p["stall"] if p.get("stall") else "")
        rule = rules.get(key) or rules.get(p["type"])
        if rule:
            things.append((key, p["pos"][0], p["pos"][2], p["yaw"], rule))
    for lm in json.loads((city / f"{map_id}.landmarks.json").read_text()):
        rule = rules.get(lm.get("model", ""))
        if rule:
            things.append((lm["model"].split("/")[-1], lm["pos"][0], lm["pos"][2], math.radians(lm.get("yaw", 0.0))
                           if abs(lm.get("yaw", 0.0)) > 6.3 else lm.get("yaw", 0.0), rule))
    out = []
    for what, x, z, yaw, rule in things:
        best = None
        for a, b, lane in segs:
            ax, az = a
            bx, bz = b
            L2 = (bx - ax) ** 2 + (bz - az) ** 2 or 1e-9
            t = max(0.0, min(1.0, ((x - ax) * (bx - ax) + (z - az) * (bz - az)) / L2))
            qx, qz = ax + t * (bx - ax), az + t * (bz - az)
            d = math.hypot(x - qx, z - qz)
            if best is None or d < best[0]:
                best = (d, qx, qz, lane)
        if best is None or best[0] > 25.0:
            continue
        d, qx, qz, lane = best
        if d < lane + 1.0:
            out.append({"kind": "on lane", "what": what, "pos": [round(x, 1), round(z, 1)],
                        "detail": f"{d:.1f} m from the street's centre line"})
            continue
        if rule.get("towards", "street") != "street":
            continue                     # a walk can be a footway the traffic graph does not have
        axis = {"+z": (0, 1), "-z": (0, -1), "+x": (1, 0), "-x": (-1, 0)}[rule.get("front", "+z")]
        fx = axis[0] * math.cos(yaw) + axis[1] * math.sin(yaw)
        fz = -axis[0] * math.sin(yaw) + axis[1] * math.cos(yaw)
        tx, tz = (qx - x) / d, (qz - z) / d
        off = math.degrees(math.acos(max(-1.0, min(1.0, fx * tx + fz * tz))))
        if off > 60.0:
            out.append({"kind": "facing", "what": what, "pos": [round(x, 1), round(z, 1)],
                        "detail": f"front {off:.0f} degrees away from the street"})
    return out


if __name__ == "__main__":
    main()
