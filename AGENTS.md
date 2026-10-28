# AGENTS.md

Instructions for AI coding agents - Codex, Claude Code, Cursor, Gemini CLI,
Copilot or any other - and for the people driving them. Everything here is
tool-neutral; how to set up each agent (its context file, the DevAgent as MCP
tools) is in [docs/AGENTS.md](docs/AGENTS.md#setting-up-your-agent).

City Invaders is a co-op first-person shooter in the real streets of Porto
Alegre, made with Godot 4.7: maps generated from OpenStreetMap and open
photos, GDScript game code, a Python map pipeline and Blender scripts for the
models. The game has a built-in remote control, the **DevAgent**, so an agent
can play it, look at it and test its own changes.

## Setting up the repository

```bash
git lfs install                      # models, textures, sounds and maps come through Git LFS
git clone https://github.com/vgartner/city-invaders.git && cd city-invaders
cd godot && godot --headless --path . --import && cd ..     # once, a few minutes
python3 -m venv tools/.venv && tools/.venv/bin/pip install numpy shapely trimesh pillow scipy requests duckdb
./run-godot.sh                       # the game, with the DevAgent on port 24690
```

Godot 4.7 must be on the PATH as `godot`. All tools run from the repository
root with `tools/.venv/bin/python` (the examples below write it as `$P`).

## Rules

- **English** in everything that goes into the repository: code, comments,
  commit messages, documentation.
- **Docs move with the code**: a change to gameplay, scripts, the map
  pipeline, assets or tools updates its document in the same commit (see the
  index below). The docs are how the next person - or agent - learns the
  project; nothing important may live only in a chat or an agent's memory.
- **One topic per commit**, with a message that says what changed and why.
- **Commits and pull requests carry only the contributor's GitHub identity.**
  No `Co-Authored-By:` trailers for an AI agent, no "Generated with ..."
  lines or AI signatures in commit messages, pull request descriptions or
  code comments - even if your agent's defaults add them. The README already
  says the project is built with AI help. Commit with the email of the
  person's GitHub account (`git config --local user.email ...` in this
  repository), so GitHub credits the right account.
- **GDScript warnings are errors** in this project: give a variable a type
  where the parser can't infer it (`var x: Vector3 = ...` from a Variant).
- **No material you have no right to use**: no Google Maps / Street View
  imagery (looking things up is fine, copying is not), no commercial game
  assets. Credit every asset in `godot/assets/CREDITS.md`
  ([docs/LICENSING.md](docs/LICENSING.md)).
- Models are reproducible: a script in `tools/blender/` or `tools/assets/`,
  not a hand-only edit of a `.blend`.
- Don't delete data or assets you didn't create; move them aside and say so.
- Ask before downloading third-party files; unpack them in a scratch folder
  and don't run code from them.

## Working next to other agents and people

Several agents (and the owner, playing) often work on this repository at
the same time. Two agents editing the same folder, or two test games on the
same port, break each other's work.

- **One agent per working tree.** For parallel work make a git worktree:
  `git worktree add ../city-invaders-<topic> -b <topic>`. A worktree needs its
  own `godot --headless --path godot --import` the first time.
- **Before starting**: `git status` (someone else's uncommitted changes are
  not yours to commit or revert) and `pgrep -fl godot` (a game already
  running on your test port belongs to someone else).
- **Commit only your own files** - `git add <paths>`, not `git add -A`.
  `maps/*/user/` holds the owner's edits from the in-game map editor.
- Pull/rebase before you push; the history on `main` is linear.

## Testing in the game

Compiling is not testing: run the change in the game.

For gameplay recording requests, read [tools/video/README.md](tools/video/README.md)
first: it records the approved movement, encounter, interaction and delivery rules.

1. Parse check: `godot --headless --path godot --quit` - no `SCRIPT ERROR` / `Parse Error`.
2. Your own test game, never the player's:

   | Port | Game |
   |---|---|
   | 24690 | the player's game, started by `./run-godot.sh` - read it (`get_state`, `screenshot`, `inbox`), answer with `say`; never `start_solo`, `teleport` or `quit` it |
   | 24691 | your test instance: `DEVAGENT_PORT=24691 $P tools/devagent/devagent.py launch`, then `start_solo map=gasometro`, drive it, `quit` when done |

3. Drive it through the DevAgent ([docs/DEVAGENT.md](docs/DEVAGENT.md)):
   `hold_keys` (real input), `teleport`, `screenshot width=800 hud=false`,
   `eval`, `audit_ground`, `nav_probe`, `errors`. Check numbers, then look at
   a small screenshot.
4. A longer check: the **autoplay** bot plays by itself for N minutes and
   reports what it did, the frame rate per area and the map problems it ran
   into: `devagent.py autoplay minutes=10`, then `$P tools/bench/autoplay_report.py`.
5. `errors` must be empty at the end.

## Importing a new city

Any place with OpenStreetMap data becomes a playable city in one command.
Details: [docs/MAP_PIPELINE.md](docs/MAP_PIPELINE.md).

1. **Ask the person** which place (a town, or "City, District"), how big
   (each phase is a square map, 400 m is the norm - larger gets heavy) and
   how many phases.
2. **Street photos (Mapillary)** - the facades are textured with Mapillary's
   free street-level photos. That needs the person's own access token: they
   create a free account at mapillary.com, register an application under
   *Dashboard > Developers*, and put its client token in the repository
   root's `.env` (git-ignored) as `MAPILLARY_TOKEN="MLY|..."` (quoted). An
   agent doesn't create the account and never prints or commits the token.
   Without it, run with `--no-photos`: the buildings get generated facades.
