"""Gaúcho pickups for City Invaders, built procedurally in Blender:
espeto de churrasco (big heal), chimarrão (small heal) and a pala (armour).

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        --python tools/blender/pickups_gaucho.py -- godot/assets/common/pickups

Each model: metres, +Y up in glTF (Blender Z up), front -Z, origin on the
ground at the centre, ~0.5-0.8 m across.
"""
import math
import random
import sys
from pathlib import Path

import bmesh
import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402
from mathutils import Vector

OUT = Path(sys.argv[sys.argv.index("--") + 1])
random.seed(7)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mat(name, colour, rough=0.6, metal=0.0, sss=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*colour, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


def add(obj, m):
    obj.data.materials.append(m)
    return obj


def smooth(obj, level=1):
    for p in obj.data.polygons:
        p.use_smooth = True
    if level:
        mod = obj.modifiers.new("sub", "SUBSURF")
        mod.levels = mod.render_levels = level


def bevel(obj, w=0.004, seg=2):
    mod = obj.modifiers.new("bev", "BEVEL")
    mod.width = w
    mod.segments = seg


def cube(name, size, loc, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    return o


def cyl(name, r, depth, loc, rot=(0, 0, 0), verts=24, r2=None):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r if r2 is None else r2,
                                    depth=depth, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    return o


def jitter(obj, amount):
    for v in obj.data.vertices:
        v.co += Vector((random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1))) * amount


def export(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True)
    print("wrote", path)


# ---- costela fogo de chão on its espeto (reference: Commons
# "Costela de Chao 2 fogos"): a whole rib slab, golden with charred patches,
# speared on an iron stake planted in the ground ----------------------------
def costela():
    bu.reset()
    iron = bu.principled("iron", (0.12, 0.11, 0.1), 0.55, 1.0)
    bone = bu.principled("bone", (0.82, 0.74, 0.6), 0.55)
    W, H, T = 0.46, 0.56, 0.06
    z0 = 0.42                                  # bottom of the slab above the ground
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=46, y_subdivisions=56, size=1, location=(0, 0, 0))
    slab = bpy.context.object
    slab.name = "costela"
    slab.scale = (W, H, 1)
    bpy.ops.object.transform_apply(scale=True)
    # irregular outline: trim the corners and one ragged edge
    bm = bmesh.new()
    bm.from_mesh(slab.data)
    kill = []
    for v in bm.verts:
        x, y = v.co.x / (W / 2), v.co.y / (H / 2)
        edge = 0.86 + 0.08 * math.sin(y * 7) + 0.05 * math.sin(x * 11)
        if abs(x) ** 3 + abs(y) ** 3 > edge ** 3 or (y > 0.8 and x > 0.45 - 0.2 * (y - 0.8)):
            kill.append(v)
    bmesh.ops.delete(bm, geom=kill, context="VERTS")
    # rib ridges across the slab and a meaty bulge in the middle
    for v in bm.verts:
        x, y = v.co.x / (W / 2), v.co.y / (H / 2)
        v.co.z = 0.012 * math.cos(y * 7 * math.pi / 2) ** 2 + 0.015 * (1 - x * x) * (1 - y * y) \
            + random.uniform(-0.002, 0.002)
    bm.to_mesh(slab.data)
    bm.free()
    sol = slab.modifiers.new("thick", "SOLIDIFY")
    sol.thickness = T
    sol.offset = 0
    tex = bpy.data.textures.new("lumps", "CLOUDS")
    tex.noise_scale = 0.06
    disp = slab.modifiers.new("lumps", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.012
    sub = slab.modifiers.new("sub", "SUBSURF")
    sub.levels = 1
    slab.data.materials.append(bu.meat("costela"))
    for poly in slab.data.polygons:
        poly.use_smooth = True
    # stand it up (slab in the XZ plane), facing -Y
    slab.rotation_euler = (math.pi / 2, 0, 0)
    slab.location = (0, 0, z0 + H / 2)
    bpy.ops.object.select_all(action="DESELECT")
    slab.select_set(True)
    bpy.context.view_layer.objects.active = slab
    bpy.ops.object.convert(target="MESH")
    bu.bake(slab, 1024)
    # rib bone ends sticking out of the left edge, bone faces on the back
    for i in range(7):
        zb = z0 + 0.07 + i * (H - 0.14) / 6
        bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=0.011, depth=0.09,
                                            location=(-W / 2 + 0.06, 0.0, zb), rotation=(0, math.pi / 2, 0))
        b_ = bpy.context.object
        b_.scale = (1, 1.5, 1)
        b_.data.materials.append(bone)
    # the espeto: iron stake through the slab, cross piece, planted in the ground
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.009, depth=1.12, location=(0, -0.002, 0.52))
    bpy.context.object.data.materials.append(iron)
    bpy.ops.mesh.primitive_cone_add(vertices=12, radius1=0.009, radius2=0, depth=0.05, location=(0, -0.002, 1.105))
    bpy.context.object.data.materials.append(iron)
    bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=0.006, depth=W * 0.9, location=(0, 0.035, z0 + H * 0.62),
                                        rotation=(0, math.pi / 2, 0))
    bpy.context.object.data.materials.append(iron)
    # scorched earth disc where it stands
    bpy.ops.mesh.primitive_circle_add(vertices=24, radius=0.12, fill_type="NGON", location=(0, 0, 0.003))
    bpy.context.object.data.materials.append(bu.principled("earth", (0.12, 0.09, 0.07), 0.95))
    export(OUT / "churrasco" / "churrasco.glb")


