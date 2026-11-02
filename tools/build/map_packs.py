#!/usr/bin/env python3
"""Export presets and the download catalog for a release with one package per map.

A released game is the game package and one maps/<id>.pck per map
(res://city/<id>*), so maps can be installed or added on their own
(docs/BUILDING.md). On Windows the installer fetches the maps; the macOS and
Linux packages carry the first phase inside the game and download the others
from the game's Maps screen.

  map_packs.py presets         rewrite godot/export_presets.cfg: the Windows
                               game preset leaves every map out, the macOS and
                               Linux ones keep the first phase, one "Map <id>"
                               preset per map; prints the map ids
  map_packs.py release BUILD OUT VERSION
                               the release files in OUT, flat as a GitHub
                               release holds them: the game files from BUILD,
                               BUILD/maps/<id>.pck as CityInvaders-map-<id>.pck,
                               and the catalog (files, sizes, SHA-256, map
                               names): catalog.ini for the installer,
                               catalog.json for the game

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


# The macOS and Linux game presets; their options not listed take Godot's defaults.
# macOS is x86_64 (Apple Silicon runs it through Rosetta 2): Godot exports
# universal / arm64 only with ETC2/ASTC textures imported too, which would double
# the import and push the game package past 2 GiB.
OTHER_GAME_PRESETS = [
    ("macOS", "macOS", "../build/macos/CityInvaders.zip", """binary_format/architecture="x86_64"
application/bundle_identifier="net.vgdata.cityinvaders"
application/name="City Invaders"
application/short_version="{version}"
application/version="{version}"
application/copyright="GPL-3.0-or-later"
codesign/codesign=1
notarization/notarization=0
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false"""),
    ("Linux", "Linux", "../build/linux/CityInvaders.x86_64", """binary_format/embed_pck=false
binary_format/architecture="x86_64"
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false"""),
]


def first_phase(ids: list) -> str:
    """The map the macOS and Linux packages carry: the first in the menu."""
    return next((m for m in map_names() if m in ids), ids[0])


def preset(n: int, name: str, platform: str, path: str, include: str, exclude: str,
           options: str, runnable: str = "true") -> str:
    return f'''
[preset.{n}]

name="{name}"
platform="{platform}"
runnable={runnable}
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="{include}"
exclude_filter="{exclude}"
export_path="{path}"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.{n}.options]
{options.strip()}
'''


def presets() -> None:
    ids = map_ids()
    text = PRESETS.read_text()
    first = re.split(r"\n(?=\[preset\.1\])", text)[0].rstrip() + "\n"
    options = first.split("[preset.0.options]", 1)[1]
    version = re.search(r'^application/file_version="([^"]*)"', options, re.M).group(1)
    game_exclude = ", ".join([BASE_EXCLUDE] + [globs(m) for m in ids])
    first = re.sub(r'^exclude_filter=".*"$', f'exclude_filter="{game_exclude}"', first, flags=re.M)
    out = [first]
    n = 1
    keep = first_phase(ids)
    for name, platform, path, opts in OTHER_GAME_PRESETS:
        exclude = ", ".join([BASE_EXCLUDE] + [globs(m) for m in ids if m != keep])
        out.append(preset(n, name, platform, path, "*.json", exclude, opts.format(version=version)))
        n += 1
    for mid in ids:
        others = [globs(m) for m in ids if m != mid]
        exclude = ", ".join([BASE_EXCLUDE, NOT_CITY, SHARED] + others)
        out.append(preset(n, f"Map {mid}", "Windows Desktop", f"../build/windows/maps/{mid}.pck",
                          f"city/{mid}.*.json", exclude, options, "false"))
        n += 1
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
    # the same maps for the game's Maps screen (scripts/map_store.gd)
    cat = {"version": version, "maps": []}
    for mid in maps:
        f = d / f"CityInvaders-map-{mid}.pck"
        cat["maps"].append({"id": mid, "name": names.get(mid, mid), "file": f.name,
                            "size": f.stat().st_size, "sha256": sha256(f)})
    (d / "catalog.json").write_text(json.dumps(cat, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    if sys.argv[1:2] == ["presets"]:
        presets()
    elif sys.argv[1:2] == ["release"] and len(sys.argv) == 5:
        release(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
