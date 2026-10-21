#!/usr/bin/env python3
"""Trace one object in the running game: samples its position, velocity and
a few fields many times a second through the DevAgent and writes a CSV, then
prints what looks wrong (hops: height jumping up and down, teleports, being
off the floor while not jumping).

    tools/devagent/devagent_trace.py C80                      # a pedestrian, robot or vehicle by name
    tools/devagent/devagent_trace.py C80 --seconds 20 --hz 30 --out /tmp/c80.csv
    tools/devagent/devagent_trace.py Players/1

The node is looked up under the civilians, enemies and traffic roots, or as
a path from the main scene.
"""
import argparse
import csv
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devagent import DevAgent  # noqa: E402


def find_node(da, name: str) -> str:
    """An Expression for the node (the DevAgent's eval has no ternaries)."""
    if "/" in name:
        return 'main.get_node("%s")' % name
    for r in ["civilians_root", "enemies_root", "traffic_root"]:
        if da.call("eval", expr='main.%s.has_node("%s")' % (r, name)).get("value") == "true":
            return 'main.%s.get_node("%s")' % (r, name)
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--seconds", type=float, default=15.0)
    ap.add_argument("--hz", type=float, default=20.0)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    da = DevAgent(timeout=10)
    n = find_node(da, a.name)
    if not n:
        print("no such object: %s" % a.name)
        return 1
    on_floor = da.call("eval", expr="%s.has_method(\"is_on_floor\")" % n).get("value") == "true"
    # one list as text: position, velocity (or null), on the floor, state
    expr = "str([%s.global_position, %s.get(\"velocity\"), %s, %s.get(\"state\")])" % (
        n, n, "%s.is_on_floor()" % n if on_floor else "\"-\"", n)
    out = a.out or "/tmp/trace_%s.csv" % a.name.replace("/", "_")
    rows = []
    end = time.time() + a.seconds
    while time.time() < end:
        v = str(da.call("eval", expr=expr).get("value", ""))
        ms = int(time.time() * 1000)
        nums = re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", v)
        vel = v.count("(") >= 2
        x, y, z = map(float, nums[0:3])
        vx, vy, vz = map(float, nums[3:6]) if vel else (0.0, 0.0, 0.0)
        rest = v.strip("[]").rsplit(",", 2)
        floor, state = rest[-2].strip().strip('"'), rest[-1].strip()
        rows.append([x, y, z, vx, vy, vz, floor, state, ms])
        time.sleep(1.0 / a.hz)
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["x", "y", "z", "vx", "vy", "vz", "on_floor", "state", "ms"])
        w.writerows(rows)
    # what looks wrong
    hops, jumps, airborne = 0, 0, 0
    for i in range(1, len(rows)):
        dt = max(1, rows[i][8] - rows[i - 1][8]) / 1000.0
        dy = rows[i][1] - rows[i - 1][1]
        dxz = ((rows[i][0] - rows[i - 1][0]) ** 2 + (rows[i][2] - rows[i - 1][2]) ** 2) ** 0.5
        if abs(dy) > 0.12:
            hops += 1
            print("  %6.2f s  height %+.2f m  (y %.2f -> %.2f) at %.1f, %.1f  floor=%s state=%s" % (
                (rows[i][8] - rows[0][8]) / 1000.0, dy, rows[i - 1][1], rows[i][1], rows[i][0], rows[i][2],
                rows[i][6], rows[i][7]))
        if dxz / dt > 15.0:
            jumps += 1
            print("  %6.2f s  teleport %.1f m" % ((rows[i][8] - rows[0][8]) / 1000.0, dxz))
        if rows[i][6] == "false":
            airborne += 1
    ys = [r[1] for r in rows]
    print("%d samples over %.1f s -> %s" % (len(rows), a.seconds, out))
    print("height %.2f..%.2f, %d height jumps > 0.12 m, %d teleports, off the floor in %d samples" % (
        min(ys), max(ys), hops, jumps, airborne))
    return 0


if __name__ == "__main__":
    sys.exit(main())