# ---- chimarrão: porongo cuia (reference: Commons "Chimarrão na cuia
# paysanita"), erva rente à boca, bomba de alpaca, and the thermos ---------------
def chimarrao():
    bu.reset()
    alpaca = bu.principled("alpaca", (0.8, 0.79, 0.76), 0.22, 1.0)
    erva = bu.principled("erva", (0.16, 0.27, 0.05), 0.95)
    foam = bu.principled("espuma", (0.42, 0.48, 0.2), 0.8)
    # porongo profile (radius, height): round belly, waist, flared mouth
    prof = [(0.0, 0.0), (0.03, 0.002), (0.052, 0.014), (0.063, 0.038), (0.064, 0.06), (0.058, 0.082),
            (0.047, 0.1), (0.041, 0.113), (0.042, 0.123), (0.045, 0.13)]
    bm = bmesh.new()
    verts = [bm.verts.new((r, 0, z)) for r, z in prof]
    for a, b in zip(verts[:-1], verts[1:]):
        bm.edges.new((a, b))
    bmesh.ops.spin(bm, geom=bm.verts[:] + bm.edges[:], cent=(0, 0, 0), axis=(0, 0, 1),
                   angle=math.tau, steps=48, use_duplicate=False)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    me = bpy.data.meshes.new("cuia")
    bm.to_mesh(me)
    bm.free()
    cuia = bpy.data.objects.new("cuia", me)
    bpy.context.scene.collection.objects.link(cuia)
    for v in me.vertices:                       # a gourd is never perfectly round
        v.co.x *= 1.0 + 0.04 * math.sin(v.co.z * 40)
        v.co.y *= 0.97
    cuia.modifiers.new("shell", "SOLIDIFY").thickness = 0.004
    cuia.modifiers.new("sub", "SUBSURF").levels = 1
    for p_ in me.polygons:
        p_.use_smooth = True
    me.materials.append(bu.gourd("porongo"))
    bpy.ops.object.select_all(action="DESELECT")
    cuia.select_set(True)
    bpy.context.view_layer.objects.active = cuia
    bpy.ops.object.convert(target="MESH")
    bu.bake(cuia, 1024)
    # erva up to the mouth, a little mound on one side, foam where the water goes
    bpy.ops.mesh.primitive_circle_add(vertices=40, radius=0.043, fill_type="NGON", location=(0, 0, 0.126))
    e = bpy.context.object
    for v in e.data.vertices:
        v.co.z += 0.006 * max(0.0, v.co.x / 0.043) + random.uniform(-0.0008, 0.0008)
    e.data.materials.append(erva)
    bpy.ops.mesh.primitive_circle_add(vertices=20, radius=0.014, fill_type="NGON", location=(-0.014, 0.004, 0.1265))
    bpy.context.object.data.materials.append(foam)
    # bomba: straight tube from the bottom, bent near the top towards the drinker
    curve = bpy.data.curves.new("bomba", "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = 0.0042
    curve.bevel_resolution = 3
    sp = curve.splines.new("BEZIER")
    sp.bezier_points.add(2)
    pts = [(-0.012, 0, 0.03), (0.012, 0, 0.215), (0.045, 0, 0.255)]
    for bp, co in zip(sp.bezier_points, pts):
        bp.co = co
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    bomba = bpy.data.objects.new("bomba", curve)
    bpy.context.scene.collection.objects.link(bomba)
    curve.materials.append(alpaca)
    # alpaca rim on the mouth
    bpy.ops.mesh.primitive_torus_add(major_radius=0.045, minor_radius=0.0028, location=(0, 0, 0.13))
    bpy.context.object.data.materials.append(alpaca)
    # thermos beside it
    steelm = bu.principled("inox", (0.75, 0.75, 0.77), 0.3, 1.0)
    cap = bu.principled("tampa", (0.05, 0.05, 0.06), 0.5)
    tx = 0.15
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=0.047, depth=0.29, location=(tx, 0.05, 0.145))
    t = bpy.context.object
    t.modifiers.new("bev", "BEVEL").width = 0.008
    t.data.materials.append(steelm)
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.034, depth=0.05, location=(tx, 0.05, 0.315))
    bpy.context.object.data.materials.append(cap)
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.011, depth=0.035, location=(tx - 0.03, 0.05, 0.32),
                                        rotation=(0, math.radians(65), 0))
    bpy.context.object.data.materials.append(cap)
    export(OUT / "chimarrao" / "chimarrao.glb")


