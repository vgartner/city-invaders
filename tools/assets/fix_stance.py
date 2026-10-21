#!/usr/bin/env python3
"""Bring splayed legs in. The generated pedestrians keep the A-pose leg
spread in every clip: ankles ~36 cm apart while the hip joints are ~20 cm.

For every clip except `die`, each upper leg is rotated about the
character's forward axis (through its hip joint) so the ankles end up at
NARROW x the hip-joint spacing, and the foot rotation is compensated so the
sole stays as it was. Rotation keys are rewritten in place in the .glb.

    tools/.venv/bin/python tools/assets/fix_stance.py godot/assets/common/people/ped_*.glb
    tools/.venv/bin/python tools/assets/fix_stance.py --clips=idle_alert,walk,run,aim,fire godot/assets/rio_grande_do_sul/police/*.glb
"""
import json
import struct
import sys

import numpy as np

from anim_speed import quat_mat

NARROW = 0.8
CLIPS = ("idle", "walk", "sprint")


def mat_quat(m):
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s]
    q = np.array(q)
    return q / np.linalg.norm(q)


def rot_z(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def fix(path, clips=CLIPS):
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

    def node_rot(node):
        return np.array(js["nodes"][node].get("rotation", [0, 0, 0, 1]), float)

    def node_t(node):
        return np.array(js["nodes"][node].get("translation", [0, 0, 0]), float)

    for clip in clips:
        anim = next(a for a in js["animations"] if a["name"] == clip)
        hips = names["mixamorig:Hips"]
        legs = {}
        for side in ("Left", "Right"):
            legs[side] = [names[f"mixamorig:{side}{bn}"] for bn in ("UpLeg", "Leg", "Foot")]
        tracks = {}
        trans = {}          # animated translations (some packs key every bone's offset)
        for ch in anim["channels"]:
            if ch["target"]["path"] == "rotation":
                tracks[ch["target"]["node"]] = anim["samplers"][ch["sampler"]]["output"]
            elif ch["target"]["path"] == "translation":
                trans[ch["target"]["node"]] = view(anim["samplers"][ch["sampler"]]["output"])[0].astype(float)
        keys = {nd: view(acc)[0].astype(float) for nd, acc in tracks.items()}
        # tracks may have different key counts (constant ones keep 2): work on the
        # longest leg track and read shorter ones at their last key
        count = max(len(keys[n_]) for n_ in keys if n_ in sum(legs.values(), [])) if legs else 0

        def q_at(nd, k):
            return keys[nd][min(k, len(keys[nd]) - 1)] if nd in keys else node_rot(nd)

        def t_at(nd, k):
            return trans[nd][min(k, len(trans[nd]) - 1)] if nd in trans else node_t(nd)

        # per-side hip joint and ankle positions (Hips parent space), median over the clip
        geo = {}
        for side, (up, leg, foot) in legs.items():
            hip_p, ank_p = [], []
            for k in range(count):
                Rh = quat_mat(q_at(hips, k))
                Ru = Rh @ quat_mat(q_at(up, k))
                Rl = Ru @ quat_mat(q_at(leg, k))
                hp = Rh @ t_at(up, k)
                ap = hp + Ru @ t_at(leg, k) + Rl @ t_at(foot, k)
                hip_p.append(hp)
                ank_p.append(ap)
            geo[side] = (np.median(hip_p, axis=0), np.median(ank_p, axis=0))
        mid = (geo["Left"][0][0] + geo["Right"][0][0]) / 2
        for side, (up, leg, foot) in legs.items():
            hp, ap = geo[side]
            x, y = ap[0] - hp[0], ap[1] - hp[1]
            r, phi = np.hypot(x, y), np.arctan2(x, -y)
            target = -(1 - NARROW) * (hp[0] - mid)
            theta = np.arcsin(np.clip(target / r, -1, 1)) - phi
            Rz = rot_z(theta)
            for k in range(count):
                Rh = quat_mat(q_at(hips, k))
                Ru = Rh @ quat_mat(q_at(up, k))
                Rl = quat_mat(q_at(leg, k))
                Rf = quat_mat(q_at(foot, k))
                Ru_new = Rz @ Ru
                up_new = Rh.T @ Ru_new
                foot_new = Rl.T @ Ru_new.T @ Ru @ Rl @ Rf
                for nd, m in ((up, up_new), (foot, foot_new)):
                    q = mat_quat(m)
                    if np.dot(q, q_at(nd, k)) < 0:
                        q = -q
                    if nd not in keys or len(keys[nd]) < count:
                        old = keys.get(nd, np.tile(node_rot(nd), (1, 1)))
                        keys[nd] = np.array([old[min(i, len(old) - 1)] for i in range(count)])
                    keys[nd][k] = q
            print(f"  {clip} {side}: {np.degrees(theta):+.1f} deg")
            for nd in (up, foot):
                if nd not in tracks:
                    raise SystemExit(f"{path}: no rotation track for node {nd} in {clip}")
                arr, off = view(tracks[nd])
                if len(arr) != count:
                    raise SystemExit(f"{path}: {clip} track {nd} has {len(arr)} keys, needs {count}")
                b[off:off + arr.nbytes] = keys[nd].astype(np.float32).tobytes()
    open(path, "wb").write(bytes(b))


if __name__ == "__main__":
    clips = CLIPS
    for a in sys.argv[1:]:
        if a.startswith("--clips="):
            clips = tuple(a.split("=", 1)[1].split(","))
    for p in [a for a in sys.argv[1:] if not a.startswith("--")]:
        print(p)
        fix(p, clips)
