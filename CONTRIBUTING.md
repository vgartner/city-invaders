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

- **A new city or neighbourhood**: `tools/map/new_city.py "Place, District"`
  (or *Studio > Import a new city*) builds it and lists it in
  `godot/city/maps.json`; keep each phase around 400 x 400 m. Step by step,
  including the Mapillary token for the facade photos:
  [AGENTS.md, "Importing a new city"](AGENTS.md#importing-a-new-city).
- **New phases and campaigns**: a city's phases run eastwards, each one's
  exit leading into the next (`--phases N`); goals per phase in its menu entry.
- **Gameplay and mechanics**: weapons and items are data
  ([docs/ENTITIES.md](docs/ENTITIES.md)); robots, vehicles and the player are
  scripts ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). Describe the idea in
  an issue first if it changes how the game plays.
- **A mod** (no code, no pull request): change a map with the in-game editor
  (F2) and share it from *File > Share these edits as a mod*; it is reviewed
  on the server and then everyone can install it from *Mods*. A good mod can
  also come into the repository as a pull request of its
  `maps/<map>/user/` edits. See [docs/MODDING.md](docs/MODDING.md).
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

## Sending a pull request

1. Fork the repository on GitHub and clone your fork (with Git LFS installed).
2. Make a branch for one topic: `git checkout -b my-city-pelotas`.
3. Change, then **test in the game** - for an AI agent, the loop in
   [AGENTS.md](AGENTS.md); for a map, also a few minutes of the autoplay bot
   and its report.
4. Commit with an English message that says what and why; update the docs
   the change touches in the same commit. Use the email of your GitHub
   account (`git config --local user.email`), and leave AI co-author trailers
   or signatures out: commits carry only your GitHub identity.
5. Push the branch to your fork and open a pull request: what it does, how
   you tested it, screenshots for anything visible. Credit every photo and
   model you used.
6. We review it, may ask for changes, and merge it once it is ready.

### Large files and Git LFS

Models, textures, sounds and some map data go through Git LFS to the
project's own server, which anyone can read but only maintainers can write.
A pull request from a fork therefore carries **text files only**:

- **A new city**: commit its sources - `maps/<map>/build.json`, `data/osm.json`,
  `data/terrain.json`, the `facades/*.json` and `mapillary/` listings,
  `user/*.json` and `facades/commons_credits.txt` - and the `godot/city/maps.json`
  entry, but not the generated `godot/city/<map>.*` files or images
  (`git add` those paths only). A maintainer rebuilds the map from your
  sources with the same command and adds the generated files.
- **Models, images or sounds**: attach them to the pull request as a zip (or
  a link), with their source and licence; a maintainer adds them. If you
  contribute assets regularly, ask in the pull request for write access to
  the LFS server.