# ---- poncho (after the user's photo): grey herringbone wool with a striped
# chest band, folded collar, fringed hem, hanging on a shoulder stand ---------------
def pala():
    reset()
    wool = bpy.data.materials.new("poncho_wool")
    wool.use_nodes = True
    nt = wool.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = 0.95
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / "poncho_wool.png"))
    tex.image.pack()
    nt.links.new(tex.outputs["Color"], b.inputs["Base Color"])
    fringe = mat("fringe", (0.12, 0.1, 0.09), 0.95)
    collar_m = mat("collar", (0.42, 0.4, 0.38), 0.95)
    wood = mat("stand", (0.3, 0.18, 0.09), 0.7)
    add(cyl("post", 0.025, 1.5, (0, 0, 0.75), verts=12), wood)
    for rz in (0, math.pi / 2):
        add(cube("foot", (0.5, 0.05, 0.04), (0, 0, 0.02), rot=(0, 0, rz)), wood)
    # the drape: a loft of rounded rings from the shoulders (narrow, flat) to the
    # hem (wide), sagging between the shoulders and cut with a V at the neck
    top, hem = 1.45, 0.3
    rings, n = 14, 64
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new()
    grid = []
    for r in range(rings + 1):
        t = r / rings
        z = top - t * (top - hem)
        half_w = 0.2 + 0.46 * min(1.0, t / 0.16) ** 0.5 + 0.04 * t   # broad square shoulders, then straight down
        half_d = 0.14 + 0.1 * min(1.0, t / 0.16) ** 0.5 + 0.03 * t
        row = []
        for k in range(n):
            a = k / n * math.tau
            cx, cy = math.cos(a), math.sin(a)
            x = half_w * math.copysign(abs(cx) ** 0.35, cx)
            y = half_d * math.copysign(abs(cy) ** 0.35, cy)
            sag = 0.06 * min(1.0, t / 0.16) * abs(cx) * (1 - t)                # shoulders lower than the neck
            fold = 0.012 * math.sin(a * 9) * t            # soft vertical folds lower down
            row.append(bm.verts.new((x * (1 + fold), y * (1 + fold), z - sag)))
        grid.append(row)
    for r in range(rings):
        for k in range(n):
            f = bm.faces.new((grid[r][k], grid[r][(k + 1) % n], grid[r + 1][(k + 1) % n], grid[r + 1][k]))
            for lp, (u, v) in zip(f.loops, ((k / n, 1 - r / rings), ((k + 1) / n, 1 - r / rings),
                                            ((k + 1) / n, 1 - (r + 1) / rings), (k / n, 1 - (r + 1) / rings))):
                lp[uv_layer].uv = (u * 2.0, v)
    me = bpy.data.meshes.new("poncho")
    bm.to_mesh(me)
    bm.free()
    poncho = bpy.data.objects.new("poncho", me)
    bpy.context.scene.collection.objects.link(poncho)
    me.materials.append(wool)
    poncho.modifiers.new("thick", "SOLIDIFY").thickness = 0.012
    for p_ in me.polygons:
        p_.use_smooth = True
    # folded collar standing round the neck, a leather V at the front
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.13, depth=0.07, location=(0, 0, top + 0.01),
                                        end_fill_type="NOTHING")
    c = bpy.context.object
    c.scale = (1.15, 0.9, 1)
    c.modifiers.new("thick", "SOLIDIFY").thickness = 0.02
    add(c, collar_m)
    add(cube("v_neck", (0.12, 0.01, 0.16), (0, -0.155, top - 0.08)), mat("leather", (0.25, 0.14, 0.08), 0.7))
    # fringes all round the hem
    for k in range(120):
        a = k / 120 * math.tau
        cx, cy = math.cos(a), math.sin(a)
        x = 0.7 * math.copysign(abs(cx) ** 0.35, cx)
        y = 0.27 * math.copysign(abs(cy) ** 0.35, cy)
        L = random.uniform(0.05, 0.09)
        add(cyl("franja", 0.004, L, (x, y, hem - L / 2 + 0.005), verts=5), fringe)
    export(OUT / "pala" / "pala.glb")


# ---- lata de Fruki Guaraná (350 ml): the adrenaline shot -----------------------
def fruki():
    # Real can profile, two opposite logos, one PBR atlas; no default cylinder UVs.
    import fruki_can
    fruki_can.build(OUT / "fruki", Path(__file__).resolve().parent / "ref" / "fruki_can_v2")


which = sys.argv[sys.argv.index("--") + 2:] or ["costela", "chimarrao", "pala", "fruki"]
for w in which:
    globals()[w]()
