# Facade tiles baked from the modular kit

Baked by `tools/blender/bake_facades.py` from the modular architecture kit
(CC0, see LICENSE.txt): each tile is assembled from the kit's real 3D panels
and rendered straight on into base colour, normal (tangent space, OpenGL),
height (white = out, the wall at 0.71, glass set 0.18 m back) and roughness,
at 80 px/m. The base colour's alpha is the wall mask (255 = the painted wall):
the map pipeline repaints the wall in a building's colour. Every tile is two 3 m bays wide and repeats without a seam.

| Tile | Size (m) | What |
|---|---|---|
| `<style>_upper` | 6 x 2 storeys | two storeys of windows |
| `<style>_ground` | 6 x 1 storey | the street storey: a door and a window |
| `<style>_shop` | 6 x 1 storey | a shop door (glass or a steel shutter), a shop window, a canopy |
| `<style>_top` | 6 x 2.5 | the roof line: cornice and parapet |

Styles (recipes over the kit's three panel families, `STYLES` in the bake
script): `antigo` and `ecletico` (3.6 m storeys); `residencial`, `sacada`,
`contemporaneo` and `comercial` (3.2 m).
The map pipeline's use of them (a test block first) is described in
docs/MAP_PIPELINE.md.
