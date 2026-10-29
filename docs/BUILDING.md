# Building a release

The game is exported with Godot's own export templates; a Windows build can
be made on macOS or Linux, no Windows machine needed to build it.

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
3. Export with the preset in `godot/export_presets.cfg`:

   ```bash
   cd godot
   godot --headless --path . --export-release "Windows Desktop" ../build/windows/CityInvaders.exe
   ```

   ```bash
   godot --headless --path . --export-pack "Windows maps pack" ../build/windows/CityInvaders-maps.pck
   ```

   The result is `CityInvaders.exe`, `CityInvaders.pck` (the game's data,
   kept outside the executable because it is larger than 1 GB) and
   `CityInvaders-maps.pck` (`res://city/`, the generated maps). The maps have
   a package of their own because one package would be over 2 GB, the most a
   GitHub release file may hold; `scripts/packs.gd`, the first autoload,
   loads it from next to the executable. Ship the three together.

The game preset packs every resource plus the `*.json` data files
(collections, the people roster) except `city/`, and leaves notes and Blender
files out; the maps preset packs only `city/` (the maps and their layouts). `build/` is ignored by git.

## Building on GitHub

`.github/workflows/build-windows.yml` makes the same Windows build on
GitHub's free Linux runner. It only runs when started by hand: *Actions >
Build Windows > Run workflow*, with a version (e.g. `0.2.0`), or
`gh workflow run build-windows.yml -f version=0.2.0`.

It fetches `godot/`'s LFS files from the project's LFS server, installs
Godot and the Windows export templates, imports, exports, starts a round
from the packages (`--main-pack`, no errors allowed) and attaches
`CityInvaders-<version>-windows.zip` (game) and
`CityInvaders-<version>-windows-maps.zip` (maps; unzip both into the same
folder) to a **draft release**
`v<version>-build<run>`. Publish the draft to share it.

Kept free on purpose: no automatic trigger, no Actions artifacts (they count
against the private repository's 500 MB storage; release files don't), and
caches (Godot and its templates, Godot's import) stay within the 10 GB a
repository gets. The first run imports every asset and takes much longer
than later ones.

## Checking a build without Windows

The exported `.pck` runs in the macOS / Linux editor binary, which shows
whether everything the game reads made it into the package:

```bash
DEVAGENT_PORT=24691 godot --headless --main-pack build/windows/CityInvaders.pck -- --devagent --maps-pack=build/windows/CityInvaders-maps.pck
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
DEVAGENT_PORT=24691 tools/devagent/devagent.py errors
```

## Notes

- `--maps-pack=<path>` tells the editor binary where the maps package is;
  the exported game finds it next to the executable.
- The build is not code-signed: Windows SmartScreen asks for confirmation the
  first time ("More info", then "Run anyway").
- The DevAgent stays off in a release unless the game is started with
  `-- --devagent`.
