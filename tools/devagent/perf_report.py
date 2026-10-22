#!/usr/bin/env python3
"""Read an F5 performance recording (user://devagent/perf/rec_*.json, written
by the DevAgent while the player pressed F5 ... F5) and say where the time
went: the summary, a timeline in 2 s steps (fps, worst frame, what was drawn,
people and robots, where the player was and looked) and the worst frames with
what had just come into the scene.

    tools/devagent/perf_report.py                 # the latest recording
    tools/devagent/perf_report.py path/to/rec.json
"""
import glob
import json
import os
import sys

PERF_DIR = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/City Invaders/devagent/perf")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob(os.path.join(PERF_DIR, "rec_*.json")), key=os.path.getmtime)
    d = json.load(open(path))
    cols = d["columns"]
    rows = [dict(zip(cols, r)) for r in d["rows"]]
    s = d["summary"]
    print(f"{path}\n{s['map']}: {s['seconds']} s, {s['frames']} frames, {s['avg_fps']} fps avg, median {s['median_ms']} ms, "
          f"p95 {s['p95_ms']}, p99 {s['p99_ms']}, worst {s['max_ms']} ms, {s['over_33ms']} over 33 ms, {s['over_100ms']} over 100 ms")
    print("\n  time    fps  worst ms  script ms  physics ms  draws   prims  people robots cars   where (x, z) looking")
    step, i = 2.0, 0
    while i < len(rows):
        t0 = rows[i]["t"]
        chunk = []
        while i < len(rows) and rows[i]["t"] < t0 + step:
            chunk.append(rows[i])
            i += 1
        ms = [r["frame_ms"] for r in chunk]
        avg = lambda k: sum(r[k] for r in chunk) / len(chunk)
        last = chunk[-1]
        print(f"{t0:6.1f}s {len(ms) / max(sum(ms) / 1000, 1e-6):5.0f} {max(ms):9.1f} {avg('process_ms'):10.1f} {avg('physics_ms'):11.1f}"
              f" {avg('draw_calls'):6.0f} {avg('primitives') / 1e6:6.2f}M {last['civilians']:6} {last['robots']:6} {last['vehicles']:4}"
              f"   ({last['x']:.0f}, {last['z']:.0f}) {last['heading_deg']:.0f} deg")
    worst = sorted(rows, key=lambda r: -r["frame_ms"])[:8]
    print("\nworst frames:")
    for r in worst:
        print(f"  {r['t']:6.1f}s {r['frame_ms']:7.1f} ms  script {r['process_ms']:.1f}  physics {r['physics_ms']:.1f}  draws {r['draw_calls']}"
              f"  people {r['civilians']} robots {r['robots']}  at ({r['x']:.0f}, {r['z']:.0f})")
    if d.get("hitches"):
        print("\nhitches (what had just come into the scene):")
        for h in sorted(d["hitches"], key=lambda h: -h["ms"])[:8]:
            print(f"  {h['ms']:.0f} ms (physics {h['physics_ms']} ms): {', '.join(a.split('@')[0] for a in h['last_added'][-5:])}")


if __name__ == "__main__":
    main()
