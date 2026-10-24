#!/usr/bin/env python3
"""Read an autoplay run (user://devagent/autoplay/run_*.json, written when the
DevAgent's `autoplay` bot finishes) and its F5 recording, and say:

  - what the bot did (robots, pickups, drives, grenades, containers, trades)
  - the frame time per activity (walking, fighting, driving...)
  - a heatmap of the map in 50 m cells: the fps where it went, worst cells first
  - the worst frames and what had just come into the scene
  - the map problems it ran into, grouped by place (10 m): where it got stuck
    and on what, pickups or spots it could not reach, cars that got wedged,
    falls through the ground
  - script errors raised during the run

    tools/bench/autoplay_report.py                # the latest run
    tools/bench/autoplay_report.py path/to/run.json [--cell 50]
"""
import argparse
import collections
import glob
import json
import math
import os

RUN_DIR = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/City Invaders/devagent/autoplay")


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0.0


def fps(ms):
    return len(ms) / max(sum(ms) / 1000.0, 1e-6)


def stationary_tail(rows, radius=0.6, minimum_s=15.0):
    """Find a contiguous final position hold; combat holds are not always bugs."""
    if len(rows) < 2:
        return None
    last = rows[-1]
    start = len(rows) - 1
    while start > 0:
        previous = rows[start - 1]
        if math.hypot(previous["x"] - last["x"], previous["z"] - last["z"]) > radius:
            break
        start -= 1
    return start if last["t"] - rows[start]["t"] >= minimum_s else None


def print_segment(label, rows):
    if not rows:
        return
    ms = [row["frame_ms"] for row in rows]
    print(f"  {label}: {sum(ms) / 1000:.1f} s, {fps(ms):.1f} fps, "
          f"median {pct(ms, .5):.1f} ms, p99 {pct(ms, .99):.1f} ms, "
          f"{sum(v > 100 for v in ms)} frames over 100 ms")


