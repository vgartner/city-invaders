#!/usr/bin/env python3
"""Make Godot import the maps' textures compressed for the GPU.

Godot extracts a city glb's images to godot/city/<map>_<n>.png and imports
them lossless: four bytes a pixel in video memory, over a gigabyte for one
map. The editor would switch a texture to GPU compression (S3TC/BPTC, a
quarter to an eighth of that) the first time it draws it in 3D, but a
headless import never does. This writes the images out, as Godot would,
with their import settings, before Godot makes its own - for every image
of the glbs given (or of all in godot/city):

    tools/.venv/bin/python tools/map/texture_imports.py [godot/city/<map>.glb ...]
    godot --headless --path godot --import

Run it before the first import of a map (the map pipeline does, and the
release build). --force also replaces settings Godot already wrote, so the
next import converts the textures again.

Only the Python standard library.
"""
import argparse
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CITY = ROOT / "godot" / "city"

STUB = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/normal_map={normal}
mipmaps/generate=true
detect_3d/compress_to=0
"""


def images(glb):
    """[(index, is_normal_map, png bytes)] of the glb's embedded images."""
    data = Path(glb).read_bytes()
    n = struct.unpack("<I", data[12:16])[0]
    j = json.loads(data[20:20 + n])
    binary = data[20 + n + 8:]                       # the BIN chunk after its 8-byte header
    textures = j.get("textures", [])
    normal = {textures[m["normalTexture"]["index"]].get("source") for m in j.get("materials", [])
              if "normalTexture" in m}
    out = []
    for i, im in enumerate(j.get("images", [])):
        if im.get("mimeType") != "image/png" or "bufferView" not in im:
            continue
        v = j["bufferViews"][im["bufferView"]]
        start = v.get("byteOffset", 0)
        out.append((i, i in normal, binary[start:start + v["byteLength"]]))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("glb", nargs="*", type=Path)
    ap.add_argument("--force", action="store_true", help="replace import settings that already exist")
    a = ap.parse_args()
    glbs = a.glb or sorted(CITY.glob("*.glb"))
    for glb in glbs:
        made = kept = 0
        for i, is_normal, png in images(glb):
            # the file Godot would extract on import, under the same name: with
            # only the settings there and no image, the import fails
            image = glb.with_name(f"{glb.stem}_{i}.png")
            target = image.with_name(image.name + ".import")
            if target.exists() and not a.force:
                kept += 1
                continue
            if not image.exists() or image.read_bytes() != png:
                image.write_bytes(png)
            target.write_text(STUB.format(normal=1 if is_normal else 0))
            made += 1
        print(f"{glb.name}: {made} texture import settings written, {kept} kept")


if __name__ == "__main__":
    main()
