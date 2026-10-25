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

Swarm combat targets are individual live drones, aimed at their actual centres.
Dead units are excluded; walls and roofs block target visibility.

`autoplay` hands the local player to a bot (`godot/scripts/autoplay.gd`) that
plays the way a person does - through the same keys (`Settings.virtual`) and
by turning the body and head - for a set time, while the F5 recorder runs:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay minutes=10 seed=7
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay_status   # read-only, including after completion
DEVAGENT_PORT=24691 tools/devagent/devagent.py autoplay on=false # stop early
```

Parameters: `minutes` (10), `seed` (7: bot RNG only; world/navigation randomness is not reset), `god`
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
(`road_graph`, in the right-hand lane). `road_path.gd` projects onto street
segments, pursues a point along their arc length, and plans the next edge
before the junction. It prefers continuations over immediate U-turns, brakes
for upcoming curves using their spacing and angle, and uses horizontal heading
so hill pitch cannot create a false steering error. Steering keys account for
the player's wheel smoothing rather than assuming key duty equals wheel angle.
It only joins a car within 4 m of a mapped street; off-street yards need
an explicit drivable connection. `road_join_refused` records skipped cars,
which are excluded for the run. The admission check is repeated on entry in
case a selected vehicle moved. It waits behind vehicles instead of blindly changing lanes; after 12 seconds
blocked it logs `traffic_blocked`, leaves that car and continues on foot.
Wall recovery still backs out and pulls forward when there is no room behind.

When it can't get on, it says where: no progress for 1.5 s logs a `stuck`
event with what is in front of it, and it steps aside, then gives the goal up,
then searches for a walkable point where the player's full capsule is free
of world, vehicle and pedestrian collisions. The last-resort hop is logged as
`nav_recovery` (or `recovery_blocked` if no safe point is found within 8 m).
This is test-bot recovery, not a change to manual player movement. Check these
events before treating a run as uninterrupted walking. A failed shop is skipped
by position for that run; shop markers share the main node, so a node-id
blacklist cannot distinguish them. Selecting a new goal does not clear stuck
attempts: only actual progress does. Once movement resumes, the activity tag
returns from `stuck` to its current task. Also `unreachable` (no navmesh path),
`slow_goal` (far longer than the path says), `pickup_not_taken` (stood on it,
still there), `car_stuck` (a car that doesn't move: backs out, gives up after
three, and that car is not taken again), `traffic_blocked` (waited 12 s for
traffic), and `fell` (below the ground).

Run/status JSON also includes `driving`: simulation seconds in the road
controller (including stops), maximum horizontal distance from its planned lane,
seconds more than 3 m from that lane, planned edge count, and rejected joins. These measure the
OSM lane route, not visible asphalt boundaries. A short interrupted drive must
not be reported as a completed long route. Regression fixture:
`godot --headless --path godot ../tools/bench/test_road_path.tscn`.

Semi-automatic weapons release and press the trigger between shots, including
following a reload. `counts.shots` counts observed ammunition consumption.
If one target takes no damage for 15 seconds, `combat_stalled` records its
name, weapon, ammunition, health, shots and time without damage; the bot
skips it for 30 seconds and resumes other goals. The timer resets when the
target changes or its health changes.

At the end it writes `user://devagent/autoplay/run_<time>_<pid>_<start_us>.json` (the counts,
the events, the script errors, the recording's path and test conditions) and an inbox message.
`tools/bench/autoplay_report.py` reads the latest run: the frame time per
activity, a heatmap of the fps in 50 m cells (`--cell`), the slowest cells
with what was drawn there, the worst frames, and the map problems grouped by
place with a teleport line for each. New runs also save seed, requested duration,
god/armed settings, drive interval, window/viewport sizes, render scale,
frame cap and VSync mode. The report separates a final position hold of at
least 15 seconds (within 0.6 m), so prolonged combat does not silently pass
as map exploration. A hold can be intentional; check damage and shot progress.
Run it with the player's own game closed.

For a portable measured run against an already running, isolated DevAgent game:

```bash
python3 tools/bench/autoplay_bench.py --port 24691 --minutes 3 --seed 7 --output /tmp/ci-bench-new
python3 tools/bench/autoplay_report.py /tmp/ci-bench-new/run.json
```

The output directory must be new. The runner polls `autoplay_status`, verifies
its run ID, samples the OS process once a second, and copies the run and
recording into the bundle. It does not launch/quit the game and refuses to
replace another active autoplay. On failure it stops only its own still-active
run. Do not poll bare `autoplay`: that command starts a new bot after the old
one finishes. Status queries return scalar summaries, never live Node objects.
Run/recording names include a process ID and monotonic timestamp, so rapid
stop/start tests cannot overwrite each other. Durations must be finite/positive.

New run diagnostics include observed horizontal distance on foot and in a
vehicle (not chase-camera motion), visited 50 m cells, stationary/combat time,
activity/weapon time, simulation and wall time, and finish reason. Explicit bot
recovery hops and discontinuities are excluded from travelled distance and
reported separately. Coverage cells are observed occupancy, not proof that
every street or action was tested. The report lists unexercised tracked actions.
Shots count consumed ammunition; reloads count completed magazine increases;
drives require observed, valid driver ownership; grenades count consumed
inventory and respect normal cooldowns. Drive/grenade attempts are separate.
Other legacy counters (pickups, rescues and trades) are not all strict success
confirmations. Wrecks are skipped; a stale/unowned vehicle association logs
`vehicle_invalid`, detaches the test player and resumes navigation.

