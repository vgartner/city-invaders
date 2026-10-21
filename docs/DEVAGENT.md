# DevAgent: driving the game from scripts and AI assistants

`godot/scripts/dev_agent.gd` is an autoload. When the game runs with
`-- --devagent` (`./run-godot.sh` adds it) it listens on 127.0.0.1:24690 for
line-delimited JSON-RPC: `{"id": 1, "method": "teleport", "params": {...}}`.

Clients:

- `tools/devagent/devagent.py` – Python library and CLI
  (`tools/.venv/bin/python tools/devagent/devagent.py launch`, `... start_solo map=poa`, `... teleport x=108 z=4`)
- `tools/devagent/devagent_mcp.py` – an MCP server (registered in `.mcp.json` as
  `city-invaders-devagent`) so an AI assistant can play-test

## Methods

| Method | Use |
|---|---|
| `start_solo map=<id>` | start a solo round |
| `perf` | frame cost: FPS, ms per frame (process, physics, navigation), draw calls, agents |
| `get_state` | players, robots, director, fps, design mode |
| `teleport x y z yaw`, `look_at x y z` | move / aim the player camera |
| `screenshot width crop=[x0,y0,x1,y1] hud=false` | a frame, cropped (fractions) and scaled; unique file names |
| `design enabled` | design mode: freeze the world, fly the camera |
| `aim` | what the crosshair is on |
| `mark from to base top` / `clear` | outline a wall (used by `pick_building`) |
| `hold_keys actions seconds` | hold game actions (`forward`, `right`, `jump`, ...) through the real input path |
| `tap action` | press an action once (`use`, `reload`, `weapon_3`, `design`) |
| `audit_ground tolerance` | vehicles, pedestrians, robots standing off the street (sunk or floating) |
| `errors limit` | latest script errors from the game log |
| `inspect id` | an NPC's AI state, goal, navigation and automatic diagnoses |
| `raycast from to mask` | physics ray |
| `scan_gaps` | see-through slits between buildings |
| `spawn_enemy x y z variant` | a trooper, mech or drone |
| `kill_enemies`, `set_director enabled phase`, `set_god enabled`, `set_sun` | test helpers |
| `say text seconds` | a message to the player, on screen |
| `eval expr` | evaluate a GDScript expression with `main`, `player`, `tree`, `nav`, `map` bound |

## Talking to the assistant from the game

With the DevAgent on, **F1** opens "Message to Claude": Enter sends it (with
the map, your position and what you selected in design mode - all of it
when several objects are selected, as `selections`), Esc closes.
The assistant reads them with `inbox`, or runs
`tools/devagent/devagent_wait.py` in the background, which returns as soon as a
message arrives, and answers on screen with `say`.

## Tracing an object

`tools/devagent/devagent_trace.py C80 --seconds 15` follows one pedestrian, robot or
vehicle (by name, or a node path from the main scene) about 20 times a
second: position, velocity, on the floor, AI state. It writes a CSV
(`--out`) and lists what looks wrong: height jumps, teleports, time off the
floor. Smooth numbers while the model still looks jumpy point at the
animation clip rather than the movement.

## Changing things live (no restart)

- `move name=posto_charrua dx=5 dyaw=15` / `x= z= yaw=` - move or turn an
  object (a landmark or placed model by name, or a vehicle / pedestrian /
  robot / pickup like `V12`, `C50`, `E3`, `P8`), kept on the ground. A
  preview; `save=true` keeps a placed model's new spot in the map's edits.
- `tune` - list the tuning values of `godot/scripts/tune.gd`;
  `tune vehicle_max_roll_deg=4` changes one in the running game. To keep it,
  write the value into tune.gd.
- `eval` - anything else (any node, any variable).
- `reload paths=[res://...]` - see below.

Only script logic changes need a restart.

`reload paths=[res://...]` is a hot reload: after changing a model and
re-importing it (`godot --headless --path godot --import`), it re-reads those
files and rebuilds the map's props, stalls, landmarks and vendors in the
running game - no restart. (Scripts still need a restart.)

`selection` returns what the player clicked in design mode (the last pick;
`all` lists every selected object, with the model and name of placed ones). MCP-only
helpers: `pick_building` (aim + identify the OSM building + outline
it), `design_mode`, `clear_mark`.

## Typical checks

```python
from devagent import DevAgent
d = DevAgent()
d.call("start_solo", map="gasometro")
d.call("hold_keys", actions=["forward"], seconds=2)       # walk
print(d.call("audit_ground"))                              # anything sunk?
print(d.call("errors"))                                    # anything broken?
d.call("screenshot", width=800, hud=False)
```

## A second instance for tests

To test without touching the game someone is playing (for example a paused
design session), start a headless instance on another port:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py launch headless
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
```

AI and physics run as usual; screenshots need a window.
