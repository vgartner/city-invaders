#!/usr/bin/env python3
"""Roll a hand about its forearm in every clip of a first-person view model
(the support hand of the carbine held the handguard back to front). The
axis is the forearm -> hand bone direction, in the forearm's space; every
rotation key of the hand is pre-multiplied, so the grip turns as a whole
(the clips all key the hand; its rest pose is left alone).

    tools/.venv/bin/python tools/assets/hand_roll.py godot/assets/common/weapons/machinegun/machinegun_fp.glb LeftHand 180
"""
import json
import struct
import sys

import numpy as np


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw,
                     aw * bw - ax * bx - ay * by - az * bz])


def roll(path, bone, deg):
    b = bytearray(open(path, "rb").read())
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    base = 20 + n + 8
    node = next(i for i, nd in enumerate(js["nodes"]) if nd.get("name") == bone)
    axis = np.array(js["nodes"][node].get("translation", [0, 1, 0]), float)
    axis /= np.linalg.norm(axis)
    h = np.radians(deg) / 2
    r = np.array([*(axis * np.sin(h)), np.cos(h)])
    seen = set()
    for anim in js.get("animations", []):
        for ch in anim["channels"]:
            if ch["target"]["node"] != node or ch["target"]["path"] != "rotation":
                continue
            acc_i = anim["samplers"][ch["sampler"]]["output"]
            if acc_i in seen:
                continue                     # shared key array: rolled once
            seen.add(acc_i)
            acc = js["accessors"][acc_i]
            bv = js["bufferViews"][acc["bufferView"]]
            off = base + bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            q = np.frombuffer(b, np.float32, count=acc["count"] * 4, offset=off).reshape(-1, 4).astype(float)
            out = np.array([qmul(r, k) for k in q], np.float32)
            b[off:off + out.nbytes] = out.tobytes()
            print(anim["name"], acc["count"], "keys")
    open(path, "wb").write(bytes(b))


if __name__ == "__main__":
    roll(sys.argv[1], sys.argv[2], float(sys.argv[3]))
