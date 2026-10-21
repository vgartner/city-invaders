#!/usr/bin/env python3
"""Client for the in-game DevAgent (godot/scripts/dev_agent.gd).

Library:   DevAgent().call("teleport", x=10, z=5, yaw=90)
CLI:       tools/devagent/devagent.py launch            # start the game with --devagent
           tools/devagent/devagent.py get_state
           tools/devagent/devagent.py teleport x=108 z=4 yaw=90
           tools/devagent/devagent.py scan_gaps radius=150 step=0.5
Values in key=value pairs are parsed as JSON when possible.
"""
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HOST, PORT = "127.0.0.1", int(os.environ.get("DEVAGENT_PORT", 24690))   # a second instance: another port
GODOT_DIR = Path(__file__).resolve().parents[2] / "godot"


class DevAgent:
    def __init__(self, host=HOST, port=PORT, timeout=120):
        self.addr, self.timeout, self.sock, self.buf, self.seq = (host, port), timeout, None, b"", 0

    def connect(self):
        self.sock = socket.create_connection(self.addr, timeout=self.timeout)

    def call(self, method, **params):
        if self.sock is None:
            self.connect()
        self.seq += 1
        self.sock.sendall((json.dumps({"id": self.seq, "method": method, "params": params}) + "\n").encode())
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("DevAgent closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        msg = json.loads(line)
        if msg.get("error"):
            raise RuntimeError(msg["error"])
        return msg.get("result")


def reachable():
    try:
        socket.create_connection((HOST, PORT), timeout=1).close()
        return True
    except OSError:
        return False


def launch(wait=90, headless=False):
    """Start the game with the DevAgent enabled (if not running) and wait for it.
    headless: no window (AI and physics still run; no screenshots)."""
    if reachable():
        return "already running"
    log = open("/tmp/claude-501/devagent-game.log", "w") if Path("/tmp/claude-501").exists() else subprocess.DEVNULL
    subprocess.Popen(["godot"] + (["--headless"] if headless else []) + ["--path", str(GODOT_DIR), "--", "--devagent"],
                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < wait:
        if reachable():
            return f"started in {time.time() - t0:.0f}s"
        time.sleep(1)
    raise TimeoutError("game did not open the DevAgent port")


def _value(v):
    try:
        return json.loads(v)
    except json.JSONDecodeError:
        return v


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "launch":
        print(launch(headless="headless" in sys.argv[2:]))
        sys.exit()
    params = dict(a.split("=", 1) for a in sys.argv[2:])
    print(json.dumps(DevAgent().call(sys.argv[1], **{k: _value(v) for k, v in params.items()}), indent=1))
