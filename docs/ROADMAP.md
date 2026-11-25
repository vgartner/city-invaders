# Roadmap

## Cities as chains of small maps

A map larger than ~400 x 400 m costs frame rate (every building, prop and
pedestrian is live). Instead of one big Porto Alegre, a **city** becomes a
chain of small maps, one per phase, linked by their exit points:

```
Porto Alegre:  gasometro ──exit east──► centro_historico ──exit north──► mercado_publico ──► ...
```

**Done for Porto Alegre:** `gasometro` -> `centro` -> `mercado` (the last two
cut from the same Centro data, sharing `maps/poa/user` through `"user"` in
their `build.json`; `MAPS` has an exit side column). Still to do: the
`cities/<city>.json` layer and the menu choosing a city.

- Each phase map is generated on its own bounds (`maps/<map>/build.json`),
  so it loads fast and plays smoothly.
- Neighbouring maps share a street at their border: the exit beacon of one
  stands where the next one starts, so walking out of one puts you at the
  matching street corner of the next.
- `MAPS` in `main.gd` already chains phases (`next phase` column); what is
  missing is a city layer: `cities/<city>.json` listing its maps, their
  order and the link points, and the menu choosing a city instead of a map.
- The current `poa` map (500 x 590 m) would split into two or three phases
  (Centro Histórico south / Praça da Alfândega, Mercado / Paço).

## Automatic import of new cities

Today a map needs about ten commands (MAP_PIPELINE.md). The goal is one:

```bash
tools/map/new_city.py "Santa Cruz do Sul, Centro" --size 400 --phases 2
```

which geocodes the place, downloads OSM (plus Overture where OSM lacks
buildings), the Mapillary listing and the terrain, builds the facades, splits
the area into phase maps, writes their `build.json` files and the city file,
and builds the maps. Each step already exists as a tool; it is a matter of
chaining them and picking sensible defaults (bounds, start point, exits).

## A map editor

Generated maps get you 80 % of the way; the rest is hand work: a wrong
height, a missing photo, a landmark model, a monument, where the stalls go.
Options for an editor, from cheapest to most capable:

| Option | What it is | Pros | Cons |
|---|---|---|---|
| **In-game editor (design mode, extended)** | today's F2 mode plus tools: click a building to set its height, drop a photo on a wall, place and move props and models, save to `maps/<map>/user/` | edits where you see them, no extra software, works for everyone who has the game, reuses the existing `user/` format and `building_photo.py` | UI to build in Godot; fine control of shapes is limited |
| **Godot editor plugin** | an `EditorPlugin` that loads a generated map in the Godot editor with gizmos for heights, props and landmarks | Godot's editor gives selection, gizmos, undo, inspector for free | contributors need the Godot editor and must understand it |
| **Blender add-on** | import a map into Blender, edit buildings / props / models there, export the `user/` files | the best modelling tools; landmarks can be modelled in place on their real footprint | Blender is heavy for simple edits; a round trip to the game to test |
| **JOSM / iD (OpenStreetMap editors)** | edit the map data itself: footprints, heights (`height`, `building:levels`), names, trees, shops | fixes go back to OpenStreetMap and help everybody; no editor to write | changes need OSM community rules and time to be accepted; only data, no models or photos |
| **CAD (FreeCAD, LibreCAD, CADCraft)** | precise 2D plans / 3D parts | exact dimensions for façades and interiors | overkill for maps; no notion of the game world; exchange via DXF / glTF only |

**Started:** the in-game editor (design mode + `map_editor.gd`) edits building
heights linked to their OSM ids, sends them to OSM through JOSM, and
rebuilds. Next: photos onto walls, placing props and landmark models,
moving the start and exit points.

**Recommendation:** grow the **in-game editor** first (it builds on design
mode, `selection` and the `user/` files, and anyone can use it), push data
fixes to **OpenStreetMap** with JOSM/iD where they are facts (heights, names,
footprints), and use **Blender** for landmark models and interiors through
the existing scripts. A Godot plugin can come later if contributors ask for
it. CAD tools are useful for exact plans of a building, exported to Blender,
not as the map editor.

## Pedestrians on zebra crossings

Pedestrians walk anywhere on the navmesh, carriageway included (honked at,
they step aside). To make them cross at zebras: bake the carriageway and the
pavements as separate navigation regions and give the carriageway a high
travel cost and the zebra crossings a low one; paths then naturally go
along pavements and over crossings, while a pedestrian fleeing a robot still
runs straight across.

