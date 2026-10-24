# Performance

How the game keeps its frame rate, what costs what, and how to measure it.

## Measuring

The DevAgent `perf` method (MCP tool `perf`) reports, for the current frame:
FPS, render scale, process / physics / navigation ms, draw calls, objects
and primitives drawn, node count and how many pedestrians, vehicles and
robots exist. Two switches make runs comparable:

- `main.dynamic_resolution = false` and `get_viewport().scaling_3d_scale = 1.0`
  measure at full resolution (otherwise the dynamic resolution hides changes:
  it trades sharpness for frame rate);
- `player.set_physics_process(false)` after a teleport keeps the camera still.

Measure a change against its baseline back to back in the same session: the
same machine varies by 10-20% between runs (heat, background load).

## What costs what (Gasômetro, MacBook M3 Max on a 6260 x 2656 screen)

| | cost |
|---|---|
| Screen-space indirect light (SSIL) | ~25% of the frame at full resolution |
| Ambient occlusion (SSAO) | ~12% |
| Pedestrian physics (~80 walkers) | ~10 ms per physics tick before the LOD |
| Robot physics | ~4-5 ms |
| Draw calls | ~4,300-7,200 per frame before batching, of which ~6,000 objects were street props (a tree alone was 13 meshes) |

On a large screen the game is limited by the pixels the GPU shades, not by
draw calls: halving the draw calls changed little at full resolution, while
dropping SSIL gained ~40%.

## What the game does

- **Dynamic resolution** (`main.gd`): the 3D view renders between 50% and
  100% of the screen (FSR upscaled, the HUD stays sharp) to hold ~60 fps.
- **Graphics preset** (Settings: LOW / MEDIUM / HIGH, default MEDIUM): HIGH
  adds SSIL, LOW also drops SSAO and MSAA and shortens the sun's shadows.
- **Batching** (`batcher.gd`): trees are 8 templates turned and scaled per
  tree; trees, shrubs, ferns, weeds and manhole covers are drawn as one
  MultiMesh per mesh and 64 m map cell (culled per cell). A tree shot through
  still shudders (its instance transform is tweened). Props that break or
  fall over are not batched: they are visible only up to ~90 m and batching
  them gained nothing measurable.
- **Distance LOD for agents**: pedestrians farther than 90 m and patrolling
  robots farther than 110 m from every player think and move every 0.1 s
  instead of every physics frame, covering the same ground in longer steps.
- **Performance guard** (server): if frames stay below ~48 fps even at the
  lowest render scale, fewer passers-by are kept (down to 60%; far ones leave
  first) and they come back when there is headroom. Robots, goals and scores
  never change with it.
- **Population cap**: pedestrians and traffic grow with the map's area up to
  2.2x a 300 x 300 m map, so a bigger map does not mean a heavier crowd.

## Results (dynamic resolution on, the way the game runs)

| Gasômetro | fps | render scale |
|---|---|---|
| before | 55-57 | 50-65% |
| after | 64-68 | 85-90% |

At full resolution: 35.5 fps before, ~52-62 fps after.

## Bigger maps

With these changes a Gasômetro map extended 150 m south and 350 m east
(6.1 km of streets instead of 1.7 km, 578 buildings) ran at the same frame
rate as the current one (the crowd is capped, distant cells are culled),
and loaded in about the same time (~50 s, most of it spent before the
navmesh bake).

## October 2026: lights, shops, physics engine

Measured at one street of the Centro (DevAgent `perf`, `show_only`, `lights`):

- Lights from model markers (`lamp_*`) fade out by 30 m, and a closed shop
  keeps one of its four: 334 lights in the Centro down to 122.
- A closed shop's light model is merged into one mesh per material
  (`_merge_by_material`): a dozen draw calls and shadow calls each, now two.
- The tablet's and the cinema's SubViewports have no 3D pass and stop
  redrawing while put away or far.
