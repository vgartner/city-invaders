#!/usr/bin/env python3
"""The delivered cyclists pedal backwards: in their `ride` clip the wheels
roll forward (about -X) but the crank turns about +X. The feet are solved to
the pedals, so the fix is to play everything except the wheels backwards in
time: crank, pedals and legs then turn forwards, wheels keep their roll.

The clip is a seamless loop sampled at a fixed rate (first key == last), so
reversing each non-wheel channel's key values in place is a time reversal.
Rewrites the .glb files in place; run once:

    tools/.venv/bin/python tools/assets/fix_cyclist_crank.py godot/assets/common/cyclists/*.glb
"""
import json
import struct
import sys

import numpy as np

KEEP = {"wheel_front", "wheel_rear"}


def crank_sign(js, view, anim, names):
    for ch in anim["channels"]:
        if ch["target"]["node"] == names["crank"] and ch["target"]["path"] == "rotation":
            q, _ = view(anim["samplers"][ch["sampler"]]["output"])
            a, b = q[0], q[1]
            rx = b[3] * -a[0] + b[0] * a[3] + b[1] * -a[2] - b[2] * -a[1]
            return np.sign(rx)
    return 0.0


def fix(path):
    b = bytearray(open(path, "rb").read())
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    base = 20 + n + 8
    names = {nd.get("name"): i for i, nd in enumerate(js["nodes"])}

    def view(i):
        a = js["accessors"][i]
        bv = js["bufferViews"][a["bufferView"]]
        comps = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
        off = base + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(b, np.float32, count=a["count"] * comps, offset=off).reshape(a["count"], comps), off

    anim = next(a for a in js["animations"] if a["name"] == "ride")
    if crank_sign(js, view, anim, names) <= 0:
        print(path, "already pedals forwards")
        return
    keep = {names[k] for k in KEEP if k in names}
    done = set()
    for ch in anim["channels"]:
        s = anim["samplers"][ch["sampler"]]
        if ch["target"]["node"] in keep or s["output"] in done:
            continue
        if s.get("interpolation", "LINEAR") == "CUBICSPLINE":
            raise SystemExit(f"{path}: cubic channel, can't reverse by values")
        arr, off = view(s["output"])
        b[off:off + arr.nbytes] = arr[::-1].copy().tobytes()
        done.add(s["output"])
    open(path, "wb").write(bytes(b))
    print(path, f"ride: {len(done)} channels reversed, wheels kept")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        fix(p)
