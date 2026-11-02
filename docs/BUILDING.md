# Building a release

The game is exported with Godot's own export templates; Windows, macOS and
Linux builds can all be made on one Linux or macOS machine.

## What a release is

| File | What |
|---|---|
| `CityInvaders.exe` | Godot's Windows runtime |
| `CityInvaders.pck` | the game: scripts, assets, data (kept outside the executable because it is larger than 1 GB) |
| `CityInvaders-map-<id>.pck` | one package per map: `res://city/<id>*`, its scene, textures and layouts; installed as `maps/<id>.pck` or downloaded into `user://map_packs/` |
| `CityInvaders-<version>-setup.exe` | the Windows installer, which downloads the files above |
| `CityInvaders-<version>-macos.zip` | the macOS app (universal: Apple Silicon and Intel), with the first phase inside |
| `CityInvaders-<version>-linux-x86_64.tar.gz` | the Linux game, with the first phase inside |
| `catalog.ini`, `catalog.json` | the maps and game files with sizes and SHA-256, for the installer and for the game's Maps screen |

Each map has a package of its own so a player installs only the maps they
want and adds others later, and so no file gets near 2 GiB, the most a
GitHub release file may hold. `scripts/packs.gd`, the first autoload, loads
every map package from `maps/` next to the executable and from
`user://map_packs/`. It refuses a package with anything but map files
(`res://city/`, their imported data): a map can't replace or add game code.
It also registers the maps' UIDs, which the game package's UID table doesn't
know. A next phase that isn't installed makes the current map the last one
(`main.gd` `_map_spec`).

The game's **Maps** screen (title screen > Maps, `scripts/map_store.gd`)
reads `catalog.json` from the release of the game's own version, downloads a
map into `user://map_packs/`, checks its SHA-256 and loads it at once. The
macOS and Linux packages carry only the first phase (one file under 2 GiB,
no installer) and get the others this way; on Windows it adds maps the
installer left out. `CITY_INVADERS_CATALOG=<url>` points it at another
catalog (a local server, for testing).

## Exporting

