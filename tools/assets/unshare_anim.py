#!/usr/bin/env python3
"""Give every animation sampler its own output accessor. Exporters dedupe
identical key arrays (e.g. a constant foot rotation used by both legs and by
several clips); the in-place fix tools (fix_stance, fix_arms, arm_swing)
would then overwrite one track with another. Run first on new packs:

    tools/.venv/bin/python tools/assets/unshare_anim.py godot/assets/common/people/ped_*.glb
"""
import json
import struct
import sys
from collections import Counter


def unshare(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    binlen = struct.unpack("<I", b[20 + n:24 + n])[0]
    blob = bytearray(b[28 + n:28 + n + binlen])
    use = Counter(s["output"] for a in js["animations"] for s in a["samplers"])
    seen, copies = set(), 0
    for a in js["animations"]:
        for s in a["samplers"]:
            acc_i = s["output"]
            if use[acc_i] < 2:
                continue
            if acc_i not in seen:
                seen.add(acc_i)                  # the first user keeps the original
                continue
            acc = dict(js["accessors"][acc_i])
            bv = js["bufferViews"][acc["bufferView"]]
            start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            size = acc["count"] * {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[acc["type"]] * 4
            while len(blob) % 4:
                blob.append(0)
            js["bufferViews"].append({"buffer": 0, "byteOffset": len(blob), "byteLength": size})
            blob.extend(blob[start:start + size])
            acc["bufferView"] = len(js["bufferViews"]) - 1
            acc["byteOffset"] = 0
            js["accessors"].append(acc)
            s["output"] = len(js["accessors"]) - 1
            copies += 1
    while len(blob) % 4:
        blob.append(0)
    js["buffers"][0]["byteLength"] = len(blob)
    jb = json.dumps(js, separators=(",", ":")).encode()
    jb += b" " * (-len(jb) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(jb) + 8 + len(blob)))
        f.write(struct.pack("<I4s", len(jb), b"JSON") + jb)
        f.write(struct.pack("<I4s", len(blob), b"BIN\0") + bytes(blob))
    print(path, f"{copies} shared tracks given their own keys")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        unshare(p)
