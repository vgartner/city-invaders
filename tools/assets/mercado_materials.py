#!/usr/bin/env python3
"""Rebuild the Mercado's shared PBR atlas without changing its geometry or UVs.

Requires numpy and Pillow. Example, from the repository root:
  tools/.venv/bin/python tools/assets/mercado_materials.py \
    godot/assets/rio_grande_do_sul/landmarks/mercado_publico

Only the existing three embedded PNGs and their external mirrors are replaced.
The source is read before writing, so rebuilding in place is deterministic.
"""
import argparse
import hashlib
import io
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


SIZE = 2048
CELL = SIZE // 4
PALETTE = [(204, 159, 75), (216, 209, 189), (144, 69, 39), (54, 65, 60),
           (145, 148, 135), (117, 143, 133), (114, 79, 47), (216, 214, 199),
           (137, 174, 177), (165, 68, 43), (80, 109, 48), (169, 138, 88),
           (171, 156, 123), (89, 57, 30), (241, 226, 175), (33, 60, 44)]
ROUGHNESS = [.84, .80, .86, .55, .69, .62, .68, .71,
             .16, .73, .65, .90, .92, .72, .46, .78]


def png_bytes(pixels):
    stream = io.BytesIO()
    Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8)).save(
        stream, format="PNG", compress_level=9)
    return stream.getvalue()


def field(rng, resolution, blur=0):
    image = Image.fromarray(rng.integers(0, 256, (resolution, resolution), dtype=np.uint8))
    image = image.resize((CELL, CELL), Image.Resampling.BICUBIC)
    if blur:
        image = image.filter(ImageFilter.GaussianBlur(blur))
    value = np.asarray(image, dtype=np.float32) / 255
    return (value - .5) * 2