1. Install the export templates for the Godot version the project uses
   (`godot --version`, 4.7.2 at the time of writing): download
   `Godot_v4.7.2-stable_export_templates.tpz` from the
   [Godot releases](https://github.com/godotengine/godot/releases) and unpack
   its `templates/` folder into the editor's template directory, named after
   the version (`4.7.2.stable`):
   - macOS: `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`
   - Linux: `~/.local/share/godot/export_templates/4.7.2.stable/`
   - Windows: `%APPDATA%\Godot\export_templates\4.7.2.stable\`

   Needed: `version.txt`, the `windows_*` files, `macos.zip` and
   `linux_release.x86_64`.
2. Make sure the maps are built and imported (README, Quick start).
3. Write the export presets for the maps in `godot/city/` (a new city gets
   its preset this way) and export the game and each map:

   ```bash
   ids=$(python3 tools/build/map_packs.py presets)
   godot --headless --path godot --export-release "Windows Desktop" ../build/windows/CityInvaders.exe
   for id in $ids; do godot --headless --path godot --export-pack "Map $id" ../build/windows/maps/$id.pck; done
   godot --headless --path godot --export-release "macOS" ../build/macos/CityInvaders.zip
   godot --headless --path godot --export-release "Linux" ../build/linux/CityInvaders.x86_64
   ```

The Windows game preset packs every resource plus the `*.json` data files
(collections, the people roster, `city/maps.json`) except the maps' files,
and leaves notes and Blender files out; the macOS and Linux presets keep the
first phase (the first map in the menu); each `Map <id>` preset packs only
`city/<id>.*` and `city/<id>_*`. All of them use the same desktop texture
compression (S3TC/BPTC), so one map package serves every platform. Godot
exports a universal or arm64 macOS app only with ETC2/ASTC textures imported
as well, which would double the import and push the game package past 2 GiB;
so the macOS preset says x86_64 and uses a template (`map_packs.py
macos-template`, `MACOS_TEMPLATE`) that holds Godot's universal runtime under
that name. Apple Silicon runs it natively and reads the desktop (BC)
textures, as the editor does there. The macOS app gets Godot's built-in ad-hoc
signature; it is not notarized (that needs an Apple Developer account), so
macOS blocks its first start until *System Settings > Privacy & Security >
Open Anyway*. `build/` is ignored by git.

## The installer

`tools/build/installer.iss` (Inno Setup 6.3+, built on Windows) is a small
setup that downloads the game: it reads `catalog.ini` from the release it was
built for, shows the maps to choose, and downloads the game and those maps,
checking each file's SHA-256. Run again, it downloads only what is new or
changed, so it also adds maps. `python3 tools/build/map_packs.py release
build/windows build/release <version>` lays out the files flat, as a release
holds them (`CityInvaders-map-<id>.pck`), and writes the catalog. Setup
options: `/CATALOG=<url>` (another catalog, e.g. a local server for testing),
`/MAPS=gasometro,centro` (preselect maps), and Inno's `/VERYSILENT`,
`/DIR=...`. The setup also installs `LICENSE`, `docs/LICENSING.md` and
`godot/assets/CREDITS.md` into the game's `licenses` folder: the maps carry
OpenStreetMap and Mapillary data whose licences require the attribution.

The setup downloads from the release without signing in, so it works once
the release is published and the repository is public. While the repository
is private, install by hand: `CityInvaders.exe` and `CityInvaders.pck` in a
folder, the map packages in its `maps` subfolder.

## Building on GitHub

`.github/workflows/build-release.yml` makes the release on GitHub. It only
runs when started by hand: *Actions > Build release > Run workflow*, with a
new version (e.g. `0.3.0`; it refuses one already published, and a draft from an earlier run gets the new files), or
`gh workflow run build-release.yml -f version=0.3.0`. The version goes into
the game (`config/version`) and the executable's file version for that
build; *pre-release* marks the release as one (it is then not the
"latest" the README links to).

1. **build** (Linux runner): fetches `godot/`'s LFS files from the project's
   LFS server, installs Godot and the export templates, imports, exports the
   Windows game, every map, the macOS app and the Linux game, and lays out
   the release files. Tests (`tools/build/smoke_test.py`, no errors or invalid
   UIDs allowed): a round from the Windows packages in the editor binary; a
   round in the real Linux game; the Maps screen's download of a map from a
   local copy of the release, then a round on it after a restart. Then the
   files go to a **draft release** `v<version>`, with the install steps for
   each system, the maps and the licences in its notes.
2. **installer** (Windows runner): builds the setup for that release, installs
   it silently from a local copy of the release files, starts a round in the
   installed game and adds the setup to the release.
3. **macos** (Apple Silicon runner): checks the app's signature and that it
   is universal, starts it and plays a round.

Publish the draft to share it. Kept free on purpose: no automatic trigger, no
Actions artifacts (release files don't count against the storage quota),
caches (Godot and its templates, Godot's import) within the 10 GB a
repository gets; the runners are free on a public repository. The first run
imports every asset and takes much longer than later ones.

## Checking a build without Windows

The exported packages run in the macOS / Linux editor binary, which shows
whether everything the game reads made it into them:

```bash
DEVAGENT_PORT=24691 godot --headless --main-pack build/windows/CityInvaders.pck -- --devagent --maps-dir=build/windows/maps
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
DEVAGENT_PORT=24691 tools/devagent/devagent.py errors
```

## Notes

- `--maps-dir=<path>` tells the game another folder of map packages (the
  editor binary has no `maps/` next to it).
- The build is not code-signed: Windows SmartScreen asks for confirmation the
  first time ("More info", then "Run anyway"); macOS needs "Open Anyway" once.
- In `--headless` (the dummy renderer), a map loaded while the game runs
  reports RID errors in a round; with a renderer it plays fine. The tests
  download a map, start the game again and play it from `user://map_packs/`.
- The DevAgent stays off in a release unless the game is started with
  `-- --devagent`.
