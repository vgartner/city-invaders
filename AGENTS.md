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
