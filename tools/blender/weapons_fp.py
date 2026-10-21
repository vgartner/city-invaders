"""First-person revolver (.38, 4" barrel, six shots) and side-by-side
double-barrel 12-gauge shotgun, modelled procedurally and put into the
existing view-model arms: the pistol / rifle mesh parts (bones Weapon,
Magazine, SpareMagazine, Bolt) are removed, the new gun is parented to the
Weapon bone, so the arms' idle / fire / reload / draw clips still drive it.

    Blender -b --factory-startup --python tools/blender/weapons_fp.py -- godot/assets/common/weapons

Writes revolver/revolver_fp.glb, revolver/revolver_pickup.glb and
shotgun/shotgun_fp.glb, shotgun/shotgun_pickup.glb.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402

OUT = Path(sys.argv[sys.argv.index("--") + 1])
GUN_BONES = {"Weapon", "Magazine", "SpareMagazine", "Bolt"}


def obj_box(name, size, loc, rot=(0, 0, 0), bevel=0.0015):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        m = o.modifiers.new("bev", "BEVEL")
        m.width = bevel
        m.segments = 2
    return o


def obj_cyl(name, r, depth, loc, axis="Y", verts=32, r2=None):
    rot = {"X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0), "Z": (0, 0, 0)}[axis]
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r if r2 is None else r2,
                                    depth=depth, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    return o


def cut(target, cutters):
    for c in cutters:
        m = target.modifiers.new("cut", "BOOLEAN")
        m.object = c
        m.operation = "DIFFERENCE"
        m.solver = "EXACT"
    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.convert(target="MESH")
    for c in cutters:
        bpy.data.objects.remove(c)


def loft(name, sections, n=12):
    """Rounded-rectangle cross sections (y, width, height, z centre) bridged
    into a solid: gun stocks and grips."""
    bm = bmesh.new()
    rings = []
    for y, w, h, zc in sections:
        ring = []
        for k in range(n):
            a = k / n * math.tau
            # superellipse: flat sides, rounded corners
            cx, cz = math.cos(a), math.sin(a)
            x = w / 2 * math.copysign(abs(cx) ** 0.6, cx)
            z = zc + h / 2 * math.copysign(abs(cz) ** 0.6, cz)
            ring.append(bm.verts.new((x, y, z)))
        rings.append(ring)
    for r0, r1 in zip(rings[:-1], rings[1:]):
        for k in range(n):
            bm.faces.new((r0[k], r0[(k + 1) % n], r1[(k + 1) % n], r1[k]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    o.modifiers.new("sub", "SUBSURF").levels = 2
    for p in me.polygons:
        p.use_smooth = True
    return o


def assign(objs, mat):
    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(mat)


def place(objs, scale, offset):
    """Scale about the local origin, then move: local gun frame -> view frame."""
    M = Matrix.Translation(offset) @ Matrix.Scale(scale, 4)
    for o in objs:
        o.matrix_world = M @ o.matrix_world
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


# ---- the guns, in a local frame: bore along +Y at z = 0, muzzle forward ------
def revolver():
    """Smith & Wesson Model 10 style .38 Special, 4" barrel, walnut grips."""
    steel, wood = [], []
    steel.append(obj_cyl("barrel", 0.0095, 0.104, (0, 0.087, 0)))
    steel.append(obj_box("shroud", (0.011, 0.088, 0.012), (0, 0.083, -0.012), bevel=0.003))   # ejector rod shroud
    steel.append(obj_box("rib", (0.006, 0.1, 0.004), (0, 0.087, 0.0095), bevel=0.0012))
    steel.append(obj_box("front_sight", (0.003, 0.014, 0.009), (0, 0.13, 0.013),
                         rot=(math.radians(-12), 0, 0), bevel=0.0008))
    # cylinder: six chambers, six flutes
    cyl = obj_cyl("cylinder", 0.0195, 0.04, (0, 0.014, -0.013), verts=48)
    cutters = []
    for k in range(6):
        a = k / 6 * math.tau + math.pi / 2
        cutters.append(obj_cyl("ch", 0.0047, 0.05, (0.0128 * math.cos(a), 0.014, -0.013 + 0.0128 * math.sin(a)), verts=16))
        a2 = a + math.pi / 6
        fl = obj_cyl("fl", 0.0042, 0.024, (0.0215 * math.cos(a2), 0.012, -0.013 + 0.0215 * math.sin(a2)), verts=12)
        cutters.append(fl)
    cut(cyl, cutters)
    steel.append(cyl)
    # frame: top strap, recoil shield, body behind the cylinder, under the cylinder
    steel.append(obj_box("topstrap", (0.013, 0.048, 0.007), (0, 0.012, 0.0095), bevel=0.002))
    steel.append(obj_box("shield", (0.016, 0.01, 0.04), (0, -0.011, -0.012), bevel=0.002))
    steel.append(obj_box("frame", (0.014, 0.04, 0.042), (0, -0.032, -0.016), bevel=0.003))
    steel.append(obj_box("lower", (0.012, 0.05, 0.008), (0, 0.012, -0.034), bevel=0.002))
    steel.append(obj_cyl("ejector", 0.0028, 0.03, (0, 0.05, -0.024), verts=12))
    # hammer with chequered spur, trigger and round guard
    steel.append(obj_box("hammer", (0.006, 0.018, 0.02), (0, -0.05, 0.004), rot=(math.radians(35), 0, 0), bevel=0.001))
    steel.append(obj_box("spur", (0.008, 0.012, 0.005), (0, -0.06, 0.013), rot=(math.radians(15), 0, 0), bevel=0.001))
    steel.append(obj_box("trigger", (0.005, 0.006, 0.02), (0, -0.016, -0.045), rot=(math.radians(-15), 0, 0), bevel=0.001))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.016, minor_radius=0.0028, major_segments=32,
                                     location=(0, -0.017, -0.045), rotation=(0, math.pi / 2, 0))
    guard = bpy.context.object
    bm = bmesh.new()
    bm.from_mesh(guard.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z > 0.004], context="VERTS")   # open at the top
    bm.to_mesh(guard.data)
    bm.free()
    steel.append(guard)
    # grip frame strap and walnut grip panels, raked back ~20 degrees
    steel.append(obj_box("backstrap", (0.012, 0.012, 0.085), (0, -0.062, -0.075), rot=(math.radians(20), 0, 0), bevel=0.003))
    g = loft("grip", [(-0.002, 0.03, 0.016, 0.0), (0.01, 0.032, 0.03, 0.0), (0.03, 0.033, 0.032, 0.0),
                      (0.05, 0.031, 0.03, 0.0), (0.072, 0.028, 0.027, 0.0)])
    g.rotation_euler = (math.radians(-90 - 20), 0, 0)
    g.location = (0, -0.04, -0.034)
    wood.append(g)
    steel.append(obj_cyl("screw", 0.0035, 0.034, (0, -0.06, -0.07), axis="X", verts=16))
    bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.004, depth=0.003, location=(0, 0.1395, 0),
                                        rotation=(math.pi / 2, 0, 0))
    bore = bpy.context.object
    return steel, wood, [bore]


