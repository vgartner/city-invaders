# Open world

A city is made of **tiles** that come in and go out round the players
(`godot/scripts/open_world.gd`). Every round is played on them: a **world**
is a grid of tiles cut from one city's data, and a map of its own (the
Gasômetro, about 400-750 m across, `godot/city/<map>.glb`, 90-170 MB) is a
world of one tile. There is one way to build a city in the game - the
tile's: read on a loader thread, built on a worker thread, furnished a few
milliseconds a frame, its navigation mesh baked once and kept - and
`main.gd` builds none of it (see "Every map is a tile").

It began as a prototype next to the maps, to answer whether a neighbouring
tile can enter and leave a running round without the player feeling it;
this page keeps what was measured on the way.

## What it does

`godot/scripts/open_world.gd`. A **world** is a grid of tiles cut from one
city's data, each a map of its own:

```bash
tools/.venv/bin/python tools/map/tiles.py poa --name centro_world --bounds -350 -330 400 420
tools/.venv/bin/python tools/map/far_view.py centro_world
godot --headless --path godot --import
DEVAGENT_PORT=24691 tools/devagent/devagent.py launch
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=centro_world_1_1
```

`tiles.py` cuts the area (metres from the source map's centre, y north)
into tiles of 250 m (`--size`), writes `maps/<name>_<column>_<row>/build.json`
for each (the source map's data, photos and hand edits, `"tile": true`),
builds them and lists them in `godot/city/<name>.world.json` (a rebuild
keeps what else the list says: label, start, far view, goal). The menu
lists every world found in `godot/city/` as a free-play city of its own
(`main.world_entry`): the list may name the menu label (`"label"`, "City ·
Area" like the maps) and the tile to start on (`"start"`, `tiles.py
--label --start`), by default the tile in the middle of the grid. A world is free play
unless the list sets `"goal"` (robots to destroy): then it has antennas and
people containers like a phase. A round
started on one of the tiles finds the world it belongs to and registers the
others: they come and go round the player, and so does the round's own
tile (below). Single maps can be registered too: `main.open_world("<id>")`
(DevAgent `eval`) or `-- --open-world=<id or world>`.

- A tile is known by its bounds (`<id>.spawn.json`). When the player comes
  within 120 m of them (`LOAD_M`) the tile's `<id>.glb` and
  `<id>_collision.glb` are read on a loader thread
  (`ResourceLoader.load_threaded_request`), its scene and collision shapes
  are built on a worker thread, and one frame puts it into the tree. Beyond
  220 m (`UNLOAD_M`) it is freed.
- **Street furniture and landmarks**: the tile's `<id>.props.json` (trees,
  lamps, signs, benches, bus shelters) is built by `props.gd`, 4 ms of it a
  frame; its landmarks and shops (`<id>.landmarks.json`,
  `<id>.shells.json`) by `main._landmark` and `_shell`, one a frame, their models read beforehand on the loader
  thread (also the furniture of the shops the game draws itself). A
  landmark's triangle collision is made on a worker thread and put in one
  mesh a frame (`main.trimesh_later`, `_shape_later`): the Mercado's 86 000
  triangles cost a frame of 145 ms on the main thread. They leave with the tile. A shop walked into (E) has its pocket
  under the city built in the shop's tile too (`main.enter_shop`). A player who still
  falls out of a pocket is put back (`player.gd`). A tile's lamps, signals
  and bins are shot out, and its bins, benches and planters run over: its
  `Props` node carries the tile's id (`tile`), a shot or a
  vehicle finds the Props its body belongs to (`Props.of`), and the fall
  goes to every peer through the scene (`main.prop_down`: on every peer,
  whatever tiles each has loaded). The scene keeps what went down this
  round (`props_down`): a tile coming back lies its own down again without
  fall or sound, a player who joins gets all of it, and a new round stands
  everything up (`props_up`).
  The tile's pickups and the map editor's edits are not applied; robots
  only shoot at the map's props.
- **Navigation**: after that the tile gets a navigation mesh of its own. Its
  colliders are read (1 ms), the mesh is baked on a thread
  (`NavigationServer3D.bake_from_source_geometry_data_async`, 0.1 s for a
  250 m tile) and added as a region of the same map. The baked mesh is
  kept (`res://city/<id>.nav.res` when the game runs from the project,
  git-ignored with the tiles; `user://tile_nav/` in a released game) with a
  stamp of the tile's files and the bake settings; the next time the tile
  comes in, the mesh is read back on a loader thread (same polygons, same
  links) and neither the colliders are read nor the mesh baked. A rebuilt
  tile, or other bake settings, bake again. The bake's callbacks are bound
  methods, not lambdas, and the world waits for every bake and worker task
  when it leaves the tree (`_exit_tree`): quitting while a tile baked
  aborted the game (`recursive_mutex lock failed`), every time. That wait
  serves the rendering server while it lasts (`_wait_out`): a worker building
  a tile reads meshes through the rendering server and sleeps until the main
  thread answers, so a main thread that only waited hung the game on quit
  (5 of 5 quits while a tile was being built; 0 of 12 now), and a tile still
  being built is told to stop (`_leaving`). Two meshes baked apart
  stop an agent's radius short of the shared edge, so along the tile's edge,
  every 2.5 m where both sides can be walked, a `NavigationLink3D` joins
  them (26 on the test edge). The neighbours' buildings that reach into a
  tile (`<id>.spawn.json` `foreign`, written by the pipeline in tile mode)
  are `NavigationObstacle3D`s: holes in its mesh.
- **People and robots**: the tile brings 14 passers-by of its own
  (`TILE_PEOPLE`); people and robots choose goals in a tile that has its
  mesh (`main.in_world`), and robots chasing a player follow across the
  edge. When a tile is due to leave, its passers-by leave the streets with
  it. It also brings an officer on patrol
  (`TILE_POLICE`), the vendors at its stalls, the people at its pitches and
  playgrounds, someone waiting at each of its bus stops and up to 5 cars
  parked at its kerbs that a player can drive (`TILE_PARKED`, the map's
  rule: 40 % of the parking spots; a car a player drove off is not made
  again). Everything a tile brings - each passer-by, robot, vehicle,
  parked car and pickup - is one thing to make in its turn (`_later`,
  `_bring`: two a frame at most, one when it took 2 ms): a character or a
  car costs 10-40 ms the frame its model is first drawn, so 14 people, 4
  robots or 6 vehicles in one frame were hitches of 100-190 ms. After a new
  round the tiles bring theirs again (`repopulate`: three restarts in a row
  left the same numbers of people, vehicles and robots).
  `open_world_node.extras = false` makes a tile bring only passers-by and
  robots, to compare: over a fixed route through all the tiles the frames
  over 60 ms were 38 with everything and 43-86 without (the runs differ more
  than the two do), and five minutes of autoplay gave 49.7 fps, p99 33 ms,
  4 frames over 100 ms (before the queue, with everything: 41.6 fps, 15
  frames over 100 ms).
- **Robots**: the tile brings 4 robots on patrol (`TILE_ROBOTS`), born on
  its mesh at least 60 m from every player. They carry the tile's id (meta
  `tile`) and are apart from the round's: the Director does not count them
  against its limit, so the waves come as before. A tile that leaves takes
  the tiles' robots standing in it; when it comes back it makes only those
  of its own that are no longer alive elsewhere. A robot of the round (from
  a ship, a collector, a mech) in a tile still keeps the tile until it is
  gone.
- **Traffic**: the tile's streets (`<id>.roads.json`) join the round's road
  graph, which every vehicle drives by. In tile mode a tile's streets run
  to its very edge, so the neighbour's start at the same points: a node
  where the graph already has one is that node. The ways into the tile's
  streets are open while it is in; when it leaves they close (its edges
  stay in the graph, unreachable, for when it comes back) and the traffic
  in it drives back in at an edge.
  Each tile brings 6 vehicles (`TILE_TRAFFIC`, no buses), started on its
  streets, up to what the loaded world should hold (the map's 16 and 6 a
  tile); when a tile leaves, as many go with it and the rest drive back in.
  Where traffic drives in is worked out again whenever a tile's streets
  open or close: the dead ends at the edge of what is loaded, not the
  map's edge where a tile carries the street on. A vehicle whose driver ran
  from the robots goes with its tile; one a player drives or has driven
  (meta `taken`) keeps the tile. Abandoned vehicles count against what
  the tiles may bring, so fights do not add vehicles without end.
- **Traffic evened out**: left to itself the traffic gathers where the
  one-way streets lead. Every 1.5 s the open tiles are compared with their
  share of the vehicles driving (16 where a player is, 6 elsewhere); when one is 2.5 over and another as much under, one vehicle of the
  first starts again on a street of the second - both at least 100 m from
  every player (`_even_traffic`).
- Invisible walls enclose all the tiles together (`_edge_walls`). A map of
  its own has its horizon (`<id>_horizon.glb`: far ground and towers); it
  is hidden once more tiles are added, as it would stand where they are.
- `main.open_world_node.report()` lists every step with its time,
  `census()` the people, robots and vehicles (all, and those driving) in
  each tile;
  `open_world_node.threaded = false` builds on the main thread instead, to
  compare.

- **Bus lines**: the map and every tile are an area with stops of its own
  (`main.area_stops`, one rule for both): the street point nearest each
  shelter, within 25 m, on the area's own streets; shelters placed in the
  map editor inside the area replace its OSM shelters and belong to a bus
  line. Whenever streets open or close the buses' round is made again over
  the areas whose streets are open (`_bus_round`, `main.set_bus_round`): with
  no shelter placed by hand, one round of every stop, nearest-next; with
  some, the lines - a line's hand-placed stops in the order placed, area
  after area, and the other areas' OSM stops on line 1. A bus keeps the stop
  it was making for while it is still served. On the centre tile with three
  neighbours in, the round had 18 stops (9 the map's); a bus sent to a stop
  in a neighbouring tile drove there and stopped.
- The promenade points people stroll to and are born at are those of
  everything loaded (`main.promenades`: the map's `crowd` and the tiles'),
  and a robot shoots out the lamps and bins of the area it stands in
  (`main.props_at`).
- A tile's zebra crossings and street names join the road graph with its
  streets (`crossings`, `streets`; `rev` counts the changes): traffic stops
  for people on a tile's crossing, people cross there, and the GPS draws
  and names the tile's streets.
- A shop wrecked by a blast (`main.wreck_shops`) is rebuilt where it stood,
  in its tile; the tile keeps the blast (`shop_burst`) and wrecks the shop
  again when it comes back. A landmark's forecourt clears the lamps and bins
  of its own tile (`_props_here`), and the counters players trade at are
  asked of every Props node standing (`main.trade_counters`).

- **Occluders, birds**: the tile's occluders (`<id>.occluders.json`) are
  made on its builder thread (`main.occluders_of`) and come in with it - from
  a street of a tile they took 9 % of the triangles drawn off, the draw
  calls stayed. After its furniture every peer gives it 2 pigeon flocks on
  its promenade points, 2 pairs of quero-queros on its lawns and birdsong
  in its greens (`_wildlife`, seeded by the tile's id: the same on every peer), a step a frame, 8-10 ms the worst.

- **Pickups and places**: the server gives a tile its pickups by the map's
  rule (`main.pickups_for`): the items its landmarks hold, half the map's
  scattered ones (`TILE_PICKUPS`), what its places sell at their doors
  (`<id>.places.json`) and the items put down in the map editor inside it -
  45-70 a tile. They are worked out the first time the tile comes in a
  round, 2 ms a frame (in one frame it was 50 ms), and kept: each comes
  back where it was, they leave with the tile (with what a robot dropped in
  it) and a pickup taken comes back at another street point of its tile
  (`pickup_point`). A spot counts as reachable when the tile's own mesh
  reaches it, whichever neighbours are in. The tile's places show on the
  GPS while it is in (`main.all_places`) and its pharmacies get their green
  cross.

- **The map editor's edits**: an edit belongs to the area it lies in
  (`main.area_of`: the tile under the point). The
  editor reads and writes that area's edits (unsaved edits are kept by file,
  as a world's tiles share one when playing from the sources), removes a
  tile's lamp from the tile's own street furniture, parents what it places
  to the tile, saves every area edited and rebuilds each. A tile coming in
  applies its own (`main.apply_edits`): its wall photos, and in the released
  game its placed models and removed objects; its bus shelters placed by
  hand, its item spots and its place kinds switched off are read by the
  rules above. Tested as the released game: a shelter placed and a lamp
  removed in a neighbouring tile went to that tile's file, and after a
  restart the tile came in with the shelter (a stop of bus line 1) and
  without the lamp, also after leaving and coming back.

**Not yet**: a model dragged in the map editor from one area into another
keeps its entry in the first.

**The far view** (`tools/map/far_view.py <world>`): every tile gets a light
model, `<tile>_far.glb` - its buildings as light blocks (footprint, ground,
height: the same OSM data and hand-set heights the tile is built from), on a
ground of 25 m squares that follows the terrain, and the water - 25-190 kB a
tile, no textures, no collision. The walls are one colour each from five
city tones and carry UVs in window bays (3.6 m along, a 3.2 m storey up);
the game lays one window texture over them, made at start (32 px, one pane
and a sill; `_far_windows`, one material per tone for all the models). A
building up to 9 m high and 450 m2 gets a hip roof of tiles, as does one OSM
tags pitched (`roof:shape`); the others a flat roof a shade darker than
their walls, or OSM's `roof:colour`. From the world's edge the ring reads as
streets of tiled houses and towers with rows of windows, not boxes.
A ring of two tiles round the world goes into `<world>_far_ring.glb`
(763 buildings, 1.0 MB) with bare ground beyond it, 3 km out to the
horizon, so a roof never looks over the edge of the city into the sky. The
list's `"far"` names the ring. `main.open_world()` loads them all
(`OpenWorld.add_far`, shadows off) and every frame shows a tile's far
model while the tile is not in, the ring all the time. From a roof of the centre tile the city goes on in the
haze past the loaded tiles.

**Multiplayer.** The server runs the robots, the people and the traffic, so
it keeps the tiles in round every player, not only round its own camera
(`_others()`: the players' positions, the nearest counts); a client loads
round its own camera, for what it sees and walks on. Tested with a host and a client on one
machine: the client went to the south-east tiles 200 m from the host, and
the host loaded them for it (its own camera 200 m away) and let them go
when the client came back; `errors` empty on both. Three faults of the game
itself, not of the world, came out on the way and are fixed: a player's
position synchroniser was the server's (it is made after the player's
authority is set, and had an automatic name that differs between peers), so
the host never saw a client move and the client was pulled back; the
server's calls on a player (score, getting into and out of a vehicle, the
drone, burning) were "authority" calls the client refused; and a client put
back after a fall went to (0, 1, 0), under the ground, because only the
server works out the start (the player's spawn now carries it). The
server places the relay antennas anywhere in what it has loaded - the
tiles round every player - and sends their spots
(`antennas_at`); a player who joins later asks for them (`want_antennas`)
and gets those brought down or spotted as they are, and the containers
already out (`want_containers`). A client sees an antenna on a tile it has
not loaded standing over that tile's far model. Tested with a host and a
client joining after an antenna went down: the same three spots on both,
the fallen one gone, the next one brought down falling on both, the HUD's
state the same, the two containers where the host has them, no errors.

**Every map is a tile.** `main.gd` builds no city: the open world reads,
builds, furnishes, populates and frees the tile a round starts on like any
other (`main._load_city`, `open_world.load_now`: it comes in under the
loading screen, before there is a player to be near it). A tile of a world
has the world's other tiles round it; a map of its own (the Gasômetro) is
a world of one tile, with its horizon model round it, and never leaves.
What is in `main` is the round - where it starts (the tile's `spawn.json`),
its bounds as the start area, goals, score, exit - with `nav_region` and
`props` as empty nodes (the navigation mesh settings the tiles bake with,
the home of the props' effects) and a road graph that starts empty and
takes each tile's streets. Code asks about areas, not about "the map":
`in_world`, `world_areas`, `area_of`, `area_node`, `props_at`, `all_props`,
`all_places`, `reach_from`. `main.home_out` says whether the start tile is
in; in a world it leaves at 220 m like any tile, also with several players
(the server keeps the tiles round all of them), and comes back as a tile
does: its pickups where they were, what was shot out lying down, the war
machine and the round's own pickups asleep meanwhile. A robot of the round
left in a tile that goes is freed and the Director sends others; a heavy
mech or a collector still keeps its tile.

*A map of its own, before and after* (the Gasômetro, 750 x 550 m, the
robots switched off, counted 30 s into the round): the same 79 landmarks,
17 places, 48 street edges, 4 bus stops, 39 crossings, 4 antennas, 2
containers and 78 birds; 164-170 pickups (162-164 before, each kind within
two), 42-43 vehicles of which 30 drive, 105-120 people (officers 5-6, 3
vendors, 8-10 skaters at the skatepark, two waiting at each stop). The
round is live 9.2 s after the start (8.3-8.7 s before); the first start
after a rebuild bakes the navigation mesh, later ones read it back
(`godot/city/<id>.nav.res`, git-ignored). A phase change (Gasômetro to
Centro) frees the open world with the map and makes the next one. The
DevAgent's map tools work on the tiles: `reload` builds the street
furniture and landmarks of every tile that is in again
(`open_world.refurnish`), `nav_probe landmark_pickups=true` takes the
tiles' fixed items, `show_only` hides every tile's city or furniture. The
map editor placed a model in the map's tile and removed a lamp, and both
were there after a restart (released-game mode).

*Density by distance.* What moves follows the players: the round's crowd is
born anywhere in the loaded world (`_spawn_civilians`, `in_world`), a tile a
player stands in has the full traffic (16, with buses; more on a larger
tile, `main.density`) and the others 6 (`_share`). What stands is brought
full - pickups, parked cars, officers, two people waiting at each stop,
pigeon flocks and quero-queros - by the tile a player is in when
it comes in (the start tile; without the tile's own 14 people and 4 robots
on top of the round's), and light by the others; a light tile is topped up
once when a player walks into it (`_fill`: parked cars only where no player
is within 50 m). Tested: the start tile came in with 92 pickups, 70 pigeons
and a traffic share of 16, a neighbour with 57 and 21, topped up to 97 and
79 on entering; 360 m away the start tile left (nodes 20,100 -> 11,200,
static memory 414 -> 331 MB, draw calls 2,480 -> 650 with two tiles in) and
came back with its 92 pickups; a host and a client had the same antennas and
containers (one in a neighbouring tile), and a lamp shot out in a tile lay
down for the client who joined later.

*Loading.* The start tile takes 4.6 s of the loading screen (read 2.0 s,
then built, furnished, its mesh read back) - what building the same map in
`main.gd` took before. The antennas and the first containers wait until the tiles round
the start have been looked at once with a player in the scene
(`open_world.settled`, `_looked`): asked before, "nothing is on its way in"
was true only because nothing had started.

*A freeze, and what stopped it.* With the start tile on the tile path one
start in three to ten froze for good a second or two after the round began:
the main thread waiting for a worker task, worker threads waiting for a
lock (thread samples; the engine build has no symbols, so the call was
never named). The published code before did not freeze (0 of 16 starts).
Two changes together did (0 of 80 starts; either alone still froze, 4 of
40 and 4 of 64): the tiles' files are read without the loader's sub-threads
(`load_threaded_request(path)`: a tile read while the main thread loads
other things is new with the start tile), and the containers and antennas
are placed after the neighbours are in, as before. The round's models are
also read only after the start tile is in, and nothing a tile brings is
made before they are (`main.models_warm`). To check again after a change
to the start: start the round 40 times through the DevAgent and see that
the game still answers 25 s after each.

**Ships, containers, collectors and swarms in the tiles.** What the round
sends picks its place in the loaded world, not in the map's bounds
(`main.in_world`, `main.world_areas()`): a dropship's drop zones, the spot
a people container is set down on, where a collector is born and the edge
it flees to (the edge of what is loaded), where a swarm appears. "Can it
be walked to?" is asked from a player while the map is out
(`main.reach_from()`). `in_world`'s margin is kept from the edge of the
loaded world as a whole, not from each tile's own edge: a street that runs
along the edge between two tiles is open to people (their goals) and to
vehicles, which stop only where the loaded world ends (`car.gd`). Ships cruise over the tallest roof loaded (a tile
raises `main.city_top`). A container or an antenna standing in a tile that
goes out sleeps there and wakes when the tile is back; the dropship's
robots are the round's, so they keep their tile in like any robot of the
round. Tested on the centre tile with the map out: a dropship called 400 m
from the map set 6 robots down in the tile, a container was delivered in a
tile, slept when its tile went and woke when it came back; the same calls
on the Gasômetro as before.

The antenna and the first people containers of a round wait until the
tiles round the start are in with their navigation meshes
(`main.wait_for_world()`, `OpenWorld.settled()`, 30 s at most) and are
then placed anywhere in what is loaded. On a tile a roof is high when it is
10 m over the street next to it (in the round's map, 10 m over the start
as before): the tiles by the river lie 15-20 m lower than the Centro's
ridge. Tested with a goal set on the test world: both containers came
down in tiles; the three antennas happened to fall on roofs of the round's
map (the spots are drawn from the map and the tiles alike). Five minutes
of autoplay in that round (27 robots down, up to 30 alive, 140-150 people
round the bot): 47 fps on average, p99 55 ms, 8 frames over 100 ms (the
worst 276 ms, in a fight), `errors` empty.

**Islands in the navigation mesh.** A baked mesh has patches nobody can
walk to - the top of a newsstand, of a wall, of a parked lorry. With robots
alive in a world, Godot's path search reported "It's not expect to not find
the most reachable polygons" now and then: a path asked for across a link
to such a patch (probed with 784 path queries from one point of the centre
tile: the same 6 targets in the tile to the east raised it in two runs out
of three; the engine's source calls it a geometry problem). So every
tile's mesh drops its islands after the bake
(`OpenWorld.drop_islands`): every group of joined polygons but the largest
(the streets) that does not reach the edge of the tile, where a
neighbouring tile may carry it on. Up to November 2026 only groups under
150 m2 went, and the message came once more from a larger one - an
enclosed yard - when a container was delivered in a tile; now size does not
matter. With the new rule the Gasômetro loses 81 islands (368 of 13,623
polygons; 73 and 214 before), the centre tile as the round's map 19 (39 of
1,491), a tile 11 to 34 (50-107 polygons).

## The test world

`centro_world`: 3 x 3 tiles of 250 m over the Centro (750 x 750 m, from the
Mercado Público and the quay to the Praça da Matriz), built by the command
above in 64 s and imported in 56 s; 525 MB of glb. Its files
(`godot/city/centro_world*`, `maps/centro_world_*/`) are not in the
repository: build it to try the open world.

## What it showed (November 2026)

**The grid.** A round on the centre tile and a tour of all nine - 2.1 km in
jumps of 50 m every 2.5 s, the pace of a car: 24 tiles came in and 20 left,
two to four of the eight neighbours in at a time, 54-74 fps, texture memory
between 0.9 and 2.5 GB, `errors` empty. 24 frames took over 100 ms (the
worst about 200 ms, one of 590 ms): the landmarks' frames below, and
whatever else a tile brings when it enters, still to be profiled.

The numbers below are from the first tests with two tiles, on a MacBook M3
Max that was swapping at the time, so the frame times are rough:

| | 350 x 250 m, cut at the edge | 250 m tile |
|---|---|---|
| Reading the tile's files (loader thread) | 0.9 s | |
| Building scene and collision (worker thread) | 0.2-0.3 s | |
| The frame that puts it into the tree | 12-14 ms | |
| Until the tile is in, from 120 m away | 1-2 s | 1.5-2.5 s |
| Worst frame while it came in (worker thread, 3-4 runs) | 59-200 ms | 37-69 ms |
| Worst frame, built on the main thread | 156 ms | 100 ms |
| Buildings in both tiles / cut at the edge | cut, 3 m free each side | 0 in both, 17 whole across the edge |

The streets continue across the edge, the player walks from one tile into
the other, and `errors` stays empty through the rounds of loading and
unloading.

**Navigation** (the same machine): the tile's mesh was baked and linked
3 s after the player came near; a path from the round's map to a point 60 m
into the tile was found; of three robots set down in the map with the
player standing in the tile, two had crossed the edge 24 s later, and the
tile stayed while they were in it; `errors` empty. The passers-by thinned
out during the test because the busy machine ran under 48 fps (the
performance guard), so how they spread between map and tile over time is
still to be watched.

**Street furniture and landmarks**: the test tile has 850 pieces of street
furniture and nine landmarks and shops - the Mercado Público, the Paço
Municipal, the Chalé da Praça XV, the Talavera fountain. With them the tile
is complete (furniture, landmarks, navigation, links) 1.2-2.4 s after the
player comes near. The furniture takes 0.36 s spread over frames; a shop
costs a frame of about 25 ms; the Mercado Público, a set laid out from many
pieces, cost one frame of 170 ms - the worst frame of each of three runs
(174-180 ms) - and a restaurant the game draws, 200-220 ms reading its
furniture from disk. Measured again: 145 ms of the Mercado's was its triangle
collision; made on a worker thread (1.4 s later, one mesh a frame, at most
6 ms) and the shops' furniture read with the tile, the worst landmark frame
is 14 ms.

**Traffic** (the grid): vehicles started on the map's streets that lead to
the northern edge drove into the neighbouring tile and on through it to
the far edge of the world, 240 m away, where they came back in at a border
street of the map; one turned at a junction inside the tile and drove back.
With the tile gone no vehicle was left in it. In two minutes of ordinary
traffic (17 vehicles) none happened to cross: few streets lead over an
edge, and nothing spawned in a tile then.

**Robots and traffic born in the tiles**: a round on the centre tile with
two neighbours in started with 20 robots (8 of them the tiles', 4 each) and
28 vehicles; walking between the northern and the southern edge twice,
tiles came and went three times and the numbers stayed level (23-24
robots, 34 vehicles driving with three tiles in), `errors` empty. Before
abandoned vehicles left with their tile, one robot attack was enough to
keep a tile for good.

**Traffic evened out**: over three minutes standing still, the western
tile held 15 of 34 vehicles and the round's map 6 (it should hold 16).
Where vehicles drive in was not the cause - choosing the emptiest entry
moved the crowd to another tile: the one-way streets lead there, and the
tiles' streets drain the map. With the traffic evened out (five tiles in,
36 driving) the map held 9 on average and the tiles 3 to 7. The map stays
under its share while the player stands in the middle of it: few of its
streets are 100 m away. One run each, with different tiles in, on a
machine that was swapping - the counts are fair, timings were not taken.

**Textures were the weight.** The first tile cost about 0.8 GB of video
memory: Godot imports the images it extracts from a glb lossless, four
bytes a pixel. Imported compressed for the GPU
(`tools/map/texture_imports.py`, now part of `rebuild` and of the setup),
the 250 m tile's 119 million pixels take 0.1-0.2 GB. The game's reading of
texture memory moves by more than that between runs, because the game's own
models and people are still imported lossless and hold 4-6 GB
([PERFORMANCE.md](PERFORMANCE.md)): that is the next thing to compress.

## What an open world still needs

1. **Less texture still.** Most of a tile is one photo per building. Kit
   facades ([MAP_PIPELINE.md](MAP_PIPELINE.md)) cost a building only its
   footprint, height, style and colour: photos kept for the main streets
   and the landmarks. And the game's own textures compressed for the GPU.
2. **Edges.** A tile knows the neighbouring tile's buildings that reach
   over the edge (`foreign`): no tree or street furniture stands in one
   (18 did in five of the nine tiles, none now), and a wall facing one is
   a blind wall, as one facing a building of its own. The ground meets: every tile levels the landmark lots of the whole OSM file
   (a lot near an edge is levelled on both sides), where before a lot of
   one tile left a 1.3-1.5 m step at the edge of the next; walked along
   every inner edge (2,984 points), the ground of the two tiles differs by
   at most 0.4 m (91 points over 0.1 m, on lawns), and the only hole - the
   Mercado Público's lot, its model smaller than the OSM outline - has
   ground now (`layout.json` lots are open ground like `site.json` ones).
3. **Navigation, the rest.** A tile keeps its baked mesh and reads it
   back the next time (see Navigation above), saving 7-10 ms of the main
   thread and 60-100 ms of baking; the first entry after a rebuild still
   bakes. Measured before (PERFORMANCE.md, loading time step by step): the
   round's map read its colliders in 40-55 ms on the main thread and baked
   for 0.7-0.8 s on a thread at every start; as a tile it keeps its mesh too.
4. **Bus lines across tiles, breakable props, big landmarks**: done (see
   above). Left: robots shooting a tile's props, its pickups.
5. **The far view, the rest**: windows and roofs are in (see The far view).
   Left: lit windows at night, and gabled roofs that follow a long building
   rather than a hip to its middle.
6. **Multiplayer, the rest**: done - the server places the antennas in the
   whole loaded world and tells the others (see Multiplayer).
7. **Every map a tile**: done, in stages.
   1. A tile has what the map had (see above): crossings and street names,
      bus stops by one rule, police, vendors, leisure and waiting people,
      parked cars, pigeons, quero-queros, birdsong, occluders, pickups,
      places, the map editor's edits.
   2. What went through the map's `Props` node or its start point: the
      props' network calls are the scene's (`main.prop_down`, `props_up`),
      which also keeps what went down this round for a tile that is out and
      for a player who joins; the counters inside shops are the scene's
      list; "can it be walked to?" is asked from `main.reach_from()`.
   3. The round's map of a world comes through the tile path; its
      navigation mesh is kept on disk like any tile's; density by distance
      from the players.
   4. The map's own leave-and-return code (`_home_*`: its city freed and
      the rest put to sleep under its navigation region) is gone.
   5. A map that is no world's tile is a world of one tile, and
      `main.gd`'s own city building is gone with everything only it used:
      the map's own streets, bus stops, traffic, parked cars, vendors,
      officers, people at play, pickups, places, birds, occluders, edge
      walls and landmarks (about 600 lines).
   Left: a tile that comes back with a player already near gets its birds
   in two lots (the light ones, then the top-up), so their number differs
   a little from the first time.
8. **A tile's files smaller**: done for the images, which were 95 % of a
   tile's glb. The tiles of a world share them as files
   (`<world>_tx_<hash>.png`, [MAP_PIPELINE.md](MAP_PIPELINE.md)): the test
   world's nine tiles held 3,776 images of which 392 differ. Its sources
   went from 1.1 GB to 174 MB (a tile's glb from 36-89 MB to 0.8-2.5 MB),
   what Godot imports from 975 MB to 214 MB. In the game a texture two tiles
   use is one resource, loaded once; the texture memory read in a round did
   not show it (2.8 GB before, 2.5-2.6 GB after, one run each: the game's
   own models are most of it and it moves by more between runs).

## Bus distance cache

Opening or closing a tile's streets invalidates `bus_routes.gd`'s graph-owned
reverse adjacency and target tables. Replacing the round's graph also drops
the cache. Appending edges has an additional size guard; edits to existing
edge costs, endpoints or one-way flags must explicitly call
`BusRoutes.invalidate(graph)`. The optimisation preserves the previous
routing rules, including consideration of retained tile edges: respecting
closed streets in shortest-distance searches remains a separate behaviour
change. There are at most 32 cached target tables per graph.
