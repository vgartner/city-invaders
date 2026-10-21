#!/usr/bin/env python3
"""Make a ground-pickup model from a first-person view model: keep only the
triangles skinned to the weapon bones (drop arms, hands and the spare
magazine), lay the gun on its side with its bottom at y=0, and export a
static glb with the same PBR material."""
import argparse
import json
import struct

import numpy as np
import trimesh


def joints_of(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    binary = b[20 + n + 8:]
    prim = js["meshes"][0]["primitives"][0]

    def acc(i):
        a = js["accessors"][i]
        bv = js["bufferViews"][a["bufferView"]]
        comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        arr = np.frombuffer(binary, dt, count=a["count"] * comps, offset=off)
        return arr.reshape(a["count"], comps)

    names = [js["nodes"][j]["name"] for j in js["skins"][0]["joints"]]
    J, W = acc(prim["attributes"]["JOINTS_0"]), acc(prim["attributes"]["WEIGHTS_0"])
    dominant = J[np.arange(len(J)), W.argmax(1)]
    return np.array([names[k] for k in dominant])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("viewmodel")
    ap.add_argument("out")
    ap.add_argument("--keep", nargs="+", default=["Weapon", "Magazine", "Bolt"])
    args = ap.parse_args()
    owner = joints_of(args.viewmodel)
    scene = trimesh.load(args.viewmodel, process=False, maintain_order=True)
    mesh = next(iter(scene.geometry.values()))
    assert len(mesh.vertices) == len(owner), "vertex order changed on load"
    keep_v = np.isin(owner, args.keep)
    keep_f = keep_v[mesh.faces].all(1)
    gun = mesh.submesh([np.nonzero(keep_f)[0]], append=True)
    # lie on its right side: rotate about the barrel axis (Z), then sit on y=0
    gun.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [0, 0, 1]))
    lo, hi = gun.bounds
    gun.apply_translation([-(lo[0] + hi[0]) / 2, -lo[1], -(lo[2] + hi[2]) / 2])
    gun.export(args.out)
    print(f"{args.out}: {len(gun.faces)} triangles, size {np.round(gun.extents, 2)} m")


if __name__ == "__main__":
    main()
