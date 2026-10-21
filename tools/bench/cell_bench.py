#!/usr/bin/env python3
"""City mesh cells A/B (CITY_CELL_M) on the Centro: four fixed views drawn
with the simulation paused and no frame cap, and a walk down two streets.
Run it once per build of the map, the player's own game closed.

    CITY_CELL_M=120 tools/.venv/bin/python tools/map/building_photo.py rebuild centro
    godot --headless --path godot --import
    tools/bench/cell_bench.py <label>
"""
import json
import sys
import time

sys.path.insert(0, __import__("os").path.dirname(__file__))
import play_bench as pb  # noqa: E402
import kit_bench as kb  # noqa: E402

kb.VIEWS = [("Rua da Praia", (-43.9, -5), (-60, 5)),
            ("down an avenue", (-60, 5), (-20, -40)),
            ("Theatro square", (-134.5, 260), (-134.6, 230)),
            ("Praça da Matriz", (-150, 330), (-100, 380))]


def walk():
    pb.at(-43.9, -5, look=(-60, 5))
    pb.hold(["forward", "run"], 8)
    pb.at(-60, 5, look=(-20, -40))
    pb.hold(["forward", "run"], 8)


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "run"
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
    print(f"== {label}", flush=True)
    kb.views(label)
    pb.stretch(f"{label} walk + run", walk)
    pb.call("quit")


if __name__ == "__main__":
    main()