def shotgun():
    """Side-by-side 12-gauge, 28" barrels, walnut stock - the farm gun."""
    steel, wood, black = [], [], []
    for x in (-0.0118, 0.0118):
        steel.append(obj_cyl("barrel", 0.0118, 0.7, (x, 0.40, 0), verts=40))
        bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.0092, depth=0.004, location=(x, 0.7505, 0),
                                            rotation=(math.pi / 2, 0, 0))
        black.append(bpy.context.object)
    steel.append(obj_box("toprib", (0.008, 0.7, 0.006), (0, 0.40, 0.011), bevel=0.001))
    steel.append(obj_box("botrib", (0.01, 0.62, 0.008), (0, 0.38, -0.011), bevel=0.001))
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, radius=0.0022, location=(0, 0.745, 0.0158))
    brass = bpy.context.object
    steel.append(obj_box("receiver", (0.044, 0.11, 0.046), (0, -0.005, -0.007), bevel=0.006))
    steel.append(obj_box("standing_breech", (0.044, 0.012, 0.03), (0, -0.065, 0.008), bevel=0.003))
    steel.append(obj_box("toplever", (0.01, 0.04, 0.006), (0.006, -0.085, 0.022), rot=(0, 0, math.radians(-12)), bevel=0.002))
    steel.append(obj_box("tang", (0.012, 0.07, 0.004), (0, -0.11, 0.017), bevel=0.0015))
    for k, y in enumerate((-0.02, -0.035)):
        steel.append(obj_box(f"trigger{k}", (0.005, 0.006, 0.022), (0, y, -0.045), rot=(math.radians(-12), 0, 0), bevel=0.001))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.026, minor_radius=0.003, major_segments=32,
                                     location=(0, -0.03, -0.045), rotation=(0, math.pi / 2, 0))
    guard = bpy.context.object
    guard.scale = (1, 1.25, 1)
    bm = bmesh.new()
    bm.from_mesh(guard.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z > 0.004], context="VERTS")
    bm.to_mesh(guard.data)
    bm.free()
    steel.append(guard)
    # splinter forend under the barrels, English-style straight stock
    wood.append(loft("forend", [(0.05, 0.03, 0.02, -0.018), (0.07, 0.046, 0.03, -0.02), (0.25, 0.046, 0.028, -0.02),
                                (0.28, 0.03, 0.018, -0.016)]))
    wood.append(loft("stock", [(-0.06, 0.04, 0.045, -0.01), (-0.1, 0.032, 0.036, -0.018), (-0.17, 0.031, 0.036, -0.03),
                               (-0.24, 0.036, 0.07, -0.05), (-0.33, 0.04, 0.11, -0.065), (-0.42, 0.042, 0.135, -0.075)]))
    pad = loft("buttpad", [(-0.42, 0.042, 0.135, -0.075), (-0.435, 0.041, 0.133, -0.075)])
    black.append(pad)
    return steel, wood, black + [brass]