def atlas(original):
    base = np.zeros((SIZE, SIZE, 3), dtype=np.uint8)
    normal = np.zeros_like(base)
    orm = np.zeros_like(base)
    y, x = np.mgrid[0:CELL, 0:CELL].astype(np.float32)
    for index, color in enumerate(PALETTE):
        rng = np.random.default_rng(20261117 + index)
        broad = field(rng, 12, 8)
        medium = field(rng, 64, 1)
        # Subpixel noise bloats the embedded PNGs without surviving game mipmaps.
        fine = field(rng, 128, .8)
        tone = .025 * broad + .012 * medium + .006 * fine
        height = .10 * fine + .12 * medium
        rough = ROUGHNESS[index] + .025 * medium
        metal = np.zeros_like(x)
        strength = .7
        if index in (0, 1, 7):
            # Soft mineral variation, rather than high-contrast all-over dirt.
            pores = np.clip(-fine - .35, 0, 1)
            tone += .035 * broad - .025 * pores
            height = .25 * fine + .15 * medium
            rough += .035 * broad
            strength = .9
        elif index in (6, 13):
            # Long grain, a small colour change per board, and recessed joins.
            warp = 7 * field(rng, 9, 4) + 2 * np.sin(y / 57)
            grain = np.sin((x + warp) * .63) * .014
            grain += np.sin((x + warp) * 1.78) * .006
            board = np.floor(x / 128).astype(int)
            board_tone = np.array([-.035, .025, -.012, .018])[board]
            seam_distance = np.minimum(x % 128, 128 - x % 128)
            seams = np.exp(-(seam_distance / 1.15) ** 2)
            tone += grain + board_tone - .14 * seams + .035 * broad
            height = grain * 5 - .32 * seams + fine * .025
            rough += .03 * broad + .09 * seams
            strength = 1.4
        elif index == 4:
            # Preserve the original eight-by-eight floor tile scale.
            u, v = x % 64, y % 64
            distance = np.minimum(np.minimum(u, 64 - u), np.minimum(v, 64 - v))
            grout = np.exp(-(distance / .95) ** 2)
            ids = (x // 64 + (y // 64) * 8).astype(int)
            tile_tone = rng.uniform(-.035, .035, 64)[ids]
            tone += tile_tone - .22 * grout + .025 * broad
            height = -.3 * grout + .025 * fine
            rough += .13 * grout
            strength = 1.8
        elif index == 2:
            # Overlapping terracotta courses with a rounded tile section.
            u = (x + (y // 64 % 2) * 32) % 64
            v = y % 64
            side = np.minimum(u, 64 - u)
            seam = np.exp(-(side / 1.15) ** 2)
            lap = np.exp(-(v / 1.5) ** 2)
            roundness = np.sin(u * np.pi / 64)
            tone += .04 * broad + .02 * medium - .16 * seam - .10 * lap
            height = .30 * roundness - .20 * seam - .20 * lap + .015 * fine
            strength = 2.5
        elif index in (3, 5):
            # Painted metal stays dielectric; only tiny exposed scratches are metal.
            scratches = (rng.random((CELL, CELL)) > .9992).astype(np.float32)
            scratches = np.asarray(Image.fromarray((scratches * 255).astype(np.uint8))
                                   .filter(ImageFilter.GaussianBlur(.65))) / 255
            tone += .025 * broad + .16 * scratches
            rough += .04 * broad - .15 * scratches
            metal = np.clip(scratches * 3.0, 0, 1)
            height = fine * .035 - scratches * .15
            strength = 1.0
        elif index == 11:
            weave = (np.sin(x * np.pi) + np.sin(y * np.pi)) * .008
            tone += weave + .025 * broad
            height = weave * 8 + fine * .04
        elif index in (8, 14, 15):
            height = np.zeros_like(x)
            tone *= .1
        color_pixels = np.asarray(color)[None, None, :] * (1 + tone[..., None])
        # At the edge of each cell flatten bump to avoid atlas-boundary derivatives.
        border = np.minimum(np.minimum(x, CELL - 1 - x), np.minimum(y, CELL - 1 - y))
        height *= np.clip(border / 6, 0, 1)
        dy, dx = np.gradient(height)
        vector = np.dstack((-dx * strength, dy * strength, np.ones_like(x)))
        vector /= np.linalg.norm(vector, axis=2, keepdims=True)
        row, col = divmod(index, 4)
        region = np.s_[row * CELL:(row + 1) * CELL, col * CELL:(col + 1) * CELL]
        base[region] = np.clip(color_pixels, 0, 255).astype(np.uint8)
        normal[region] = np.clip((vector * .5 + .5) * 255, 0, 255).astype(np.uint8)
        orm[region] = np.dstack((np.full_like(x, 255), np.clip(rough, 0, 1) * 255,
                                metal * 255)).astype(np.uint8)
    # Keep every original caption pixel, including antialiasing and padding.
    label = np.s_[3 * CELL:4 * CELL, 3 * CELL:4 * CELL]
    base[label] = np.asarray(Image.open(io.BytesIO(original)).convert("RGB"))[label]
    return {"basecolor": png_bytes(base), "normal": png_bytes(normal),
            "metallic_roughness": png_bytes(orm)}


def read_glb(data):
    magic, version, length = struct.unpack_from("<III", data)
    if magic != 0x46546C67 or version != 2 or length != len(data):
        raise ValueError("Expected a complete glTF 2.0 binary")
    chunks = {}
    offset = 12
    while offset < len(data):
        size, kind = struct.unpack_from("<II", data, offset)
        chunks[kind] = data[offset + 8:offset + 8 + size]
        offset += 8 + size
    return json.loads(chunks[0x4E4F534A]), chunks[0x004E4942]


def image_data(document, blob, image_index):
    view = document["bufferViews"][document["images"][image_index]["bufferView"]]
    start = view.get("byteOffset", 0)
    return blob[start:start + view["byteLength"]]


def image_slots(document):
    slots = {}
    for material in document["materials"]:
        pbr = material.get("pbrMetallicRoughness", {})
        for kind, info in [("basecolor", pbr.get("baseColorTexture")),
                           ("normal", material.get("normalTexture")),
                           ("metallic_roughness", pbr.get("metallicRoughnessTexture"))]:
            if info is not None:
                image = document["textures"][info["index"]]["source"]
                slots[document["images"][image]["bufferView"]] = kind
    return slots


def rewrite(data, maps):
    document, blob = read_glb(data)
    slots = image_slots(document)
    if set(slots.values()) != set(maps):
        raise ValueError("Expected the Mercado's existing three-map atlas")
    output = bytearray()
    geometry = hashlib.sha256()
    for index, view in enumerate(document["bufferViews"]):
        start = view.get("byteOffset", 0)
        payload = blob[start:start + view["byteLength"]]
        if index in slots:
            payload = maps[slots[index]]
        else:
            geometry.update(payload)
        while len(output) % 4:
            output.append(0)
        view["byteOffset"] = len(output)
        view["byteLength"] = len(payload)
        output.extend(payload)
    document["buffers"][0]["byteLength"] = len(output)
    while len(output) % 4:
        output.append(0)
    text = json.dumps(document, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    binary = (struct.pack("<III", 0x46546C67, 2, 28 + len(text) + len(output))
              + struct.pack("<II", len(text), 0x4E4F534A) + text
              + struct.pack("<II", len(output), 0x004E4942) + output)
    return binary, geometry.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    output = args.output or args.source
    building = args.source / "building/mercado_publico_porto_alegre.glb"
    document, blob = read_glb(building.read_bytes())
    texture = document["materials"][0]["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    maps = atlas(image_data(document, blob, document["textures"][texture]["source"]))
    report = {"atlas_size": SIZE, "models": []}
    for source in sorted(args.source.rglob("*.glb")):
        original = source.read_bytes()
        binary, signature = rewrite(original, maps)
        target = output / source.relative_to(args.source)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(binary)
        for kind, png in maps.items():
            (target.parent / f"{target.stem}_mercado_shared_{kind}.png").write_bytes(png)
        report["models"].append({"file": str(source.relative_to(args.source)),
                                 "geometry_sha256": signature,
                                 "before_bytes": len(original), "after_bytes": len(binary)})
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
