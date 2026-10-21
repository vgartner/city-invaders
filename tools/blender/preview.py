"""Render GLBs side by side for a quick look.

    Blender -b --factory-startup --python tools/blender/preview.py -- out.png a.glb b.glb ...
"""
import math
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
out, files = args[0], args[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
x = 0.0
centres = []
for f in files:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=f)
    objs = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
    lo = Vector((1e9, 1e9, 1e9))
    hi = -lo
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    size = max(hi - lo)
    shift = Vector((x - (lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    for o in [o for o in bpy.data.objects if o not in before and o.parent is None]:
        o.location += shift
    centres.append((x, size, hi.z - lo.z))
    x += max(hi.x - lo.x, size) * 1.3
span = x
h = max(c[2] for c in centres)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
bpy.context.scene.collection.objects.link(cam)
target = Vector((span / 2 - centres[0][1] * 0.6, 0, h * 0.4))
import os
view = Vector(tuple(float(v) for v in os.environ.get("PREVIEW_VIEW", "0,-1,0.75").split(",")))
cam.location = target + view.normalized() * span * 1.15 * float(os.environ.get("PREVIEW_DIST", "1"))
cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
bpy.context.scene.camera = cam
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 4
sun.rotation_euler = (math.radians(50), 0, math.radians(30))
bpy.context.scene.collection.objects.link(sun)
bpy.ops.mesh.primitive_plane_add(size=span * 6, location=(span / 2, 0, 0))
w = bpy.context.scene.world = bpy.data.worlds.new("w")
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.6, 0.65, 0.72, 1)
w.node_tree.nodes["Background"].inputs[1].default_value = 0.8
s = bpy.context.scene
s.render.engine = "BLENDER_EEVEE"
s.render.resolution_x, s.render.resolution_y = 1200, 600
s.render.filepath = out
bpy.ops.render.render(write_still=True)