# ---- put a gun into a view-model rig -------------------------------------------
def build(src_fp, gun_fn, scale, offset, out_fp, out_pickup):
    bu.reset()
    bpy.ops.import_scene.gltf(filepath=str(src_fp))
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    mesh = next(o for o in bpy.data.objects if o.type == "MESH")
    # drop the old gun: vertices whose strongest weight is on a gun bone
    names = {g.index: g.name for g in mesh.vertex_groups}
    bm = bmesh.new()
    bm.from_mesh(mesh.data)
    deform = bm.verts.layers.deform.active
    kill = []
    for v in bm.verts:
        d = v[deform]
        if d and names[max(d.items(), key=lambda kv: kv[1])[0]] in GUN_BONES:
            kill.append(v)
    bmesh.ops.delete(bm, geom=kill, context="VERTS")
    bm.to_mesh(mesh.data)
    bm.free()
    before = set(bpy.data.objects)
    steel_o, wood_o, dark_o = gun_fn()
    new = [o for o in bpy.data.objects if o not in before]
    place(new, scale, Vector(offset))
    bpy.context.scene.frame_set(0)
    blued = bu.principled("blued_steel", (0.045, 0.05, 0.06), 0.3, 1.0)
    dark = bu.principled("black", (0.02, 0.02, 0.02), 0.6)
    s = bu.join(steel_o, "gun_steel")
    assign([s], blued)
    w = bu.join(wood_o, "gun_wood")
    assign([w], bu.wood("walnut"))
    bu.bake(w, 1024)
    d = bu.join(dark_o, "gun_dark")
    assign([d], dark)
    for p in (s, w, d):
        for poly in p.data.polygons:
            poly.use_smooth = True
        p.data.set_sharp_from_angle(angle=math.radians(35)) if hasattr(p.data, "set_sharp_from_angle") else None
    # world pickup: the bare gun, lying on its side, before parenting
    out_pickup.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for p in (s, w, d):
        p.location = -Vector(offset)          # gun centred on its own origin
        p.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(out_pickup), export_format="GLB", use_selection=True,
                              export_yup=True, export_animations=False)
    for p in (s, w, d):
        p.location = (0, 0, 0)
    # skin the gun rigidly to the Weapon bone and merge it into the arms mesh,
    # exactly how the original gun was bound (rest pose = where it was measured)
    for p in (s, w, d):
        vg = p.vertex_groups.new(name="Weapon")
        vg.add(list(range(len(p.data.vertices))), 1.0, "REPLACE")
    bpy.ops.object.select_all(action="DESELECT")
    for p in (s, w, d):
        p.select_set(True)
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.join()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(out_fp), export_format="GLB", use_selection=True,
                              export_yup=True, export_animations=True, export_skins=True)
    print("wrote", out_fp)


root = Path(__file__).resolve().parent / "arms"   # the original view models: arms + old guns
if __name__ == "__main__":
  build(root / "pistol_arms.glb", revolver, 1.25, (0.247, 0.405, -0.2425),
      OUT / "revolver/revolver_fp.glb", OUT / "revolver/revolver_pickup.glb")
  build(root / "rifle_arms.glb", shotgun, 1.1, (0.243, 0.447, -0.276),
      OUT / "shotgun/shotgun_fp.glb", OUT / "shotgun/shotgun_pickup.glb")
