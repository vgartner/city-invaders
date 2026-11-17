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
others: they come and go round the player. The round's own tile never
leaves. Single maps can be registered too: `main.open_world("<id>")`
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
  it; a robot in it keeps the tile until it is gone.
- **Traffic**: the tile's streets (`<id>.roads.json`) join the round's road
  graph, which every vehicle drives by. In tile mode a tile's streets run
  to its very edge, so the neighbour's start at the same points: a node
  where the graph already has one is that node. The ways into the tile's
  streets are open while it is in; when it leaves they close (its edges
  stay in the graph, unreachable, for when it comes back) and the traffic
  in it comes back in at a border street of the map. A vehicle someone
  left in a tile keeps the tile.
- The map's invisible border walls move out to enclose the tiles, and its
  horizon (far ground and towers, which would stand where the tiles are) is
  hidden.
- `main.open_world_node.report()` lists every step with its time,
  `census()` the people and robots in each tile;
  `open_world_node.threaded = false` builds on the main thread instead, to
  compare.

**Not yet**: occluders, pickups, robots and traffic spawned in a tile
(vehicles drive in from the round's map; bus lines and stops stay the
map's), and anything about multiplayer. The round's own map never leaves.

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
edge, and nothing spawns in a tile yet.

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
4. **Traffic and robots spawned by tile**, bus lines across tiles; a
   tile's props breakable like the map's; a big landmark built
   over several frames.
5. **A far view**: low buildings of the tiles that are not loaded.
6. **Multiplayer**: the server keeps the tiles round every player.
7. **The round's own tile leaving too**: today it stays, with its
   navigation mesh, its people and the round's goals; a world needs every
   tile equal, and the round's state (robots to destroy, the exit) apart
   from any one of them.
8. **A tile's files smaller**: 40-90 MB of glb each; the menu, the release
   packages and the map editor know nothing of worlds yet.
