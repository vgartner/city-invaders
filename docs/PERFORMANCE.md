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


## Hitch investigation: native profiler (2026-10-24)

A two-minute Gasometro autoplay with the native Godot debugger profiler
identified first-use resource work inside `_show_weapon`: three pickup
frames spent about 242-276 ms in the give/switch/show chain. Initial autoplay
arming spent about 476 ms preparing two weapons (test setup, not ordinary
frame cost). The first swarm spawn spent 103.6 ms in `_ready` under
`main._swarms`, rather than a long walker path search. On a fixed camera,
the first cannon view-model creation took 65.30 ms; repeated cached switches
took 0.022-0.046 ms. These are native per-function timings, not the sampled
process/physics monitor fields.

The loading phase now requests every `Player.VIEW_MODELS` resource and the
swarm model alongside the existing threaded people-model requests. `_warm`
is keyed by resource path and retains strong references: comparing path
strings against the previous resource array did not deduplicate by path.
No geometry, texture resolution or gameplay population setting changes.
This moves first-read cost behind the loading screen and retains these few
resources earlier; it does not eliminate their memory use or guarantee every
rendering pipeline is ready.

In a fresh process, seven first weapon creations after map loading took
0.455-1.124 ms (the same cannon 0.530 ms); an explicit eight-unit swarm probe
took 0.984 ms. Swarm unit counts in the earlier uncontrolled encounter may
differ; these are targeted probes, not a universal speedup ratio. A subsequent
two-minute autoplay reported no script errors, 60.1 FPS and five frames over
100 ms. Its route, prior test state, cache state and population differ from
the exploratory run (55.7 FPS, twelve >100 ms), so those totals do **not**
establish an overall FPS improvement. A live DevAgent self-reload experiment
crashed the isolated test instance; it was discarded and accepted validation
used a fresh process. Do not count that instrumentation experiment as a
normal gameplay failure or omit it when reproducing the investigation.

The F5 collector itself took at most 0.516 ms per `_rec_frame` in the native
capture. In a fixed paused view (65 civilians, 23 robot nodes), 12-second
A/B/A windows with the lightweight frame recorder gave median frame times
15.3 / 15.2 / 15.2 ms, with F5 enabled only in B. This did not show a large
recording penalty in that scene; it is not proof of zero overhead everywhere.

Remaining hitches have multiple signatures. In the after-run, a ~306 ms
frame coincided with two additional DRAW pipelines within a neighbouring
recorded frame, while a ~296 ms frame had no nearby pipeline-counter change.
There were 82 new DRAW pipelines during the capture. The renderer documents
DRAW and SURFACE compilation as possible gameplay stutter sources;
SPECIALIZATION is background work and must not be treated as the same thing:
https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#enum-renderingserver-renderinginfo
No useful GPU time was returned on this Metal setup, so the remaining native
renderer/OS waits are not conclusively attributed to GPU saturation.

Memory is the next concrete lead, not an established cause for each hitch:
engine-tracked textures were around 15,026 MiB (14.67 GiB), and a macOS
sample reported a 17.1G process footprint. The 36 GiB machine had roughly
22 GiB of system-wide swap in use. This is whole-system usage, not proof the
game alone caused it. All 334 inspected Gasometro/horizon PNG imports used
`compress/mode=0`; their estimated raw pixels+mips were only about 0.9 GiB,
so map PNGs alone do not explain the full texture total. Inventory resources
with the native `memory` request and test VRAM texture compression on a
representative subset with visual comparison before any bulk conversion.
Do not reduce models or all texture sizes based only on these totals.


## Identical textures and view-model warm-up (2026-10-24)

Many independently exported props repeat the same atlas in distinct texture
resources. Gasometro's initial native rendering inventory listed 980 texture
entries totalling 11,480 MiB (including internal render targets). Comparing
imported files identified over 400 byte-identical payloads, rather than
merely similar-looking images.

`texture_sharing.gd` now visits retained PackedScenes, material overrides,
Mesh and MultiMesh surface materials behind the loading screen. Imported
CompressedTexture2D resources with identical SHA-256 payloads share one
texture object. The hash covers the entire `.ctex`, including format,
mipmaps and import flags; matching source image names or PNG pixels alone
would not be sufficient. Unchanged material slots are not reassigned.
Procedural textures and render targets are skipped. Per-pass weak references do not retain textures. A later loading pass
starts fresh, including for previously checked artwork; there is no maintained alias manifest that can become
stale after artwork changes. No geometry, UV, resolution or compression
settings change. Future assets first loaded after this pass are not
necessarily shared until a later loading pass.

