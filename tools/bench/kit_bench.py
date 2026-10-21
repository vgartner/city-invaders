#!/usr/bin/env python3
"""Kit facades A/B on the test block (centro, the Casa de Cultura's block):
walking round the block (frame times) and three fixed views drawn with the
simulation paused and no frame cap. Run it once per build, with and without
"kit_facades" in maps/centro/build.json, the player's own game closed.

    tools/bench/kit_bench.py <label>
"""
import json
import sys
import time

sys.path.insert(0, __import__("os").path.dirname(__file__))
import play_bench as pb  # noqa: E402

VIEWS = [("street, front", (-500, 160), (-527, 122)),
         ("along the block", (-492, 157), (-470, 146)),
         ("corner", (-575, 160), (-545, 130))]


def walk():
    pb.at(-500, 160, look=(-575, 160))
    pb.hold(["forward"], 8)
    pb.at(-575, 160, look=(-575, 90))
    pb.hold(["forward", "run"], 8)
    pb.at(-470, 185, look=(-470, 100))
    pb.hold(["forward"], 8)


def views(label):
    pb.call("uncap")
    pb.ev('main.set("dynamic_resolution", false)')
    pb.ev('main._set_render_scale(0.67)')
    for name, spot, look in VIEWS:
        pb.ev('main.get_tree().set("paused", false)')
        pb.at(*spot, look=look)
        pb.ev('main.get_tree().set("paused", true)')
        time.sleep(6)
        fps = [json.loads(pb.call("perf"))["fps"] for _ in range(4)]
        d = json.loads(pb.call("perf"))
        print(f"{label:8} {name:16} paused fps {fps}  draws {d['draw_calls']:.0f}  prims {d['primitives'] / 1e6:.2f}M", flush=True)
    pb.ev('main.get_tree().set("paused", false)')


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "run"
    pb.main_setup = None
    import socket
    while True:
        try:
            socket.create_connection(("127.0.0.1", 24691), timeout=1).close()
            pb.call("quit")
            time.sleep(2)
        except OSError:
            break
    pb.call("launch")
    pb.call("start_solo", "map=centro")
    time.sleep(12)
    pb.call("set_god", "on=true")
    pb.call("set_director", "enabled=false")
    print(f"== {label}: kit materials {pb.ev('main._kit_mats.size()')}", flush=True)
    views(label)
    pb.stretch(f"{label} walk round", walk)
    pb.call("quit")


if __name__ == "__main__":
    main()
