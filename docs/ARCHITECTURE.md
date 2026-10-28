# Architecture

City Invaders is a Godot 4.7 project in `godot/`. Everything in the world is
built at run time from files the map pipeline generates (`godot/city/<map>.*`,
see [MAP_PIPELINE.md](MAP_PIPELINE.md)) plus the models in `godot/assets/`.
There are no hand-made scenes: `main.tscn` only holds `main.gd`.

## Scripts (`godot/scripts/`)

| Script | What it does |
|---|---|
| `main.gd` | Menu, loading, phases, networking (ENet host/join), the city, navmesh bake, spawners (pedestrians, traffic, robots, pickups, dropships), status broadcast to the HUDs, score, design mode, landmarks, cinema screens, pause and settings menus |
| `player.gd` | First-person player: movement, mouse look, weapons and view models, health / pala armour, pickups, vehicles (enter, drive, chase camera), score display |
| `tablet.gd` | Field tablet apps and video UI; video titles refresh on list entry, with retained pictograms for draw callbacks |
| `hud.gd` | The Doom-style status bar (health, weapon, ammo, robots, civilians, threat, score), objective banner, prompts |
| `civilian.gd` | Pedestrians, skaters, street dogs, vendors and Brigada Militar officers: wander / flee AI, police combat, death |
| `enemy.gd` | URB-07 trooper and URB-H9 mech: patrol, hunt civilians, chase players in flank slots, vandalise props, shoot; break apart when destroyed (`wreck.gd`) |
| `drone.gd` | URB-D3 flying drone: patrols above the street, circles and shoots players, calls idle robots |
| `dropship.gd` | Brings reinforcements: flies in, hovers, lowers robots on a beam |
| `director.gd` | AI director (Left 4 Dead style): intensity per player, BUILD_UP / PEAK / RELAX phases, waves, breather drops |
| `car.gd` | Traffic: cars, buses, the Charrua tanker, motorcycle couriers, cyclists, horsemen, and the parked armoured harvester. Follows the road graph; drivers bail out when shot; player-driven arcade handling |
| `props.gd` | Street furniture from `<map>.props.json`: trees (with shot-able crowns), lamps, signals, bins, stalls, the tram, parked cars, street name signs; destructible props |
| `pickup.gd` | Pickups: churrasco, chimarrão, remédio, Fruki, pala, ammo, weapons |
| `pigeon.gd` | Local (per peer) pigeon flocks that scatter at gunshots |
| `wreck.gd` | Splits a robot's skinned mesh into per-bone plates once, throws visible, nonsingular pieces as rigid bodies on death |
| `step.gd` | Step-up over kerbs for character bodies |
| `studio.gd` | Studio (title screen): cities and phases, import a city, rebuild a phase, open a phase for editing |
| `editor_tools.gd` | Design-mode tools panel for the current phase: place models (saved as `_props`) |
| `map_editor.gd` | In-game map editor panel (design mode): building identity from `<map>.buildings.json`, height ghost, save to `user/`, JOSM remote control, rebuild |
| `editor_tools.gd` | Design mode palette (left): groups, thumbnails, search; placing models, sets and item spots; saving, removing and editing placed models in `user/` |
| `inspector.gd` | Design mode Object Inspector (right): map properties (roles, bus line) or the selected object(s), editable for hand-placed models |
| `editor_menu.gd` | Design mode menu bar: open phase, rebuild, undo, remove, view, help |
| `thumbs.gd` | Offscreen thumbnail renderer for the palette (cached in `user://thumbs/`) |
| `edits.gd` | Where a map's user edits live (repository `maps/<map>/user/` or `user://maps/<map>/`) and whether the map pipeline is there |
| `photos.gd` | Photos on walls shown at once: fit to a building side, moved and sized from the inspector, kept in `_photos` |
| `tune.gd` | Autoload `Tune`: gameplay tuning values (vehicle tilt limits, horn interval, pigeon spook radius, police range, robot sight, poncho absorption, Fruki effect) read live - the DevAgent `tune` changes them in a running game |
| `settings.gd` | Autoload: key bindings, mute, friendly fire, steering sensitivity, player name (`user://settings.cfg`) |
| `controls_menu.gd` | Key rebinding UI |
| `sfx.gd` | Autoload: sound cues |
| `autoplay_metrics.gd` | Per-run observed player/vehicle travel and activity coverage; separates bot relocations and external discontinuities |
| `autoplay.gd` | DevAgent-driven player bot: normal inputs, semi-auto trigger edges, confirmed shot/reload/vehicle tracking, blocked-shop/capsule-safe recovery, stale-vehicle and stalled-combat recovery; lane projection and filtered steering feedback |
| `road_path.gd` | Horizontal road projection, arc-length pursuit targets, curve speed limits and normal-key steering feedback for autoplay |
| `dev_agent.gd` | Autoload: JSON-RPC test interface and opt-in frame/pipeline/scene diagnostics (see [DEVAGENT.md](DEVAGENT.md)) |
| `batcher.gd` | Draw-call batching: copies of a mesh become one MultiMesh per 64 m cell (see [PERFORMANCE.md](PERFORMANCE.md)) |
| `texture_sharing.gd` | Loading-time sharing of byte-identical imported texture payloads in retained scenes and live meshes; weak caches, no pixel or import changes |
| `model_library.gd` | Lists the `.glb` models of a folder |

