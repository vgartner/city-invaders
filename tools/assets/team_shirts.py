#!/usr/bin/env python3
"""Football fans: copy a pedestrian and repaint its shirt in club colours
(no crests - colours and stripes only).

The pedestrians are one skinned mesh on a shared atlas. The shirt is found
in texture space: triangles whose vertices mostly follow the torso / upper
arm bones are rasterised into a mask, then only the pixels close to the
mask's dominant colour are kept (drops skin, straps and prints). Those are
repainted keeping their shading: team colour x (pixel brightness / shirt
brightness). Stripes follow the body's rest-pose X, so they run vertically
across seams.

    tools/.venv/bin/python tools/assets/team_shirts.py godot/assets/common/people/ped_10_student_man_20s.glb \\
        gremio godot/assets/rio_grande_do_sul/people/ped_16_fan_gremio_man.glb
"""
import io
import json
import struct
import sys

import numpy as np
from PIL import Image

TORSO = {"Spine", "Spine1", "Spine2", "LeftShoulder", "RightShoulder", "LeftArm", "RightArm"}
CELESTE, BLACK, WHITE = (0.0, 0.58, 0.84), (0.06, 0.06, 0.07), (0.93, 0.93, 0.93)
RED = (0.80, 0.05, 0.07)
STRIPE_M = 0.045


def team_colour(team, x, y, collar):
    if team == "gremio":
        k = np.floor(x / STRIPE_M).astype(int) % 4          # blue, black, blue, white
        pal = np.array([CELESTE, BLACK, CELESTE, WHITE])
        return pal[k]
    out = np.tile(np.array(RED), (len(x), 1))
    out[collar] = WHITE                                      # Inter: white collar trim
    return out


def load(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    js = json.loads(b[20:20 + n])
    binlen = struct.unpack("<I", b[20 + n:24 + n])[0]
    blob = bytearray(b[28 + n:28 + n + binlen])
    return js, blob


def acc(js, blob, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride")
    item = np.dtype(dt).itemsize * comps
    if stride and stride != item:
        raw = np.frombuffer(bytes(blob[off:off + stride * a["count"]]), np.uint8).reshape(a["count"], stride)[:, :item]
        arr = np.frombuffer(raw.tobytes(), dt).reshape(a["count"], comps)
    else:
        arr = np.frombuffer(bytes(blob[off:off + item * a["count"]]), dt).reshape(a["count"], comps)
    if a.get("normalized") and dt != np.float32:
        arr = arr / np.iinfo(dt).max
    return arr


def raster(mask, xs, ys, uv, tris, vals, W, H):
    """Rasterise triangles in UV space; write interpolated vals (x, y) per pixel."""
    for t in tris:
        p = uv[t] * [W, H]
        x0, y0 = np.floor(p.min(0)).astype(int)
        x1, y1 = np.ceil(p.max(0)).astype(int)
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, W - 1), min(y1, H - 1)
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        a, b_, c = p
        den = (b_[1] - c[1]) * (a[0] - c[0]) + (c[0] - b_[0]) * (a[1] - c[1])
        if abs(den) < 1e-9:
            continue
        w0 = ((b_[1] - c[1]) * (gx - c[0]) + (c[0] - b_[0]) * (gy - c[1])) / den
        w1 = ((c[1] - a[1]) * (gx - c[0]) + (a[0] - c[0]) * (gy - c[1])) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= -0.01) & (w1 >= -0.01) & (w2 >= -0.01)
        if not inside.any():
            continue
        v = vals[t]
        sl = (slice(y0, y1 + 1), slice(x0, x1 + 1))
        mask[sl] |= inside
        xs[sl] = np.where(inside, w0 * v[0, 0] + w1 * v[1, 0] + w2 * v[2, 0], xs[sl])
        ys[sl] = np.where(inside, w0 * v[0, 1] + w1 * v[1, 1] + w2 * v[2, 1], ys[sl])


def main(src, team, out):
    js, blob = load(src)
    prim = js["meshes"][0]["primitives"][0]
    at = prim["attributes"]
    pos = acc(js, blob, at["POSITION"]).astype(float)
    uv = acc(js, blob, at["TEXCOORD_0"]).astype(float)
    joints = acc(js, blob, at["JOINTS_0"]).astype(int)
    weights = acc(js, blob, at["WEIGHTS_0"]).astype(float)
    idx = acc(js, blob, prim["indices"]).reshape(-1, 3).astype(int)
    skin = js["skins"][0]
    jname = [js["nodes"][j]["name"].split(":")[-1] for j in skin["joints"]]
    dom = joints[np.arange(len(joints)), weights.argmax(1)]
    torso_v = np.array([jname[d] in TORSO for d in dom])
    tris = idx[torso_v[idx].sum(1) >= 2]
    mat = js["materials"][prim["material"]]
    img_i = js["textures"][mat["pbrMetallicRoughness"]["baseColorTexture"]["index"]]["source"]
    bv = js["bufferViews"][js["images"][img_i]["bufferView"]]
    im = Image.open(io.BytesIO(bytes(blob[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]]))).convert("RGB")
    W, H = im.size
    px = np.asarray(im, float) / 255
    mask = np.zeros((H, W), bool)
    xs = np.zeros((H, W))
    ys = np.zeros((H, W))
    raster(mask, xs, ys, uv, tris, pos[:, [0, 1]], W, H)
    # keep the shirt fabric: pixels near the dominant colour of the mask
    med = np.median(px[mask], 0)
    dist = np.linalg.norm(px - med, axis=2)
    cloth = mask & (dist < 0.22)
    lum = px.mean(2)
    shade = np.clip(lum / max(med.mean(), 1e-3), 0.25, 1.6)[cloth]
    neck_y = ys[cloth].max()
    collar = ys[cloth] > neck_y - 0.03
    col = team_colour(team, xs[cloth], ys[cloth], collar)
    newpx = px.copy()
    newpx[cloth] = np.clip(col * shade[:, None], 0, 1)
    print(f"{src}: shirt {cloth.sum()} px of {mask.sum()} torso px, dominant colour {np.round(med, 2)}")
    buf = io.BytesIO()
    Image.fromarray((newpx * 255).astype(np.uint8)).save(buf, "PNG")
    data = buf.getvalue()
    # append the repainted atlas as a new buffer view; point the image at it
    while len(blob) % 4:
        blob.append(0)
    js["bufferViews"].append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)})
    blob.extend(data)
    while len(blob) % 4:
        blob.append(0)
    js["images"][img_i] = {"bufferView": len(js["bufferViews"]) - 1, "mimeType": "image/png"}
    js["buffers"][0]["byteLength"] = len(blob)
    jb = json.dumps(js, separators=(",", ":")).encode()
    jb += b" " * (-len(jb) % 4)
    with open(out, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(jb) + 8 + len(blob)))
        f.write(struct.pack("<I4s", len(jb), b"JSON") + jb)
        f.write(struct.pack("<I4s", len(blob), b"BIN\0") + bytes(blob))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
