#!/usr/bin/env python3
"""Rebuild the leg motion of the generated pedestrians' `walk` and `sprint`
clips with a planted-foot gait.

The delivered clips swing the legs like pendulums: the swing foot never
lifts and no foot is ever still relative to the ground, so the characters
look like they skate whatever the playback speed. Here each ankle follows a
designed path in the skeleton's parent space (character faces -Z):

  stance  the foot moves backwards at exactly the clip speed (planted),
          rocking off the heel after contact and onto the toe before lift
  swing   the foot travels forward on a lifted arc, toe down -> toe up

Thigh and shin come from analytic two-bone IK (knee bending forward), the
foot rotation is set explicitly, and the hips drop just enough for the legs
to reach. Pelvis rotation, spine, arms and head keep the original keys.
Rotation/translation keys are rewritten in place.

The clip's ground speed at stature scale 1.0 is GAITS[clip]["speed"]; the
game scales playback by actual speed / (that x stature) - see civilian.gd.

    tools/.venv/bin/python tools/assets/gait.py godot/assets/common/people/ped_*.glb
    tools/.venv/bin/python tools/assets/gait.py --clips=walk godot/assets/rio_grande_do_sul/police/*.glb
"""
import json
import struct
import sys

import numpy as np

from anim_speed import quat_mat
from fix_stance import mat_quat

GAITS = {
    # speed (m/s at stature 1.0), stance fraction, toe-off and heel-strike
    # pitch (deg), swing lift (m), leg reach at full stance
    "walk": {"speed": 1.25, "duty": 0.6, "toe_off": 28.0, "heel": 12.0, "lift": 0.11, "reach": 0.985},
    "sprint": {"speed": 3.6, "duty": 0.34, "toe_off": 38.0, "heel": 4.0, "lift": 0.26, "reach": 0.95},
    # the Brigada officers' run (civilian.gd plays it against RUN = 4 m/s)
    "run": {"speed": 4.0, "duty": 0.34, "toe_off": 38.0, "heel": 4.0, "lift": 0.26, "reach": 0.95},
}
HEEL_BACK = 0.045        # heel contact point behind the ankle (m)


def rot_x(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def min_rot(a, b):
    """Smallest rotation turning direction a onto direction b."""
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3)
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1 / (1 + c))


def smooth(x):
    return x * x * (3 - 2 * x)


