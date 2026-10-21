"""Put the JOHN DEERE lettering (public-domain text logo, ref/) on the
armoured combine delivered as a GLB: on its blank `decal_panel` (right side)
and at the same spot on the left side of the body, found by a ray.

    Blender -b --factory-startup --python tools/blender/harvester_logo.py -- in.glb out.glb
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

src, out = sys.argv[sys.argv.index("--") + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
root = next(o for o in bpy.data.objects if o.parent is None)
panel = bpy.data.objects["decal_panel"]
dg = bpy.context.evaluated_depsgraph_get()

logo = bpy.data.materials.new("john_deere_logo")
logo.use_nodes = True
nt = logo.node_tree
b = nt.nodes["Principled BSDF"]
img = nt.nodes.new("ShaderNodeTexImage")
img.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / "john_deere_text_yellow.png"))
nt.links.new(img.outputs["Color"], b.inputs["Base Color"])
nt.links.new(img.outputs["Alpha"], b.inputs["Alpha"])
b.inputs["Roughness"].default_value = 0.45
if hasattr(logo, "surface_render_method"):
    logo.surface_render_method = "DITHERED"
else:
    logo.blend_method = "CLIP"

# the panel's outer face, in world space (Blender: X right, -Y front, Z up)
corners = [panel.matrix_world @ Vector(c) for c in panel.bound_box]
x_out = max(c.x for c in corners)
cy = sum(c.y for c in corners) / 8
cz = sum(c.z for c in corners) / 8
length = max(c.y for c in corners) - min(c.y for c in corners)
w = length * 0.9
h = w * 176 / 1280                    # the lettering's aspect


def plane(x, side, z):
    bpy.ops.mesh.primitive_plane_add(size=1, location=(x, cy, z), rotation=(math.pi / 2, 0, side * math.pi / 2))
    p = bpy.context.object
    p.name = f"logo_{'r' if side > 0 else 'l'}"
    p.scale = (w, h, 1)
    p.data.materials.append(logo)
    p.parent = root
    p.matrix_parent_inverse = root.matrix_world.inverted()


plane(x_out + 0.004, 1, cz)
# left side: the body surface where a ray from outside first meets it, a
# little higher than on the right (an armour plate covers the panel's height)
zl = cz + 0.2
hit, loc, *_ = bpy.context.scene.ray_cast(dg, Vector((-6.0, cy, zl)), Vector((1, 0, 0)))
if hit:
    plane(loc.x - 0.004, -1, zl)
print("logo: right at x", round(x_out, 3), "left", round(loc.x, 3) if hit else None, "size", round(w, 2), round(h, 2))
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_yup=True, export_animations=False)
