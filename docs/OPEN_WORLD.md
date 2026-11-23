# Open world (prototype)

Today a round plays on one map: a square of about 400 m, built by the
pipeline into one model (`godot/city/<map>.glb`, 90-170 MB), loaded whole
with its collision, navigation mesh, props, people and traffic. This page
is about going past that: a city of many **tiles** that come in and go out
round the player. So far it is a prototype that answers the first question
- can a neighbouring tile enter and leave a running round without the
player feeling it?

## What the prototype does

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
  lamps, signs, benches, bus shelters) is built by the same `props.gd` as
  the map's, 4 ms of it a frame; its landmarks and shops
  (`<id>.landmarks.json`, `<id>.shells.json`) by the map's own
  `_landmark`, one a frame, their models read beforehand on the loader
  thread (also the furniture of the shops the game draws itself). A
  landmark's triangle collision is made on a worker thread and put in one
  mesh a frame (`main.trimesh_later`, `_shape_later`): the Mercado's 86 000
  triangles cost a frame of 145 ms on the main thread. They leave with the tile. A shop walked into (E) has its pocket
  under the city built in the shop's tile too (`main.enter_shop`): in the
  round's map it had no floor while the map was out. A player who still
  falls out of a pocket is put back (`player.gd`). A tile's lamps, signals
  and bins are shot out, and its bins, benches and planters run over, like
  the map's: its `Props` node carries the tile's id (`tile`), a shot or a
  vehicle finds the Props its body belongs to (`Props.of`), and the fall
  goes to every peer through the map's Props (on every peer, whatever tiles
  each has loaded) to `open_world.prop_down`. The tile keeps what went down
  while it is out, and a new round stands it up again (`restore_props`).
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
  aborted the game (`recursive_mutex lock failed`), every time. Two meshes baked apart
  stop an agent's radius short of the shared edge, so along the tile's edge,
  every 2.5 m where both sides can be walked, a `NavigationLink3D` joins
  them (26 on the test edge). The neighbours' buildings that reach into a
  tile (`<id>.spawn.json` `foreign`, written by the pipeline in tile mode)
  are `NavigationObstacle3D`s: holes in its mesh, in the round's map too.
- **People and robots**: the tile brings 14 passers-by of its own
  (`TILE_PEOPLE`); people and robots choose goals in a tile that has its
  mesh (`main.in_world`), and robots chasing a player follow across the
  edge. When a tile is due to leave, its passers-by leave the streets with
  it.
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
  one-way streets lead and the round's map empties. Every 1.5 s the map and
  each open tile are compared with their share of the vehicles driving (16
  to 6); when one is 2.5 over and another as much under, one vehicle of the
  first starts again on a street of the second - both at least 100 m from
  every player (`_even_traffic`).
- The map's invisible border walls move out to enclose the tiles, and its
  horizon (far ground and towers, which would stand where the tiles are) is
  hidden.
- `main.open_world_node.report()` lists every step with its time,
  `census()` the people, robots and vehicles (all, and those driving) in
  each tile and in the round's map;
  `open_world_node.threaded = false` builds on the main thread instead, to
  compare.

