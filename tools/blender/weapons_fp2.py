"""Realistic replacements for the pistol (polymer-frame 9 mm, Taurus-style)
and the machine gun (5.56 AR-pattern carbine), built like weapons_fp.py but
with moving parts: the magazine is skinned to the Magazine bone (a copy to
SpareMagazine) and the slide / charging handle to Bolt, so the reload clip
really swaps magazines and the fire clip cycles the action.

    Blender -b --factory-startup --python tools/blender/weapons_fp2.py -- godot/assets/common/weapons
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402
from weapons_fp import GUN_BONES, loft, obj_box, obj_cyl  # noqa: E402

OUT = Path(sys.argv[sys.argv.index("--") + 1])
ARMS = Path(__file__).resolve().parent / "arms"


def mats():
    return {
        "steel": bu.principled("slide_steel", (0.035, 0.037, 0.04), 0.38, 1.0),
        "alu": bu.principled("anodised", (0.028, 0.028, 0.03), 0.45, 0.55),
        "poly": bu.principled("polymer", (0.03, 0.03, 0.032), 0.62, 0.0),
        "bore": bu.principled("bore", (0.005, 0.005, 0.005), 0.8, 0.0),
        "brass": bu.principled("brass", (0.75, 0.55, 0.22), 0.3, 1.0),
        "dot": bu.principled("sight_dot", (0.9, 0.9, 0.85), 0.4, 0.0),
    }


def serrations(y0, y1, n, z0, z1, x, depth=0.0012):
    """Slide serrations: thin cutter boxes on both flanks."""
    out = []
    for k in range(n):
        y = y0 + (y1 - y0) * k / max(n - 1, 1)
        for sx in (-1, 1):
            out.append(obj_box("ser", (depth * 2, 0.0012, z1 - z0), (sx * x, y, (z0 + z1) / 2), bevel=0))
    return out


def boolean(target, cutters, op="DIFFERENCE"):
    for c in cutters:
        m = target.modifiers.new("b", "BOOLEAN")
        m.object = c
        m.operation = op
        m.solver = "EXACT"
    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.convert(target="MESH")
    for c in cutters:
        bpy.data.objects.remove(c)


# ---- pistol: local frame, bore along +Y at z = 0, muzzle at y = 0 -------------
def pistol():
    parts = []
    slide = obj_box("slide", (0.025, 0.186, 0.03), (0, -0.093, 0.004), bevel=0.003)
    boolean(slide, serrations(-0.175, -0.145, 9, -0.006, 0.016, 0.0125)
            + serrations(-0.045, -0.025, 6, -0.006, 0.016, 0.0125)
            + [obj_box("port", (0.02, 0.03, 0.012), (0.006, -0.075, 0.018), bevel=0),
               obj_cyl("muzzle", 0.0052, 0.02, (0, 0.0, 0.0), verts=20)])
    parts.append((slide, "steel", "Bolt"))
    parts.append((obj_cyl("barrel", 0.0058, 0.03, (0, -0.075, 0.004), verts=20), "brass", "Bolt"))   # hood in the port
    parts.append((obj_box("front_sight", (0.004, 0.006, 0.006), (0, -0.008, 0.022), bevel=0.0008), "steel", "Bolt"))
    parts.append((obj_box("rear_sight", (0.02, 0.006, 0.007), (0, -0.172, 0.022), bevel=0.001), "steel", "Bolt"))
    for x in (-0.006, 0.0, 0.006):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=6, radius=0.0012,
                                             location=(x, -0.006 if x == 0 else -0.175, 0.0255 if x == 0 else 0.026))
        parts.append((bpy.context.object, "dot", "Bolt"))
    # polymer frame: dust cover with a rail, trigger guard, grip with texture
    parts.append((obj_box("dustcover", (0.023, 0.13, 0.016), (0, -0.075, -0.016), bevel=0.003), "poly", "Weapon"))
    for k in range(3):
        parts.append((obj_box("rail", (0.018, 0.004, 0.004), (0, -0.04 - 0.01 * k, -0.026), bevel=0.0006), "poly", "Weapon"))
    parts.append((obj_box("frame", (0.023, 0.07, 0.012), (0, -0.15, -0.018), bevel=0.003), "poly", "Weapon"))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.019, minor_radius=0.0032, major_segments=28,
                                     location=(0, -0.078, -0.03), rotation=(0, math.pi / 2, 0))
    guard = bpy.context.object
    guard.scale = (1, 1.25, 1)
    bm = bmesh.new()
    bm.from_mesh(guard.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z > 0.004], context="VERTS")
    bm.to_mesh(guard.data)
    bm.free()
    parts.append((guard, "poly", "Weapon"))
    parts.append((obj_box("trigger", (0.006, 0.006, 0.02), (0, -0.085, -0.032), rot=(math.radians(-14), 0, 0),
                          bevel=0.0012), "steel", "Weapon"))
    grip = loft("grip", [(0.0, 0.03, 0.05, 0.0), (0.02, 0.031, 0.052, 0.0), (0.06, 0.031, 0.05, 0.0),
                         (0.1, 0.03, 0.048, 0.0)])
    grip.rotation_euler = (math.radians(-90 - 18), 0, 0)
    grip.location = (0, -0.148, -0.022)
    # stippled grip texture
    tex = bpy.data.textures.new("stipple", "STUCCI")
    tex.noise_scale = 0.002
    d = grip.modifiers.new("stipple", "DISPLACE")
    d.texture = tex
    d.strength = 0.0006
    parts.append((grip, "poly", "Weapon"))
    parts.append((obj_box("slide_stop", (0.004, 0.02, 0.004), (0.0135, -0.11, -0.008), bevel=0.0008), "steel", "Weapon"))
    parts.append((obj_box("mag_release", (0.005, 0.008, 0.006), (0.0128, -0.118, -0.028), bevel=0.001), "poly", "Weapon"))
    # magazine: steel body inside the grip, polymer base plate, top round
    mag = obj_box("mag", (0.022, 0.03, 0.105), (0, -0.17, -0.07), rot=(math.radians(-18), 0, 0), bevel=0.002)
    parts.append((mag, "steel", "Magazine"))
    parts.append((obj_box("baseplate", (0.026, 0.036, 0.008), (0, -0.188, -0.122), rot=(math.radians(-18), 0, 0),
                          bevel=0.002), "poly", "Magazine"))
    return parts


# ---- carbine: AR-pattern 5.56, 14.5" barrel, collapsible stock --------------------
def carbine():
    parts = []
    parts.append((obj_cyl("flash_hider", 0.0105, 0.055, (0, -0.0275, 0), verts=6), "steel", "Weapon"))
    parts.append((obj_cyl("bore", 0.003, 0.002, (0, 0.0005, 0), verts=12), "bore", "Weapon"))
    parts.append((obj_cyl("barrel", 0.0085, 0.33, (0, -0.215, 0), verts=24), "steel", "Weapon"))
    parts.append((obj_box("gas_block", (0.02, 0.02, 0.026), (0, -0.215, 0.004), bevel=0.002), "steel", "Weapon"))
    parts.append((obj_box("front_sight", (0.004, 0.012, 0.045), (0, -0.215, 0.035), bevel=0.001), "steel", "Weapon"))
    # free-float handguard with a top rail and slots
    hg = obj_box("handguard", (0.05, 0.27, 0.052), (0, -0.395, 0.002), bevel=0.008)
    cut = []
    for k in range(7):
        for sx in (-1, 1):
            cut.append(obj_box("slot", (0.01, 0.022, 0.01), (sx * 0.025, -0.29 - k * 0.032, -0.006), bevel=0))
    boolean(hg, cut)
    parts.append((hg, "alu", "Weapon"))
    for k in range(26):
        parts.append((obj_box("rail", (0.022, 0.0055, 0.004), (0, -0.27 - k * 0.0095, 0.03), bevel=0.0005), "alu", "Weapon"))
    # upper receiver with flat-top rail, ejection port, forward assist
    parts.append((obj_box("upper", (0.032, 0.18, 0.04), (0, -0.62, 0.004), bevel=0.004), "alu", "Weapon"))
    for k in range(18):
        parts.append((obj_box("rail_u", (0.022, 0.0055, 0.004), (0, -0.54 - k * 0.0095, 0.026), bevel=0.0005), "alu", "Weapon"))
    parts.append((obj_box("rear_sight", (0.022, 0.016, 0.022), (0, -0.69, 0.04), bevel=0.002), "alu", "Weapon"))
    parts.append((obj_box("port", (0.002, 0.05, 0.016), (0.0165, -0.6, 0.006), bevel=0.0005), "steel", "Weapon"))
    parts.append((obj_cyl("fwd_assist", 0.006, 0.02, (0.018, -0.66, 0.012), axis="Y", verts=12), "alu", "Weapon"))
    parts.append((obj_box("charging_handle", (0.03, 0.03, 0.008), (0, -0.715, 0.018), bevel=0.0015), "alu", "Bolt"))
    # lower receiver, mag well, trigger guard, pistol grip
    parts.append((obj_box("lower", (0.03, 0.17, 0.035), (0, -0.62, -0.032), bevel=0.004), "alu", "Weapon"))
    parts.append((obj_box("magwell", (0.032, 0.07, 0.05), (0, -0.585, -0.07), bevel=0.004), "alu", "Weapon"))
    parts.append((obj_box("guard", (0.02, 0.07, 0.005), (0, -0.66, -0.07), bevel=0.0015), "alu", "Weapon"))
    parts.append((obj_box("trigger", (0.005, 0.006, 0.022), (0, -0.655, -0.058), rot=(math.radians(-12), 0, 0),
                          bevel=0.001), "steel", "Weapon"))
    pg = loft("pistol_grip", [(0.0, 0.028, 0.04, 0.0), (0.03, 0.03, 0.042, 0.0), (0.075, 0.028, 0.04, 0.0),
                              (0.095, 0.026, 0.036, 0.0)])
    pg.rotation_euler = (math.radians(-90 - 22), 0, 0)
    pg.location = (0, -0.7, -0.045)
    parts.append((pg, "poly", "Weapon"))
    # buffer tube and a collapsible stock
    parts.append((obj_cyl("buffer", 0.0155, 0.2, (0, -0.8, -0.002), verts=24), "alu", "Weapon"))
    stock = loft("stock", [(-0.82, 0.04, 0.05, -0.004), (-0.86, 0.042, 0.07, -0.012), (-0.93, 0.044, 0.11, -0.03),
                           (-0.945, 0.044, 0.115, -0.032)])
    parts.append((stock, "poly", "Weapon"))
    # curved 30-round magazine with ribs
    # sections run down the magazine (depth, width, front-to-back, forward lean)
    mag = loft("mag", [(0.0, 0.026, 0.062, 0.0), (0.05, 0.026, 0.064, 0.006), (0.1, 0.026, 0.066, 0.018),
                       (0.15, 0.026, 0.066, 0.034)])
    mag.rotation_euler = (-math.pi / 2, 0, 0)
    mag.location = (0, -0.585, -0.07)
    parts.append((mag, "alu", "Magazine"))
    return parts


def build(arms, gun_fn, fit, out_fp, out_pickup):
    """fit: (scale, offset) placing the local gun in the view-model frame."""
    bu.reset()
    bpy.ops.import_scene.gltf(filepath=str(arms))
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    mesh = next(o for o in bpy.data.objects if o.type == "MESH")
    names = {g.index: g.name for g in mesh.vertex_groups}
    # where the old magazine and spare sit (rest pose), to place ours and its copy
    centres = {}
    for v in mesh.data.vertices:
        if v.groups:
            g = names[max(v.groups, key=lambda g: g.weight).group]
            centres.setdefault(g, []).append(mesh.matrix_world @ v.co)
    spare_shift = None
    if centres.get("SpareMagazine") and centres.get("Magazine"):
        c = lambda pts: sum(pts, Vector()) / len(pts)
        spare_shift = c(centres["SpareMagazine"]) - c(centres["Magazine"])
    bm = bmesh.new()
    bm.from_mesh(mesh.data)
    deform = bm.verts.layers.deform.active
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v[deform] and
                               names[max(v[deform].items(), key=lambda kv: kv[1])[0]] in GUN_BONES], context="VERTS")
    bm.to_mesh(mesh.data)
    bm.free()
    m = mats()
    parts = gun_fn()
    scale, offset = fit
    M = Matrix.Translation(Vector(offset)) @ Matrix.Scale(scale, 4)
    for o, _, _ in parts:
        o.matrix_world = M @ o.matrix_world
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.convert(target="MESH")
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # spare magazine: a copy of the magazine parts where the old spare was
    if spare_shift is not None:
        for o, key, bone in [p for p in parts if p[2] == "Magazine"]:
            c = o.copy()
            c.data = o.data.copy()
            bpy.context.scene.collection.objects.link(c)
            c.location += spare_shift
            bpy.ops.object.select_all(action="DESELECT")
            c.select_set(True)
            bpy.context.view_layer.objects.active = c
            bpy.ops.object.transform_apply(location=True)
            parts.append((c, key, "SpareMagazine"))
    for o, key, bone in parts:
        o.data.materials.clear()
        o.data.materials.append(m[key])
        for p in o.data.polygons:
            p.use_smooth = True
        vg = o.vertex_groups.new(name=bone)
        vg.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    # world pickup: the gun without the spare, centred
    gun = [p[0] for p in parts if p[2] != "SpareMagazine"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in gun:
        o.location = -Vector(offset)
        o.select_set(True)
    out_pickup.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(out_pickup), export_format="GLB", use_selection=True,
                              export_yup=True, export_animations=False)
    for o in gun:
        o.location = (0, 0, 0)
    bpy.ops.object.select_all(action="DESELECT")
    for o, _, _ in parts:
        o.select_set(True)
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.join()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(out_fp), export_format="GLB", use_selection=True,
                              export_yup=True, export_animations=True, export_skins=True)
    print("wrote", out_fp)


if __name__ == "__main__":
    # pistol: muzzle at y 0.614, slide top at z -0.146 (old pistol), 1.7x
    build(ARMS / "pistol_arms.glb", pistol, (1.7, (0.2465, 0.614, -0.146 - 0.019 * 1.7)),
          OUT / "pistol/pistol_fp.glb", OUT / "pistol/pistol_pickup.glb")
    # carbine: muzzle at y 0.877 (old rifle), bore low enough that the right hand
    # holds the pistol grip and the left one the handguard, 0.84x
    build(ARMS / "rifle_arms.glb", carbine, (0.84, (0.243, 0.877, -0.205)),
          OUT / "machinegun/machinegun_fp.glb", OUT / "machinegun/machinegun_pickup.glb")