def rebuild(path, clips=None):
    b = bytearray(open(path, "rb").read())
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    base = 20 + n + 8
    names = {nd.get("name"): i for i, nd in enumerate(js["nodes"])}
    hips = names["mixamorig:Hips"]

    def view(i):
        a = js["accessors"][i]
        bv = js["bufferViews"][a["bufferView"]]
        comps = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
        off = base + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(b, np.float32, count=a["count"] * comps, offset=off).reshape(-1, comps) \
            if comps > 1 else np.frombuffer(b, np.float32, count=a["count"], offset=off), off

    def t_of(node):
        return np.array(js["nodes"][node].get("translation", [0, 0, 0]), float)

    def tracks_of(clip):
        anim = next(a for a in js["animations"] if a["name"] == clip)
        out = {}
        times = None
        for ch in anim["channels"]:
            s = anim["samplers"][ch["sampler"]]
            out[(ch["target"]["node"], ch["target"]["path"])] = s["output"]
            times = s["input"]
        return out, view(times)[0].astype(float)

    side_nodes = {}
    for side in ("Left", "Right"):
        side_nodes[side] = [names[f"mixamorig:{side}{bn}"] for bn in ("UpLeg", "Leg", "Foot", "ToeBase")]

    # standing reference from the idle clip's first frame (feet flat on the ground;
    # the Brigada models only have idle_alert)
    stand = next(n for n in ("idle", "idle_alert") if any(a["name"] == n for a in js["animations"]))
    idle, _ = tracks_of(stand)

    def key(tracks, node, path, k):
        return view(tracks[(node, path)])[0][k].astype(float)

    ref = {}
    Rh0 = quat_mat(key(idle, hips, "rotation", 0))
    hipT0 = key(idle, hips, "translation", 0)
    for side, (up, leg, foot, toe) in side_nodes.items():
        Ru = Rh0 @ quat_mat(key(idle, up, "rotation", 0))
        Rl = Ru @ quat_mat(key(idle, leg, "rotation", 0))
        Rf = Rl @ quat_mat(key(idle, foot, "rotation", 0))
        H = hipT0 + Rh0 @ t_of(up)
        A = H + Ru @ t_of(leg) + Rl @ t_of(foot)
        ref[side] = {"Rf": Rf, "ankle": A, "toe": Rf @ t_of(toe),
                     "a": np.linalg.norm(t_of(leg)), "b": np.linalg.norm(t_of(foot))}

    for clip, g in GAITS.items():
        if (clips and clip not in clips) or not any(a["name"] == clip for a in js["animations"]):
            continue
        tracks, times = tracks_of(clip)
        T = times[-1] - times[0]             # loop clips: last key repeats the first
        count = len(times)
        v, duty = g["speed"], g["duty"]
        S = v * T * duty                        # ankle travel during stance
        hipT = view(tracks[(hips, "translation")])[0].astype(float).copy()
        Rh = [quat_mat(key(tracks, hips, "rotation", k)) for k in range(count)]
        # left heel strike when the original clip had the left ankle furthest forward
        orig_z = []
        for k in range(count):
            up, leg, foot, _ = side_nodes["Left"]
            Ru = Rh[k] @ quat_mat(key(tracks, up, "rotation", k))
            Rl = Ru @ quat_mat(key(tracks, leg, "rotation", k))
            orig_z.append((Ru @ t_of(leg) + Rl @ t_of(foot))[2])
        hs = {"Left": (times[int(np.argmin(orig_z))] - times[0]) / T}
        hs["Right"] = (hs["Left"] + 0.5) % 1.0

        def foot_pose(side, u):
            """Ankle position and foot rotation at gait phase u (0 = heel strike)."""
            r = ref[side]
            x = r["ankle"][0]
            ya = r["ankle"][1]
            zc = hipT0[2]
            heel_vec = np.array([0, ya, -HEEL_BACK])          # heel contact -> ankle, foot flat
            toe_vec = -r["toe"] + np.array([0, 0, 0])          # toe joint -> ankle, foot flat
            toe_y = ya + r["toe"][1]

            def stance(u):
                zf = zc - S / 2 + S * (u / duty)               # flat-foot ankle z, moving back at v
                if u < 0.15 * duty:                            # heel rock: pivot on the heel
                    a = -np.radians(g["heel"]) * (1 - smooth(u / (0.15 * duty)))
                    pivot = np.array([x, 0.0, zf + HEEL_BACK])
                    R = rot_x(-a)
                    return pivot + R @ heel_vec, R
                if u > 0.6 * duty:                             # heel off: pivot on the toe
                    a = np.radians(g["toe_off"]) * smooth((u - 0.6 * duty) / (0.4 * duty))
                    pivot = np.array([x + r["toe"][0], toe_y, zf + r["toe"][2]])
                    R = rot_x(-a)
                    return pivot + R @ toe_vec, R
                return np.array([x, ya, zf]), np.eye(3)

            if u < duty:
                return stance(u)
            s = (u - duty) / (1 - duty)
            P0, _ = stance(duty - 1e-6)
            P1, _ = stance(0.0)
            e = (1 - np.cos(np.pi * s)) / 2
            P = P0 + (P1 - P0) * e
            P[1] += g["lift"] * np.sin(np.pi * s ** 0.8)
            a = np.radians(g["toe_off"]) + (-np.radians(g["heel"]) - np.radians(g["toe_off"])) * smooth(s)
            return P, rot_x(-a)

        poses = {}
        for side in side_nodes:
            poses[side] = [foot_pose(side, ((times[k] - times[0]) / T - hs[side]) % 1.0) for k in range(count)]

        # hips: drop just enough for the stance leg(s) to reach
        newy = hipT[:, 1].copy()
        for k in range(count):
            for side, (up, _, _, _) in side_nodes.items():
                u = ((times[k] - times[0]) / T - hs[side]) % 1.0
                if u >= duty:
                    continue
                A = poses[side][k][0]
                off = Rh[k] @ t_of(up)
                L = (ref[side]["a"] + ref[side]["b"]) * g["reach"]
                d2 = (A[0] - hipT[k, 0] - off[0]) ** 2 + (A[2] - hipT[k, 2] - off[2]) ** 2
                newy[k] = min(newy[k], A[1] + np.sqrt(max(L * L - d2, 0.0)) - off[1])
        newy = (np.roll(newy, 1) + 2 * newy + np.roll(newy, -1)) / 4 if count > 3 else newy
        hipT[:, 1] = newy

        new_rot = {}
        for side, (up, leg, foot, _) in side_nodes.items():
            r = ref[side]
            for nd in (up, leg, foot):
                new_rot.setdefault(nd, np.zeros((count, 4)))
            for k in range(count):
                A, Rp = poses[side][k]
                H = hipT[k] + Rh[k] @ t_of(up)
                a, bl = r["a"], r["b"]
                d = np.clip(np.linalg.norm(A - H), abs(a - bl) + 1e-4, (a + bl) * 0.999)
                uax = (A - H) / np.linalg.norm(A - H)
                pole = np.array([0.0, 0.0, -1.0])               # knees bend forward
                w = pole - uax * np.dot(pole, uax)
                w /= np.linalg.norm(w)
                cos_h = (a * a + d * d - bl * bl) / (2 * a * d)
                K = H + a * (cos_h * uax + np.sqrt(max(0.0, 1 - cos_h * cos_h)) * w)
                Ru = Rh[k] @ quat_mat(key(tracks, up, "rotation", k))
                Ru = min_rot(Ru @ t_of(leg), K - H) @ Ru
                Rl = Ru @ quat_mat(key(tracks, leg, "rotation", k))
                Rl = min_rot(Rl @ t_of(foot), H + uax * d - K) @ Rl
                Rf = Rp @ r["Rf"]
                for nd, m in ((up, Rh[k].T @ Ru), (leg, Ru.T @ Rl), (foot, Rl.T @ Rf)):
                    q = mat_quat(m)
                    if k and np.dot(q, new_rot[nd][k - 1]) < 0:
                        q = -q
                    new_rot[nd][k] = q

        for nd, arr in new_rot.items():
            _, off = view(tracks[(nd, "rotation")])
            b[off:off + arr.size * 4] = arr.astype(np.float32).tobytes()
        _, off = view(tracks[(hips, "translation")])
        b[off:off + hipT.size * 4] = hipT.astype(np.float32).tobytes()
        print(f"  {clip}: {v} m/s, cycle {T:.2f} s, stance travel {S:.2f} m")
    open(path, "wb").write(bytes(b))


if __name__ == "__main__":
    # --clips walk: only those (the Brigada models have walk + run, no sprint)
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--clips=")), None)
    for p in [a for a in sys.argv[1:] if not a.startswith("--")]:
        print(p)
        rebuild(p, only)
