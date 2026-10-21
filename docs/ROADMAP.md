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

## Other ideas

- the Farmácias São João shop front from a real photo; more enterable buildings
- more cities of the interior (Lajeado, Santa Cruz do Sul, Caxias do Sul, Pelotas)
- a Laçador scan (the UFRGS LDSM laser scan, if its licence allows)
- weather and night (lamps already light up)