In the accepted real-game test, 884 imported textures were checked and
404 duplicate objects shared in 3.31 seconds behind the loading screen.
The subsequent inventory contained 609 texture entries totalling 6,614 MiB
(6.46 GiB), about 42% below the initial inventory. Populations and resource
sets differ slightly, so this is a scene inventory comparison, not a
byte-exact whole-process A/B. The after-process physical footprint was
12.4G, compared with 17.1G in the preceding investigation. Peak footprint
was still 18.0G: this pass releases duplicates after loading, so it does not
solve the initial loading peak. The instantaneous texture counter reported
14,024 -> 2,155 MiB within the pass, but does not agree with the resource
inventory on this Metal setup; do not call that a measured 85% RAM reduction
or add these overlapping counters to OS footprint.

An exploratory implementation hashed `get_image()` readbacks. It took
36.31 seconds and hit a Metal fence timeout. It was discarded: the accepted
implementation reads imported files and does not read back GPU pixels.
A five-texture BC7 compression pilot was also restored; no compression or
image changes are part of this fix.

The local player's cached view models now render idle and mid-reload poses
with the actual camera/environment before the loading screen disappears.
This exposes skinned surfaces and reload accessories that loading the
PackedScene alone does not compile. It does not grant inventory or ammo,
and restores the selected weapon afterwards. Hidden cached AnimationPlayers
are paused during switches. Headless servers skip rendering warm-up.
Seven first armed weapon switches after warm-up created zero new DRAW
pipelines; native `_show_weapon` times were 0.054-0.113 ms, with a 21.3 ms
maximum frame in that fixed paused probe. This does not prewarm every
combat effect, light variant or later scene.

A subsequent two-minute autoplay (seed 7, scale 1, 2545x1080 viewport,
6260x2656 window, VSync on) averaged 60.0 FPS, p99 22.4 ms and maximum
87.8 ms, with no >100 ms frames or script errors. It fired 11 rounds,
killed two robots and collected five pickups. It still created 35 DRAW
pipelines and spent 26% of its time recovering from a ground_brick collider
near x=110,z=190. The earlier run had a different route, state and combat
load, so these totals do not establish a general FPS improvement or prove
all hitches fixed. Some 70-88 ms frames still coincided with pipeline work.

Checks: normal headless parse, 12 Python profiler/report tests, texture
sharing tests in the project and in a PCK with no source PNGs:

```bash
godot --headless --path godot --script ../tools/bench/test_texture_sharing.gd
```

The sharing test checks distinct payloads, procedural textures, unchanged
geometry, identical payload reuse and weak cache lifetime. Native inventory
packets above 64 KiB are now supported by the capture helper.


## Autoplay recovery regression (2026-10-24)

The earlier ground_brick hold near (110.7, 7.2, 187.3) exposed two bot errors:
failed shops were marked by the shared Main node id but shop selection ignored
that blacklist; selecting a new goal reset the best distance to INF, and the
next tick treated the first distance sample as progress, resetting recovery.
The bot now skips failed shop positions and preserves attempts across goal
changes until real progress is observed. Last-resort placement checks the full
player capsule against world, cars and pedestrians instead of blindly moving
to a navmesh point. `nav_recovery` records the hop. Resumed movement also clears
the stale `stuck` activity tag, which previously could misclassify later walking.
These changes affect the DevAgent bot only; manual player movement is unchanged.

A controlled before-run at that coordinate logged 11 stuck events in 21 s,
repeatedly choosing the same shop. In the after-run it left the point following
one sidestep, with one stuck event in 14.2 s and about 80 m displacement. These
are separate physics runs, so that escape alone does not prove every recovery
branch. A fault-injection test disabled only player physics for six seconds:
the bot skipped the shop at the second attempt and logged a capsule-checked
recovery at 4.8 s after the third attempt, from (110.7,7.2,187.3) to
(111.5,7.6,189.2). Player physics was restored afterwards.


## Reused impact resources and valid wreck bodies (2026-10-24)

A fixed-camera probe after view-model warm-up still created two new DRAW and
two SURFACE pipelines for **every** bullet impact, even repeated effects of
the same type. `player._impact` rebuilt a SphereMesh and material each time.
It now reuses two immutable meshes/materials (dust/metal); each effect still
has its independent CPUParticles node. Particle amount (14), lifetime (0.45 s),
colour, mesh size and tessellation are unchanged. Both real particle draw
modes render briefly behind the loading screen and are removed before play.
No shots, damage, sound or drops are triggered by the warm-up.

The same four-effect sequence (dust/metal/dust/metal) produced eight DRAW
and eight SURFACE creations before, zero of either after. Initial probe
windows peaked at 40.7/61.3 ms before and 19.6/16.6 ms after; these separate
processes have different frozen world populations, so do not treat the timing
ratios as a general FPS improvement. The pipeline deltas directly verify the
resource reuse. Effects keep the original geometry and appearance.

