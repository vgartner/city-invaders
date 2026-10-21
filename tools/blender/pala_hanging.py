"""The pala pickup hanging over a wooden rail, so it reads as a poncho from
afar: a 1.4 x 2.0 m wool sheet (texture of the folded pala delivery,
ref/pala_gaucho_*.png) dropped onto the rail with Blender's cloth simulation,
fringes at the two short ends, two posts. Origin on the ground at the centre.

    Blender -b --factory-startup --python tools/blender/pala_hanging.py -- godot/assets/rio_grande_do_sul/pickups/pala/pala.glb
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

out = sys.argv[sys.argv.index("--") + 1]
REF = Path(__file__).resolve().parent / "ref"
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
RAIL_H, W, L = 1.45, 1.4, 2.0          # rail height; cloth width (along the rail) and length
CLOTH_U = 612 / 700                    # the cloth part of the atlas (the rest: a fringe strand)

# ---- the rail and two posts (also the cloth's collider)
def wood():
    m = bpy.data.materials.new("pala_stand_wood")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.32, 0.2, 0.11, 1)
    b.inputs["Roughness"].default_value = 0.8
    return m
wm = wood()
bpy.ops.mesh.primitive_cylinder_add(radius=0.025, depth=W + 0.3, location=(0, 0, RAIL_H), rotation=(0, math.pi / 2, 0))
rail = bpy.context.object
rail.name = "rail"
rail.data.materials.append(wm)
rail.modifiers.new("collision", "COLLISION")
rail.collision.thickness_outer = 0.006
parts = [rail]
for x in (-(W / 2 + 0.12), W / 2 + 0.12):
    bpy.ops.mesh.primitive_cylinder_add(radius=0.03, depth=RAIL_H + 0.05, location=(x, 0, (RAIL_H + 0.05) / 2))
    p = bpy.context.object
    p.data.materials.append(wm)
    parts.append(p)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, 0, 0.02))
    f = bpy.context.object
    f.scale = (0.12, 0.35, 0.04)
    f.data.materials.append(wm)
    parts.append(f)

# ---- the sheet: width along X (the rail), length along Y, laid over the rail
nx, ny = 22, 34
bm = bmesh.new()
uv = bm.loops.layers.uv.new()
verts = [[bm.verts.new((-W / 2 + W * i / nx, -L / 2 + L * j / ny, RAIL_H + 0.05)) for j in range(ny + 1)] for i in range(nx + 1)]
for i in range(nx):
    for j in range(ny):
        f = bm.faces.new((verts[i][j], verts[i + 1][j], verts[i + 1][j + 1], verts[i][j + 1]))
        for lp, (a, b) in zip(f.loops, ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1))):
            lp[uv].uv = (a / nx * CLOTH_U, 1.0 - b / ny)
me = bpy.data.meshes.new("pala_cloth")
bm.to_mesh(me)
cloth = bpy.data.objects.new("pala_cloth", me)
sc.collection.objects.link(cloth)
for p in me.polygons:
    p.use_smooth = True
mat = bpy.data.materials.new("pala_wool")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
img = nt.nodes.new("ShaderNodeTexImage")
img.image = bpy.data.images.load(str(REF / "pala_gaucho_basecolor.png"))
nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
nrm = nt.nodes.new("ShaderNodeTexImage")
nrm.image = bpy.data.images.load(str(REF / "pala_gaucho_normal.png"))
nrm.image.colorspace_settings.name = "Non-Color"
nm = nt.nodes.new("ShaderNodeNormalMap")
nt.links.new(nrm.outputs["Color"], nm.inputs["Color"])
nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
bsdf.inputs["Roughness"].default_value = 0.92
me.materials.append(mat)
sol = cloth.modifiers.new("thick", "SOLIDIFY")
sol.thickness = 0.008
cl = cloth.modifiers.new("cloth", "CLOTH")
cl.settings.quality = 8
cl.settings.mass = 0.6
cl.settings.tension_stiffness = 25
cl.settings.bending_stiffness = 2.0
cl.collision_settings.use_self_collision = False
cl.collision_settings.distance_min = 0.006
cloth.modifiers.move(1, 0)              # cloth before solidify
sc.frame_start, sc.frame_end = 1, 70
cl.point_cache.frame_end = 70
for f in range(1, 71):
    sc.frame_set(f)
bpy.context.view_layer.objects.active = cloth
cloth.select_set(True)
for mod in list(cloth.modifiers):
    bpy.ops.object.modifier_apply(modifier=mod.name)

# ---- fringes: short twisted strands hanging off the two lowest edges
fr = bmesh.new()
fuv = fr.loops.layers.uv.new()
dg = bpy.context.evaluated_depsgraph_get()
low_edge = {}
for v in cloth.data.vertices:
    co = cloth.matrix_world @ v.co
    key = round(co.x / (W / nx))
    side = 1 if co.y > 0 else -1
    if co.z < low_edge.get((key, side), Vector((0, 0, 9))).z:
        low_edge[(key, side)] = co
u0, u1 = 640 / 700, 676 / 700          # the strand image in the atlas
for (key, side), co in low_edge.items():
    if abs(co.x) > W / 2 - 0.01:
        continue
    for k in range(2):
        x = co.x + (k - 0.5) * W / nx * 0.5
        q = [fr.verts.new(c) for c in ((x - 0.006, co.y, co.z + 0.01), (x + 0.006, co.y, co.z + 0.01),
                                        (x + 0.006, co.y, co.z - 0.09), (x - 0.006, co.y, co.z - 0.09))]
        f = fr.faces.new(q)
        for lp, (a, b) in zip(f.loops, ((u0, 0.0), (u1, 0.0), (u1, 0.24), (u0, 0.24))):
            lp[fuv].uv = (a, 1.0 - b)
fme = bpy.data.meshes.new("pala_fringe")
fr.to_mesh(fme)
fringe = bpy.data.objects.new("pala_fringe", fme)
sc.collection.objects.link(fringe)
fmat = mat.copy()
fmat.name = "pala_fringe"
ft = fmat.node_tree
fb = ft.nodes["Principled BSDF"]
fimg = next(n for n in ft.nodes if n.type == "TEX_IMAGE" and n.image and "basecolor" in n.image.name)
ft.links.new(fimg.outputs["Alpha"], fb.inputs["Alpha"])
if hasattr(fmat, "surface_render_method"):
    fmat.surface_render_method = "DITHERED"
fme.materials.append(fmat)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_yup=True, use_selection=True)
lo = min((cloth.matrix_world @ v.co).z for v in cloth.data.vertices)
print("wrote", out, "cloth lowest point", round(lo, 2))