## Networking

Server-authoritative ENet (port 24680). The host simulates robots, pedestrians,
traffic, pickups and scoring; `MultiplayerSpawner`s replicate them and
`MultiplayerSynchronizer`s their position, rotation and health. Each player is
the authority of their own body: they move locally and send shots
(`server_shoot`) and vehicle controls (`drive_input`) to the server. Visual
effects (shots, explosions, robot wrecks, leaves) run on every peer.

## Collision layers

| Layer | Bit | Used by |
|---|---|---|
| World (buildings, ground, props, landmarks) | 1 | everything |
| Robots | 2 | shots, vehicles |
| Players | 4 | pickups |
| Map edge walls | 8 | players, driven vehicles |
| Vehicles | 16 | shots, driven vehicles |
| Pedestrians | 32 | robots' shots, driven vehicles, friendly fire |
| Roofs | 64 | kept out of the street navmesh |
| Tree crowns (areas) | 128 | shots only (leaves) |

The navmesh is baked at load time from the static colliders on layer 1 inside
the map bounds; robots, pedestrians and pickups use it.

## Phases and maps

`MAPS` in `main.gd` lists the maps: `[id, label, next phase, robot goal]`.
Destroying the goal (which grows by one per two civilians lost) opens a green
exit beacon; walking in loads the next map in place, keeping health and
weapons. The last phase ends in victory.

## Landmarks and interiors

A building listed in `maps/<map>/user/buildings_user.json` with a `"model"` is
left out of the generated city and replaced by that model (exported in
`<map>.landmarks.json` with its position and yaw). Models can carry marker
nodes the game reads:

