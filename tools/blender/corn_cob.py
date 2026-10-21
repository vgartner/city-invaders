"""A corn cob (espiga de milho) for the armoured harvester's cannon: rows of
yellow kernels on a tapered core, a few dry husk leaves at the stem end.
About 20 cm long, along -Z (the way it flies), origin at its centre.

    Blender -b --factory-startup --python tools/blender/corn_cob.py -- out.glb
(superseded in the game by the modelled war/corn/espiga_milho.glb)
"""
import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

out = sys.argv[sys.argv.index("--") + 1]
random.seed(3)
bpy.ops.wm.read_factory_settings(use_empty=True)


def mat(name, colour, rough):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*colour, 1)
    b.inputs["Roughness"].default_value = rough
    return m


L, R = 0.2, 0.024                     # length, radius at the middle
kern = bmesh.new()
rows, rings = 14, 22
for i in range(rings):
    t = i / (rings - 1)
    y = -L / 2 + t * L
    r = R * (0.75 + 0.45 * math.sin(math.pi * min(1.0, t * 1.1)) - 0.25 * t)   # thicker near the stem
    for j in range(rows):
        a = (j + 0.5 * (i % 2)) / rows * math.tau
        p = Vector((math.cos(a) * r, y, math.sin(a) * r))
        s = 0.0055 * random.uniform(0.85, 1.1) * (0.6 + 0.4 * r / R)
        M = Matrix.Translation(p) @ Matrix.Rotation(a, 4, "Y") @ Matrix.Diagonal((s, s * 1.15, s * 0.9, 1))
        bmesh.ops.create_icosphere(kern, subdivisions=1, radius=1.0, matrix=M)
core = bmesh.new()
bmesh.ops.create_cone(core, cap_ends=True, segments=12, radius1=R * 0.95, radius2=R * 0.5, depth=L,
                      matrix=Matrix.Rotation(math.pi / 2, 4, "X"))
husk = bmesh.new()
for k in range(4):                    # dry leaves peeled back at the stem end (+Y)
    a = k / 4 * math.tau + 0.4
    v = [husk.verts.new(Vector(c)) for c in ((-0.012, 0, 0), (0.012, 0, 0), (0.016, 0.07, 0.012), (-0.004, 0.09, 0.02))]
    husk.faces.new(v)
    bmesh.ops.transform(husk, matrix=Matrix.Translation((0, L / 2 - 0.01, 0)) @ Matrix.Rotation(a, 4, "Y")
                        @ Matrix.Translation((0, 0, R)) @ Matrix.Rotation(0.5, 4, "X"), verts=v)
objs = []
for name, bm, m in (("kernels", kern, mat("corn_kernel", (0.95, 0.72, 0.12), 0.45)),
                    ("core", core, mat("corn_core", (0.85, 0.7, 0.4), 0.8)),
                    ("husk", husk, mat("corn_husk", (0.78, 0.68, 0.45), 0.9))):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(m)
    bpy.context.scene.collection.objects.link(ob)
    for p in me.polygons:
        p.use_smooth = name != "husk"
    objs.append(ob)
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_yup=True)
print("wrote", out)
