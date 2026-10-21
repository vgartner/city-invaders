#!/usr/bin/env python3
"""Make GLBs share one texture set instead of each embedding its own copy.

Asset packs often embed the same atlas (base colour, normal, ...) in every
GLB: dozens of identical 2-8 MB images, imported - and held in video memory -
once per file. This rewrites each GLB so an embedded image that matches one
of the shared PNGs (same bytes) points at that file by a relative URI; the
image's bytes leave the GLB. Geometry, materials and everything else stay as
they are. Godot then imports the shared PNGs once.

    tools/map/glb_shared_textures.py --textures DIR in1.glb [in2.glb ...] --out OUTDIR

Each output GLB refers to the textures by a path relative to OUTDIR, so keep
the textures where --textures says relative to the output (copy them first).
An image that matches no shared PNG stays embedded.
"""
import argparse
import hashlib
import json
import os
import struct
from pathlib import Path


def _read(path):
    b = Path(path).read_bytes()
    magic, version, _length = struct.unpack("<III", b[:12])
    if magic != 0x46546C67 or version != 2:
        raise ValueError(f"{path}: not a glTF 2.0 binary")
    jlen, jtype = struct.unpack("<II", b[12:20])
    doc = json.loads(b[20:20 + jlen])
    binary = b""
    off = 20 + jlen
    if off < len(b):
        blen, _btype = struct.unpack("<II", b[off:off + 8])
        binary = b[off + 8:off + 8 + blen]
    return doc, binary


def _write(path, doc, binary):
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    binary += b"\0" * ((4 - len(binary) % 4) % 4)
    chunks = struct.pack("<II", len(js), 0x4E4F534A) + js
    if binary:
        chunks += struct.pack("<II", len(binary), 0x004E4942) + binary
    Path(path).write_bytes(struct.pack("<III", 0x46546C67, 2, 12 + len(chunks)) + chunks)


def share(src, dst, shared, rel_dir):
    """shared: md5 -> file name. Returns how many images now point outside."""
    doc, binary = _read(src)
    views = doc.get("bufferViews", [])
    drop = set()
    n = 0
    for im in doc.get("images", []):
        if "bufferView" not in im:
            continue
        v = views[im["bufferView"]]
        data = binary[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]]
        name = shared.get(hashlib.md5(data).hexdigest())
        if not name:
            continue
        drop.add(im.pop("bufferView"))
        im.pop("mimeType", None)
        im["uri"] = f"{rel_dir}/{name}".lstrip("/")
        n += 1
    if drop:
        # repack the buffer without the dropped views; renumber the rest
        keep, new_bin, remap = [], bytearray(), {}
        for i, v in enumerate(views):
            if i in drop:
                continue
            start = v.get("byteOffset", 0)
            data = binary[start:start + v["byteLength"]]
            while len(new_bin) % 4:
                new_bin.append(0)
            nv = dict(v, byteOffset=len(new_bin))
            new_bin += data
            remap[i] = len(keep)
            keep.append(nv)
        doc["bufferViews"] = keep
        for acc in doc.get("accessors", []):
            if "bufferView" in acc:
                acc["bufferView"] = remap[acc["bufferView"]]
            sp = acc.get("sparse")
            if sp:
                sp["indices"]["bufferView"] = remap[sp["indices"]["bufferView"]]
                sp["values"]["bufferView"] = remap[sp["values"]["bufferView"]]
        for im in doc.get("images", []):
            if "bufferView" in im:
                im["bufferView"] = remap[im["bufferView"]]
        binary = bytes(new_bin)
        if doc.get("buffers"):
            doc["buffers"][0]["byteLength"] = len(binary)
    _write(dst, doc, binary)
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("glbs", nargs="+", type=Path)
    ap.add_argument("--textures", type=Path, required=True, help="folder with the shared PNGs")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    shared = {hashlib.md5(p.read_bytes()).hexdigest(): p.name for p in args.textures.glob("*.png")}
    args.out.mkdir(parents=True, exist_ok=True)
    rel = os.path.relpath(args.textures.resolve(), args.out.resolve())
    for g in args.glbs:
        n = share(g, args.out / g.name, shared, rel)
        print(f"{g.name}: {n} images shared, {g.stat().st_size // 1024} KB -> {(args.out / g.name).stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
