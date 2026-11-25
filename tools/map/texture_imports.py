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
- **A world's tiles** (`--share <prefix>`, what `rebuild` does for a tile):
  the tiles of a world draw mostly with the same images, and each glb held
  its own copy. With --share every image leaves the glb and becomes
  godot/city/<prefix>_<hash>.png, one file for every tile that uses those
  bytes, which the glb refers to by name; the tile's own extracted images
  (<tile>_<n>.png) are removed. A glb that already refers to its images gets
  their settings written. `--prune <prefix>` removes the shared images no
  glb in godot/city refers to any more.
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
import hashlib
import json
import os
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import glb_shared_textures                                   # noqa: E402

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


def _doc(glb):
    data = Path(glb).read_bytes()
    n = struct.unpack("<I", data[12:16])[0]
    return json.loads(data[20:20 + n]), data[20 + n + 8:]      # the BIN chunk after its 8-byte header


def _normals(j):
    """The indices of the images a material uses as its normal map."""
    textures = j.get("textures", [])
    return {textures[m["normalTexture"]["index"]].get("source") for m in j.get("materials", [])
            if "normalTexture" in m}


def images(glb):
    """[(index, is_normal_map, png bytes)] of the glb's embedded images."""
    j, binary = _doc(glb)
    normal = _normals(j)
    out = []
    for i, im in enumerate(j.get("images", [])):
        if im.get("mimeType") != "image/png" or "bufferView" not in im:
            continue
        v = j["bufferViews"][im["bufferView"]]
        start = v.get("byteOffset", 0)
        out.append((i, i in normal, binary[start:start + v["byteLength"]]))
    return out


def referred(glb):
    """[(file, is_normal_map)] of the images the glb refers to by name."""
    j, _ = _doc(glb)
    normal = _normals(j)
    return [(Path(glb).parent / im["uri"], i in normal) for i, im in enumerate(j.get("images", []))
            if "uri" in im and not im["uri"].startswith("data:")]


def share(glb, prefix, force=False):
    """The glb's images as shared files next to it, <prefix>_<hash>.png (an
    image used as a normal map: <prefix>_<hash>n.png), and the glb referring
    to them. Returns (images, files written, settings written)."""
    glb = Path(glb)
    normal = _normals(_doc(glb)[0])
    wrote = [0, 0]

    def uri(i, png):
        if png[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        name = f"{prefix}_{hashlib.sha1(png).hexdigest()[:16]}{'n' if i in normal else ''}.png"
        image = glb.with_name(name)
        if not image.exists():
            tmp = image.with_name(f"{name}.{os.getpid()}.tmp")   # tiles are built side by side
            tmp.write_bytes(png)
            os.replace(tmp, image)
            wrote[0] += 1
        wrote[1] += write(image, i in normal, force)
        return name

    n = glb_shared_textures.point_out(glb, glb, uri)
    for old in glb.parent.glob(f"{glb.stem}_*.png"):             # what Godot or an earlier run extracted
        if re.fullmatch(rf"{re.escape(glb.stem)}_\d+\.png", old.name):
            old.unlink()
            old.with_name(old.name + ".import").unlink(missing_ok=True)
    return n, wrote[0], wrote[1]


def prune(prefix):
    """Removes the shared images no glb refers to. Returns how many."""
    used = set()
    for glb in CITY.glob("*.glb"):
        used.update(p.name for p, _ in referred(glb))
    gone = 0
    for image in CITY.glob(f"{prefix}_*.png"):
        if re.fullmatch(rf"{re.escape(prefix)}_[0-9a-f]{{16}}n?\.png", image.name) and image.name not in used:
            image.unlink()
            image.with_name(image.name + ".import").unlink(missing_ok=True)
            gone += 1
    return gone


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("glb", nargs="*", type=Path)
    ap.add_argument("--force", action="store_true", help="write the maps' settings anew (after a rebuild)")
    ap.add_argument("--share", metavar="PREFIX",
                    help="the glbs' images as shared files godot/city/<PREFIX>_<hash>.png (a world's tiles)")
    ap.add_argument("--prune", metavar="PREFIX", help="remove the shared images no glb refers to")
    a = ap.parse_args()
    if a.prune:
        print(f"{a.prune}: {prune(a.prune)} shared images no longer used, removed")
        if not a.glb:
            return
    for glb in a.glb or sorted(CITY.glob("*.glb")):
        if a.share:
            n, files, changed = share(glb, a.share, a.force)
            print(f"{glb.name}: {n} images shared as {a.share}_*.png, {files} new, "
                  f"{changed} texture import settings written")
            continue
        changed = 0
        for i, is_normal, png in images(glb):
            # the file Godot would extract on import, under the same name: with
            # only the settings there and no image, the import fails
            image = glb.with_name(f"{glb.stem}_{i}.png")
            if not image.exists() or image.read_bytes() != png:
                image.write_bytes(png)
            changed += write(image, is_normal, a.force)
        for image, is_normal in referred(glb):
            if image.exists():
                changed += write(image, is_normal)       # shared: the texture keeps its id
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
