# Building a release

The game is exported with Godot's own export templates; a Windows build can
be made on macOS or Linux, no Windows machine needed to build it.

## What a release is

| File | What |
|---|---|
| `CityInvaders.exe` | Godot's Windows runtime |
| `CityInvaders.pck` | the game: scripts, assets, data (kept outside the executable because it is larger than 1 GB) |
| `maps/<id>.pck` | one package per map: `res://city/<id>*`, its scene, textures and layouts |
| `CityInvaders-<version>-setup.exe` | the installer, which downloads the files above |

Each map has a package of its own so a player installs only the maps they
want and adds others later, and so no file gets near 2 GiB, the most a
GitHub release file may hold. `scripts/packs.gd`, the first autoload, loads
every map package from `maps/` next to the executable and from
`user://map_packs/`. It refuses a package with anything but map files
(`res://city/`, their imported data): a map can't replace or add game code.
It also registers the maps' UIDs, which the game package's UID table doesn't
know. A next phase that isn't installed makes the current map the last one
(`main.gd` `_map_spec`).

## Windows

1. Install the export templates for the Godot version the project uses
   (`godot --version`, 4.7.2 at the time of writing): download
   `Godot_v4.7.2-stable_export_templates.tpz` from the
   [Godot releases](https://github.com/godotengine/godot/releases) and unpack
   its `templates/` folder into the editor's template directory, named after
   the version (`4.7.2.stable`):
   - macOS: `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`
   - Linux: `~/.local/share/godot/export_templates/4.7.2.stable/`
   - Windows: `%APPDATA%\Godot\export_templates\4.7.2.stable\`

   Only `version.txt` and the `windows_*` files are needed for a Windows build.
2. Make sure the maps are built and imported (README, Quick start).
3. Write the export presets for the maps in `godot/city/` (a new city gets
   its preset this way) and export the game and each map:

   ```bash
   ids=$(python3 tools/build/map_packs.py presets)
   godot --headless --path godot --export-release "Windows Desktop" ../build/windows/CityInvaders.exe
   for id in $ids; do godot --headless --path godot --export-pack "Map $id" ../build/windows/maps/$id.pck; done
   ```

The game preset packs every resource plus the `*.json` data files
(collections, the people roster, `city/maps.json`) except the maps' files,
and leaves notes and Blender files out; each `Map <id>` preset packs only
`city/<id>.*` and `city/<id>_*`. `build/` is ignored by git.

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
`/DIR=...`.

The setup downloads from the release without signing in, so it works once
the release is published and the repository is public. While the repository
is private, install by hand: `CityInvaders.exe` and `CityInvaders.pck` in a
folder, the map packages in its `maps` subfolder.

## Building on GitHub

`.github/workflows/build-windows.yml` makes the release on GitHub. It only
runs when started by hand: *Actions > Build Windows > Run workflow*, with a
version (e.g. `0.2.0`), or `gh workflow run build-windows.yml -f version=0.2.0`.

1. **build** (Linux runner): fetches `godot/`'s LFS files from the project's
   LFS server, installs Godot and the Windows export templates, imports,
   exports the game and every map, starts a round from the packages
   (`--main-pack`, no errors or invalid UIDs allowed) and puts the files and
   `catalog.ini` in a **draft release** `v<version>-build<run>`.
2. **installer** (Windows runner): builds the setup for that release, installs
   it silently from a local copy of the release files, starts a round in the
   installed game (no errors allowed) and adds the setup to the release.

Publish the draft to share it. Kept free on purpose: no automatic trigger, no
Actions artifacts (they count against the private repository's 500 MB
storage; release files don't), caches (Godot and its templates, Godot's
import) within the 10 GB a repository gets. Windows minutes count double on a
private repository; the installer job is short. The first run imports every
asset and takes much longer than later ones.

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
  first time ("More info", then "Run anyway").
- The DevAgent stays off in a release unless the game is started with
  `-- --devagent`.
