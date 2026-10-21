#!/usr/bin/env python3
"""Play-through benchmark: the same route through the Centro every time, the
way a player plays it - walking and running down a street, a fight with the
machine gun, into the Theatro São Pedro and out, into a shop and out, a car
driven a few blocks. Per stretch: frame times (median, 95th and 99th
percentile, worst, frames over 33 / 100 ms) and the hitches with what had
just entered the scene.

    tools/bench/play_bench.py [label]          # a test instance on port 24691

Run it with the player's own game closed (two games share the GPU) and
compare runs only with the same resolution setting.
"""
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = dict(os.environ, DEVAGENT_PORT="24691")


def call(*a):
    return subprocess.run([sys.executable, str(ROOT / "tools" / "devagent" / "devagent.py"), *a],
                          capture_output=True, text=True, env=ENV, cwd=ROOT).stdout


def ev(x):
    try:
        return json.loads(call("eval", f"expr={x}")).get("value")
    except ValueError:
        return None


def v3(s):
    import re
    return [float(t) for t in re.findall(r"-?\d+\.?\d*", (s or "").replace("Vector3", ""))[:3]]


def ground(x, z):
    r = json.loads(call("raycast", f"from=[{x},200,{z}]", f"to=[{x},-50,{z}]"))
    return r["pos"][1] if r.get("hit") else 25.0


def at(x, z, look=None, up=1.0):
    call("teleport", f"x={x}", f"y={ground(x, z) + up}", f"z={z}")
    time.sleep(1.0)
    if look:
        call("look_at", f"x={look[0]}", f"y={ground(look[0], look[1]) + 1.6}", f"z={look[1]}")


def hold(actions, seconds):
    call("hold_keys", "actions=" + json.dumps(actions), f"seconds={seconds}")


results = []


def stretch(name, fn):
    call("frames", "on=true")
    call("hitches")
    t0 = time.time()
    fn()
    pr = {}
    f = json.loads(call("frames"))
    h = json.loads(call("hitches"))
    call("frames", "on=false")
    worst = sorted(h["hitches"], key=lambda x: -x["ms"])[:3]
    results.append((name, f, worst))
    print(f"{name:22} {time.time() - t0:5.1f}s  fps {f.get('avg_fps', 0):5.1f}  median {f.get('median_ms', 0):5.1f} ms"
          f"  p95 {f.get('p95_ms', 0):5.1f}  p99 {f.get('p99_ms', 0):6.1f}  max {f.get('max_ms', 0):6.1f}"
          f"  >33ms {f.get('over_33ms', 0):3}  >100ms {f.get('over_100ms', 0):2}", flush=True)
    dur = time.time() - t0
    if pr:
        print(f"{'':24}script ms per second: " + ", ".join(f"{k} {v / 1000 / dur:.1f}" for k, v in sorted(pr.items(), key=lambda kv: -kv[1])), flush=True)
    for x in worst:
        if x["ms"] > 100:
            print(f"{'':24}hitch {x['ms']:.0f} ms (physics {x['physics_ms']} ms): {', '.join(a.split('@')[0] for a in x['last_added'][-5:])}")


def walk_and_run():
    at(-43.9, -5, look=(-60, 5))
    hold(["forward"], 6)
    hold(["forward", "run"], 6)
    at(-60, 5, look=(-20, -40))
    hold(["forward", "run"], 8)


def fight():
    at(-43.9, -5, look=(-43.9, -40))
    call("arm", "weapon=machinegun")
    for i in range(6):
        call("spawn_enemy", f"x={-52 + 4 * i}", f"y={ground(-52 + 4 * i, -30) + 0.5}", "z=-30")
    time.sleep(1.5)
    end = time.time() + 20
    while time.time() < end:
        rob = ev("main.enemies_root.get_child(0).global_position if main.enemies_root.get_child_count() > 0 else Vector3.INF")
        p = v3(rob)
        if len(p) == 3 and abs(p[0]) < 1e6:
            call("look_at", f"x={p[0]}", f"y={p[1] + 1.2}", f"z={p[2]}")
        hold(["fire"], 1.5)
    print(f"{'':24}check: robots left {ev('main.enemies_root.get_child_count()')}, ammo {ev('main._local_player()._mags.get(\"machinegun\")')}", flush=True)


def theatro():
    at(-134.5, 241.5, look=(-134.6, 230))
    call("tap", "action=use")
    time.sleep(3)
    hold(["forward"], 7)
    print(f"{'':24}check: inside the Theatro {ev('main.get_node(\"Navigation/theatro_sao_pedro\").inside(main._local_player().global_position)')}", flush=True)
    at(-134.5, 226, look=(-134.6, 260))
    hold(["forward"], 5)


def shop():
    call("teleport", "x=-51", "y=26.5", "z=-14")
    time.sleep(1.5)
    call("look_at", "x=-49", "y=26.5", "z=-18")
    call("tap", "action=use")
    time.sleep(2)
    hold(["forward"], 2)
    print(f"{'':24}check: in the shop {ev('main._local_player().in_shop')}", flush=True)
    hold(["back"], 3)
    time.sleep(2)


def drive():
    n = int(ev("main.traffic_root.get_child_count()") or 0)
    car = None
    for i in range(n):
        if ev(f'main.traffic_root.get_child({i}).kind') == '"car"':
            car = ev(f'str(main.traffic_root.get_child({i}).name)').strip('"')
            break
    if not car:
        return
    x, y, z = v3(ev(f'main.traffic_root.get_node("{car}").global_position'))
    call("teleport", f"x={round(x + 2.5, 2)}", f"y={round(y + 1.5, 2)}", f"z={round(z, 2)}")
    ev(f'main._local_player().request_vehicle("{car}")')
    time.sleep(1.5)
    hold(["forward"], 6)
    hold(["forward", "left"], 2)
    hold(["forward"], 6)
    hold(["forward", "right"], 2)
    hold(["forward"], 4)
    p2 = v3(ev('main._local_player().global_position'))
    print(f"{'':24}check: driving {ev('main._local_player().vehicle != null')}, moved {((p2[0]-x)**2+(p2[2]-z)**2)**0.5:.0f} m", flush=True)
    call("tap", "action=use")


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "run"
    while True:
        try:
            socket.create_connection(("127.0.0.1", 24691), timeout=1).close()
            call("quit")
            time.sleep(2)
        except OSError:
            break
    call("launch")
    call("start_solo", "map=centro")
    time.sleep(12)
    call("set_god", "on=true")
    print(f"== {label}: resolution scale {ev('main.get_viewport().scaling_3d_scale')}, "
          f"window {ev('main.get_window().size')}, navmesh polygons {ev('main.nav_region.navigation_mesh.get_polygon_count()')}", flush=True)
    for name, fn in [("walk + run", walk_and_run), ("fight (machine gun)", fight), ("Theatro in and out", theatro),
                     ("shop in and out", shop), ("drive a car", drive)]:
        stretch(name, fn)
    errs = call("errors").replace("\n", "")
    print("errors:", errs[:300])
    out = ROOT / "build" / f"play_bench_{label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps([{"stretch": n, "frames": f, "worst": w} for n, f, w in results], indent=1))
    call("quit")


if __name__ == "__main__":
    main()
