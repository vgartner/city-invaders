#!/usr/bin/env python3
"""Estimate the ground speed an in-place locomotion clip implies, so the
game can move characters at the speed their feet are actually stepping.

Forward kinematics of hips -> upper leg -> leg -> foot over the clip; the
stance foot sweeps backwards relative to the hips at ground speed, so the
speed is the steepest sustained backwards foot velocity (median of the
fastest 30% of samples)."""
import json
import struct
import sys

import numpy as np


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def load(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    binary = b[20 + n + 8:]

    def acc(i):
        a = js["accessors"][i]
        bv = js["bufferViews"][a["bufferView"]]
        comps = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        arr = np.frombuffer(binary, np.float32, count=a["count"] * comps, offset=off)
        return arr.reshape(a["count"], comps) if comps > 1 else arr
    return js, acc


def foot_track(js, acc, clip, side="Left"):
    names = {n.get("name"): i for i, n in enumerate(js["nodes"])}
    chain = [names[f"mixamorig:{b}"] for b in ("Hips", f"{side}UpLeg", f"{side}Leg", f"{side}Foot")]
    anim = next(a for a in js["animations"] if a["name"] == clip)
    rot, times = {}, None
    for ch in anim["channels"]:
        node, path = ch["target"]["node"], ch["target"]["path"]
        s = anim["samplers"][ch["sampler"]]
        if node in chain and path == "rotation":
            rot[node] = acc(s["output"])
            times = acc(s["input"])
    out = []
    for k in range(len(times)):
        R = np.eye(3)
        p = np.zeros(3)
        for j, node in enumerate(chain):
            nd = js["nodes"][node]
            t = np.array(nd.get("translation", [0, 0, 0]), float)
            if j > 0:
                p = p + R @ t
            q = rot[node][k] if node in rot else nd.get("rotation", [0, 0, 0, 1])
            R = R @ quat_mat(q) if j > 0 else quat_mat(q)
        out.append(p)
    return np.array(times), np.array(out)


def clip_speed(path, clip):
    js, acc = load(path)
    scale = 1.0
    for n in js["nodes"]:
        if "scale" in n and n.get("children"):
            scale = n["scale"][0]
    speeds = []
    for side in ("Left", "Right"):
        t, p = foot_track(js, acc, clip, side)
        v = -np.diff(p[:, 2]) / np.diff(t)      # backwards (+Z) foot velocity, character faces -Z
        v = -v                                  # positive when the foot moves towards +Z (backwards)
        top = np.sort(v)[-max(1, len(v) * 3 // 10):]
        speeds.append(np.median(top))
    return float(np.mean(speeds)) * scale, float(t[-1])


if __name__ == "__main__":
    for path in sys.argv[1:]:
        res = {c: clip_speed(path, c) for c in ("walk", "sprint")}
        print(path.split("/")[-1], {c: f"{v:.2f} m/s (cycle {T:.2f} s)" for c, (v, T) in res.items()})
