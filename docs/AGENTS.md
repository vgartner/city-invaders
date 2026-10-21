# Working with AI agents

Much of City Invaders is built with AI agents. This page explains how they
work on the project, so contributors can use them the same way, and so the
agents themselves have a starting point. (`AGENTS.md` at the repository root
points here.)

## Who does what

| Agent | Role | How it works |
|---|---|---|
| Claude Code (coding agent) | game code, map pipeline, procedural models, tests | edits the repository, runs Blender and the map tools from the command line, plays the game through the DevAgent |
| Asset agents (e.g. ChatGPT / Codex with Blender) | character, vehicle and prop packs | deliver `.glb` packs (zip) following [ASSETS.md](ASSETS.md); the coding agent checks and integrates them |

Several agents can use Blender at the same time: each run is its own
process. Rules that keep them out of each other's way:

- asset agents deliver zips to their own output folder; they don't write into the repository
- the coding agent never edits another agent's `.blend` in place; it copies first
- integrated packs keep their originals (zip or folder) until the owner deletes them

## The loop the coding agent follows

1. **Understand** the request, read the relevant docs and code.
2. **Change** the code or generate the asset with a script (models are
   reproducible: `tools/blender/*.py`, never hand-only edits).
3. **Verify in the game**, not only by compiling:
   - `godot --headless --path godot --quit` must show no parse errors
   - start the game with the DevAgent (`./run-godot.sh`), drive it with
     `tools/devagent/devagent.py` / the MCP tools: `start_solo`, `hold_keys` (real
     input), `screenshot` (cropped, without HUD), `audit_ground`, `errors`
   - check numbers (health, distances, scores) and look at screenshots
4. **Commit** one topic at a time, English message, and update the docs in
   the same commit ([ARCHITECTURE](ARCHITECTURE.md), [GAMEPLAY](GAMEPLAY.md),
   [ASSETS](ASSETS.md), [MAP_PIPELINE](MAP_PIPELINE.md), CREDITS).
5. **Report** what was done, what was tested and how, and what was not.

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