3. **Run**: `$P tools/map/new_city.py "Pelotas, Centro" --name pelotas --size 400 --phases 2`.
   It geocodes the place (Nominatim), downloads OpenStreetMap, the Overture
   footprints OSM lacks, the terrain (Copernicus) and the Mapillary listing,
   builds the facades and one map per phase, imports them into Godot, lists
   them in `godot/city/maps.json` (the menu reads it) and runs the street
   audit. `--clean` paints people and cars out of the photos (needs the ML
   environment, see MAP_PIPELINE). Behind a TLS-inspecting proxy set
   `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` first. The same import runs from
   the game: *Studio > Import a new city*.
4. **Check it in the game** (your test instance, port 24691):
   `start_solo map=<id>`, screenshots of the streets and landmarks,
   `audit_ground`, `nav_probe landmark_pickups=true` (every fixed item
   reachable), `autoplay minutes=5` and `tools/bench/autoplay_report.py`
   (where the bot got stuck, unreachable spots, frame rate per area),
   `maps/<map>/out/street_audit.json`, and `errors` empty. Report what looks
   wrong (buildings in the street, floating props, dead ends) - many are
   fixed in `maps/<map>/user/` or by the map editor (F2).
5. **Images**: only Mapillary, Wikimedia Commons or the person's own photos
   - never Google Maps / Street View. Commons photos are credited in
   `maps/<map>/facades/commons_credits.txt`, made by the import; keep it.
6. **Commit only if the person wants the city in the repository** (a city
   is ~100 MB or more through Git LFS): `git add maps/<map>/ godot/city/<map>*
   godot/city/maps.json` - `.gitignore` already keeps the photo downloads
   and build caches out. Add a line to the README's maps table if it ships
   with the game. Working from a fork (no write access to the LFS server)?
   Commit the text sources only and let a maintainer add the generated
   files - see CONTRIBUTING.md, "Large files and Git LFS".

## Talking with the player in the game

With the game running, the player presses **F1** to write to the AI agent
(with their position, view, screenshot and design-mode selection), **F5** to
record performance. To work this way:

- keep one `$P tools/devagent/devagent_wait.py --timeout 28800` running in the
  background - it returns with the message when F1 is pressed;
- answer at once on the player's screen (`devagent.py say text="..."`), do the
  work, answer again, start the waiter again;
- an F1 message carries `view.screenshot`: look at it before guessing where
  the player is looking; an F5 message carries `perf_log`:
  `$P tools/devagent/perf_report.py <perf_log>`;
- after a change the player should see: say you are restarting, `devagent.py quit`
  (port 24690), start `./run-godot.sh` again, wait for `get_state` to answer,
  say what changed. Tuning values can often go live instead (`tune`, `move`, `reload`).

## Measuring performance

Numbers are only comparable under the same conditions
([docs/PERFORMANCE.md](docs/PERFORMANCE.md)): the player's game closed, one
game instance, its window visible and the same size (a covered window stops
drawing; the reports mark such runs INVALID), the same map and seed. Don't
trust a run on a machine that is swapping.

## Where things are

| Path | What |
|---|---|
| `README.md`, `CONTRIBUTING.md` | the project, quick start, how to contribute |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the game is built: scripts, scenes, networking, collision layers, landmark markers - read first |
| [docs/GAMEPLAY.md](docs/GAMEPLAY.md) | controls, weapons, pickups, robots, score |
| [docs/ENTITIES.md](docs/ENTITIES.md) | entity definitions (`*.def.json`): weapons, items, robots |
| [docs/MAP_PIPELINE.md](docs/MAP_PIPELINE.md) | OSM + photos + terrain to a playable map; rebuilding one |
| [docs/ASSETS.md](docs/ASSETS.md) | model conventions, rigs, the Blender scripts, asking for assets |
| [docs/DEVAGENT.md](docs/DEVAGENT.md) | the DevAgent: every method, F1/F2/F3/F5, autoplay |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | frame budget, how to measure, past findings |
| [docs/ONLINE.md](docs/ONLINE.md), `server/README.md` | the online services (API, the Bah assistant, Git LFS server) |
| [docs/AGENTS.md](docs/AGENTS.md) | agent setup per tool, roles, recipes, cost habits |
| [docs/BUILDING.md](docs/BUILDING.md), [docs/LICENSING.md](docs/LICENSING.md), [docs/ROADMAP.md](docs/ROADMAP.md), [docs/MODDING.md](docs/MODDING.md) | releases, licences, plans, mods |
| `godot/scripts/` | game code; `main.gd` (rounds, the city, spawners), `player.gd`, `enemy.gd`, `car.gd`, `civilian.gd`, `dev_agent.gd` (the DevAgent), `autoplay.gd` (the bot) |
| `godot/assets/` | models, textures, sounds, entity definitions |
| `godot/city/` | generated maps (`<map>.glb` + json), rebuilt by the pipeline - don't edit by hand |
| `maps/<map>/` | each map's sources: `build.json`, OSM data, photos, `user/` edits |
| `tools/map/` | the map pipeline (`osm2gltf.py`, `building_photo.py rebuild <map>`) |
| `tools/devagent/` | DevAgent CLI (`devagent.py`), MCP server (`devagent_mcp.py`), F1 waiter, reports |
| `tools/bench/` | benchmarks and the autoplay report |
| `tools/blender/`, `tools/assets/` | scripts that make and fix models and sounds |
| `server/` | the online API and its deploy scripts (owner only) |
| `AGENTS.md` (this file), `CLAUDE.md`, `.mcp.json` | agent instructions; `CLAUDE.md` only imports this file for Claude Code |