F5 adds approximately 1 Hz engine telemetry: CPU render time, GPU timing when
available, allocator/texture/buffer counters, orphan nodes, effect-node
populations, render scale and ambient scale. Effect nodes are tracked by
instance ID on tree entry/removal; counts are neither awake rigid bodies nor
active/visible effects. A zero GPU timestamp is saved as unavailable, not idle.
The native visual profiler also returned only zero GPU times on the M3 Max
Metal run; GPU bottlenecks therefore remain unmeasured here. Row-collector
self-cost excludes node hooks, bot logic, host sampling and final serialization.

The macOS host sampler uses `proc_pid_rusage` v2: physical footprint, RSS,
page-ins and disk I/O. Other platforms/errors are explicitly unsupported.
Do not add memory counters together or equate page-ins with swap activity;
texture counters can disagree with resource inventory on Metal. One-second
samples correlate with stalls but cannot assign a specific function's cost.
A changed ambient/render scale or world population prevents a clean FPS A/B.
Renderer fence errors and tester Expression errors remain in separate arrays,
instead of being silently discarded or labelled gameplay script failures.

Concurrent headless tests must use their own `--log-file /tmp/unique-test.log`:
the default user-data log is shared with the rendered game and can be rotated
by another instance, invalidating its error audit. DevAgent eval probes should
return only scalars, not Nodes/Resources that expand into large object graphs.

Report regression checks: `python3 -m unittest discover -s tools/bench -p test_autoplay_report.py`.
For the trigger regression, isolate a durable stationary enemy in a solo
DevAgent round, give the bot only a shotgun with reserve ammunition, and
check that more than two rounds are consumed and enemy health falls across
a reload. Then deliberately hold the player's fire cooldown above zero;
within 15 seconds without damage, `combat_stalled` must be logged and the
bot must resume another goal. Use an isolated test round, not a player's save.

Verification on 2026-10-24: the isolated shotgun scenario consumed 10 rounds
in 12 seconds across reloads and reduced target health; a forced no-fire
scenario logged `combat_stalled` after 15 seconds without damage and resumed
pickup movement. A subsequent five-minute Gasometro run completed with
44 rounds consumed, 8 robots down, 4 pickups, 2 drives and no script errors.
The previous prolonged combat hold did not recur. Navigation events and
frame hitches still occurred; the different route is not an FPS A/B test.

## Native function profiling and hitch correlation

F5 now enables the node-add history automatically, including deep PackedScene
roots such as weapon view models. Every recorded row includes `engine_frame`
and `tick_us`, plus cumulative pipeline compilation counters. Hitch records
also retain recent RPC method names and start/end timestamps: arming a test,
a screenshot or a large evaluation must not silently be blamed on gameplay.
The first interval preceding record start is skipped. Raw hitch history can
still include setup intervals: use the row window and command tags to select
the actual measured portion.

`perf` also reports engine-tracked static, texture and buffer allocation MiB,
and pipeline counts. These are not resident OS memory measurements; on unified
memory hardware they must not be added to the process footprint as separate
RAM allocations. GPU milliseconds may still be unavailable on Metal.

For function timings, use the engine's native debugger channel, not sampled
`Performance` monitors. In a separate terminal at the repository root:

```bash
godot --headless --script "$PWD/tools/devagent/profiler_capture.gd" -- --port=6008 --output=/tmp/ci-profile.jsonl --control=/tmp/ci-profile.control
```

Start **one** test game with `DEVAGENT_PORT=24691 godot --path godot
--remote-debug tcp://127.0.0.1:6008 --ignore-error-breaks -- --devagent`.
After loading, write `start label` to `/tmp/ci-profile.control`; wait about
half a second before the measured action. Write `stop label` afterwards.
`memory` requests the native rendering resource inventory. The capture helper
allows 64 MiB incoming packets: the default 64 KiB buffer cannot receive the
full city inventory. `visual_start`
and `visual_stop` control the renderer profiler where supported. `quit`
ends the capture helper. The listener is loopback-only and rejects object
instantiation when decoding Variants. Runtime debugger breaks are continued
and their errors remain in the capture/console.

Read it with `python3 tools/devagent/profile_report.py /tmp/ci-profile.jsonl`.
`--label 'start label'` selects one capture and `--json /tmp/decoded.json`
saves decoded frames. Function signature IDs restart on each capture;
server/native-call and callback timings can overlap, so don't sum them as
independent CPU costs. Correlate with F5's `engine_frame`, checking adjacent
frames because the two hooks run at different points in the engine loop.
The native frame payload parser targets the five-field Godot 4.7 layout and
fails rather than guessing when it does not match. Capturing is optional;
normal/release games do not open a debugger connection or run this helper.
Do not hot-reload the DevAgent while its own RPC handler is executing;
restart the isolated test process after instrumentation changes.

Regression tests: `python3 -m unittest discover -s tools/devagent -p test_profile_report.py`.

## A second instance for tests

To test without touching the game someone is playing (for example a paused
design session), start a headless instance on another port:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py launch headless
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=gasometro
```

AI and physics run as usual; screenshots need a window.
