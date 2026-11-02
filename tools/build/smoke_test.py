#!/usr/bin/env python3
"""Smoke test of a packaged game already started with `-- --devagent`
(DEVAGENT_PORT): wait for it, optionally download a map through the Maps
screen's code, start a solo round, and fail on any error the game reports.
Used by .github/workflows/build-release.yml (docs/BUILDING.md).

  smoke_test.py --map gasometro      a round on a map the game has
  smoke_test.py --download mercado   download mercado into user://map_packs/
                                     and quit (start the game again and play
                                     it with --map mercado)

A map loaded while the game runs plays fine with a renderer, but in
--headless Godot's dummy renderer reports RID errors for it; hence the
restart before the round.

Only the Python standard library (and tools/devagent/devagent.py).
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "devagent"))
from devagent import DevAgent, reachable  # noqa: E402


def ev(agent, expr):
    return agent.call("eval", expr=expr).get("value")


def round_on(agent, map_id, seconds):
    agent.call("start_solo", map=map_id)
    time.sleep(seconds)
    errors = agent.call("errors").get("errors", [])
    if errors:
        print(json.dumps(errors, indent=1))
        sys.exit(f"{len(errors)} errors in a round on {map_id}")
    print(f"round on {map_id}: no errors")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map")
    ap.add_argument("--download", help="a map to fetch from the catalog (CITY_INVADERS_CATALOG)")
    ap.add_argument("--seconds", type=int, default=30)
    a = ap.parse_args()
    t0 = time.time()
    while not reachable():
        if time.time() - t0 > 240:
            sys.exit("the game did not open the DevAgent port")
        time.sleep(2)
    agent = DevAgent()
    if a.download:
        ev(agent, f'main.download_map("{a.download}")')
        t0 = time.time()
        while True:
            status = json.loads(ev(agent, "main.map_store.status"))
            if status.endswith(" installed."):
                print(status)
                break
            if any(w in status for w in ("failed", "damaged", "could not", "No list")) or time.time() - t0 > 600:
                sys.exit(f"download of {a.download}: {status or 'timed out'}")
            time.sleep(3)
    if a.map:
        round_on(agent, a.map, a.seconds)
    try:
        agent.call("quit")
    except (OSError, RuntimeError, ConnectionError):
        pass


if __name__ == "__main__":
    main()
