#!/usr/bin/env python3
"""What the people far from the player cost: the same walk with everyone on
the map, then with only those within a radius of the player (the rest taken
off and not refilled). Per run: script and physics ms a frame, frame times,
people on the map and near. Run it with the player's own game closed.

    tools/bench/crowd_bench.py [map] [radius]
"""
import json
import sys
import time

sys.path.insert(0, __import__("os").path.dirname(__file__))
import play_bench as pb  # noqa: E402

ROUTES = {"centro": [(-43.9, -5, (-60, 5)), (-60, 5, (-20, -40))],
          "gasometro": [(-36.5, 229, (-36, 180)), (6.0, -60, (60, -60))]}


def sample(seconds):
    """Script / physics ms a frame, averaged over `seconds` (twice a second)."""
    proc, phys, n = 0.0, 0.0, 0
    end = time.time() + seconds
    while time.time() < end:
        d = json.loads(pb.call("perf"))
        proc += d["process_ms"]
        phys += d["physics_ms"]
        n += 1
        time.sleep(0.5)
    return proc / max(n, 1), phys / max(n, 1), d


def walk(route):
    for x, z, look in route:
        pb.at(x, z, look=look)
        pb.hold(["forward", "run"], 8)


def run(label, map_id, radius):
    pb.call("quit")
    time.sleep(2)
    pb.call("launch")
    t0 = time.time()
    pb.call("start_solo", f"map={map_id}")
    print(f"{label}: loading {time.time() - t0:.1f} s", flush=True)
    time.sleep(14)
    pb.call("set_god", "on=true")
    pb.call("set_director", "enabled=false")
    pb.call("kill_enemies")
    pb.call("uncap")
    pb.ev('main.set("dynamic_resolution", false)')
    pb.ev('main._set_render_scale(0.67)')
    route = ROUTES[map_id]
    pb.at(route[0][0], route[0][1], look=route[0][2])
    time.sleep(3)
    if radius:
        pb.ev("main.set(\"ambient_scale\", 0.05)")          # no refill of the ones taken off
        n = int(pb.ev("main.civilians_root.get_child_count()"))
        for i in range(n - 1, -1, -1):
            pb.ev(f"main.civilians_root.get_child({i}).queue_free() if main.civilians_root.get_child({i}).global_position.distance_to(main._local_player().global_position) > {radius} else null")
        time.sleep(2)
    people = pb.ev("main.civilians_root.get_child_count()")
    asleep = sum(1 for i in range(int(people or 0))
                 if pb.ev(f'main.civilians_root.get_child({i}).get("asleep")') in (True, "true"))
    proc, phys, d = sample(10)
    pb.stretch(f"{label} walk", lambda: walk(route))
    proc2, phys2, d2 = sample(6)
    print(f"{label:22} people {people} (near {d['civilians_near']}, asleep {asleep}): standing script {proc:.2f} ms, physics {phys:.2f} ms;"
          f" after the walk script {proc2:.2f}, physics {phys2:.2f}, fps {d2['fps']}", flush=True)
    pb.call("quit")


def main():
    map_id = sys.argv[1] if len(sys.argv) > 1 else "centro"
    radius = float(sys.argv[2]) if len(sys.argv) > 2 else 150.0
    for label, r in [("everyone", 0), (f"within {radius:.0f} m", radius), ("everyone", 0), (f"within {radius:.0f} m", radius)]:
        run(f"{map_id} {label}", map_id, r)


if __name__ == "__main__":
    main()