- **Bus lines**: the tile's bus shelters (`<id>.props.json`) become stops
  on the tile's own streets when they first join the graph (`_tile_stops`,
  the map's rule: the nearest street point within 25 m). Whenever streets
  open or close, the buses' round is made again over the map's stops (while
  the map is in) and the open tiles' ones, nearest-next like the map's
  (`_bus_round`); a bus keeps the stop it was making for while it is still
  served. Lines designed in the map editor stay the map's. On the centre
  tile with three neighbours in, the round had 22 stops (13 the map's); a
  bus sent to a stop in a neighbouring tile drove there and stopped.

**Not yet**: occluders, pickups.

**The far view** (`tools/map/far_view.py <world>`): every tile gets a light
model, `<tile>_far.glb` - its buildings as plain boxes (footprint, ground,
height: the same OSM data and hand-set heights the tile is built from), one
colour each from five city tones, on a ground of 25 m squares that follows
the terrain, and the water - 14-91 kB a tile, no textures, no collision.
A ring of two tiles round the world goes into `<world>_far_ring.glb`
(763 buildings, 0.6 MB) with bare ground beyond it, 3 km out to the
horizon, so a roof never looks over the edge of the city into the sky. The
list's `"far"` names the ring. `main.open_world()` loads them all
(`OpenWorld.add_far`, shadows off) and every frame shows a tile's far
model while the tile is not in, the round's map's while the map is out, the
ring all the time. From a roof of the centre tile the city goes on in the
haze past the loaded tiles.

**Multiplayer.** The server runs the robots, the people and the traffic, so
it keeps the tiles in round every player, not only round its own camera
(`_others()`: the players' positions, the nearest counts); a client loads
round its own camera, for what it sees and walks on. The round's map stays
while there are other players. Tested with a host and a client on one
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
antennas are placed by every peer itself, so with other players they stay
in the round's map, the same on every peer.

**The round's own map leaves too** (`_home_check`, one player). Everything
the round's map built hangs under its navigation region: the city and its
collision, the street furniture, the landmarks, the occluders. When the
player is 220 m from its bounds and stands on a tile:

- the city's meshes and collision are freed - that is the memory;
- the rest sleeps where it is: the region hidden, out of the physics, its
  navigation mesh off, and the people, vehicles, pickups, containers and
  antennas inside hidden and stopped (meta `asleep`);
- its streets close like a tile's (traffic entries recomputed, the map's
  share of the traffic no longer wanted), and the links between its mesh
  and the tiles' go off;
- the round's robots left in it go, and the Director sends others where the
  player is. A heavy mech (a goal of the round) or a collector (people
  aboard) keeps the map in;
- `main.home_out` is true and `main.in_world()` no longer counts the map.

The round's state is not the map's: goals, score, the exit, the Director
stay in `main`. At 120 m the city is read and built on threads like a tile
and all of it wakes up as it was - the navigation mesh is not baked again,
a lamp shot out stays out, a parked car is where it was - and links are
made to the tiles that came in meanwhile. `report()` lists it as `@home`.

Measured on the centre tile of the test world, two games open on the
machine: leaving takes 4-6 ms on the main thread and puts 160-190 nodes
to sleep; draw calls 2,260 -> 1,330, nodes 18,000 -> 9,300, static memory
377 -> 326 MB, texture memory 2,940 -> 2,280 MB. Coming back: 130-290 ms
reading and 320-730 ms building on threads, 13-15 ms entering the tree,
22-44 ms for 35 links. Two rounds out and back, with and without the
Director's robots: the map the same as before in the screenshots.

Not done: with more than one player the map stays; the landmarks and the
street furniture sleep in memory instead of leaving.

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
of three; the engine's source calls it a geometry problem). So every mesh,
a tile's and the round's map's, drops its islands after the bake
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
   round's map reads its colliders in 40-55 ms on the main thread and bakes
   for 0.7-0.8 s on a thread; the round's map does not keep its mesh yet.
4. **Bus lines across tiles, breakable props, big landmarks**: done (see
   above). Left: robots shooting a tile's props, its pickups.
5. **The far view, the rest**: its buildings are boxes of one colour; roofs
   and a few windows would carry further. The round's map has no far model
   when it is not a world's tile.
6. **Multiplayer, the rest**: the antennas stay in the round's map with
   other players (the server could place them and tell the clients).
7. **The round's own tile, the rest**: it leaves and comes back now (one
   player), but as itself: its landmarks, street furniture and navigation
   mesh sleep in memory. Every tile equal means the round's map built
   through the tile path from the start, with its breakable props and
   fixed pickups as a tile's.
8. **A tile's files smaller**: 40-90 MB of glb each; the release packages
   and the map editor know nothing of worlds yet (the menu does).

## Bus distance cache

Opening or closing a tile's streets invalidates `bus_routes.gd`'s graph-owned
reverse adjacency and target tables. Replacing the round's graph also drops
the cache. Appending edges has an additional size guard; edits to existing
edge costs, endpoints or one-way flags must explicitly call
`BusRoutes.invalidate(graph)`. The optimisation preserves the previous
routing rules, including consideration of retained tile edges: respecting
closed streets in shortest-distance searches remains a separate behaviour
change. There are at most 32 cached target tables per graph.
