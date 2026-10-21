# Facade tiles baked from the modular kit

Baked by `tools/blender/bake_facades.py` from the modular architecture kit
(CC0, see LICENSE.txt): each tile is assembled from the kit's real 3D panels
and rendered straight on into base colour, normal (tangent space, OpenGL),
height (white = out, the wall at 0.71, glass set 0.18 m back) and roughness,
at 80 px/m. Every tile is two 3 m bays wide and repeats without a seam.

| Tile | Size (m) | What |
|---|---|---|
| `<style>_upper` | 6 x 2 storeys | two storeys of windows |
| `<style>_ground` | 6 x 1 storey | the street storey: a door and a window |
| `<style>_shop` | 6 x 1 storey | a glass door, a shop window, a canopy |
| `<style>_top` | 6 x 2.5 | the roof line: cornice and parapet |

Styles: `antigo` (3.6 m storeys), `residencial` and `contemporaneo` (3.2 m).
The map pipeline's use of them (a test block first) is described in
docs/MAP_PIPELINE.md.
