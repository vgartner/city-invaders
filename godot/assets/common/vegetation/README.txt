CITY INVADERS — VEGETATION STUDY

Geometry is original and reproducible from scripts/vegetation_trees.gd and
scripts/grass_detail.gd. Eight locally seeded tree templates share one RGBA
broadleaf atlas and the existing bark texture. Three crown proportions;
branched trunks, secondary limbs, small twig cards and soft canopy normals.
Each near tree: 1,694 triangles; far: 566 triangles. The prior template was
72 triangles. This is a deliberate geometry/quality trade, not a free FPS gain.
Props keep their trunk colliders, crown hit areas and falling-leaf/shudder IDs.
The two ranges share the same batch reference ID, switching at 60 metres by batch bounds (not per-instance distance).

Grass: opaque, curved, pointed blades (72 triangles per tuft), no collision,
no individual Nodes or shadow pass. MultiMesh cells near the camera, 28 m
shader fade range, at most 6,000 tuft instances per active map/tile. Cells are
recycled as the camera moves; closest missing cells replace farther cached
ones when the cap is reached. Original lawn triangles provide heights; a
world collision query rejects non-grass top surfaces. Indexing and placement
are spread across frames with a 1.8 ms target budget (not a hard realtime
ceiling). The original ground remains; lawn.gdshader keeps its CC0 albedo and
normal textures and adds world-space macro colour variation.

Atlas broadleaf_twigs.png: original 1254 x 1254 RGBA, retained unchanged from
the image-generation output. Four isolated twig fans; alpha-scissor rendering.
It is base colour only; no normal, roughness or photographic source is claimed.
Prompt and creation notes: GENERATION.txt. The atlas is the sole added bitmap.

Licences: project artwork CC BY-SA 4.0, per docs/LICENSING.md.
Existing ground/bark textures retain their credited source licences.
Build/runtime/preview scripts follow the repository's GNU GPL v3 licence.
No ProtonScatter textures, models, shaders or plugin code are incorporated.
The ProtonScatter demo is inspected separately, without executing its code.