`wreck.shatter` also skips nonfinite/singular source transforms. Zero-scale
bones/accessories have no visible plate but previously became phantom rigid
bodies and triggered Jolt singular-transform warnings. Visible pieces retain
their existing meshes, velocities and colliders. The fixture verifies both
a rigid zero-scale mesh and an accessory hidden by a zero-scale skeleton bone:
only the valid visible piece becomes a body. This does not cap debris or
remove visible destruction effects.

Fresh two-minute Gasometro autoplay, seed 7, scale 1, 2545x1080 viewport,
6260x2656 window, VSync on: 60.9 FPS, p99 24.8 ms, maximum 76.9 ms,
zero >100 ms frames and zero script errors. It fired 45 rounds, killed seven
robots, took three pickups, drove once, opened one container and traded once.
There were no navigation/recovery events in that run. It still created 13
DRAW pipelines (seven SURFACE and two CANVAS), so not all first-use work is
prewarmed. The prior run created 35 DRAW pipelines but had only 11 shots,
two kills and a different route; do not infer a universal 35-to-13 improvement
or general FPS gain. The focused four-impact probe is the controlled evidence.
No singular-transform warning appeared in this accepted combat run; the
existing navmesh-radius rounding warning remains.

Regression checks (normal project autoloads are required for the fixture):

```bash
godot --headless --path godot ../tools/bench/test_recovery_fx.tscn
```

It covers real progress versus goal changes, per-shop exclusion, activity
tag recovery, rigid/skinned hidden wreck parts and shared impact resources.
The 12 Python report/profiler tests and normal headless parse also pass.
The impact probe and bot block/fault-injection tests were run in the rendered
game. A baseline polling request after its short autoplay had already ended
returned an evaluation error; the completed run file, not that late query,
was used for before-run events.


## Measurement audit and autoplay coverage (2026-10-24)

A new M3 Max / Metal Gasometro test adds measurements missing from the earlier
runs: actual player/vehicle travel, confirmed reloads/entries, process physical
footprint and disk I/O, effect-node populations, configuration drift, and
collector self-cost. GPU timing is unavailable: both viewport timing and 1,585
native visual-profiler frames returned only zero GPU times. Do not interpret
these as GPU idle. Render-thread timing is not total frame CPU cost.

The initial 90-second baseline averaged 60.1 FPS (median 16.5 ms, p99 24.5 ms,
worst 79.4 ms), 55 rounds and 3 robots. It ended holding position while the bot
was attached to a destroyed lorry whose driver owner was zero. A separate
rendered fault-injection test reproduced the server accepting entry despite
`take()` refusing it. Vehicle entry now rejects wrecks and checks ownership;
the bot also detaches and blacklists stale associations. Runtime tests verify
rejected wreck entry, inherited stale-association recovery, read-only status
after completion, invalid durations, and unique files during rapid stop/start.

The instrumented 180-second run (seed 7, scale 1, VSync 1, 2545x1080 viewport)
averaged 58.2 FPS, median 16.9 ms, p99 24.6 ms and worst 140.6 ms, with two
frames over 100 ms. It consumed 94 rounds, downed 9 robots, completed 3 reloads
and 2 confirmed vehicle entries, and covered 943.1 m on foot plus 167.8 m driving
in 20 observed 50 m cells. No relocation/discontinuity distance, script errors,
renderer fence errors or tester-eval errors were recorded. Grenades, container
rescues and trades were not exercised; a general bot run is not their test.
Ambient scale changed from 0.9 to 1.0 during this run. Its duration, route,
world randomness and population differ from baseline, so this is not evidence
of an overall FPS improvement/regression.

179 low-rate samples showed physical footprint 12,228.9 -> 12,430.6 MiB,
1 process page-in and 6,569,984 bytes of disk reads. This short increase neither
establishes a leak nor proves a swap hitch. Orphan nodes remained zero.
Peak tracked populations were 135 RigidBody3D, 18 CPUParticles3D, 85 positional
audio players and 69 OmniLight3D nodes; these are not active/awake counts.
Sampled CPU render time was median 1.75 / maximum 3.44 ms. Row collection cost
was mean 0.025 / maximum 0.094 ms per frame, excluding hooks, bot, host sampler
and final writing. Allocation counters overlap and the Metal texture counter
is not resident RAM.

The 140.6 ms frame occurred at first container/mothership creation near 5 MB
of disk reads and an approximately 85 MiB texture-counter increase. The
container model was missing from the loading cache. A separate 119.7 ms late
frame coincided with two DRAW pipeline compilations, without nearby disk I/O;
its cause is unresolved. Correlation does not attribute the whole frame to a
specific resource or function. Future matched-route tests should pin ambient
population, target those pipeline variants, exercise grenades/rescues/trades,
and obtain GPU timings with a supported Metal profiler before changing detail.

