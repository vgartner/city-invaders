# Open world (prototype)

Today a round plays on one map: a square of about 400 m, built by the
pipeline into one model (`godot/city/<map>.glb`, 90-170 MB), loaded whole
with its collision, navigation mesh, props, people and traffic. This page
is about going past that: a city of many **tiles** that come in and go out
round the player. So far it is a prototype that answers the first question
- can a neighbouring tile enter and leave a running round without the
player feeling it?

## What the prototype does

`godot/scripts/open_world.gd`. With a round running on one map, other maps
of the same source and frame are registered as tiles:

```bash
DEVAGENT_PORT=24691 tools/devagent/devagent.py eval 'expr=main.open_world("owb")'
godot --path godot -- --devagent --open-world=owb      # or from the command line
```

- A tile is known by its bounds (`<id>.spawn.json`). When the player comes
  within 120 m of them (`LOAD_M`) the tile's `<id>.glb` and
  `<id>_collision.glb` are read on a loader thread
  (`ResourceLoader.load_threaded_request`), its scene and collision shapes
  are built on a worker thread, and one frame puts it into the tree. Beyond
  220 m (`UNLOAD_M`) it is freed.
- The map's invisible border walls move out to enclose the tiles, and its
  horizon (far ground and towers, which would stand where the tiles are) is
  hidden.
- `main.open_world_node.report()` lists every step with its time;
  `open_world_node.threaded = false` builds on the main thread instead, to
  compare.

A tile brings its streets, buildings and collision only. **Not yet**: the
navigation mesh (so no people, robots or traffic there), props (trees,
lamps, benches), landmarks, occluders, pickups, and anything about
multiplayer. The round's own map never leaves.

## The test tiles

Two tiles cut from the Centro's sources, sharing an edge (z = -100):

```bash
tools/.venv/bin/python tools/map/building_photo.py rebuild owa    # 350 x 250 m, the round's map
tools/.venv/bin/python tools/map/building_photo.py rebuild owb    # its northern neighbour
godot --headless --path godot --import
```

`maps/owa/build.json` and `maps/owb/build.json` are in the repository; the
built files (`godot/city/owa*`, `owb*`, about 95 and 72 MB) are not.

## What it showed (November 2026)

One run on a MacBook M3 Max that was swapping at the time, so the frame
times are rough - to be repeated on a quiet machine:

| | |
|---|---|
| Reading the tile's files (loader thread) | 0.9 s |
| Building scene and collision (worker thread) | 0.2-0.3 s |
| The frame that puts it into the tree | 12-14 ms |
| Worst frame while a tile came in, built on a worker thread | 59-200 ms over four runs |
| Worst frame, built on the main thread | 156 ms |
| Texture memory, one tile more | about +0.8 GB (5.4 to 6.3 GB), given back when it leaves |

The streets continue across the edge, the player walks from one tile into
the other, and `errors` stays empty through four rounds of loading and
unloading. The step on the main thread is small; the remaining hitches come
from elsewhere (uploading the tile's textures and meshes to the GPU is the
first suspect) and need a profile.

## What an open world still needs

1. **Smaller tiles and less texture.** A 350 x 250 m tile holds 0.8 GB of
   textures, most of it one photo per building. Kit facades
   ([MAP_PIPELINE.md](MAP_PIPELINE.md)) cost a building only its footprint,
   height, style and colour: tiles of about 250 m with photos kept for the
   main streets and the landmarks.
2. **Clean edges.** The pipeline cuts a building at the tile's edge and
   keeps 3 m free inside it (`EDGE_MARGIN_M`): a building belongs whole to
   the tile its centre is in, and streets are cut exactly at the edge.
3. **Navigation by tile**: a navigation region per tile, linked at the
   edges, baked when the tile is built instead of at load.
4. **People, traffic, robots, props and landmarks by tile**, with the road
   graph joined across tiles.
5. **A far view**: low buildings of the tiles that are not loaded.
6. **Multiplayer**: the server keeps the tiles round every player.
7. **The pipeline in tiles**: one command that cuts a city into a grid and
   a list of tiles the game reads.
