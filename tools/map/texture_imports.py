#!/usr/bin/env python3
"""Make Godot import the game's 3D textures compressed for the GPU.

Godot imports an image lossless unless told otherwise: four bytes a pixel in
video memory - over a gigabyte for one map, and several for the models of a
round. The editor would switch a texture to GPU compression (S3TC/BPTC, a
quarter to an eighth of that) the first time it draws it in 3D, but a
headless import never does, and the `.import` files are not in the
repository. This writes those settings before Godot makes its own:

    python3 tools/map/texture_imports.py [godot/city/<map>.glb ...]
    godot --headless --path godot --import

- **Maps**: every image of the city glbs given (or of all in godot/city),
  written out as godot/city/<map>_<n>.png - the file Godot would extract -
  with its settings. The map pipeline runs this for a rebuilt map (--force:
  the images' numbers change with a rebuild).
- **Models**: the textures listed in tools/build/texture_imports.json with their
  use (colour, normal map, data), made by tools/build/texture_usage.gd from
  the models' materials. Only with no glb given. Images a model does not
  draw with - the interface's above all - are not in the list and stay
  lossless.

Settings Godot already wrote are changed in place (the texture keeps its
id); the next import converts the textures again. Run it before the first
import of a fresh clone; the release build does.

Only the Python standard library.
"""
import argparse
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GODOT = ROOT / "godot"
CITY = GODOT / "city"
MODELS = ROOT / "tools" / "build" / "texture_imports.json"

# compress/mode 2: VRAM compressed; normal_map 1: a normal map (two
# channels), 2: not one; detect_3d off: the choice is made here
SETTINGS = {"compress/mode": "2", "compress/high_quality": "false", "mipmaps/generate": "true",
            "detect_3d/compress_to": "0"}
STUB = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

"""


def settings(normal):
    return dict(SETTINGS, **{"compress/normal_map": "1" if normal else "2"})


def write(image, normal, force=False):
    """The import settings of one image; True if the file changed."""
    target = image.with_name(image.name + ".import")
    want = settings(normal)
    if target.exists() and not force:
        text = old = target.read_text()
        for key, value in want.items():
            text, n = re.subn(rf"(?m)^{re.escape(key)}=.*$", f"{key}={value}", text)
            if not n:
                break
        else:
            if text != old:
                target.write_text(text)
            return text != old
    target.write_text(STUB + "".join(f"{k}={v}\n" for k, v in want.items()))
    return True


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
    ap.add_argument("--force", action="store_true", help="write the maps' settings anew (after a rebuild)")
    a = ap.parse_args()
    for glb in a.glb or sorted(CITY.glob("*.glb")):
        changed = 0
        for i, is_normal, png in images(glb):
            # the file Godot would extract on import, under the same name: with
            # only the settings there and no image, the import fails
            image = glb.with_name(f"{glb.stem}_{i}.png")
            if not image.exists() or image.read_bytes() != png:
                image.write_bytes(png)
            changed += write(image, is_normal, a.force)
        print(f"{glb.name}: {changed} texture import settings written")
    if a.glb or not MODELS.exists():
        return
    changed = missing = 0
    for path, kind in json.loads(MODELS.read_text()).items():
        image = GODOT / path.removeprefix("res://")
        if not image.exists():
            missing += 1
            continue
        changed += write(image, kind == "normal")
    print(f"models: {changed} texture import settings written"
          + (f", {missing} listed textures not found (run tools/build/texture_usage.gd)" if missing else ""))


if __name__ == "__main__":
    main()