Validation: 14 Python benchmark/report tests, 4 native-profiler parser tests,
normal headless startup and the recovery/effect and measurement GDScript
fixtures pass. Each headless test uses its own log file so it cannot rotate
the rendered game's error log. See DEVAGENT.md for the safe portable runner.


### Targeted container warm-up follow-up

After the 180-second measurement above, the container GLB was added to threaded
loading and rendered behind the loading screen. No model/material quality was
reduced. In a fresh rendered game with the director disabled, a one-container
probe found the model cached and no increase in any pipeline compilation
counter or texture counter. The 61-frame sample had maximum 17.8 ms, with no
frames over 33 ms. The native profiler captured 90 frames (maximum 17.42 ms);
`_add_container` reported 0.449 ms inclusive and container `_ready` 0.335 ms.
Inclusive/callback figures overlap and must not be summed. No script errors.
The screenshot confirms the real container is visible. This isolates first
container creation; it is not a rerun of the full mothership delivery or proof
that every 140 ms stall has been eliminated. The complete three-minute run
predates this final warm-up change.


## Fifteen-minute soak test (2026-10-24)

A fresh rendered Gasometro game ran the updated autoplay for 900 simulation
seconds / 900.6 wall seconds (seed 7; M3 Max Metal; scale 1; dynamic resolution
off; VSync 1; 2545x1080). The director stayed enabled and ambient scale varied
0.9-1.0. No gameplay/settings/code changes were made during this measurement.
Low-rate read-only status/performance checkpoints were taken every 30 seconds;
screenshots were taken outside the recorded interval.

52,917 frames averaged 58.8 FPS (median 16.8 ms, p99 24.4 ms, worst 212.5 ms).
Five consecutive three-minute windows averaged 58.4, 58.0, 59.9, 60.2 and
57.4 FPS; p99 was 25.1, 25.2, 23.8, 23.7 and 24.0 ms. There is no clear
progressive frame-rate degradation in this run, but different positions,
actions and populations prevent a controlled beginning/end FPS comparison.

The bot covered 5,800.6 m on foot and 449.9 m driving in 61 observed 50 m
cells. It consumed 314 rounds, downed 29 robots, completed 15 reloads and
5 vehicle entries, consumed 7 grenades, and recorded 23 pickups, one container
opening and three trades. Every tracked action category was exercised, though
legacy pickup/rescue/trade counters are not all strict success confirmations.
One 2 m navigation recovery at 261.2 s is excluded from normal travel; no
external discontinuity, invalid-vehicle association or stalled-combat recovery
was recorded. Script, renderer-fence and tester-eval error lists were empty.

Six frames exceeded 100 ms: at 6.003 s (115.22 ms), 214.250 s (160.59),
254.452 s (134.55), 534.487 s (212.53), 779.183 s (120.90) and 890.643 s
(100.66). The worst occurred while walking at local x=-52.1, z=175.0, with
4,116 draw calls, 197 civilians and 14 robots. Nearby host samples (within
1.5 s) recorded about 9 MiB of reads and an 88 MiB footprint increase, without
page-ins. No pipeline counter increased within two neighbouring recorder rows
around any of these six frames. The two driving stalls and the 120.90 ms
walking stall had no nearby disk-read increase. These correlations identify
reproduction targets, not confirmed causes; native CPU/Metal capture is still
needed. GPU times remained unavailable (0/893 usable low-rate samples).

889 host samples: process physical footprint 12,904.2 -> 13,053.8 MiB, peak
13,082.1 MiB (net +149.6 MiB); 17 page-ins and 28,237,824 bytes read, no disk
writes. Footprint did not remain flat: its fitted slope after minute five
was approximately +12.4 MiB/min, with steps and a late decline. This does not
establish or exclude a leak: caches/world load change and F5 retains growing
row arrays. Allocator usage grew 403.6 -> 456.8 MiB. Nodes started at 19,731,
peaked at 20,594 and ended at 19,952; orphan nodes stayed zero. Effect peaks
were 87 rigid-body, 24 CPU-particle, 81 positional-audio and 63 OmniLight nodes.
Row collection averaged 0.024 ms / peaked at 0.536 ms (not total observer cost).

Next useful controlled tests: replay the two driving coordinates with native
profiling; reproduce the 534 s wave/resource read; and compare repeated fixed
routes with/without full F5 row retention to separate recorder growth from
world/cache growth. A longer or repeated same-route session is needed before
calling the memory behaviour a leak. The rendered test instance was closed.
