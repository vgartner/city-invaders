#!/usr/bin/env python3
"""Bring the arms in. The generated pedestrians keep part of the A-pose arm
spread in idle/walk/sprint. Each upper arm is rotated about the
character's forward axis (through the shoulder) so its median angle from
vertical becomes TARGET_DEG; forearm and hand follow unchanged.

    tools/.venv/bin/python tools/assets/fix_arms.py [--measure] godot/assets/common/people/ped_*.glb
"""
import json
import struct
import sys

import numpy as np

from anim_speed import quat_mat
from fix_stance import mat_quat, rot_z

TARGET_DEG = 10.0
CLIPS = ("idle", "walk", "sprint")


def fix(path, measure=False):
    b = bytearray(open(path, "rb").read())
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    base = 20 + n + 8
    nodes = js["nodes"]
    names = {nd.get("name"): i for i, nd in enumerate(nodes)}
    parent = {c: i for i, nd in enumerate(nodes) for c in nd.get("children", [])}
    hips = names["mixamorig:Hips"]

    def view(i):
        a = js["accessors"][i]
        bv = js["bufferViews"][a["bufferView"]]
        comps = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
        off = base + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(b, np.float32, count=a["count"] * comps, offset=off).reshape(a["count"], comps), off

    out = []
    for clip in CLIPS:
        anim = next(a for a in js["animations"] if a["name"] == clip)
        tracks = {ch["target"]["node"]: anim["samplers"][ch["sampler"]]["output"]
                  for ch in anim["channels"] if ch["target"]["path"] == "rotation"}
        keys = {nd: view(acc)[0].astype(float).copy() for nd, acc in tracks.items()}
        count = max(len(v) for v in keys.values())       # tracks may differ in key count

        def q_at(nd, k):
            return keys[nd][min(k, len(keys[nd]) - 1)] if nd in keys else np.array(nodes[nd].get("rotation", [0, 0, 0, 1]), float)

        def world_rot(nd, k):
            chain = []
            while True:
                chain.append(nd)
                if nd == hips:
                    break
                nd = parent[nd]
            R = np.eye(3)
            for c in reversed(chain):
                R = R @ quat_mat(q_at(c, k))
            return R

        for side, sign in (("Left", -1), ("Right", 1)):
            arm = names[f"mixamorig:{side}Arm"]
            fore = names[f"mixamorig:{side}ForeArm"]
            bone = np.array(nodes[fore].get("translation", [0, 0, 0]), float)
            ang = []
            for k in range(count):
                d = world_rot(arm, k) @ bone
                ang.append(np.degrees(np.arctan2(abs(d[0]), -d[1])))
            cur = float(np.median(ang))
            out.append(f"{clip} {side} {cur:.0f}")
            if measure:
                continue
            # arm hangs along -Y; outward is sign*X. Rotating by +delta about Z moves
            # the lower end towards +X, so the left arm (out at -X) needs +delta
            delta = np.radians(cur - TARGET_DEG) * (1 if sign < 0 else -1)
            Rz = rot_z(delta)
            for k in range(len(keys[arm])):          # the arm track's own keys
                Rp = world_rot(parent[arm], k)
                Ra = Rp @ quat_mat(q_at(arm, k))
                q = mat_quat(Rp.T @ Rz @ Ra)
                if np.dot(q, q_at(arm, k)) < 0:
                    q = -q
                keys[arm][k] = q
            arr, off = view(tracks[arm])
            b[off:off + arr.nbytes] = keys[arm].astype(np.float32).tobytes()
    print(path.split("/")[-1], " | ".join(out))
    if not measure:
        open(path, "wb").write(bytes(b))


if __name__ == "__main__":
    measure = "--measure" in sys.argv
    for p in [a for a in sys.argv[1:] if not a.startswith("--")]:
        fix(p, measure)
