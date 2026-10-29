#!/usr/bin/env python3
"""Export presets and the download catalog for a release with one package per map.

A released game is CityInvaders.exe + CityInvaders.pck (the game) and one
maps/<id>.pck per map (res://city/<id>*), so maps can be installed or added
on their own (docs/BUILDING.md).

  map_packs.py presets         rewrite godot/export_presets.cfg: the game
                               preset leaves every map out, one "Map <id>"
                               preset per map; prints the map ids
  map_packs.py release BUILD OUT VERSION
                               the release files in OUT, flat as a GitHub
                               release holds them: the game files from BUILD,
                               BUILD/maps/<id>.pck as CityInvaders-map-<id>.pck,
                               and catalog.ini (files, sizes, SHA-256, map
                               names) that the installer reads

Only the Python standard library.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GODOT = ROOT / "godot"
CITY = GODOT / "city"
PRESETS = GODOT / "export_presets.cfg"
BASE_EXCLUDE = "*.md, *.txt, *.blend, *.blend1"
# everything in the project outside city/
NOT_CITY = "assets/*, data/*, scripts/*, shaders/*, main.tscn"
# city/ files every map shares; they stay in the game package
SHARED = "city/maps.json, city/bark.png, city/leaves.png"
GAME_FILES = ["CityInvaders.exe", "CityInvaders.console.exe", "CityInvaders.pck"]


def map_ids() -> list:
    ids = sorted(p.stem for p in CITY.glob("*.glb")
                 if not p.stem.endswith(("_horizon", "_collision")))
    for a in ids:
        for b in ids:
            if a != b and b.startswith(a + "_"):
                sys.exit(f"map id {b!r} starts with {a!r}_: their files can't be told apart")
    return ids


def globs(mid: str) -> str:
    return f"city/{mid}.*, city/{mid}_*"


def presets() -> None:
    ids = map_ids()
    text = PRESETS.read_text()
    first = re.split(r"\n(?=\[preset\.1\])", text)[0].rstrip() + "\n"
    options = first.split("[preset.0.options]", 1)[1]
    game_exclude = ", ".join([BASE_EXCLUDE] + [globs(m) for m in ids])
    first = re.sub(r'^exclude_filter=".*"$', f'exclude_filter="{game_exclude}"', first, flags=re.M)
    out = [first]
    for n, mid in enumerate(ids, 1):
        others = [globs(m) for m in ids if m != mid]
        exclude = ", ".join([BASE_EXCLUDE, NOT_CITY, SHARED] + others)
        out.append(f'''
[preset.{n}]

name="Map {mid}"
platform="Windows Desktop"
runnable=false
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="city/{mid}.*.json"
exclude_filter="{exclude}"
export_path="../build/windows/maps/{mid}.pck"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.{n}.options]
{options.strip()}
''')
    PRESETS.write_text("".join(out))
    print(" ".join(ids))


def map_names() -> dict:
    """Menu names: the built-in maps from main.gd, imported ones from maps.json."""
    names = {}
    src = (GODOT / "scripts" / "main.gd").read_text()
    block = src.split("const MAPS := [", 1)[1].split("\n]", 1)[0]
    for mid, label in re.findall(r'\["(\w+)", "([^"]*)"', block):
        names[mid] = label
    reg = CITY / "maps.json"
    if reg.exists():
        for m in json.loads(reg.read_text()):
            names[m[0]] = m[1]
    return names


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def release(build_dir: str, out_dir: str, version: str) -> None:
    b, d = Path(build_dir), Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    names = map_names()
    game = [f for f in GAME_FILES if (b / f).exists()]
    built = sorted(p.stem for p in (b / "maps").glob("*.pck"))
    order = list(names)                       # the menu's order: phase 1, 2, 3, free play
    maps = sorted(built, key=lambda m: (order.index(m) if m in order else len(order), m))
    for f in game:
        (d / f).hardlink_to(b / f)
    for mid in maps:
        (d / f"CityInvaders-map-{mid}.pck").hardlink_to(b / "maps" / f"{mid}.pck")
    lines = ["; City Invaders download catalog, read by the installer.",
             "; Files are relative to this file's URL.",
             "[catalog]", f"version={version}", "game=" + ",".join(game), "maps=" + ",".join(maps)]
    for f in game:
        lines += ["", f"[file:{f}]", f"size={(d / f).stat().st_size}", f"sha256={sha256(d / f)}"]
    for mid in maps:
        f = d / f"CityInvaders-map-{mid}.pck"
        lines += ["", f"[map:{mid}]", f"name={names.get(mid, mid)}", f"file={f.name}",
                  f"size={f.stat().st_size}", f"sha256={sha256(f)}"]
    # UTF-16 with a BOM: Windows' INI reader (the installer's) reads it as Unicode
    (d / "catalog.ini").write_text("\r\n".join(lines) + "\r\n", encoding="utf-16")
    print("\n".join(lines))


if __name__ == "__main__":
    if sys.argv[1:2] == ["presets"]:
        presets()
    elif sys.argv[1:2] == ["release"] and len(sys.argv) == 5:
        release(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
