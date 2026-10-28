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
| `nav_probe points=[[x,y,z],...]`, `nav_probe landmark_pickups=true` | can a player walk there: metres to the nearest walkable (navmesh) point and how far from it a path from the start ends (0 = reachable, -1 = no path) |
| `scan_gaps` | see-through slits between buildings |
| `spawn_enemy x y z variant` | a trooper, mech or drone |
| `kill_enemies`, `set_director enabled phase`, `set_god enabled`, `set_sun` | test helpers |
| `say text seconds` | a message to the player, on screen |
| `eval expr` | evaluate a GDScript expression with `main`, `player`, `tree`, `nav`, `map` bound |

## Talking to the assistant from the game

With the DevAgent on, **F1** opens "Message to the AI assistant": Enter sends it (with
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

Only with the DevAgent on (a player's game has none of them). The game
started this way (`./run-godot.sh`, port 24690) shows them in a "Developer
keys" panel when its first round appears, with an OK button (Enter or Esc
close it too); solo, the round waits while it is open. A test instance on
another port doesn't show it, nor a round a script started (`start_solo`),
and it closes by itself as soon as a script starts driving the game.

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
It only joins a car within 4 m of a mapped street, or one in a car park
with its way out (the map's `out` route, while the car still stands at its
spot): it drives that out (`drive_out` event) and joins the street where the
route ends, in the lane's own direction. `road_join_refused` records skipped cars,
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


## Opt-in frame-stage and pickup diagnostics

`frame_stages(on=true)` creates a temporary timing node. Query `frame_stages()`
for its snapshot; `frame_stages(on=false)` returns the final snapshot and removes
it. No stage callbacks run by default. Samples above 50 ms are bounded to the
latest 400. `matched` verifies process/pre-draw/post-draw frame IDs and timestamp
ordering before publishing intervals. These are CPU signal intervals, **not GPU
execution times**; `after_draw_ms` also includes pacing and physics before the
next process signal. Correlate with F5/native frames, not low-rate averages.

`spawn_pickup(kind="core", x=0, y=1, z=0)` uses the normal gameplay creation path
and returns its node ID, model cache state and CPU `create_ms`. Subsequent drawing
is outside this duration. It changes the world: only use it in an isolated test.
`warm_pickups()` retains all existing pickup scenes in the map cache;
`warm_pickups(on=false)` removes those strong references for a cold-cache control
(live instances can still retain resources). Both are diagnostic mutations;
normal map loading already retains these scenes automatically. Restart the test
game afterwards, and never measure these synchronous setup calls as gameplay.

Cache regression: `godot --headless --path godot ../tools/bench/test_pickup_cache.tscn`.
The fixture limits requests to pickup assets; full threaded map loading is checked
separately in the rendered game.


### Drawability audit for render comparisons

`perf` reports `window_can_draw` and `window_focused`. F5 records drawability
at both ends of every process interval in the `window_can_draw` column;
`frames` and `frame_stages` also report `non_drawable_intervals` and
`render_comparison_valid`. Headless runs are explicitly non-drawable even if
the dummy display server's Window API returns true. Focus alone is not enough:
a covered/minimized macOS window may stop drawing while process frames continue.
These checks qualify a render comparison; they do not measure GPU execution or
prove that every frame was presented.

`autoplay_report.py` marks captures with non-drawable intervals INVALID for
render comparisons and older/partial captures UNVERIFIED. It keeps raw data and
functional coverage instead of silently dropping slow frames. Leave the test
window visible, keep its size fixed and use one game instance. Do not compare
background process FPS with foreground rendering FPS. Changing focus/occlusion
is itself a confound; repeat interrupted runs. The diagnostic never forces
window focus, resizes windows or changes graphics settings on its own.


## Making a gameplay video

Use your isolated test instance (port **24691**). Staging is an explicit,
destructive solo rehearsal: it clears the current robots/ships, disables the
Director and scheduled swarms, relocates the player on the navmesh, supplies
weapons/items and enables god mode. It does not edit maps/assets. Never stage
the owner's live game without their explicit request. The CLI protects port
24690 unless `--allow-player-game` is supplied. It rejects shared rounds and
active autoplay/takes; leave vehicles/editor and unpause first.

```bash
DEVAGENT_PORT=24691 godot --path godot -- --devagent
python3 tools/devagent/stage.py --list
python3 tools/devagent/stage.py usina_walk --take --wait
python3 tools/devagent/stage.py street_battle
python3 tools/devagent/stage.py --drop
python3 tools/devagent/stage.py grenades_swarm
python3 tools/devagent/stage.py drone_lasso
```

Presets live in `godot/data/video_scenes.json`:

- `usina_walk`: pistol, a 14 s walking/look-up take near the Usina, then real Fruki and pala pickups.
- `street_battle`: armed troopers and ammo in the long east-west street. `--drop`
  separately requests a gameplay dropship; its valid landing zone is selected by
  normal game logic, not fixed in the shot. Result 1 = dropship requested, 0 =
  an existing dropship, -1 = no suitable zone.
- `grenades_swarm`: troopers/swarm, Bergamota and Porongo for manual play.
- `drone_lasso`: a flying drone, laço and one spare captured drone for rehearsing
  flight independently of the capture. G flies it; click fires its green ray.

Only `usina_walk` currently has a fully scripted take; the other presets are
manual scene setups for OBS/gameplay recording. Click the window to capture the
mouse before playing manually. Scene preparation is not part of a shot. A
2–8 s simulation-time settle lets the spawn effects finish; enemies remain
active, so manual shots can vary. Pedestrians/traffic and world RNG are not reset.
Scene clear restores Director/swarm timing and temporary movie render/audio
settings, removes tracked stage actors/items and releases movement control;
it cannot undo cleared original robots, combat damage or collected items.
Restart the solo round for a pristine rehearsal.

RPC methods: `stage` (no name lists presets), `stage(name=...)`, `take`,
`take(on=false)`, `take_status`, `stage_clear`, `stage_drop(count=4)`.
CLI `--status`, `--stop` and `--clear` wrap the corresponding methods.

### Smooth movement and offline capture

The take uses engine simulation time, not Python sleeps or network intervals.
It sets an optional analog walking input before the player's ordinary movement
physics: acceleration/deceleration use quintic easing, still passing through
`Step.try_step` / `move_and_slide`, footsteps and collisions. Camera keyframes
use the shortest yaw arc and smooth easing; no position writes or interpolation
resets happen during a take. `scripted_control` defaults off and is released on
finish/cancel. This is a scripted rehearsal, not footage of a human playing.

After a 6 s opening at normal walking speed, `approach` cues walk to the two
staged items using their nav-projected positions. The camera can look independently of the
walking direction. Acceleration and distance-based braking keep approaches
smooth. `speed_mps` is the unboosted pace; Fruki's actual speed bonus remains
active, so the player visibly accelerates after collecting the can (5 m/s
unboosted, 7 m/s boosted, except the eased starts and final braking). No item
is granted by the stage: the ordinary pickup
`body_entered` handler grants it, plays its sound and displays the game's toast.
Setup resets armour/adrenaline eligibility. The take log records `collected`
events (time, armour, adrenaline) and `missing_pickups`, so reaching the end of
the timeline alone is not evidence that both items were collected.

Movie Maker writes fixed-rate frames and audio independently of wall-clock
render speed. Test a short independent shot before a full 2–3 minute montage:

```bash
DEVAGENT_PORT=24691 godot --path godot --windowed --resolution 1920x1080 \
  --write-movie /absolute/output/usina_raw.avi --fixed-fps 60 -- \
  --devagent --video-stage=usina_walk --video-take --video-quit
```

Keep that port free. Do not use `--headless` for the visual capture. The output
includes menu/loading/settle footage: trim to the `VIDEO_TAKE_START` frame marker,
then the duration specified by the preset (currently 14 s). Actual output resolution is reported by Movie Maker; the
staged movie capture matches the window to its 1920x1080 base viewport to avoid
a cropped HUD on macOS/Retina.
`VIDEO_TAKE_END` gives a JSON log in `user://devagent/takes/` containing per-tick
position/aim/input and start frame markers. Graceful `--video-quit` closes the
movie cleanly. Do not force-kill AVI recording. AVI/MJPEG is an intermediate;
convert a trimmed clip to H.264/MP4 for sharing. Keep shots short (the built-in
AVI writer has a 4 GB limit). Movie capture temporarily fixes render scale to
1.0 and unmutes the master bus in memory; it does not save those preferences.

Movie Maker removes recording-time frame drops; it does not fix logical jumps,
collisions or bad choreography. Review the encoded frames and the take log.
Official reference: https://docs.godotengine.org/en/stable/tutorials/animation/creating_movies.html

Regression checks: `python3 -m unittest discover -s tools/devagent -p test_stage.py`
and `godot --headless --fixed-fps 60 --path godot ../tools/bench/test_video_take.tscn`.
The latter exercises a fixed 12 s locomotion fixture through the actual player's
collision movement: 720 continuous physics samples, bounded motion/aim, eased
endpoints, cancellation, and approach direction/speed under the Fruki bonus.
Live-map capture separately verifies both pickup grants.


### Complete three-minute presentation

Read [the gameplay video README](../tools/video/README.md) before staging or
recording: it contains the reusable rules from the approved edit.

`tools/video/presentation.json` orders twelve independent shots totalling exactly
180 s at 60 fps. `video_actions.gd` adds simulation-time actions to the staging
system: gradual target tracking and real triggers, grenades, laço, drone flight
and fire, a reachable container rescue, vehicle entry/controls/grain fire and
tablet apps. Free-camera paths are reserved for location shots. Enemy spawns,
starting equipment and framing are explicitly staged; this is a scripted demo,
not a recording of an unscripted human session. Ordinary game movement tuning
and combat damage are unchanged.

On macOS, with Godot on PATH and port 24691 free:

```bash
python3 tools/video/render_presentation.py --output /absolute/output/full_3min
```

The tool compiles the bundled Swift source against native AVFoundation, records
one bounded AVI at a time, trims menu/loading/setup frames using the take marker,
encodes H.264 with the game's audio and short chapter captions, then assembles
`city_invaders_gameplay_3min.mp4`. Every clip is decoded to verify frame count and
audio before assembly; the final audit requires 10,800 frames, 180 s and one audio
track. This is offline capture, not an FPS benchmark. Native API deprecation
warnings are harmless; runtime GDScript errors abort the job. Existing resource
warnings on Godot exit are retained in each log.

`--only film_battle film_drone` renders selected takes for review without joining.
Completed clips with their audit file are reused. To revise a completed scene,
use a fresh output folder or move its old clip/audit aside first. Raw AVI, silent
video and temporary audio made by this tool are removed only after that clip's
verification; `--keep-raw` retains them. It never removes other outputs or source
assets. JSON take/capture audits and three preview frames remain per clip. The
pipeline needs about 1.5 GB free for each bounded shot, plus final MP4 storage.

The combine shot reserves a clear staging corridor by removing nearby AI traffic,
accelerates over a short verified stretch, brakes before fixed obstacles, and
uses the normal chase-camera orbit and grain-gun aim. It is a staged action
showcase, not an autonomous road-following/performance test. Normal map/world
collisions remain enabled. The drone shot starts with zero captured drones; its
lasso result and successful launch are required before assembly. A previously
failed lasso take is retained only under `superseded/` in the working outputs.


### Prepared encounters and scene transitions

The revised presentation prepares all robots before recording. The five encounter
presets use `enemies` plus `prestage_enemies=true`, an 8 s settle, and actual
walking cues to approach each encounter. Preparation temporarily suspends those
actors' physics and removes their robot group membership so nearby police cannot
destroy a waiting cast. At take start, their original group/physics state is
restored; normal AI, collisions and damage then run. Spawn effects have already
finished outside the selected movie frames. `prepared_enemy_count` is retained in
the take log. The battle, grenade and mech shots use different starting locations.
The action director no longer has a runtime enemy-spawn action. The presentation
contract rejects `spawn`/`dropship` timeline events, preventing the old sequence
of materialising enemies in front of a stationary player.

Final assembly re-encodes the joined video with 0.3 s fades to/from black at each
scene boundary, plus short audio ramps. These fades stay inside each shot, keeping
exactly 180 s and 60 fps. Frame extraction now requests exact timestamps, avoiding
nearby keyframes when checking a cut. The revised capture lives in `full_3min_v2/`
in the Codex outputs; the original video is preserved for comparison. Unchanged
source clips can be copied into the fresh output directory before running the
renderer, while revised encounters are recorded again.

The v3 encounter takes collect natural robot drops (`loot` cues), aim both
throws with the real 11 m/s launch arc, and fly the captured drone vertically
before advancing above the Usina roof. The drone then aims at a pre-staged
far-side trooper; neither damage nor pickup grants are faked. Drop observers
attach after the normal pickup handler. Take logs include carried parts,
grenade-to-robot distances immediately before each burst, drone positions and
target health. `render_presentation.py` checks these outcomes as well as video
frames/audio. Use `--port 24693` (or another free test port) when 24691 belongs
to another session; 24690 is rejected. Keep revised captures in a new output
folder: existing verified clips are deliberately reused without source hashes.

Clearing a video stage restores the original player's god-mode metadata,
including whether the metadata existed at all. The snapshot keeps a weak player
reference, so changing rounds cannot apply the old player's state to a new one.
The native video-take test covers absent, false and true prior states.
