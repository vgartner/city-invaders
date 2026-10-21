#!/usr/bin/env python3
"""Block until the player writes to the assistant in the game (F1), then
print the messages as JSON and exit. An AI assistant runs this in the
background and is woken up when it returns.

    tools/.venv/bin/python tools/devagent/devagent_wait.py [--timeout 3600]
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from devagent import DevAgent  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, default=3600)
    ap.add_argument("--every", type=float, default=2.0)
    a = ap.parse_args()
    end = time.time() + a.timeout
    while time.time() < end:
        try:
            msgs = DevAgent().call("inbox")["messages"]
        except (OSError, RuntimeError):
            msgs = []                       # game not running (yet): keep waiting
        if msgs:
            print(json.dumps(msgs, ensure_ascii=False, indent=1))
            return
        time.sleep(a.every)
    print("[]")


if __name__ == "__main__":
    main()
