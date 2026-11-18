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
godot --headless --path godot --import
DEVAGENT_PORT=24691 tools/devagent/devagent.py launch
DEVAGENT_PORT=24691 tools/devagent/devagent.py start_solo map=centro_world_1_1
```

`tiles.py` cuts the area (metres from the source map's centre, y north)
into tiles of 250 m (`--size`), writes `maps/<name>_<column>_<row>/build.json`
for each (the source map's data, photos and hand edits, `"tile": true`),
builds them and lists them in `godot/city/<name>.world.json`. A round
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
  thread. They leave with the tile. A tile's props are scenery with
  collision: a lamp there cannot be shot out or knocked over, and its
  pickups and the map editor's edits are not applied.
- **Navigation**: after that the tile gets a navigation mesh of its own. Its
  colliders are read (1 ms), the mesh is baked on a thread
  (`NavigationServer3D.bake_from_source_geometry_data_async`, 0.1 s for a
  250 m tile) and added as a region of the same map. Two meshes baked apart
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

**Not yet**: occluders, pickups, dropships landing in a tile, bus lines
and stops (they stay the map's), and anything about multiplayer.

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

Not done: with more than one player the map stays; a dropship cannot land
and no container is delivered while the player is outside the map (those
still pick spots by the map's bounds); the landmarks and the street
furniture sleep in memory instead of leaving.

Seen in these tests and not looked into: with robots alive and the player
teleported 400 m at a time, Godot's path search reports "It's not expect
to not find the most reachable polygons" now and then - also in a run
where the map never left.

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
pieces, costs one frame of 170 ms - the worst frame of each of three runs
(174-180 ms). Building a set a few pieces a frame is still to do.

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
2. **Edges, the rest.** A tile does not know the neighbouring tile's
   buildings that reach over the edge: its trees and props may stand inside
   one, and a wall facing one gets windows instead of a blind wall.
3. **Navigation, the rest.** The round's map still bakes its mesh at load,
   on the main thread (most of the loading time): every tile, the first
   one too, should bake on a thread or come with its mesh baked.
4. **Bus lines across tiles**, dropships landing in a tile; a tile's props
   breakable like the map's; a big landmark built over several frames.
5. **A far view**: low buildings of the tiles that are not loaded.
6. **Multiplayer**: the server keeps the tiles round every player.
7. **The round's own tile, the rest**: it leaves and comes back now (one
   player), but as itself: its landmarks, street furniture and navigation
   mesh sleep in memory. Every tile equal means the round's map built
   through the tile path from the start, with its breakable props and
   fixed pickups as a tile's.
8. **A tile's files smaller**: 40-90 MB of glb each; the menu, the release
   packages and the map editor know nothing of worlds yet.

## Bus distance cache

Opening or closing a tile's streets invalidates `bus_routes.gd`'s graph-owned
reverse adjacency and target tables. Replacing the round's graph also drops
the cache. Appending edges has an additional size guard; edits to existing
edge costs, endpoints or one-way flags must explicitly call
`BusRoutes.invalidate(graph)`. The optimisation preserves the previous
routing rules, including consideration of retained tile edges: respecting
closed streets in shortest-distance searches remains a separate behaviour
change. There are at most 32 cached target tables per graph.
