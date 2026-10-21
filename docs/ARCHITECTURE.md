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
| `wreck.gd` | Splits a robot's skinned mesh into per-bone plates once, throws them as rigid bodies on death |
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
| `dev_agent.gd` | Autoload: JSON-RPC test interface (see [DEVAGENT.md](DEVAGENT.md)) |
| `batcher.gd` | Draw-call batching: copies of a mesh become one MultiMesh per 64 m cell (see [PERFORMANCE.md](PERFORMANCE.md)) |
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
  pharmacy's `remedio`)
- meshes ending in `_screen` – a cinema screen playing `godot/assets/rio_grande_do_sul/video/cinema.ogv`
- materials ending in `_wall`, `_base`, `_brick` – textured in game with the
  city's PBR scans (triplanar), tinted with the model's colour

`"_props"` in the same file places free-standing models (monuments, the
farroupilha camp) with box colliders.
