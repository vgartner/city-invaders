"""Brand the unbranded petrol station delivery: put the livery images
(tools/assets/charrua_livery.py) on its brand_* materials and export the game model.
Fascia and shop-sign strips have their UV band stretched over the whole
(long) image; the other surfaces use their delivered UV rectangles.

    Blender -b --factory-startup --python tools/blender/brand_station.py -- \\
        station_unbranded.glb branding_manifest.json livery_dir out.glb
"""
import json
import sys
from pathlib import Path

import bpy

src, manifest, livery, out = sys.argv[sys.argv.index("--") + 1:][:4]
rects = json.loads(Path(manifest).read_text())
STRIPS = ("brand_canopy_front", "brand_canopy_back", "brand_canopy_left", "brand_canopy_right", "brand_shop_sign")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

for mat in bpy.data.materials:
    name = mat.name.split(".")[0]
    png = Path(livery) / f"{name}.png"
    if not name.startswith("brand_") or not png.exists():
        continue
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(png))
    for link in list(bsdf.inputs["Base Color"].links):
        nt.links.remove(link)
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    if name in STRIPS:
        u0, v0, u1, v1 = rects[name]["rectangles"][0]
        lo, hi = 1.0 - v1, 1.0 - v0                 # Blender UVs: origin bottom-left
        for ob in bpy.data.objects:
            if ob.type != "MESH" or mat.name not in [m.name for m in ob.data.materials if m]:
                continue
            slot = [m.name if m else "" for m in ob.data.materials].index(mat.name)
            uv = ob.data.uv_layers.active.data
            for poly in ob.data.polygons:
                if poly.material_index != slot:
                    continue
                for li in poly.loop_indices:
                    u, v = uv[li].uv
                    uv[li].uv = (1.0 - u, (v - lo) / (hi - lo))     # the strips run right to left
    print("branded", name)

bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_yup=True, export_animations=False)
