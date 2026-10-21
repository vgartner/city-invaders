"""Put a livery (tools/assets/truck_livery.py images) on an assembled truck of the
unbranded truck family and export the game model.

    Blender -b --factory-startup --python tools/blender/brand_truck.py -- truck.glb livery_dir out.glb
"""
import sys
from pathlib import Path

import bpy

src, livery, out = sys.argv[sys.argv.index("--") + 1:][:3]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
n = 0
for mat in bpy.data.materials:
    name = mat.name.split(".")[0]
    png = Path(livery) / f"{name}.png"
    if not name.startswith("livery_") or not png.exists() or not mat.node_tree:
        continue
    nt = mat.node_tree
    bsdf = next(nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(png))
    for link in list(bsdf.inputs["Base Color"].links):
        nt.links.remove(link)
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    n += 1
print("livery on", n, "materials")
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_yup=True, export_animations=False)
