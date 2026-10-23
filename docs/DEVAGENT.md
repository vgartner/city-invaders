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

Every F1 message also carries `view`, taken the moment F1 is pressed: the
camera's position, its heading on the compass (`heading_deg`, 0 = north =
-Z, 90 = east = +X; `compass` N/NE/E...), its pitch, what the crosshair is on
(`aim`: distance, point, and a robot, person, vehicle, landmark or generated
building with its OSM id and link) and a picture of the screen
(`screenshot`, a 1280 px JPEG in `user://devagent/f1/`).

## Developer keys

Only with the DevAgent on (a player's game has none of them):

| Key | |
|---|---|
| F1 | message to the assistant (above) |
| F2 | design mode |
| F3 | god mode on / off: no damage |
| F5 | performance recording on / off |

**F5** records every frame until pressed again: frame time, script and
physics time, draw calls, objects and triangles drawn, people, robots and
vehicles, where the player is and looks, and every hitch (over 60 ms) with
what had just come into the scene. The file goes to
`user://devagent/perf/rec_<time>.json` and a message to the F1 channel says
where, with a summary - press it when the game feels slow, and the moment is
kept for later. `tools/devagent/perf_report.py [file]` (the latest by
default) prints the summary, a 2 s timeline and the worst frames.

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

## Autoplay: a bot that plays

`autoplay` hands the local player to a bot (`godot/scripts/autoplay.gd`) that
plays the way a person does - through the same keys (`Settings.virtual`) and
by turning the body and head - for a set time, while the F5 recorder runs:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay minutes=10 seed=7
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay          # what it is doing now
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay on=false # stop early
```

Parameters: `minutes` (10), `seed` (7: the same choices each run), `god`
(true: it doesn't die), `armed` (true: pistol, machine gun, two of each grenade),
`drive_every` (70: seconds between drives; `drive_every=3` for a driving test).

What it does, in this order: fights any robot in sight within 45 m (picks the
weapon for the target and the range; throws a Bergamota at a group or a mech
and a Porongo at drones, 9-20 m away), goes for healing when hurt, frees the
people in a container within 120 m, trades at a shop when it has the parts,
takes a car now and then (drives to a far point and gets out), picks up what
it can take, or runs to a random far point. It runs, turns on the spot for a
sharp turn and walks the last metres to a goal. A robot it has shot at for 5 s
without a hit, it goes in close to. It drives along the traffic's streets
(`road_graph`, in the right-hand lane, a random turn at each crossing), slows
for the corners, waits behind a vehicle in front and passes it in the other
lane when it stands still (a bus at its stop), backs out of a wall turning
round and pulls forward when there is no room behind.

When it can't get on, it says where: no progress for 1.5 s logs a `stuck`
event with what is in front of it, and it steps aside, then gives the goal up,
then hops onto the nearest walkable point. Also `unreachable` (no navmesh path),
`slow_goal` (far longer than the path says), `pickup_not_taken` (stood on it,
still there), `car_stuck` (a car that doesn't move: backs out, gives up after
three, and that car is not taken again) and `fell` (below the ground).

At the end it writes `user://devagent/autoplay/run_<time>.json` (the counts,
the events, the script errors, the recording's path) and an inbox message.
`tools/bench/autoplay_report.py` reads the latest run: the frame time per
activity, a heatmap of the fps in 50 m cells (`--cell`), the slowest cells
with what was drawn there, the worst frames, and the map problems grouped by
place with a teleport line for each. Run it with the player's own game closed.

## A second instance for tests

To test without touching the game someone is playing (for example a paused
design session), start a headless instance on another port:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py launch headless
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
```

AI and physics run as usual; screenshots need a window.
