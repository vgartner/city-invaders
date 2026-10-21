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

   The result is `CityInvaders.exe` plus `CityInvaders.pck` (the game's
   data, kept outside the executable because it is larger than 1 GB). Ship
   the two together, e.g. zipped.

The preset packs every resource plus the `*.json` data files (city
layouts, collections, the people roster), and leaves notes and Blender
files out. `build/` is ignored by git.

## Checking a build without Windows

The exported `.pck` runs in the macOS / Linux editor binary, which shows
whether everything the game reads made it into the package:

```bash
DEVAGENT_PORT=24691 godot --headless --main-pack build/windows/CityInvaders.pck -- --devagent
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
DEVAGENT_PORT=24691 tools/devagent/devagent.py errors
```

## Notes

- The build is not code-signed: Windows SmartScreen asks for confirmation the
  first time ("More info", then "Run anyway").
- The DevAgent stays off in a release unless the game is started with
  `-- --devagent`.