def pipeline_changes(rows, index):
    """Counter increases near an interval, not a claim about its cause."""
    changes = {}
    for key in ("pipeline_canvas", "pipeline_mesh", "pipeline_surface", "pipeline_draw", "pipeline_specialization"):
        if not rows or key not in rows[0]:
            continue
        changes[key] = sum(max(0, rows[j][key] - rows[j - 1][key])
                           for j in range(max(1, index - 1), min(len(rows), index + 2)))
    return changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run", nargs="?")
    ap.add_argument("--cell", type=float, default=50.0, help="heatmap cell size in metres")
    a = ap.parse_args()
    if a.cell <= 0:
        ap.error("--cell must be positive")
    path = a.run or max(glob.glob(os.path.join(RUN_DIR, "run_*.json")), key=os.path.getmtime)
    run = json.load(open(path))
    c = run["counts"]
    print(f"{path}\n{run['map']}: {run['seconds']:.0f} s - {c['robots_shot']} robots down, {c['pickups']} pickups, "
          f"{c['drives']} drives, {c['grenades']} grenades, {c['containers']} containers opened, {c['trades']} trades")

    if "shots" in c:
        print(f"shots fired (ammunition consumed): {c['shots']}")
    if run.get("conditions"):
        print("conditions: " + json.dumps(run["conditions"], sort_keys=True))
    else:
        print("conditions: not recorded in this older run")

    rows = []
    if run.get("recording") and os.path.exists(run["recording"]):
        rec = json.load(open(run["recording"]))
        rows = [dict(zip(rec["columns"], r)) for r in rec["rows"]]
        s = rec["summary"]
        print(f"frames: {s['frames']}, {s['avg_fps']} fps avg, median {s['median_ms']} ms, p99 {s['p99_ms']} ms, "
              f"worst {s['max_ms']} ms, {s['over_100ms']} over 100 ms")
    else:
        print("(no recording found)")

    if rows:
        print("\nMeasurement limits: process_ms and physics_ms are sampled engine monitors, "
              "not per-function profiles or additive frame costs. GPU timing is not recorded.")
        tail = stationary_tail(rows)
        if tail is not None:
            print(f"\nPosition stayed within 0.6 m of its final location from {rows[tail]['t']:.1f} s "
                  "(may be intentional combat; inspect progress before comparing runs):")
            print_segment("before final position hold", rows[:tail])
            print_segment("final position hold", rows[tail:])
        print("\nper activity:   share    fps   median ms  p99 ms  worst ms")
        by = collections.defaultdict(list)
        for r in rows:
            by[r.get("activity") or "-"].append(r["frame_ms"])
        total = sum(sum(v) for v in by.values())
        for k, ms in sorted(by.items(), key=lambda kv: -sum(kv[1])):
            print(f"  {k:12} {100 * sum(ms) / total:5.0f}% {fps(ms):6.0f} {pct(ms, 0.5):10.1f} {pct(ms, 0.99):7.1f} {max(ms):9.1f}")

        cell = a.cell
        cells = collections.defaultdict(list)
        for r in rows:
            cells[(math.floor(r["x"] / cell), math.floor(r["z"] / cell))].append(r)
        print(f"\nheatmap ({cell:.0f} m cells, fps where the bot was; X east across, Z south down; . not visited):")
        xs = [k[0] for k in cells]
        zs = [k[1] for k in cells]
        print("        " + "".join(f"{int(x * cell):>6}" for x in range(min(xs), max(xs) + 1)))
        for z in range(min(zs), max(zs) + 1):
            line = f"{int(z * cell):>7} "
            for x in range(min(xs), max(xs) + 1):
                rs = cells.get((x, z))
                line += f"{fps([r['frame_ms'] for r in rs]):6.0f}" if rs and len(rs) >= 30 else "     ."
            print(line)
        print("\nslowest cells (at least 2 s there):")
        ranked = []
        for (x, z), rs in cells.items():
            ms = [r["frame_ms"] for r in rs]
            if sum(ms) >= 2000:
                ranked.append((fps(ms), x, z, rs, ms))
        for f, x, z, rs, ms in sorted(ranked)[:8]:
            avg = lambda k: sum(r[k] for r in rs) / len(rs)
            acts = collections.Counter(r.get("activity") or "-" for r in rs).most_common(2)
            print(f"  x {x * cell:5.0f}..{(x + 1) * cell:<5.0f} z {z * cell:5.0f}..{(z + 1) * cell:<5.0f} {f:5.0f} fps  p99 {pct(ms, 0.99):5.1f} ms"
                  f"  draws {avg('draw_calls'):5.0f}  {avg('primitives') / 1e6:4.2f}M prims  people {avg('civilians'):4.0f}"
                  f"  robots {avg('robots'):3.0f}  ({', '.join(k for k, _ in acts)})")

        if "pipeline_draw" in rows[0]:
            print("\nPipeline compilation counter increases during the recording:")
            print("  " + ", ".join(f"{k.removeprefix('pipeline_')}={max(0, rows[-1][k] - rows[0][k])}"
                  for k in rows[0] if k.startswith("pipeline_")))
            print("  DRAW/SURFACE can stall rendering; SPECIALIZATION runs in the background. "
                  "Nearby changes are correlation, not proof of causation.")
        print("\nworst frames:")
        for r in sorted(rows, key=lambda r: -r["frame_ms"])[:6]:
            print(f"  {r['t']:6.1f}s {r['frame_ms']:7.1f} ms  process_monitor {r['process_ms']:.1f}  physics_monitor {r['physics_ms']:.1f}"
                  f"  at ({r['x']:.0f}, {r['z']:.0f}) {r.get('activity', '')}")
            changes = {k.removeprefix("pipeline_"): v for k, v in pipeline_changes(rows, rows.index(r)).items() if v}
            if changes:
                print(f"    pipeline increases within +/-1 recorded frame: {changes}")
        if rec.get("hitches"):
            print("hitches (what had just come into the scene):")
            for h in sorted(rec["hitches"], key=lambda h: -h["ms"])[:5]:
                print(f"  {h['ms']:.0f} ms: {', '.join(x.split('@')[0] for x in h['last_added'][-5:]) or '(no recent additions captured; cause unknown)'}")

    ev = run.get("events", [])
    print(f"\nnavigation and combat events ({len(ev)} events):")
    if not ev:
        print("  none")
    spots = collections.defaultdict(list)
    for e in ev:
        spots[(e["kind"], round(e["pos"][0] / 10) * 10, round(e["pos"][2] / 10) * 10)].append(e)
    for (kind, x, z), es in sorted(spots.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        whats = collections.Counter(e["what"].split(", going to")[0] for e in es).most_common(2)
        print(f"  {kind:16} x {x:5.0f} z {z:5.0f}  {len(es):3}x  {'; '.join(w for w, _ in whats)}"
              f"   (teleport x={es[0]['pos'][0]} y={es[0]['pos'][1]} z={es[0]['pos'][2]})")

    errs = run.get("script_errors", [])
    print(f"\nscript errors: {len(errs)}")
    for e in errs[:10]:
        print("  " + str(e)[:200])


if __name__ == "__main__":
    main()
