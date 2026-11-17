#!/usr/bin/env python3
"""Give the original URB-07 a part-specific PBR atlas, retaining its rig and clips.

Requires numpy and Pillow. Run from the repository root:
  tools/.venv/bin/python tools/assets/urb07_finish.py

The palette source GLB is retained under tools/blender/src/urb07_finish/.
Surface details are original procedural height fields, baked into tangent-space
normal maps. No third-party model, texture or script is used.
"""
import argparse
from collections import defaultdict
import hashlib
import io
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image

SIZE = 2048
PAD = 4
DTYPES = {5121: "u1", 5123: "<u2", 5125: "<u4", 5126: "<f4"}
WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(data):
    magic, version, length = struct.unpack_from("<III", data)
    if magic != 0x46546C67 or version != 2 or length != len(data):
        raise ValueError("Expected a complete glTF 2.0 binary")
    n = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20:20 + n]), data[28 + n:]


def array(doc, blob, index):
    a = doc["accessors"][index]
    v = doc["bufferViews"][a["bufferView"]]
    if "byteStride" in v or "sparse" in a:
        raise ValueError("The retained URB source uses non-interleaved accessors")
    return np.frombuffer(blob, dtype=DTYPES[a["componentType"]],
                         count=a["count"] * WIDTHS[a["type"]],
                         offset=v.get("byteOffset", 0) + a.get("byteOffset", 0)
                         ).reshape(a["count"], WIDTHS[a["type"]])


def texture_slots(doc):
    mat = doc["materials"][0]
    pbr = mat["pbrMetallicRoughness"]
    info = {"basecolor": pbr["baseColorTexture"], "normal": mat["normalTexture"],
            "metallic_roughness": pbr["metallicRoughnessTexture"],
            "emissive": mat["emissiveTexture"]}
    return {k: doc["images"][doc["textures"][v["index"]]["source"]]["bufferView"]
            for k, v in info.items()}


def images(doc, blob):
    result = {}
    for key, index in texture_slots(doc).items():
        view = doc["bufferViews"][index]
        start = view.get("byteOffset", 0)
        image = Image.open(io.BytesIO(blob[start:start + view["byteLength"]]))
        result[key] = np.asarray(image.convert("RGB"), dtype=np.float32) / 255
    return result


def sample(image, uv):
    h, w = image.shape[:2]
    x = np.clip(uv[:, 0] * w - .5, 0, w - 1)
    y = np.clip(uv[:, 1] * h - .5, 0, h - 1)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    x1, y1 = np.minimum(x0 + 1, w - 1), np.minimum(y0 + 1, h - 1)
    fx, fy = (x - x0)[:, None], (y - y0)[:, None]
    return ((image[y0, x0] * (1 - fx) + image[y0, x1] * fx) * (1 - fy)
            + (image[y1, x0] * (1 - fx) + image[y1, x1] * fx) * fy)


