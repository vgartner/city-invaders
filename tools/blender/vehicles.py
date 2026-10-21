"""Vehicles built in Blender for City Invaders.

    Blender -b --factory-startup --python tools/blender/vehicles.py -- godot/assets truck

truck: a cab-over fuel tanker in Charrua colours (lettering only, no logo
artwork), for the traffic. Same conventions as the car fleet: metres, front
-Z in glTF (+Y here), origin on the ground at the centre, wheels as their
own nodes wheel_* pivoting on the axle (roll about local X), lights_front /
lights_rear emissive.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402

args = sys.argv[sys.argv.index("--") + 1:]
OUT = Path(args[0])
WHICH = args[1:] or ["truck"]
M = {}


def mat(key):
    return M[key]


def part(name, key, size=None, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0, kind="cube", r=0.5, depth=1.0, verts=32):
    if kind == "cube":
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
        o = bpy.context.object
        o.scale = size
        bpy.ops.object.transform_apply(scale=True)
    else:
        bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=loc, rotation=rot)
        o = bpy.context.object
    o.name = name
    if bevel:
        b = o.modifiers.new("bev", "BEVEL")
        b.width = bevel
        b.segments = 3
    o.data.materials.append(mat(key))
    for p in o.data.polygons:
        p.use_smooth = kind != "cube"
    return o


def text(name, body, key, loc, size, rot):
    bpy.ops.object.text_add(location=loc, rotation=rot)
    t = bpy.context.object
    t.name = name
    t.data.body = body
    t.data.size = size
    t.data.extrude = 0.01
    t.data.align_x = "CENTER"
    t.data.align_y = "CENTER"
    t.data.materials.append(mat(key))
    return t


def emissive(name, colour, strength):
    m = bu.principled(name, colour, 0.4)
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Emission Color"].default_value = (*colour, 1)
    b.inputs["Emission Strength"].default_value = strength
    return m


def decal(name, image, size, loc, rot, alpha=False):
    """A flat image (logo, side artwork) on a vehicle panel."""
    key = "decal_" + image
    if key not in M:
        m = bpy.data.materials.new(key)
        m.use_nodes = True
        nt = m.node_tree
        b = nt.nodes["Principled BSDF"]
        b.inputs["Roughness"].default_value = 0.35
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / image))
        t.image.pack()
        nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
        if alpha:
            nt.links.new(t.outputs["Alpha"], b.inputs["Alpha"])
        M[key] = m
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = "decal_" + name
    o.scale = (size[0], size[1], 1)
    o.data.materials.append(M[key])
    return o


def side_decals(name, image, length, height, x, y, z, alpha=False):
    """The same artwork on both sides, reading front-to-back on each."""
    for sx in (-1, 1):
        decal(f"{name}{sx}", image, (length, height), (sx * x, y, z), (math.pi / 2, 0, sx * math.pi / 2), alpha)


def cab(W, y, colour, h=2.6, l=2.3):
    """A generic modern cab-over truck cab (no maker badges) facing +Y."""
    part("cab", colour, (W, l, h), (0, y, 0.75 + h / 2), bevel=0.12)
    part("bumper", "dark", (W, 0.35, 0.5), (0, y + l / 2 + 0.05, 0.6), bevel=0.05)
    part("grille", "dark", (W * 0.7, 0.05, 0.8), (0, y + l / 2 + 0.01, 1.45), bevel=0.03)
    part("windscreen", "glass", (W - 0.25, 0.04, 1.05), (0, y + l / 2 + 0.02, 2.55), rot=(math.radians(-6), 0, 0))
    part("visor", "dark", (W - 0.1, 0.25, 0.08), (0, y + l / 2 + 0.1, 3.15))
    for sx in (-1, 1):
        part("side_window", "glass", (0.04, 0.9, 0.75), (sx * (W / 2 + 0.005), y + 0.5, 2.5))
        part("mirror", "dark", (0.08, 0.2, 0.45), (sx * (W / 2 + 0.3), y + l / 2 - 0.1, 2.4), bevel=0.02)
        part("step", "dark", (0.35, 0.5, 0.06), (sx * (W / 2 - 0.15), y + 0.4, 0.95))
    return [part(f"head{sx}", "head", (0.42, 0.06, 0.22), (sx * 0.85, y + l / 2 + 0.24, 0.75), bevel=0.02) for sx in (-1, 1)]


def wheels(axles, x=1.0, r=0.52):
    names = []
    for k, y in enumerate(axles):
        for sx, side in ((-1, "l"), (1, "r")):
            n = f"wheel_{'f' if k == 0 else 'r'}{side}{'' if k < 2 else k}"
            bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=r, depth=0.4, location=(sx * x, y, r),
                                                rotation=(0, math.pi / 2, 0))
            w = bpy.context.object
            w.name = n
            w.data.materials.append(mat("tyre"))
            # bake the 90 degree turn into the mesh: the node stays unrotated, so
            # the game's roll about local X turns it about the axle
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
            bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=r * 0.58, depth=0.42, location=(sx * x, y, r),
                                                rotation=(0, math.pi / 2, 0))
            hub = bpy.context.object
            hub.data.materials.append(mat("rim"))
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
            hub.parent = w
            hub.matrix_parent_inverse = w.matrix_world.inverted()
            names.append(n)


def finish_vehicle(lf, lr, path):
    keep = ("wheel", "head", "tail", "decal")
    bpy.ops.object.select_all(action="DESELECT")
    for o in [o for o in bpy.data.objects if o.type in ("MESH", "FONT") and not o.name.startswith(keep) and o.parent is None]:
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
    bpy.ops.object.convert(target="MESH")
    bpy.ops.object.join()
    bpy.context.object.name = "body_shell"
    for group, name in ((lf, "lights_front"), (lr, "lights_rear")):
        bpy.ops.object.select_all(action="DESELECT")
        for o in group:
            o.select_set(True)
        bpy.context.view_layer.objects.active = group[0]
        bpy.ops.object.join()
        bpy.context.object.name = name
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True)
    print("wrote", path)


def base_mats():
    M.clear()
    M.update({
        "white": bu.principled("paint_white", (0.92, 0.93, 0.94), 0.25, 0.1),
        "yellow": bu.principled("charrua_yellow", (0.98, 0.78, 0.02), 0.3, 0.1),
        "grey": bu.principled("tank_grey", (0.72, 0.73, 0.74), 0.3, 0.3),
        "red": bu.principled("charrua_red", (0.85, 0.12, 0.14), 0.35),
        "steel": bu.principled("steel", (0.6, 0.62, 0.64), 0.3, 1.0),
        "dark": bu.principled("chassis", (0.05, 0.05, 0.06), 0.6),
        "tyre": bu.principled("tyre", (0.03, 0.03, 0.03), 0.85),
        "rim": bu.principled("rim", (0.75, 0.75, 0.76), 0.35, 1.0),
        "glass": bu.principled("glass", (0.05, 0.07, 0.09), 0.05, 0.5),
        "orange": bu.principled("hazard_plate", (0.95, 0.42, 0.02), 0.5),
        "black_text": bu.principled("plate_text", (0.02, 0.02, 0.02), 0.5),
        "head": emissive("headlight", (1, 0.97, 0.9), 2.0),
        "tail": emissive("taillight", (0.9, 0.05, 0.03), 1.5),
    })


## Charrua fuel tanker after the fleet photos: yellow cab-over tractor, a
## yellow tank with a light grey top, red-white reflective tape, the red
## Charrua logo with CHARRUA in red and "A SERVIÇO DA", hazard plates 33/1203.
def truck():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    base_mats()
    W = 2.5
    part("chassis", "dark", (0.9, 12.0, 0.3), (0, -0.4, 0.8))
    lf = cab(W, 4.5, "yellow")
    part("fifth_wheel", "dark", (2.2, 1.0, 0.25), (0, 2.6, 1.1))
    # the tank: yellow, with a light grey top
    tank = part("tank_lower", "yellow", kind="cyl", r=1.0, depth=8.9, loc=(0, -1.55, 2.0), rot=(math.pi / 2, 0, 0), verts=48)
    tank.scale = (1.25, 1.0, 1.0)
    top = part("tank_top", "grey", (2.4, 8.9, 0.5), (0, -1.55, 2.82), bevel=0.22)
    for y in (-6.0, 2.9):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=12, radius=1.0, location=(0, y, 2.0))
        capm = bpy.context.object
        capm.scale = (1.25, 0.22, 1.0)
        capm.data.materials.append(mat("yellow"))
    shell = lambda z: 1.25 * math.sqrt(max(0.0, 1 - ((z - 2.0) / 1.0) ** 2))
    for sx in (-1, 1):
        for k in range(22):                    # red / white reflective tape
            part("tape", "red" if k % 2 == 0 else "white", (0.02, 0.38, 0.09), (sx * (shell(1.3) + 0.01), -5.75 + k * 0.4, 1.3))
        rot = (math.pi / 2, 0, math.pi / 2 if sx > 0 else -math.pi / 2)
        # logo towards the cab, CHARRUA on the rear half, "A SERVIÇO DA" by the logo: no overlap
        text("charrua", "CHARRUA", "red", (sx * (shell(2.05) + 0.03), -3.4, 2.05), 0.6, rot)
        text("servico", "A SERVIÇO DA", "red", (sx * (shell(2.05) + 0.03), 1.3, 1.95), 0.2, rot)
        decal(f"logo{sx}", "charrua_logo.png", (1.05, 0.75), (sx * (shell(2.05) + 0.035), -0.5, 2.05),
              (math.pi / 2, 0, sx * math.pi / 2), alpha=True)
    part("walkway", "steel", (0.6, 8.0, 0.05), (0, -1.55, 3.1))
    for sx in (-1, 1):
        part("rail", "steel", (0.03, 8.0, 0.03), (sx * 0.4, -1.55, 3.5))
        for k in range(9):
            part("post", "steel", (0.03, 0.03, 0.4), (sx * 0.4, -5.5 + k * 1.0, 3.3))
        part("pipe", "steel", kind="cyl", r=0.09, depth=7.5, loc=(sx * 1.1, -1.6, 1.0), rot=(math.pi / 2, 0, 0), verts=16)
        for k in range(6):
            part("lamp", "white", kind="cyl", r=0.12, depth=0.08, loc=(sx * 1.2, -0.2 - k * 0.32, 1.1), rot=(0, math.pi / 2, 0), verts=16)
        part("diesel_tank", "steel", kind="cyl", r=0.32, depth=1.1, loc=(sx * 0.95, 3.2, 1.1), rot=(math.pi / 2, 0, 0), verts=24)
    for y, ry in ((5.74, 0.0), (-6.3, math.pi)):
        part("hazard", "orange", (0.42, 0.02, 0.32), (0, y, 1.25))
        text("hz1", "33", "black_text", (0, y + (0.015 if y > 0 else -0.015), 1.32), 0.11, (math.pi / 2, 0, ry))
        text("hz2", "1203", "black_text", (0, y + (0.015 if y > 0 else -0.015), 1.18), 0.11, (math.pi / 2, 0, ry))
    bpy.ops.mesh.primitive_cube_add(size=0.5, location=(1.27, -3.2, 1.6), rotation=(0, math.pi / 4, 0))
    bpy.context.object.scale = (0.02, 1, 1)
    bpy.context.object.data.materials.append(mat("red"))           # hazard diamond
    lr = [part(f"tail{sx}", "tail", (0.3, 0.05, 0.15), (sx * 1.05, -6.35, 0.75)) for sx in (-1, 1)]
    wheels([4.8, 2.0, 1.0, -4.0, -5.0])
    finish_vehicle(lf, lr, OUT / "rio_grande_do_sul" / "trucks" / "truck_charrua_tanker.glb")


## Fruki delivery trucks: a small white box truck with the green guaraná
## panels, and a big tractor-trailer "Tri refrescante" for the main roads.
def fruki_box():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    base_mats()
    W = 2.35
    part("chassis", "dark", (0.9, 6.6, 0.28), (0, 0.0, 0.75))
    lf = cab(W, 2.4, "white", h=2.2, l=1.9)
    part("box", "white", (W + 0.1, 4.6, 2.4), (0, -1.15, 2.3), bevel=0.04)
    side_decals("fruki", "fruki_box_side.png", 4.4, 1.76, W / 2 + 0.065, -1.15, 2.3)
    decal("back", "fruki_box_side.png", (2.2, 0.88), (0, -3.46, 2.3), (math.pi / 2, 0, math.pi))
    lr = [part(f"tail{sx}", "tail", (0.25, 0.05, 0.14), (sx * 1.0, -3.46, 0.85)) for sx in (-1, 1)]
    wheels([2.5, -2.2], x=0.95, r=0.46)
    finish_vehicle(lf, lr, OUT / "rio_grande_do_sul" / "lorries" / "lorry_fruki_box.glb")


def fruki_trailer():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    base_mats()
    W = 2.5
    part("chassis", "dark", (0.9, 15.0, 0.3), (0, -1.5, 0.8))
    lf = cab(W, 4.6, "white")
    part("trailer", "white", (W + 0.1, 11.5, 2.9), (0, -3.0, 2.55), bevel=0.05)
    side_decals("fruki", "fruki_trailer_side.png", 11.3, 2.27, W / 2 + 0.065, -3.0, 2.55)
    decal("back", "fruki_box_side.png", (2.3, 0.92), (0, -8.76, 2.5), (math.pi / 2, 0, math.pi))
    lr = [part(f"tail{sx}", "tail", (0.3, 0.05, 0.15), (sx * 1.05, -8.8, 0.8)) for sx in (-1, 1)]
    wheels([4.9, 2.1, -6.3, -7.3, -8.2])
    finish_vehicle(lf, lr, OUT / "rio_grande_do_sul" / "lorries" / "lorry_fruki_trailer.glb")


def harvester():
    """War machine of the interior: a combine harvester armoured with welded
    plates, the reel up front turned into a robot shredder. Green and yellow
    farm paint under rust and steel; drivable (kind "harvester")."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    M.update({
        "green": bu.principled("farm_green", (0.12, 0.35, 0.1), 0.45, 0.1),
        "yellow": bu.principled("farm_yellow", (0.92, 0.7, 0.05), 0.4),
        "plate": bu.principled("armour_plate", (0.32, 0.31, 0.29), 0.55, 0.85),
        "rust": bu.principled("rust", (0.35, 0.16, 0.07), 0.9, 0.3),
        "dark": bu.principled("chassis", (0.05, 0.05, 0.06), 0.6),
        "tyre": bu.principled("tyre", (0.03, 0.03, 0.03), 0.85),
        "rim": bu.principled("rim_yellow", (0.92, 0.7, 0.05), 0.4),
        "glass": bu.principled("slit_glass", (0.05, 0.07, 0.09), 0.05, 0.5),
        "blade": bu.principled("blade_steel", (0.7, 0.71, 0.72), 0.2, 1.0),
        "head": emissive("headlight", (1, 0.95, 0.8), 3.0),
        "tail": emissive("taillight", (0.9, 0.05, 0.03), 1.5),
    })
    # body: tall green hull, grain tank, engine deck, unloading auger
    part("hull", "green", (3.0, 5.2, 2.3), (0, -0.4, 2.15), bevel=0.15)
    part("grain_tank", "green", (2.6, 2.4, 1.3), (0, -0.9, 3.95), bevel=0.2)
    part("engine", "dark", (2.4, 1.6, 1.0), (0, -2.6, 3.5), bevel=0.1)
    part("exhaust", "dark", kind="cyl", r=0.12, depth=1.6, loc=(0.9, -2.4, 4.6), verts=16)
    part("auger", "yellow", kind="cyl", r=0.18, depth=4.5, loc=(-1.9, -0.9, 4.2), rot=(0, math.radians(70), 0), verts=16)
    # armoured cab: steel box with vision slits, roof hatch
    part("cab", "plate", (2.2, 1.8, 1.7), (0, 1.6, 3.85), bevel=0.06)
    part("slit_front", "glass", (1.7, 0.04, 0.22), (0, 2.51, 4.2))
    for sx in (-1, 1):
        part("slit_side", "glass", (0.04, 1.1, 0.2), (sx * 1.11, 1.6, 4.2))
    part("hatch", "plate", kind="cyl", r=0.45, depth=0.18, loc=(0, 1.4, 4.8), verts=24)
    # welded armour skirts with rivets and rust streaks
    for sx in (-1, 1):
        for k in range(4):
            part("skirt", "plate" if k % 2 == 0 else "rust", (0.1, 1.35, 1.4), (sx * 1.56, -2.2 + k * 1.3, 1.6),
                 rot=(0, 0, math.radians(sx * 3)), bevel=0.02)
        for k in range(10):
            part("rivet", "dark", kind="cyl", r=0.04, depth=0.06, loc=(sx * 1.62, -2.7 + k * 0.6, 2.2),
                 rot=(0, math.pi / 2, 0), verts=8)
    part("yellow_band", "yellow", (3.04, 5.0, 0.18), (0, -0.4, 3.0))
    # JOHN DEERE lettering on both sides of the grain tank (public-domain text logo)
    logo = bpy.data.materials.new("john_deere_logo")
    logo.use_nodes = True
    lt = logo.node_tree
    lb = lt.nodes["Principled BSDF"]
    li = lt.nodes.new("ShaderNodeTexImage")
    li.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / "john_deere_text_yellow.png"))
    li.image.pack()
    lt.links.new(li.outputs["Color"], lb.inputs["Base Color"])
    lt.links.new(li.outputs["Alpha"], lb.inputs["Alpha"])
    logo.blend_method = "CLIP" if hasattr(logo, "blend_method") else None
    for sx in (-1, 1):
        bpy.ops.mesh.primitive_plane_add(size=1, location=(sx * 1.515, -0.6, 2.45),
                                         rotation=(math.pi / 2, 0, sx * math.pi / 2))
        pl = bpy.context.object
        pl.name = "logo"
        pl.scale = (2.6, 0.36, 1)
        pl.data.materials.append(logo)
    # header: wide feeder, the reel with blades (its own node, spins)
    part("feeder", "green", (1.6, 1.6, 1.2), (0, 3.1, 1.5), rot=(math.radians(-18), 0, 0), bevel=0.08)
    part("header", "plate", (5.6, 1.4, 0.7), (0, 4.2, 0.75), bevel=0.06)
    for k in range(18):
        part("tooth", "blade", (0.08, 0.5, 0.12), (-2.6 + k * 0.3, 5.0, 0.45))
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.12, depth=5.4, location=(0, 4.4, 1.55),
                                        rotation=(0, math.pi / 2, 0))
    reel = bpy.context.object
    reel.name = "reel"
    reel.data.materials.append(mat("blade"))
    for k in range(6):
        a = k / 6 * math.tau
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 4.4 + 0.55 * math.cos(a), 1.55 + 0.55 * math.sin(a)),
                                        rotation=(a, 0, 0))
        b = bpy.context.object
        b.scale = (5.2, 0.05, 0.3)
        bpy.ops.object.transform_apply(scale=True)
        b.data.materials.append(mat("blade"))
        b.select_set(True)
    bpy.ops.object.select_all(action="DESELECT")
    blades = [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Cube")]
    for o in blades + [reel]:
        o.select_set(True)
    bpy.context.view_layer.objects.active = reel
    bpy.ops.object.join()
    reel = bpy.context.object
    reel.name = "reel"
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)    # spin axis = local X
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    lf = [part(f"head{sx}", "head", (0.35, 0.06, 0.2), (sx * 0.8, 2.52, 4.65)) for sx in (-1, 1)]
    lr = [part(f"tail{sx}", "tail", (0.3, 0.05, 0.15), (sx * 1.2, -3.02, 2.0)) for sx in (-1, 1)]
    # big front drive wheels, small rear steering wheels
    for name, (sx, y, r, wdt) in {"wheel_fl": (-1, 1.7, 0.95, 0.75), "wheel_fr": (1, 1.7, 0.95, 0.75),
                                  "wheel_rl": (-1, -2.3, 0.6, 0.5), "wheel_rr": (1, -2.3, 0.6, 0.5)}.items():
        bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=r, depth=wdt, location=(sx * 1.55, y, r),
                                            rotation=(0, math.pi / 2, 0))
        w = bpy.context.object
        w.name = name
        w.data.materials.append(mat("tyre"))
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)    # roll axis = local X
        bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=r * 0.55, depth=wdt + 0.04, location=(sx * 1.55, y, r),
                                            rotation=(0, math.pi / 2, 0))
        hub = bpy.context.object
        hub.data.materials.append(mat("rim"))
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
        hub.parent = w
        hub.matrix_parent_inverse = w.matrix_world.inverted()
    keep = ("wheel", "head", "tail", "reel", "logo")
    bpy.ops.object.select_all(action="DESELECT")
    for o in [o for o in bpy.data.objects if o.type == "MESH" and not o.name.startswith(keep) and o.parent is None]:
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
    bpy.ops.object.join()
    bpy.context.object.name = "body_shell"
    for group, name in ((lf, "lights_front"), (lr, "lights_rear")):
        bpy.ops.object.select_all(action="DESELECT")
        for o in group:
            o.select_set(True)
        bpy.context.view_layer.objects.active = group[0]
        bpy.ops.object.join()
        bpy.context.object.name = name
    # the auger tip: where the grain gun fires from
    tip = bpy.data.objects.new("muzzle_auger", None)
    tip.location = (-1.9 - 2.1, -0.9, 4.2 + 0.75)
    bpy.context.scene.collection.objects.link(tip)
    out = OUT / "rio_grande_do_sul" / "war" / "colheitadeira_blindada.glb"
    out.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True)
    print("wrote", out)


for w in WHICH:
    globals()[w]()