- `lamp_*` – an interior light
- `pickup_<kind>` – a fixed pickup that comes back in the same spot (the
  pharmacy's `remedio`; `pickup_counter` is a can of Fruki on a shop counter).
  It must be reachable on foot from the round's start: a marker inside the
  walls (most shop models' counters) is moved to where that path ends, the
  pavement in front, if that is within 8 m, else left out with a warning. Items
  at OSM shop doors get the same check (no walkable island cut off from the
  streets).
- meshes ending in `_screen` – a cinema screen playing `godot/assets/rio_grande_do_sul/video/cinema.ogv`
- materials ending in `_wall`, `_base`, `_brick` – textured in game with the
  city's PBR scans (triplanar), tinted with the model's colour

`"_props"` in the same file places free-standing models (monuments, the
farroupilha camp) with box colliders.

Native profiler capture tools live in `tools/devagent/profiler_capture.gd` and
`profile_report.py` (see DEVAGENT.md). Map preparation keeps model resources
in a path-keyed `_warm` cache, including the weapon view models, drone, swarm, people-container model and
all existing pickup models (legacy fallbacks and definition-driven drops/gadgets),
so their first disk read is performed behind the loading screen.

Player impact particles share two immutable sphere meshes/materials (dust and
metal). The actual CPUParticles draw modes are rendered briefly behind the
loading screen, alongside view-model preparation, to avoid repeated DRAW
pipeline creation during combat. Mesh tessellation and particle settings are
unchanged. Headless servers skip this rendering warm-up.

DevAgent autoplay exposes read-only `autoplay_status` with unique run IDs.
F5 records low-rate engine memory/render counters and incremental effect-node
populations; `tools/bench/autoplay_bench.py` bundles these with macOS per-process
footprint and disk I/O from `process_metrics.py`. GPU zero timestamps are
unavailable. Server vehicle entry verifies that `take()` accepted ownership
before sending `entered_vehicle`; the test bot separately repairs stale
associations inherited from an old wreck.

People-container loading warm-up instantiates only the cached imported GLB
geometry in the camera view behind the loading screen for two rendered frames.
It does not instantiate the PeopleContainer gameplay script, physics, captives,
network replication or group membership. Headless instances skip it.

The drone PackedScene is retained even after the last live drone disappears.
Otherwise the weak resource cache can evict it and the next reinforcement
synchronously rebuilds it in `_ready` (180-196 ms in native reproduction).
The same unchanged model is now requested during threaded loading and kept
in `_warm`, like the other robot resources.

HUD refresh preserves all health/threat/ammunition colours and the exit pulse,
but only applies font colour/size overrides when the effective value changes.
This avoids repeated theme/layout notifications on identical state. The tablet
keeps a title snapshot and header pictogram outside draw callbacks; video-list
re-entry refreshes title edits from disk.

### Swarm unit collisions

`swarm.gd` gives each unit a swept `CharacterBody3D` sphere. Server movement
collides with world layer 1 and roof layer 64; replicas receive the same
`positions`/`alive_mask` and avoid smoothing through walls. Death disables the
unit collision immediately. The swarm's single `died` signal advances the
director without duplicating per-unit score. Cannon splash uses unit positions.
Autoplay targets live units at their actual centres rather than skipping swarms.

Regression fixture: `godot --headless --path godot ../tools/bench/test_swarm.tscn`.
It exercises real weapon rays, death/score accounting, wall/roof sweeps, cover,
spawn placement and cannon splash.


### Controlled drone shot visuals

`Player.server_shoot` broadcasts `drone_shot_fx` only for the drone weapon, using
its authoritative hitscan endpoint. The RPC accepts the server as remote sender;
`call_local` also draws it for a solo host. The owning client does not predict a
second tracer. `drone_shot.gd` shares one emissive/unshaded cylinder and material,
scales it between a camera-relative muzzle offset and the hit, and removes the
visual after 0.10 s. Short/zero-distance and vertical shots are handled without
invalid orientations. It allocates no lights, colliders or imported resources.
This changes visual feedback only; hit masks, damage and impact particles stay
on the existing paths.

Regression: `tools/bench/test_drone_shot.tscn` drives `_drone_fire` through the
real RPC/damage path, checks hit/wall endpoints, cooldown and cleanup. Run the
same scene in two headless processes with `-- --network --host` and
`-- --network` on isolated port 24693 to verify server/client FX exactly once
and server-only damage. Start the host first.


DevAgent frame recordings qualify render comparisons with window drawability
at both interval endpoints. This avoids reporting process-only frames from an
occluded/minimized window as rendered throughput. Headless is always excluded;
older captures without the field remain unverified. The opt-in stage timer and
F5 preserve all intervals and label invalid captures rather than filtering away
hitches. This instrumentation does not change normal game rendering settings.


### Staged video rehearsals

DevAgent lazily creates `video_stage.gd` only on an explicit stage/take command
or a `--devagent --video-stage=...` startup request. Presets are data in
`godot/data/video_scenes.json`; the standalone `tools/devagent/stage.py` client
protects the owner's default port. Setup is separate from taking footage.
A take runs before player physics, using opt-in `scripted_control/scripted_move`
analog input through the existing movement/collision path. Normal keyboard
movement is unchanged when the flag is false. Quintic ramps and shortest-arc
camera easing are sampled on the game clock; no wall-clock RPC loop drives the
motion. Per-tick take logs and movie frame markers support encoded-video QA.
This is phase one: four manually playable setups and one scripted walking test,
not a complete automated trailer director, cinematic flyover or combat sequence.

The Usina video take now continues through two physical pickup approaches.
Stage-owned item positions are remembered after their removal; approach cues
steer ordinary analog input in world space with eased starts and braking.
Collection telemetry observes the pickup signal after its own handler, rather
than calling `give`; `missing_pickups` distinguishes a finished timeline from
a successful interaction rehearsal. The player's Fruki speed multiplier applies
normally: staging never cancels
the booster. The 14 s take uses normal walking pace and gains 40% speed after
the can, with shorter pauses and distance-based braking near each item.