def charts_for(pos, triangles, joints, weights, uv):
    dominant = joints[np.arange(len(pos)), weights.argmax(axis=1)]
    if np.any(np.count_nonzero(weights > .001, axis=1) != 1):
        raise ValueError("This pass expects the original rigidly weighted robot plates")
    parents = list(range(len(pos)))

    def find(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i

    def union(a, b):
        a, b = find(a), find(b)
        if a != b:
            parents[b] = a

    seen = {}
    for i, (p, bone) in enumerate(zip(pos, dominant)):
        key = (int(bone), *np.round(p, 6))
        if key in seen:
            union(i, seen[key])
        else:
            seen[key] = i
    for tri in triangles:
        for v in tri[1:]:
            if dominant[tri[0]] == dominant[v]:
                union(int(tri[0]), int(v))
    groups = defaultdict(list)
    p = pos[triangles]
    normals = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    axes = np.abs(normals).argmax(axis=1)
    for i, tri in enumerate(triangles):
        axis = int(axes[i])
        side = int(normals[i, axis] >= 0)
        groups[(find(int(tri[0])), axis, side)].append(i)
    charts = []
    for (part, axis, side), faces in sorted(groups.items()):
        vertices = np.unique(triangles[faces])
        dims = [a for a in range(3) if a != axis]
        lo = pos[vertices][:, dims].min(axis=0)
        span = np.maximum(pos[vertices][:, dims].max(axis=0) - lo, .0001)
        old = uv[vertices].mean(axis=0)
        marking = int(old[1] * 4) == 3 and int(old[0] * 4) in (0, 1)
        hazard = int(old[1] * 4) == 1 and int(old[0] * 4) == 3
        charts.append({"part": part, "axis": axis, "side": side, "dims": dims,
                       "faces": faces, "lo": lo, "span": span,
                       "bone": int(dominant[vertices[0]]),
                       "flat": np.ptp(pos[vertices, axis]) < .16 * min(span),
                       "priority": 4.0 if hazard else (1.5 if marking else 1.0)})
    return charts, len({c["part"] for c in charts})


def pack(charts):
    def attempt(density, assign=False):
        rects = [(max(4, int(np.ceil(c["span"][0] * density * c["priority"]))) + PAD * 2,
                  max(4, int(np.ceil(c["span"][1] * density * c["priority"]))) + PAD * 2,
                  i) for i, c in enumerate(charts)]
        rects.sort(key=lambda r: (-r[1], -r[0], r[2]))
        x = y = row = 0
        for w, h, i in rects:
            if w > SIZE or h > SIZE:
                return False
            if x + w > SIZE:
                x = 0
                y += row
                row = 0
            if y + h > SIZE:
                return False
            if assign:
                charts[i]["rect"] = (x, y, w, h)
            x += w
            row = max(row, h)
        return True
    low, high = 1.0, 2000.0
    for _ in range(20):
        mid = (low + high) / 2
        if attempt(mid):
            low = mid
        else:
            high = mid
    attempt(low, True)
    return low


def raster(chart, pos, triangles, uv, old_images):
    _, _, w, h = chart["rect"]
    coords = (pos[:, chart["dims"]] - chart["lo"]) / chart["span"]
    coords = coords * np.array([w - 2 * PAD - 1, h - 2 * PAD - 1]) + PAD
    outputs = {k: np.zeros((h, w, 3), dtype=np.float32)
               for k in ("basecolor", "metallic_roughness", "emissive")}
    mask = np.zeros((h, w), dtype=bool)
    for face in chart["faces"]:
        ids = triangles[face]
        a, b, c = coords[ids]
        xmin, ymin = np.maximum(0, np.floor(np.minimum(np.minimum(a, b), c))).astype(int)
        xmax, ymax = np.minimum([w - 1, h - 1], np.ceil(np.maximum(np.maximum(a, b), c))).astype(int)
        yy, xx = np.mgrid[ymin:ymax + 1, xmin:xmax + 1]
        den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(den) < 1e-10:
            continue
        u = ((b[1] - c[1]) * (xx - c[0]) + (c[0] - b[0]) * (yy - c[1])) / den
        v = ((c[1] - a[1]) * (xx - c[0]) + (a[0] - c[0]) * (yy - c[1])) / den
        z = 1 - u - v
        inside = (u >= -1e-5) & (v >= -1e-5) & (z >= -1e-5)
        tx, ty = xx[inside], yy[inside]
        if not len(tx):
            continue
        old_uv = u[inside, None] * uv[ids[0]] + v[inside, None] * uv[ids[1]] + z[inside, None] * uv[ids[2]]
        for key, target in outputs.items():
            target[ty, tx] = sample(old_images[key], old_uv)
        mask[ty, tx] = True
    return outputs, mask, coords


def detail(chart, maps, mask, bone_name):
    _, _, w, h = chart["rect"]
    width, height = chart["span"]
    y, x = np.mgrid[:h, :w].astype(np.float32)
    x = (x - PAD) * width / max(1, w - 2 * PAD - 1)
    y = (y - PAD) * height / max(1, h - 2 * PAD - 1)
    edge = np.minimum(np.minimum(x, width - x), np.minimum(y, height - y))
    rng = np.random.default_rng(7000 + chart["part"] * 7 + chart["axis"] * 2 + chart["side"])
    cloud = Image.fromarray(rng.integers(0, 256, (10, 10), dtype=np.uint8))
    cloud = np.asarray(cloud.resize((w, h), Image.Resampling.BICUBIC), dtype=np.float32) / 255 - .5
    relief = np.zeros((h, w), dtype=np.float32)
    groove = np.zeros_like(relief)
    steel = np.exp(-np.maximum(edge, 0) / .0012) * .38
    if chart["flat"] and min(width, height) > .075:
        inset = min(.014, min(width, height) * .10)
        # Recessed panel joint, with a small raised edge beside it.
        line = np.exp(-((edge - inset) / .0008) ** 2)
        groove += line * .6
        relief -= line * .0011
        relief += np.exp(-((edge - inset - .0022) / .0011) ** 2) * .00045
        radius = min(.0048, min(width, height) * .035)
        bolt_inset = inset + radius * 1.6
        for bx in (bolt_inset, width - bolt_inset):
            for by in (bolt_inset, height - bolt_inset):
                r = np.hypot(x - bx, y - by)
                cap = np.clip((radius - r) / max(radius * .3, .0001), 0, 1)
                washer = np.exp(-((r - radius * 1.24) / .0007) ** 2)
                slot = np.exp(-((x - bx + y - by) / .00065) ** 2) * (r < radius * .7)
                relief += cap * .0018 + washer * .0004 - slot * .0008
                steel = np.maximum(steel, cap * .80 + washer * .55)
                groove += slot * .4
        # Vents belong on back/side housings, not every face of every part.
        vent_bone = any(s in bone_name for s in ("Spine", "ForeArm", "Leg"))
        vent_side = chart["axis"] == 0 or (chart["axis"] == 2 and chart["side"] == 1)
        if vent_bone and vent_side and min(width, height) > .11:
            across = np.clip((width * .31 - np.abs(x - width / 2)) / .003, 0, 1)
            for cy in np.linspace(height * .34, height * .66, 4):
                slit = across * np.exp(-((y - cy) / .0018) ** 4)
                relief -= slit * .002
                groove += slit * .65
    lit = maps["emissive"].max(axis=2) > .12
    steel[lit] = 0
    groove[lit] = 0
    relief[lit] = 0
    base = maps["basecolor"]
    paint = (base[:, :, 0] > base[:, :, 1] * 1.18) & (base[:, :, 0] > .16)
    base *= (1 + cloud[..., None] * .07 - np.clip(groove, 0, .8)[..., None] * .48)
    wear = np.clip(steel, 0, .8)[..., None]
    base[:] = base * (1 - wear) + np.array([.46, .49, .49]) * wear
    mr = maps["metallic_roughness"]
    mr[:, :, 0] = 1
    mr[:, :, 1] = np.where(paint, .59, .43) + cloud * .07 + np.clip(groove, 0, 1) * .12
    mr[:, :, 2] = np.where(paint, .025, .78) * (1 - steel) + steel * .93
    # The source material uses a normal strength of .65; keep that setting.
    gy, gx = np.gradient(relief, height / max(1, h - 2 * PAD - 1),
                         width / max(1, w - 2 * PAD - 1))
    normal = np.dstack((-gx / .65, -gy / .65, np.ones_like(gx)))
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    maps["normal"] = normal * .5 + .5
    # Expand chart pixels into a gutter without changing the UV island bounds.
    valid = mask.copy()
    for _ in range(PAD + 1):
        count = np.zeros((h, w), dtype=np.float32)
        sums = {k: np.zeros_like(a) for k, a in maps.items()}
        for axis, shift in ((0, -1), (0, 1), (1, -1), (1, 1)):
            neighbor = np.roll(valid, shift, axis)
            if axis == 0:
                neighbor[0 if shift == 1 else -1] = False
            else:
                neighbor[:, 0 if shift == 1 else -1] = False
            count += neighbor
            for k, a in maps.items():
                sums[k] += np.roll(a, shift, axis) * neighbor[..., None]
        fill = ~valid & (count > 0)
        for k, a in maps.items():
            a[fill] = sums[k][fill] / count[fill, None]
        valid |= fill
    return maps


def write_glb(doc, blob, replacements):
    result = bytearray()
    for i, view in enumerate(doc["bufferViews"]):
        start = view.get("byteOffset", 0)
        payload = replacements.get(i, blob[start:start + view["byteLength"]])
        result.extend(b"\0" * (-len(result) % 4))
        view["byteOffset"], view["byteLength"] = len(result), len(payload)
        result.extend(payload)
    doc["buffers"][0]["byteLength"] = len(result)
    result.extend(b"\0" * (-len(result) % 4))
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    return (struct.pack("<III", 0x46546C67, 2, 28 + len(text) + len(result))
            + struct.pack("<II", len(text), 0x4E4F534A) + text
            + struct.pack("<II", len(result), 0x004E4942) + result)


def build(source, target, report_path):
    data = source.read_bytes()
    doc, blob = read_glb(data)
    primitive = doc["meshes"][0]["primitives"][0]
    attributes = {k: array(doc, blob, v) for k, v in primitive["attributes"].items()}
    pos, uv = attributes["POSITION"], attributes["TEXCOORD_0"]
    triangles = array(doc, blob, primitive["indices"]).reshape(-1, 3)
    charts, parts = charts_for(pos, triangles, attributes["JOINTS_0"], attributes["WEIGHTS_0"], uv)
    density = pack(charts)
    old_images = images(doc, blob)
    atlas = {k: np.zeros((SIZE, SIZE, 3), dtype=np.float32) for k in old_images}
    atlas["normal"][:] = (.5, .5, 1)
    old_ids, new_uv, tangents = [], [], []
    index_map = {}
    indices = np.zeros_like(triangles)
    for ci, chart in enumerate(charts):
        maps, mask, coords = raster(chart, pos, triangles, uv, old_images)
        joint = doc["skins"][0]["joints"][chart["bone"]]
        maps = detail(chart, maps, mask, doc["nodes"][joint]["name"])
        x, y, w, h = chart["rect"]
        for k, a in maps.items():
            atlas[k][y:y + h, x:x + w] = a
        axis_u, axis_v = np.eye(3)[chart["dims"]]
        for face in chart["faces"]:
            for corner, old in enumerate(triangles[face]):
                key = (int(old), ci)
                if key not in index_map:
                    index_map[key] = len(old_ids)
                    old_ids.append(int(old))
                    new_uv.append((coords[old] + [x, y] + .5) / SIZE)
                    n = attributes["NORMAL"][old]
                    t = axis_u - n * np.dot(n, axis_u)
                    t /= max(np.linalg.norm(t), 1e-12)
                    handedness = 1 if np.dot(np.cross(n, t), axis_v) >= 0 else -1
                    tangents.append([*t, handedness])
                indices[face, corner] = index_map[key]
        if ci % 150 == 0:
            print("Baked chart", ci, "/", len(charts), flush=True)
    old_ids = np.array(old_ids)
    replacements = {}
    for k, accessor_index in primitive["attributes"].items():
        acc = doc["accessors"][accessor_index]
        value = attributes[k][old_ids]
        if k == "TEXCOORD_0":
            value = np.array(new_uv)
        elif k == "TANGENT":
            value = np.array(tangents)
        value = value.astype(DTYPES[acc["componentType"]])
        acc["count"], acc["byteOffset"] = len(value), 0
        replacements[acc["bufferView"]] = value.tobytes()
    index_acc = doc["accessors"][primitive["indices"]]
    replacements[index_acc["bufferView"]] = indices.astype(DTYPES[index_acc["componentType"]]).tobytes()
    for kind, view in texture_slots(doc).items():
        pixels = np.clip(atlas[kind] * 255, 0, 255).astype(np.uint8)
        stream = io.BytesIO()
        Image.fromarray(pixels).save(stream, format="PNG", compress_level=9)
        png = stream.getvalue()
        replacements[view] = png
        target.parent.mkdir(parents=True, exist_ok=True)
        (target.parent / f"robot_{kind} 2048.png").write_bytes(png)
    target.write_bytes(write_glb(doc, blob, replacements))
    # Reindexing must not alter a triangle's shape or dominant-bone assignment.
    new_doc, new_blob = read_glb(target.read_bytes())
    new_tri = array(new_doc, new_blob, primitive["indices"]).reshape(-1, 3)
    for k in ("POSITION", "NORMAL", "JOINTS_0", "WEIGHTS_0"):
        assert np.array_equal(attributes[k][triangles],
                              array(new_doc, new_blob, primitive["attributes"][k])[new_tri]), k
    original_doc, _ = read_glb(data)
    for k in ("nodes", "skins", "animations", "materials"):
        assert original_doc[k] == new_doc[k], k
    for i, view in enumerate(original_doc["bufferViews"]):
        if i not in replacements:
            start, size = view.get("byteOffset", 0), view["byteLength"]
            nv = new_doc["bufferViews"][i]
            assert blob[start:start + size] == new_blob[nv["byteOffset"]:nv["byteOffset"] + size]
    report = {"source_sha256": hashlib.sha256(data).hexdigest(),
              "output_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
              "triangles": len(triangles), "source_vertices": len(pos),
              "output_vertices": len(old_ids), "rigid_components": parts,
              "uv_charts": len(charts), "texels_per_metre": density,
              "joints": len(doc["skins"][0]["joints"]),
              "clips": [a.get("name") for a in doc["animations"]],
              "triangle_positions_normals_and_weights_identical": True,
              "nodes_skins_animations_materials_identical": True,
              "untouched_buffer_views_identical": True}
    if report_path:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path("tools/blender/src/urb07_finish/robot_palette_source.glb"))
    parser.add_argument("--output", type=Path,
                        default=Path("godot/assets/common/enemies/robot/robot.glb"))
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        raise SystemExit("Keep the palette source separate from the finished GLB")
    build(args.source, args.output, args.report)