## The paving of the Rua dos Andradas and the Esquina Democrática

Asked for by the owner (November 2026), to do later. Seen on site, the
pedestrian stretch of the Rua dos Andradas and the Esquina Democrática
(Centro Histórico, Porto Alegre) is paved with large light-grey concrete
slabs, roughly 0.6-1 m, with bands of red-brown paving across it, yellow
tactile strips and round manhole covers - and it is one flat surface from
facade to facade: no raised sidewalk, no kerb. The game paves every
pedestrian street with the small setts of `PavingStones138` and lays a
sidewalk along it.

- **A slab material.** The project has none (`godot/assets/materials`:
  `PavingStones138` and `Concrete034` are the nearest). CC0 candidates to
  try, none downloaded yet: Poly Haven's `concrete_tiles`,
  `square_concrete_pavers` and `patterned_concrete_pavers`, and ambientCG's
  larger `PavingStones`/`Tiles` sets (the source of the materials in
  `osm2gltf.py`'s `PBR` table). Credit it in `godot/assets/CREDITS.md`.
- **Which streets get it.** OSM tags these ways `surface=paving_stones`
  (Rua dos Andradas, Esquina Democrática, as `highway=pedestrian`) against
  `surface=sett` on the streets around: the `surface` tag can pick the
  material - `paving_stones` the slabs, `sett` the small stones.
- **No sidewalk there.** A `highway=pedestrian` way paved wall to wall
  takes no sidewalk and no kerb (the pavement between a pedestrian street
  and its facades, MAP_PIPELINE.md, already fills the gap in paving).
- The red bands, the tactile strips and the manhole covers as details
  after that (the map already places manholes).
- Reference photos: Mapillary or Wikimedia Commons only, as for every
  other image (LICENSING.md). Mapillary's photos of these streets are from
  January 2021, before the Quadrilátero Central works (finished in March
  2026): they show the old small pavers with red borders, not today's slabs.

## Sidewalks and asphalt of the Centro's streets

Asked for by the owner (November 2026), to do later, with the paving above.

- **Sidewalks.** On the Rua Riachuelo, as on most of the Centro, the
  sidewalk is of dark grey stone slabs (the basalt slabs usual in Porto
  Alegre): rectangles of uneven sizes, roughly 0.4-0.6 m by 0.6-1 m, laid
  in rows with staggered joints, worn and patched, behind a kerb of long
  stone blocks. The game lays every sidewalk in the same small setts as the
  streets (`sidewalk` and `paving` both use `PavingStones138`). The
  sidewalks need a slab material of their own; whether it is the one for
  the Rua dos Andradas is open: both are rectangular slabs far larger than
  the setts, but the Andradas' are lighter, larger and regular (new
  concrete) and the sidewalks' darker and uneven (old stone). Two materials,
  or one with two tints, to be decided when trying them.
- **Asphalt.** The streets' asphalt is a light, worn grey with the stones
  of the mix showing, patches and manhole covers - lighter and less even
  than `Asphalt031` as the game shows it. To try: a lighter tint, or
  another CC0 asphalt (worn, patched).
- Mapillary has only 2019 photos of the Riachuelo (through a wet
  windscreen): no use for the texture, and none of these can be a texture
  source anyway - the materials come from CC0 libraries.

## One-way streets

Done in the pipeline (November 2026, [MAP_PIPELINE.md](MAP_PIPELINE.md),
road markings); a map shows it once it is rebuilt - the open-world test
tiles are, the four maps in the repository are not yet.

- **Markings.** The white dashed line is drawn only between the lanes of a
  one-way street with two or more (`lanes`); a one-way street of one lane
  has none (112 of the Centro's one-way streets).
- **Direction.** `oneway=-1` is read, and a piece of a street cut at the
  map's or a tile's edge keeps the street's direction (none of the test
  world's pieces came back turned). In a round on the test world, 469
  readings of cars moving on one-way streets were all with the street; a
  car whose street ends at the edge of what is loaded does not turn back,
  it comes in again elsewhere.

## Other ideas

- the Farmácias São João shop front from a real photo; more enterable buildings
- more cities of the interior (Lajeado, Santa Cruz do Sul, Caxias do Sul, Pelotas)
- a Laçador scan (the UFRGS LDSM laser scan, if its licence allows)
- weather and night (lamps already light up)