- Robots scan for people every 0.3 s (their own phase each), the line of
  sight only for the four nearest candidates; their hit flash overlay is on
  the meshes only while it shows.
- Traffic probes the street under its wheels once it has moved 1.5 m and
  checks the way ahead ten times a second (one shared shape); the driven
  vehicle keeps probing every tick.
- **Jolt physics** (`physics/3d/physics_engine`): with 115 people, 43
  vehicles and 22 robots, physics went from 40-45 ms a frame to 10-16 ms.
  Most of the old cost was the people's `move_and_slide` against the city's
  large collision meshes.

With the simulation paused, the same street draws at the 145 fps cap at
full resolution (55 fps at half resolution before).

## Areas and occlusion (October 2026)

- **Occlusion culling** is on (`rendering/occlusion_culling`): the map
  pipeline writes `<city>.occluders.json` - every generated building at
  least 6 m tall, its footprint set 0.6 m inside - and the game makes one
  `ArrayOccluder3D` of wall quads per 80 m cell (`_occluders` in main.gd).
  On a street of the Centro it halved the draw calls (3,559 to 1,914) and
  cut the triangles by 40%; on open squares it changes little.
- **Splitting the city's meshes into cells** (`CITY_CELL_M`) is still off,
  measured twice. The first time (279 materials, the player's game open at
  the same time) 80 m cells drew about 30% slower. Measured again with the
  facade atlas (102 materials) and the game closed (`tools/bench/cell_bench.py`,
  2-3 runs each): walking and running down two Centro streets at 67%
  resolution, one mesh per material 61-69 fps (p99 22-25 ms), 120 m cells
  66-69 (p99 21-23), 200 m cells 69-80 (p99 19-23). Cells cut the triangles
  drawn by 35-50% and add about 30% draw calls; on this Mac that is a wash
  to a few per cent better, within the spread between runs. The paused
  views are no help here: on macOS the reading jumps between ~80 and a
  145 fps ceiling (the display's rate, vsync off is not always honoured)
  from one view to the next, whatever the build.
- **People far from everyone sleep** (`civilian.gd` `SLEEP_M` 150 m from
  every player, 40 m from every robot): no AI, no physics, the animation
  stopped; woken, they are moved on along the path they were walking by
  the time they slept, so the same people stay in the same streets and the
  robots still find them. Measured with `tools/bench/crowd_bench.py` (the same
  walk with everyone on the map and with only those within 150 m): the
  ~100 people out of reach cost about 4 ms of physics a frame, half of it;
  asleep (about 85 of 115) the physics went from 7.3-8.9 to 4.1-6.2 ms.
  Taking them off the map instead would save the same, but every group
  coming in to refill the streets near the player was a 100-340 ms freeze:
  all 47 people models are now read on threads while the navmesh bakes
  (`_warm_people_request` in main.gd) - loading no longer than before
  (20-28 s against 26-28), and on the Centro walk no freezes over 100 ms
  left (4 and 2 before). Bursts of 3D sounds still give an occasional
  100-300 ms freeze on the Gasômetro.
- **People choosing where to walk** was the biggest physics cost after the
  switch to Jolt: every choice ran up to 16 path searches over the whole
  navmesh (24,000 polygons), and someone with nowhere reachable repeated it
  every tick. Now one path search per try (the agent keeps it), four tries,
  and a wait of 1-3 s after a failure: physics in the Centro stays at
  11-19 ms over minutes of play, where it climbed to 50 ms before.

## Facade atlas, and what the frame is really bound by (October 2026)

- The photographed facades are packed into atlas pages (`_atlas_photos` in
  osm2gltf.py, `ATLAS_PX`, 4096 px, 8 px of edge padding against mipmap
  bleeding): on the Centro 182 photos in 5 pages, 279 materials down to
  102. Photos repeated across a wall stay on their own.
- Measured on a fresh test instance, fixed full resolution, simulation
  paused (`uncap` off the frame cap): 55 / 52 / 62 fps before, 55 / 51 / 65
  after - the city's materials were not the bottleneck.
- **The frame is bound by the pixels.** On a 6260 x 2656 screen (16.6 Mpx,
  eight times 1080p): 54 fps at full resolution, 72 at 75 %, 117 at 50 %;
  SSAO costs 54 -> 73 fps, MSAA 2x 54 -> 65, the sun's shadow 54 -> 62.
  Dynamic resolution (main.gd) is what matters on such screens.
- Benchmarks must use a freshly started game, one run: in a match that has
  been going for a while the same view draws 30-40 % slower (something
  accumulates - not yet found). And never with a second game open on the
  same machine: the two share the GPU.

## Hitches in a fight, AUTO resolution (October 2026)

DevAgent `hitches` lists every frame over 60 ms with what had just entered
the scene; `scene_count` what the scene holds by kind.

- Every robot shot made three lights, a new mesh and material, and a sound:
  now the bolt shares one mesh, effect lights are at most 8 at a time
  (`Enemy.fx_light`), the bolt has no light of its own, and 3D sounds are at
  most 24 at a time (the same cue again within 50 ms, 4 m away, left out).
- Each shot was heard by every civilian: people re-planned their escape at
  every shot after 1.5 s running, police recomputed their route at every
  shot. Now at most 3 path searches a physics tick for everyone
  (`Civilian._path_budget`), police answer the sound once a second.
- Ships and every robot kind are loaded with the map, and every robot's
  break-apart pieces worked out then (only two kinds were).
- Result on the Centro, a 4-minute round at 67 %: 73-81 fps most of the time
  (16-25 fps in long stretches before), the worst frames 66-208 ms in the
  heaviest fights, where they were dozens of 135 ms frames in a row.
- The "slower after a while" drift was not the game: a second instance open
  on the same machine shares the GPU (58 fps with the player's game open,
  90 without, same view).
- AUTO resolution starts from the screen's size (`RES_PIXELS`, about 6 Mpx),
  keeps a step down only if it bought frames (else back up and 20 s without
  trying: the CPU was the limit) and goes back up above 80 fps.

## Collector retry correction (19 October 2026)

Decision: keep only the collector retry correction, as explicitly requested
by the owner. It fixes an unintended repeated search when no victim exists.
It is not presented as a demonstrated whole-game FPS optimization. The
broader performance measurements below remain inconclusive.

A collector with no eligible victim bypassed its one-second perception
cooldown. Dead/freed prey is now cleared immediately, while another search
waits for the existing retry deadline (at most about one second).

An isolated probe running the real collector decision/search methods for
600 ticks at 60 Hz (10 simulated seconds), scanning 112-114 actual civilians,
measured 600 searches before and 10 after. Across seven repetitions, median
search CPU time fell from 26.035 ms to 0.483 ms for the whole simulated
interval. This is a small per-collector saving, not a 98% whole-game gain.
Regression checks cover empty retries, live acquisition, dead/freed targets,
and acquisition within the next retry interval; the old implementation
fails the cooldown checks and the patched implementation passes.

A rendered Gasometro smoke test used a fixed actual 1920x1080 window,
MEDIUM graphics, SSAO, 100% render scale, 60 Hz physics and uncapped rendering:
15 s stationary, 12 s walking (~45 m), 20 s shooting, 8 s aftermath. Initial
NPCs stayed active; the director, bubble spawning and adaptive population
were suspended, and god mode prevented interruption. A fresh process ran
each version. FPS (from recorded frame intervals) was:

| Stage | Original | Patched | Original repeated |
|---|---:|---:|---:|
| Stationary | 142.4 | 117.8 | 133.9 |
| Walking | 128.1 | 109.4 | 120.0 |
| Combat | 106.9 | 98.6 | 98.4 |
| Aftermath | 110.4 | 87.8 | 86.6 |

These runs do **not** establish an overall FPS improvement or a causal
regression. Combat aim, police activity and populations differ; the repeated
original also slowed, and the aftermath views face different directions.
The automatic collector spawner is disabled in this route, so its FPS is not
an end-to-end benchmark of collector search savings. A collector-specific
probe is the evidence for the change. All three accepted runs reported no
script errors. Navigation-edge overlap warnings remain pre-existing.

Important measurement trap: this project's fullscreen startup overrode
`--resolution`. Two exploratory runs actually used 6880x2656 and 6260x2656
windows; their FPS comparison was discarded. Set the window mode/size
explicitly and verify the actual viewport before comparing. DevAgent GPU
milliseconds returned zero on this Metal run; they were not used. Engine
process/physics monitor samples are not additive per-function timings.

A microbenchmark gain alone is not sufficient to keep a performance change.
Future changes need representative end-to-end validation, matched workloads
and no unexplained regression before being retained.

The next performance investigation should correlate first-use/death-effect
hitches with scene creation, and use matched camera views plus repeated
runs. A longer normal-director session and other maps are still untested.

## Play-through benchmark (October 2026)

`tools/bench/play_bench.py [label]` plays the same route in a test instance, the
way a player does: walking and running down a Centro street, a fight with
the machine gun (robots dropped in front), into the Theatro São Pedro and
out, into a shop and out, a car driven a few blocks. Per stretch it prints
the frame times (median, 95th / 99th percentile, worst, frames over 33 and
100 ms), the worst hitches with what had just entered the scene, and checks
that each step really happened (in the Theatro, in the shop, driving). The
DevAgent gives it `frames` (every frame's time), `arm` (a weapon with
ammunition) and a virtual trigger (`hold_keys actions=["fire"]`). Close the
player's own game first, and compare runs at the same resolution setting.

What it found, at 67 % on a 6260 x 2656 screen: the people's walking goals
were still the biggest script cost in play - each path search over the
navmesh cost about 2.5 ms, and with fleeing and stuck people the search
budget was always full (people's physics up to 500 ms of script a second).
Now one path search a tick for everyone, three tries per goal and a 2-5 s
wait after a failure, and the navmesh is baked with 0.4 m cells and edges
simplified to 2 cells (24,000 polygons in the Centro down to 12,900).

| Stretch | before: fps, frames > 33 ms | after: fps, p95, frames > 33 ms |
|---|---|---|
| walk + run | 52-62, 24-43 | 67, 19 ms, 4 |
| fight | 33-56, 14-272 | 60, 21 ms, 6 |
| Theatro in and out | 33-48, 37-138 | 60, 21 ms, 5 |
| shop in and out | 48-58, 6-36 | 57, 23 ms, 10 |
| drive a car | 28-43, 72-260 | 51, 28 ms, 12 |

A frame of 100-300 ms still shows once or twice a stretch, in a fight.

## Autoplay runs (October 2026)

A fixed route measures the same streets every time; `autoplay` (docs/DEVAGENT.md)
lets a bot play for 10 minutes and goes where a player would - fights, pickups,
cars, shops - with the F5 recorder on. `tools/bench/autoplay_report.py` then
shows the fps per activity and a 50 m heatmap of the map, so a slow corner
shows up even when no route passes it. The same seed makes the same choices,
so two builds can be compared by run (the traffic and the robots still differ).

Autoplay measurement limits: `frame_ms` records elapsed frame intervals.
`process_ms` and `physics_ms` are sampled engine monitors and can repeat
across multiple recorded frames; they are not per-function script timings,
and must not be added or treated as synchronous costs of a specific row.
The recorder does not capture usable GPU timings. Empty `last_added` entries
mean the hitch cause is unknown, not that no work happened. Profile CPU/GPU
separately before choosing an optimization. Compare runs at matching saved
conditions, distinguish initial warm-up, and inspect final position holds
and `combat_stalled` events before treating a run as continuous exploration.
