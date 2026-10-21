#!/usr/bin/env python3
"""Stronger arm action for the pedestrians' `sprint` clip. The upper arm's
forward/back swing (about the character's lateral axis, through the
shoulder) is scaled to SWING_DEG peak to peak around its mean, and the
elbow is bent to ELBOW_DEG; hands keep their local keys. The phase stays
the original one, which is opposite to the legs.

    tools/.venv/bin/python tools/assets/arm_swing.py [--measure] godot/assets/common/people/ped_*.glb
"""
import json
import struct
import sys

import numpy as np

from anim_speed import quat_mat
from fix_stance import mat_quat

CLIP = "sprint"
SWING_DEG = 85.0
ELBOW_DEG = 85.0


def rot_x(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


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

    anim = next(a for a in js["animations"] if a["name"] == CLIP)
    tracks = {ch["target"]["node"]: anim["samplers"][ch["sampler"]]["output"]
              for ch in anim["channels"] if ch["target"]["path"] == "rotation"}
    keys = {nd: view(acc)[0].astype(float).copy() for nd, acc in tracks.items()}
    count = max(len(v) for v in keys.values())       # tracks may differ in key count

    def q_at(nd, k):
        return keys[nd][min(k, len(keys[nd]) - 1)] if nd in keys else np.array(nodes[nd].get("rotation", [0, 0, 0, 1]), float)

    def world_rot(nd, k):
        chain = [nd]
        while chain[-1] != hips:
            chain.append(parent[chain[-1]])
        R = np.eye(3)
        for c in reversed(chain):
            R = R @ quat_mat(q_at(c, k))
        return R

    def t_of(nd):
        return np.array(nodes[nd].get("translation", [0, 0, 0]), float)

    report = []
    for side in ("Left", "Right"):
        arm, fore, hand = (names[f"mixamorig:{side}{bn}"] for bn in ("Arm", "ForeArm", "Hand"))
        up_dir = [world_rot(arm, k) @ t_of(fore) for k in range(count)]
        lo_dir = [world_rot(fore, k) @ t_of(hand) for k in range(count)]
        # forward (-Z) positive angle from hanging straight down
        theta = np.array([np.arctan2(-d[2], -d[1]) for d in up_dir])
        elbow = np.array([np.arccos(np.clip(np.dot(u, l) / np.linalg.norm(u) / np.linalg.norm(l), -1, 1))
                          for u, l in zip(up_dir, lo_dir)])
        report.append(f"{side}: swing {np.degrees(theta.min()):+.0f}..{np.degrees(theta.max()):+.0f}, "
                      f"elbow {np.degrees(elbow.min()):.0f}..{np.degrees(elbow.max()):.0f}")
        if measure:
            continue
        mean = (theta.max() + theta.min()) / 2
        half = max((theta.max() - theta.min()) / 2, 1e-3)
        k_amp = np.radians(SWING_DEG / 2) / half
        for k in range(min(len(keys[arm]), len(keys[fore]))):    # tracks' own keys
            delta = (k_amp - 1) * (theta[k] - mean) + np.radians(8)   # carried slightly forward
            Rp = world_rot(parent[arm], k)
            Ra = Rp @ quat_mat(q_at(arm, k))
            Ra_new = rot_x(delta) @ Ra
            # bend the elbow forward/up in the plane of the swing
            Rf = Ra @ quat_mat(q_at(fore, k))
            Rf_new = rot_x(delta) @ Rf
            Rf_new = rot_x(np.radians(ELBOW_DEG) - elbow[k]) @ Rf_new
            qa = mat_quat(Rp.T @ Ra_new)
            qf = mat_quat(Ra_new.T @ Rf_new)
            for nd, q in ((arm, qa), (fore, qf)):
                if np.dot(q, q_at(nd, k)) < 0:
                    q = -q
                keys[nd][k] = q
        for nd in (arm, fore):
            arr, off = view(tracks[nd])
            b[off:off + arr.nbytes] = keys[nd].astype(np.float32).tobytes()
    print(path.split("/")[-1], " | ".join(report))
    if not measure:
        open(path, "wb").write(bytes(b))


if __name__ == "__main__":
    measure = "--measure" in sys.argv
    for p in [a for a in sys.argv[1:] if not a.startswith("--")]:
        fix(p, measure)
