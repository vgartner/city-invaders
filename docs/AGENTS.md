# Working with AI agents

Much of City Invaders is built with AI agents - Claude Code and Codex so far,
and any other agent is welcome. This page is the detail behind the root
[AGENTS.md](../AGENTS.md), which every agent should read first: setup per
tool, who does what, recipes, and habits that keep agents cheap.

## Setting up your agent

The instructions are written once, in `AGENTS.md`, and each tool is pointed
at them. The DevAgent works for every agent from the command line
(`tools/devagent/devagent.py`); an agent that speaks MCP can also get it as
tools (`tools/devagent/devagent_mcp.py`, stdio).

| Agent | Instructions | DevAgent as MCP tools |
|---|---|---|
| Codex (CLI, IDE, app) | reads `AGENTS.md` by itself | in `~/.codex/config.toml`: `[mcp_servers.city-invaders-devagent]`, `command = "<repo>/tools/.venv/bin/python"`, `args = ["<repo>/tools/devagent/devagent_mcp.py"]` (absolute paths) |
| Claude Code | `CLAUDE.md`, which imports `AGENTS.md` | `.mcp.json` in the repository (approve it once) |
| Cursor | reads `AGENTS.md` | `.cursor/mcp.json` with the same content as `.mcp.json` |
| Gemini CLI | `.gemini/settings.json`: `"contextFileName": "AGENTS.md"` | the same file: `"mcpServers"` as in `.mcp.json` |
| GitHub Copilot, others | `AGENTS.md` where supported, else paste its link | the CLI is enough |

Tool settings change between versions; check your agent's documentation if
a key above has moved. Per-user settings (`~/.codex/`, `~/.claude/`, a
personal `.cursor/`) stay out of the repository.

## Who does what

| Who | Role |
|---|---|
| Coding agents (Codex, Claude Code, ...) | game code, map pipeline, procedural models, tools, tests through the DevAgent, docs |
| Asset agents (e.g. ChatGPT with Blender) | character, vehicle and prop packs as `.glb` zips following [ASSETS.md](ASSETS.md); a coding agent checks and integrates them |
| The owner | plays the game, points at problems with F1, decides what ships; the only one who deploys the online services |

Several agents can work at once - each in its own worktree with its own test
port (rules in [AGENTS.md](../AGENTS.md#working-next-to-other-agents-and-people)).
Several can run Blender at once too; asset agents deliver zips to their own
output folder and never write into the repository; a coding agent never
edits another agent's `.blend` in place (it copies first); integrated packs
keep their originals until the owner deletes them.

## The loop a coding agent follows

1. **Understand** the request, read the relevant docs and code.
2. **Change** the code, or generate the asset with a script.
3. **Verify in the game** (AGENTS.md, "Testing in the game"): parse check,
   your own test instance on port 24691, real input, numbers first, then a
   small screenshot; `autoplay` for anything that affects a whole round.
4. **Commit** one topic at a time, English message, docs in the same commit.
5. **Report** what was done, what was tested and how, and what was not.

## Recipes

- **Play and look**: `DEVAGENT_PORT=24691 $P tools/devagent/devagent.py launch`,
  `start_solo map=gasometro`, `teleport x=.. y=.. z=.. yaw=..`,
  `screenshot width=800 hud=false`, `quit`.
- **Can a player get there?** `nav_probe points=[[x,y,z]]` (or
  `landmark_pickups=true`): metres to the walkable mesh and to the end of a
  path from the start.
- **A long unattended check**: `autoplay minutes=20` on the test instance,
  then `$P tools/bench/autoplay_report.py` - what the bot did, fps per 50 m
  cell, hitches, places where it got stuck, script errors.
- **Driving only**: `autoplay minutes=5 drive_every=3`.
- **A new city**: the step-by-step recipe in [AGENTS.md](../AGENTS.md#importing-a-new-city)
  (the place and size from the person, their Mapillary token, `new_city.py`,
  checks in the game, credits, commit).
- **A map change**: edit `tools/map/` or `maps/<map>/`, then
  `$P tools/map/building_photo.py rebuild <map>` and
  `godot --headless --path godot --import`; commit the regenerated
  `godot/city/<map>.*` files with the change.
- **The player says "this is slow"**: F5 leaves a recording;
  `$P tools/devagent/perf_report.py <perf_log>`.

## Showing the agent something in the game

- Press **F2** (design mode): the world freezes and you fly.
- **Click** an object: it is painted yellow (buildings and streets get a yellow box) and named on screen; the
  agent reads it with the DevAgent `selection` tool (for a building: OSM id,
  name, wall, height).
- Or aim at it: `pick_building` names the building under the crosshair.

## Costs

Agents spend tokens. Good habits that keep them cheap:

- small, cropped, downscaled screenshots; text checks (`eval`, `audit_ground`) before images
- batch related edits, test them together
- avoid re-reading large files; search for the lines needed
- stop and report before a long, open-ended task

## Asking for assets: a prompt template

> Produce glTF 2.0 binary (.glb), metres, +Y up, front -Z, origin on the
> ground at the centre, embedded PBR textures (base colour, normal,
> metallic/roughness, emissive where needed), no lights / cameras / ground.
> Humans: exactly the 52 `mixamorig:` bones of the City Invaders pedestrians,
> legs at hip width, arms ~10 degrees from the body, in-place clips
> (idle, walk, sprint, die), looping ones closed. Vehicles: wheels as nodes
> `wheel_fl/fr/rl/rr` turning about local X, `lights_front` / `lights_rear`
> emissive. Include previews and a README with sources and licences.
