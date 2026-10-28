# Map pipeline: from a real city to a playable map

A map is generated from open data. The Porto Alegre maps are in the
repository (the generated `godot/city/` files and each map's sources in
`maps/<map>/`, the large ones through Git LFS), so a clone plays at once;
the photo downloads and build caches are not (`.gitignore`) and are made
again by a rebuild. A new city is built here, then committed if it should
ship with the game. For an AI agent doing the import, the step-by-step
recipe is in [AGENTS.md](../AGENTS.md#importing-a-new-city).

```
OpenStreetMap ──► osm.json ──┐
Mapillary photos ──► facades.json ──┤
Wikimedia Commons ──► facades_commons.json ──┼──► osm2gltf.py ──► godot/city/<map>.glb
Copernicus DEM ──► terrain.json ──┤                 + .props.json .roads.json
your photos / heights / models ──► user/ ──┘                 + .spawn.json .landmarks.json
```

## Requirements

- Python 3.12+ with `tools/.venv` (`python3 -m venv tools/.venv && tools/.venv/bin/pip install numpy shapely trimesh pillow scipy requests duckdb`)
- Optional, to clean people and cars out of facade photos: a second venv with
  `torch torchvision transformers` (`~/.local/share/city-invaders-ml` in the examples)
- A Mapillary access token in `.env`: `MAPILLARY_TOKEN="MLY|..."` (quote it)
- Blender 5.2 for the model scripts in `tools/blender/` (only to rebuild models)
- Behind a TLS-inspecting proxy set `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`
  and `PIP_CERT` to your proxy's CA bundle

## Quick way: one command

```bash
tools/.venv/bin/python tools/map/new_city.py "Bielefeld, Altstadt" --name bielefeld --size 400 --phases 2
```

geocodes the place (Nominatim), downloads OpenStreetMap and fills missing
footprints from Overture, the terrain, the Mapillary listing (with
`MAPILLARY_TOKEN`), builds the facades and one map per phase (eastwards,
overlapping 60 m, each exit leading to the next), imports them into Godot
and lists them in `godot/city/maps.json`, which the menu reads. The in-game
editor's "Import a new city" runs the same tool. The steps below are what it
does, for doing them by hand.

## 1. Settings per map

Every map has `maps/<map>/build.json` with the export settings, e.g.:

```json
{"osm": "maps/gasometro/data/osm.json", "lat": -30.0341, "lon": -51.2411,
 "bounds": [-150, -200, 250, 200],
 "facades": ["maps/gasometro/facades/facades_clean.json", "maps/gasometro/facades/facades_commons_clean.json"],
 "terrain": "maps/gasometro/data/terrain.json", "textures": "maps/gasometro/out/gasometro_tex",
 "start": [-40, -20], "out": "godot/city/gasometro.glb"}
```

`"user": "maps/poa/user"` lets several maps cut from the same city data share
one folder of hand edits (the Centro phases do). `bounds` are metres from the centre (`[min_x, min_y, max_x, max_y]`, y north);
`half` makes a square instead. Keep maps around 400 x 400 m: bigger maps cost
frame rate.

## 2. Data

```bash
# OpenStreetMap (bbox: west,south,east,north) and conversion to Overpass JSON
curl -o maps/<map>/data/osm.osm "https://api.openstreetmap.org/api/0.6/map?bbox=..."
tools/.venv/bin/python tools/map/osmxml2json.py maps/<map>/data/osm.osm maps/<map>/data/osm.json

# where OSM lacks footprints (small towns): Overture buildings
tools/.venv/bin/python tools/map/overture_buildings.py maps/<map>/data/osm.json --lat .. --lon .. --half 280 \
  --cache maps/<map>/data/overture_buildings.json --out maps/<map>/data/osm_plus.json

# ground heights (Copernicus GLO-30, bare-earth estimate)
tools/.venv/bin/python tools/map/terrain.py --lat .. --lon .. --bounds .. --out maps/<map>/data/terrain.json
```

## 3. Facades

```bash
# street photos -> one texture per street-facing wall (fuses several views)
tools/.venv/bin/python tools/map/mapillary_facades.py maps/<map>/data/osm.json \
  --images maps/<map>/mapillary/images.json --lat .. --lon .. --bounds .. --outdir maps/<map>/facades
# optional: paint out people, cars and poles (SegFormer + LaMa)
~/.local/share/city-invaders-ml/bin/python tools/map/clean_facades.py maps/<map>/facades/facades.json
# landmarks with a Wikidata/Commons photo
tools/.venv/bin/python tools/map/commons_facades.py maps/<map>/data/osm.json --lat .. --lon .. --bounds .. --outdir maps/<map>/facades
~/.local/share/city-invaders-ml/bin/python tools/map/crop_landmarks.py maps/<map>/facades/facades_commons.json
~/.local/share/city-invaders-ml/bin/python tools/map/clean_facades.py maps/<map>/facades/facades_commons.json --name commons_clean
```

`images.json` is the Mapillary `images?bbox=...` listing of the area (several
tiles merged for bigger maps). A building tagged `mapillary=<image id>` in OSM
prefers that photo.

## 4. Your own changes: `maps/<map>/user/`

`tools/map/building_photo.py` keeps everything you add by hand:

```bash
tools/.venv/bin/python tools/map/building_photo.py pick <map> X Z              # which building/wall is at game x, z
tools/.venv/bin/python tools/map/building_photo.py photo <map> '<wall key>' photo.jpg \
    --corners 120,80 1890,140 1870,1300 100,1320 --height 22               # rectified onto the wall
tools/.venv/bin/python tools/map/building_photo.py height <map> way/123456 24
tools/.venv/bin/python tools/map/building_photo.py model <map> way/123456 res://assets/rio_grande_do_sul/landmarks/x.glb
tools/.venv/bin/python tools/map/building_photo.py rebuild <map>               # runs osm2gltf with build.json
```

In the game, design mode (F2) plus the DevAgent `pick_building` tool names
and outlines the wall under the crosshair. Only use photos you took yourself
or that have a free licence (Mapillary CC-BY-SA, Commons); Google Street View
and Google Maps images may not be used.

- `user/facades_user.json` – your rectified photos (override Mapillary)
- `user/buildings_user.json` – per OSM id: `"height"`, `"model"`; plus
  `"_props"`: `[{"model": "res://...", "x": .., "z": .., "yaw": deg, "solid": "box"|true|false}]` (optional `"y"`: an absolute height instead of the ground, e.g. a boat afloat; or `"y_offset"` above the ground, e.g. a musician on a stage - inside a piece listed before it, that piece's height is the base). On a slope a piece stands on the lowest ground under its footprint. OSM points with `amenity` = bicycle_parking / bicycle_rental, telephone, clock, fountain, recycling / waste_disposal become the Porto Alegre bike rack, orelhão, column clock, fountain and orange container (an orelhão at most one every 40 m, and on a promenade or a square against the nearest front, its back to the wall)
  and `"_asphalt"`: `[[x, z], ...]` game points; the generated paving piece
  (plaza or footway strip) under each point is laid as asphalt instead
  and `"_remove"`: `[[x, z], ...]`; a generated prop (tree, lamp, bench) within
  1 m of a point is left out (an OSM tree through a placed model)

## 5. Build and run

```bash
tools/.venv/bin/python tools/map/building_photo.py rebuild <map>
cd godot && godot --headless --path . --import        # import the new glb
./run-godot.sh
```

Add the map to `MAPS` in `godot/scripts/main.gd` to make it a phase.

## What `osm2gltf.py` does

(`tools/map/osmcity.py` is the shared OSM loader: footprints, heights, water, wall keys.)

It also writes `<map>.buildings.json`: every building's OSM id, name,
address, height, base and footprint ring in game coordinates. The game uses
it to know which OSM building is where (map editor, DevAgent `selection`).


- buildings from OSM ways and multipolygons, heights from `height` /
  `building:levels` (untagged: two storeys downtown, one for a house or a
  garage; a kiosk or newsstand, or anything under 15 m², is 3 m); a footprint reaching into the lanes is cut back to the kerb, and a small one (under 60 m²) with nothing but `building=yes` in OSM - no name, address, shop or description - that stands in the lanes or on the kerb, leaving no room for the sidewalk, is left out (parking huts; newsstands become the banca model instead), eroded and de-overlapped; each wall gets its photo, a
  neighbouring wall's photo (short walls) or a tinted procedural facade
- solid infill between buildings so there are no see-through slits (never
  over a photographed facade or into a landmark)
- streets (asphalt, promenades for car-free streets, sidewalks with kerbs,
  zebra crossings, plazas), water with a quay, terrain
- **ground surfaces**: asphalt only on the carriageway - each car street as
  wide as OSM says (`width`, else `lanes` x 3.2 m, else a width by its
  kind, `CARRIAGEWAY_M`, narrower one-way) - and on surface car parks;
  paving on pedestrian ways, squares and pedestrian areas; a raised
  sidewalk only where a building faces a street; everything else (gaps
  between buildings, backs of lots, verges, medians) is grass at the
  ground's own level. Generated buildings reaching into the carriageway are
  cut back to the kerb; OSM street furniture standing on it moves to the
  sidewalk or, without one, to the verge. Parked cars keep the traffic
  lanes free. A car parked in a car park (off the street) gets its way out
  in `.props.json` (`out`: points, `edge`: the street it joins): the
  shortest route over the asphalt - streets, service roads and car parks,
  less the buildings - on a 1 m grid, to within 3 m of a street of the road
  graph (OSM rarely maps the aisles, but the car park is asphalt). A car
  park with no asphalt way to a street (`no_way_out`) gets a car under a
  tarp instead of one you can drive. Street furniture with a front (bus stops, benches, newsstands:
  `faces` in their definition) turns it to its street or walk and keeps off
  the asphalt; nothing generated stands in a model placed by hand
- zebra crossings where OSM has them (`highway=crossing` nodes on a car
  road, unless `crossing=unmarked`); only a map without that data gets one
  near every junction
- the elevation model (30 m, smoothed) slopes places that are level in
  reality: the lots of the hand-made landmarks (the Usina, the Mercado),
  squares, pitches, playgrounds and pedestrian areas become flat platforms
  at the median of the ground under them - a landmark's lot at the level of
  the car streets passing it (`Terrain.street_level`), so the asphalt stays
  flat and the lawn beyond takes the slope - meeting the natural slope over
  30 m (`Terrain.add_platforms`; parks and parking lots keep the slope)
- **streets are level from kerb to kerb and smooth along their length**
  (`Terrain.add_roads`): every street gets a height profile from the ground
  along its centre line (gaussian, sigma 12 m, ends padded so a street
  climbing away from a junction keeps the junction's height); streets that
  cross - or end a few metres short of one another - are bent to agree on
  the crossing's height, the busier street deciding (a footway crossing an
  avenue takes its height, never dents it); the two carriageways of an
  avenue (ways side by side within 22 m) share one height; the ground within 9 m of a centre line takes the
  streets' height (nearby streets blended by nearness), back to the
  terrain by 18 m. `TERRAIN_PROBE="x,z;x,z"` prints the ground there while
  building, to check a spot. OSM buildings follow the ground
  corner by corner; models (storefronts, walk-in shells, landmarks) stand
  at the level of the pavement in front of their door (`Terrain.front`)
- `"ring": true` in `build.json` (`--ring`, on for every map): of the
  blocks the car roads enclose, those well inside the map make the city;
  the traffic keeps inside their outer road loop, so no car route runs into
  the map border (all streets are still drawn). Where the loops cover less
  than a quarter of the map the traffic stays as it was - the map's bounds
  should then be widened to the next road loop out
- paved paths across lawns and parks (OSM footways, paths, cycleways and steps that are not street sidewalks or dirt tracks) drawn as paving
- props from OSM nodes plus generated lamps (on the kerb side of sidewalks only; no two lamps, OSM's own included, closer than 14 m), trees where OSM has them,
  street name signs at corners, stalls and the tram on promenades
- the road graph for traffic, crowd points for pedestrians, a spawn point

## Street audit

`tools/map/street_audit.py <map>` opens a test instance of the game (DevAgent on
port 24691) and drives every street of the traffic graph in thought
(`audit_streets`): every 2 m along each lane, rays down find the surface
and anything on it. It lists, worst first, steps and dents in the asphalt,
too steep (over 14 %) or leaning streets, holes, and buildings, props or
landmarks on a lane, with the street's name and place; the report goes to
`maps/<map>/out/street_audit.json` and the exit code is 1 when a lane is
blocked or has a hole, or when street furniture with a front (`faces`,
docs/ENTITIES.md) turns its back on the street or stands on a lane. `tools/map/new_city.py` runs it after every build
(`--no-audit` to skip). Steep findings on streets that really are steep
(the Centro's hills) are expected; a blocked lane is a hand-placed model to
move in the map editor or a generator rule to fix.

## Example: Lajeado

(The Lajeado map and the other cities outside Porto Alegre were taken out of the
repository on 2026-10-21 to save space; their files are in the git history,
commit before that date. The steps below still show how such a city is built.)

Lajeado is only partly mapped in OSM, so the footprints OSM lacks come from
Overture Maps (Google Open Buildings / Microsoft ML footprints, storeys
guessed where unknown):

```bash
curl -s -o maps/lajeado/data/osm_centro.osm \
  "https://api.openstreetmap.org/api/0.6/map?bbox=-51.96540,-29.47000,-51.95960,-29.46500"
tools/.venv/bin/python tools/map/osmxml2json.py maps/lajeado/data/osm_centro.osm maps/lajeado/data/osm_centro.json
tools/.venv/bin/python tools/map/overture_buildings.py maps/lajeado/data/osm_centro.json \
  --lat -29.4675 --lon -51.9625 --half 280 --cache maps/lajeado/data/overture_buildings.json \
  --out maps/lajeado/data/osm_centro_plus.json
tools/.venv/bin/python tools/map/mapillary_facades.py maps/lajeado/data/osm_centro_plus.json \
  --images maps/lajeado/mapillary/images.json --lat -29.4675 --lon -51.9625 --half 150 \
  --outdir maps/lajeado/facades
~/.local/share/city-invaders-ml/bin/python tools/map/clean_facades.py maps/lajeado/facades/facades.json
tools/.venv/bin/python tools/map/osm2gltf.py maps/lajeado/data/osm_centro_plus.json \
  --lat -29.4675 --lon -51.9625 --half 150 --facades maps/lajeado/facades/facades_clean.json \
  --textures maps/lajeado/out/lajeado_tex --materials godot/assets/materials \
  --start 0 0 --out godot/city/lajeado.glb
```

`images.json` merges the Mapillary `images?bbox=...` list queries of four
tiles (`maps/lajeado/mapillary/tiles/`). The menu offers every city whose
`godot/city/<id>.glb` exists; a joining client loads the host's city.

### Hand-made landmarks: fitting a model

A building's entry in `user/buildings_user.json` can carry a `"model"`
(the landmark that replaces it) and how it sits: `"scale"`, `"yaw_offset"`
(degrees, on top of the footprint's turn), or `"at": [x, z]` with `"yaw"`
(degrees) for a model built in map coordinates (the Usina do Gasômetro).
A model whose materials carry their own textures keeps them; untextured
`*_wall` / `*_base` / `*_brick` materials get the city's plaster and brick.

### Landmarks in parts (`site.json`)

A landmark can come as a set of parts sharing one origin (the plan's centre
on the ground, front -Z): `exterior`, `lod1`, `lod2`, `doors` (leaves with
`*_pivot` hinge markers), `interior_proxy` (a dark volume behind the glass)
and `interior_*` rooms, described by a `site.json` next to them (size,
entrance, each part's file, bounds, collision boxes and markers). The
`"model"` of a building or of a `_props` entry is then that `site.json`;
a `_props` entry of a square picks its parts with `"parts": ["monument"]`.
In the game `godot/scripts/landmark_site.gd` streams it: the silhouette
beyond 230 m, the volume within, the detailed exterior within 85 m; E at
the entrance loads the rooms in the background and opens the doors once
they are in, and walking 85 m away lets them go. The exterior's collision
boxes are there from the start (navmesh, robots, bullets).

The pipeline gives the landmark its real outline: generated buildings it
covers for the most part are cleared, the others trimmed back to its wall
(OSM often maps a porch or an annex as a building of its own), and nothing
generated (trees, benches, stalls) stands inside it.

`rio_grande_do_sul/landmarks/centro_historico/` holds the Centro's set
(CC0 pack): Theatro São Pedro, Casa de Cultura Mario Quintana, MARGS,
Memorial do RS, Paço Municipal, Fonte Talavera, Chalé da Praça XV, Praça da
Alfândega, Catedral Metropolitana, Palácio Piratini and Praça da Matriz -
placed on the centro (which reaches Praça da Matriz), mercado and poa maps -
and the Viaduto Otávio Rocha, not placed yet (a bridge 9 m above Av. Borges
needs the terrain to agree). While its rooms are not loaded a landmark's
windows are dark, nearly opaque glass (the pack's `interior_proxy` box is
not used: on sites with walls set back it covered the walls). The pack embedded one atlas in every
GLB; `tools/map/glb_shared_textures.py` points them all at one shared set in
`centro_historico/textures/` (57 MB instead of ~400 MB, one copy in video
memory).

### Kit facades (in test)

The generated buildings (no photo of their own) are to get facades baked
from the modular architecture kit instead of the painted ones: flat walls
whose maps - base colour, normal, height (parallax) and roughness - come
from the kit's real 3D panels (`godot/assets/common/facades_kit/`, made by
`tools/blender/bake_facades.py`). Three styles by age and height (an old
sobrado, a 1960s residential block, a contemporary one), a street storey
with a door or a shop, storeys of windows, a cornice band at the roof line.
The test block is the Casa de Cultura's (centro map, around x -522, z 120:
43 generated buildings, 7-47 m): `"kit_facades": [-522, 120]` in its
`build.json` (`--kit-facades x,z`, or `all`) - the road block round that
point. Each wall gets a whole number of 3 m bays, the street storey (a
door or a shop), whole storeys of windows and the cornice band at the roof
line, all stretched a little to fit, so no window is cut at a corner and no
storey at the top; the style comes from the height (up to 12 m old, up to
24 m residential, above contemporary), a tint from the shared few. The
game sets the height maps on the `kit_*` materials (`_kit_facades` in
main.gd: deep parallax; `set_kit_parallax(0|1|2)` to compare). Measured
with the simulation paused at full resolution: the parallax costs nothing
visible (145 fps, the cap, in every mode); the new materials add about 250
draw calls - per material, not per building. Balconies, canopies and air conditioners
- which a flat wall cannot show from the side - are meant to stand in front
as real kit pieces, drawn in batches and only near the player.

### Places: what a building is

`godot/assets/place_kinds.json` says which OSM tags make a *place* - fuel
station, pharmacy, hospital, market, restaurant, repair shop - with its
label, the tablet's map pictogram, an item at its door (a role or item id),
a facade sign, and a hand-made model. At import `osm2gltf.py` writes
`<map>.places.json` ([{id, kind, name, at, door, yaw, building}]); a place
whose rule has a model gets it: a fuel station's forecourt (or its small
unnamed shop / canopy building) becomes the Charrua station, facing the
street. In the game the tablet's GPS shows the places, their items wait at
the doors (pharmacy: medicine, market: the small heal, restaurant: the big
one), pharmacies and hospitals get a green cross, and the map editor's
building panel says what the building is. New kinds: add a rule, rebuild.

### The import window (Studio)

Import in the Studio first opens a window with what the new city uses: its
collection (Rio Grande do Sul's for a town there), the item for each role,
an opening film (copied as `video/cities/<city>/intro.ogv`), which kinds of
places get their models and items, and facade photos (Mapillary) on or off.
The defaults are chosen. They go to `tools/map/new_city.py --setup <json>`, which
keeps them in the city's user edits (`_collection`, `_roles`,
`_place_kinds_off`) before the maps are built; the game and the map editor
read them there.

### Shops you can walk into, and captions

A small one-storey pharmacy, market or lancheria (25-260 m², up to 7.5 m;
`interior` in its place kind) becomes a *shell* (`<map>.shells.json`): the
game builds painted walls, a shop window with an open door on the street
side, a sign with the place's name, a light, and the furniture of the
interior set that fits inside.

Names on facades are captions: a model may carry empty nodes named
`caption_*` (where its sign is, facing out); the game writes the place's
name there (`caption` of the landmark: OSM's name, else the kind's
`caption` - FARMÁCIA, POSTO...). So a generic pharmacy or fuel station model
shows the real shop's name instead of a brand.

### Generic storefronts

`godot/assets/common/storefronts/` holds walk-in shops without brands
(pharmacy, market, bakery, bank; fronts of 6, 9 and 12 m, 12 m deep) and a
generic fuel station, all sharing one texture atlas. A place kind's
`storefront` rule puts the widest one that fits into a small shop building
(30-450 m², up to 9 m): on the side facing the street, the rest of the
footprint staying a building. The model's `caption_*` markers get the shop's
OSM name, `sign_cross` the green cross. Street-level modules (4-8 m) for
the ground floor of taller buildings go in front of the facade of a bigger
shop building (its front 0.25 m outside the wall; the building stays). A
storefront collides as one shape of its walls and floor plus a box per
large piece of furniture (a module: one box) - per-mesh collisions of 60
shops cost 20 ms of physics a frame. Beyond 70 m the LOD1 version shows;
a shell or a mech's cannon bursting by one swaps in its damaged version.

In the street a storefront is only its light outside (LOD1, one box). **E at
its door takes you inside**: the full model is built in a *pocket* 150 m
under the city (glass made opaque, a light, a floor) and you stand behind
its door; walking out through the door brings you back to the street. So
modules on a big building's ground floor are shops you enter too. A repair
shop (`shop=electronics|mobile_phone|computer|repair`) is a storefront like
the others (the bank's, with a counter): you trade parts at its counter
inside; a stall counter stands on the sidewalk only where OSM has the shop
without a building.

### The Studio and generated cities

The Studio opens on an empty screen with its menu: *File > Open city* (then
its phases: edit, rebuild, open the folder), *Import a city from
OpenStreetMap...* and *Generate a city...*, each followed by the import
window. A generated city is made-up OSM data from `tools/map/gen_city.py`
(a street grid with named streets and two avenues, a square, a park, lots
with buildings taller towards the centre, shops with names on some ground
floors, a fuel station), built by `tools/map/new_city.py --osm-file` exactly like
an imported town (flat ground, no photos).
