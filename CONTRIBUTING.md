# Contributing to City Invaders

Thanks for helping! New maps of real cities, models, gameplay and fixes are
all welcome.

## Getting started

1. Install [Godot 4.7](https://godotengine.org), [Git LFS](https://git-lfs.com) and Python 3.12+,
   then clone (the maps, models and sounds come through Git LFS) and import once:
   `cd godot && godot --headless --path . --import`.
2. `./run-godot.sh` (starts the game with the DevAgent enabled).
3. Working with an AI agent (Codex, Claude Code, Cursor...)? Point it at
   [AGENTS.md](AGENTS.md); setup per tool is in [docs/AGENTS.md](docs/AGENTS.md).

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first; it maps the scripts.

## What to contribute

- **A new city or neighbourhood**: a `maps/<map>/build.json`, the data
  download steps you used, and an entry in `MAPS` (`godot/scripts/main.gd`).
  Keep maps around 400 x 400 m.
- **Facade photos and building heights**: your own photos only (or freely
  licensed ones), through `tools/map/building_photo.py`; they live in
  `maps/<map>/user/`.
- **Models**: follow [docs/ASSETS.md](docs/ASSETS.md) (glTF, metres, +Y up,
  front -Z, the shared pedestrian rig, wheel and light node names), and add
  the source and licence to `godot/assets/CREDITS.md`. Prefer a reproducible
  Blender script in `tools/blender/` for procedural models.
- **Landmarks and interiors**: a model on a building's OSM footprint, see
  "Landmarks and interiors" in ARCHITECTURE.md.

## Rules

- No material you have no right to use: no Google Maps / Street View
  images, no commercial game assets. Local brands that are part of the
  region's life are welcome (see "Brands and trademarks" in
  [docs/LICENSING.md](docs/LICENSING.md)); credit their source.
- Contributions are licensed GPL v3 (code) and CC BY-SA 4.0 (assets).
- Everything in the repository is written in **English**: code, comments,
  commit messages, documentation.
- Match the surrounding code: GDScript with static types where the parser
  can't infer them, short comments that say why.
- Test what you change in the game; the DevAgent ([docs/DEVAGENT.md](docs/DEVAGENT.md))
  can drive it from a script (`hold_keys`, `audit_ground`, `errors`).
- One topic per pull request, with a short description and, for visual
  changes, a screenshot.
