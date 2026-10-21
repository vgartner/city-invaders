"""Bake facade tiles from the modular architecture kit (CC0 pack, kit_modular/):
each tile is assembled from the kit's real 3D panels and rendered straight on
with an orthographic camera into the maps a flat wall needs to look built:
base colour, normal (tangent space, OpenGL), height (white = out) and
roughness. The generated buildings' walls in the map pipeline use them
instead of the painted facades (docs/MAP_PIPELINE.md).

    Blender -b --factory-startup --python tools/blender/bake_facades.py -- KIT_GLB_DIR OUT_DIR [px_per_m]

Tiles, per style (antigo, residencial, contemporaneo), each two 3 m bays
wide so they repeat without a seam:
    <style>_upper   two storeys of windows
    <style>_ground  the street storey: a door and a window
    <style>_shop    the street storey: a glass door and a shop window
    <style>_top     the band at the roof line: cornice and parapet
The kit's panels: origin at the middle of their lower edge on the facade
plane, thickness behind it, front -Z in glTF (+Y in Blender).
"""
import math
import sys
from pathlib import Path

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
KIT = Path(argv[0])
OUT = Path(argv[1])
PX_PER_M = int(argv[2]) if len(argv) > 2 else 80
DEPTH_M = 0.7            # the height map's range: from the deepest recess to the most forward relief
GLASS_SET_BACK_M = 0.18  # how far the glass sits behind the facade

STOREY = {"antigo": 3.6, "residencial": 3.2, "contemporaneo": 3.2}
INSERTS = {              # (window insert upper, window insert ground, ground door, shop door, shop window)
    "antigo": ("janela_madeira", "janela_grade", "porta_madeira", "porta_vidro", "janela_madeira"),
    "residencial": ("janela_veneziana", "janela_grade", "porta_madeira", "porta_vidro", "janela_aluminio"),
    "contemporaneo": ("janela_aluminio", "janela_basculante", "porta_vidro", "porta_vidro", "janela_aluminio"),
}
SILL_M = 0.9
BAY_M = 3.0


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def place(name, x, z, along=0.0):
    """Import the kit piece `name` at facade x (metres) and height z, `along`
    metres in front of the facade plane."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(KIT / f"kit_modular_{name}.glb"))
    for o in bpy.data.objects:
        if o not in before and o.parent is None:
            o.location = (o.location.x + x, o.location.y + along, o.location.z + z)


def tile(style, kind):
    """Assemble one tile; returns its (width, height) in metres."""
    up_win, gr_win, gr_door, shop_door, shop_win = INSERTS[style]
    h = STOREY[style]
    xs = [-BAY_M / 2, BAY_M / 2]                 # the two bays' centres, tile from -3 to +3
    if kind == "upper":
        for k in range(2):
            for x in xs:
                place(f"{style}_window_3m", x, k * h)
                place(up_win, x, k * h + SILL_M)
        return 2 * BAY_M, 2 * h
    if kind in ("ground", "shop"):
        door, win = (gr_door, gr_win) if kind == "ground" else (shop_door, shop_win)
        place(f"{style}_door_3m", xs[0], 0.0)
        place(door, xs[0], 0.0)
        place(f"{style}_window_3m", xs[1], 0.0)
        place(win, xs[1], SILL_M)
        if kind == "shop":
            place("marquise_3m", xs[0], 2.75)
            place("marquise_3m", xs[1], 2.75)
        return 2 * BAY_M, h
    if kind == "top":
        place(f"{style}_blank_3m", xs[0], -h + 1.4)     # the top of a storey's wall behind the band
        place(f"{style}_blank_3m", xs[1], -h + 1.4)
        place(f"{style}_cornice", xs[0], 1.4)
        place(f"{style}_cornice", xs[1], 1.4)
        place("platibanda_4m", 0.0, 1.75)
        place("platibanda_4m", 4.0, 1.75)               # 4 m pieces: overlap past the tile, trimmed by the camera
        place("platibanda_4m", -4.0, 1.75)
        return 2 * BAY_M, 2.5
    raise ValueError(kind)


def setup_passes(w, h):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 24
    sc.cycles.use_denoising = False
    sc.render.resolution_x = int(round(w * PX_PER_M))
    sc.render.resolution_y = int(round(h * PX_PER_M))
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"   # the base colour as albedo, no filmic curve
    vl = sc.view_layers[0]
    vl.use_pass_diffuse_color = True
    vl.use_pass_normal = True
    vl.use_pass_z = True
    aov = vl.aovs.add()
    aov.name = "rough"
    aov.type = "VALUE"
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(w, h)
    cam_data.clip_start = 0.1
    cam_data.clip_end = 40.0
    sc.render.pixel_aspect_x = 1
    sc.render.pixel_aspect_y = 1
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    # facade front is +Y in Blender: look back along -Y at the tile's centre
    cam.location = (0.0, 20.0, h / 2.0)
    cam.rotation_euler = (math.radians(90), 0.0, math.radians(180))
    sc.camera = cam
    # flat, even light for the colour pass is not needed (diffuse colour pass is albedo);
    # a world so nothing is black
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    sc.world = world


def roughness_aov():
    """Every material writes its roughness into the "rough" AOV; glass is made
    opaque (its colour stays): seen through, the depth pass is noise."""
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        nt = mat.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is not None:
            for k, v in (("Alpha", 1.0), ("Transmission Weight", 0.0), ("Transmission", 0.0)):
                if k in bsdf.inputs:
                    for l in list(bsdf.inputs[k].links):
                        nt.links.remove(l)
                    bsdf.inputs[k].default_value = v
        mat.blend_method = "OPAQUE" if hasattr(mat, "blend_method") else None
        out = nt.nodes.new("ShaderNodeOutputAOV")
        out.aov_name = "rough"
        if bsdf is None:
            out.inputs["Value"].default_value = 0.8
            continue
        r = bsdf.inputs["Roughness"]
        if r.is_linked:
            nt.links.new(r.links[0].from_socket, out.inputs["Value"])
        else:
            out.inputs["Value"].default_value = r.default_value


def compositor(name):
    """Write the passes: base colour, normal, height, roughness."""
    sc = bpy.context.scene
    nt = bpy.data.node_groups.new("comp", "CompositorNodeTree")
    sc.compositing_node_group = nt
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    rl = nt.nodes.new("CompositorNodeRLayers")

    def node(*types):
        # node type names moved in Blender 5 (shared Shader* nodes in the compositor)
        for t in types:
            try:
                return nt.nodes.new(t)
            except RuntimeError:
                continue
        raise RuntimeError(f"none of {types}")

    def save(socket, suffix, colour="RGB", depth="8"):
        # Blender 5: one output item per file, named <file_name><item><frame>.png
        fo = nt.nodes.new("CompositorNodeOutputFile")
        fo.directory = str(OUT)
        fo.file_name = f"{name}_{suffix}"
        if hasattr(fo.format, "media_type"):
            fo.format.media_type = "IMAGE"        # Blender 5: not a multilayer EXR
        fo.format.file_format = "PNG"
        fo.format.color_mode = colour
        fo.format.color_depth = depth
        fo.save_as_render = suffix == "basecolor"     # data maps (normal, height, roughness): raw values
        item = fo.file_output_items.new("RGBA" if colour != "BW" else "FLOAT", "_")
        nt.links.new(socket, fo.inputs[item.name] if item.name in fo.inputs else fo.inputs[-1])
        return fo

    save(rl.outputs["Diffuse Color"], "basecolor")
    # depth, raw: (distance - 18 m) / 4 m - the height map is made from it after the render
    d = node("ShaderNodeMath", "CompositorNodeMath")
    d.operation = "MULTIPLY_ADD"
    d.inputs[1].default_value = 0.25
    d.inputs[2].default_value = -18.0 * 0.25
    nt.links.new(rl.outputs["Depth"], d.inputs[0])
    save(d.outputs[0], "depth", colour="BW", depth="16")
    save(rl.outputs["rough"], "roughness", colour="BW", depth="16")


def post(name):
    """From the raw depth (16-bit, written without a colour curve): the height
    map - the wall plane is the tile's most common depth - and the normal map
    (tangent space, OpenGL: from the depth's slope, which for a facade seen
    straight on is its surface); the roughness written raw."""
    import numpy as np

    def load(suffix):
        img = bpy.data.images.load(str(OUT / f"{name}_{suffix}.png"))
        img.colorspace_settings.name = "Non-Color"
        a = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)
        return img, a                      # rows bottom to top (Blender's order)

    def write(suffix, arr, size):
        out = bpy.data.images.new(f"{name}_{suffix}_raw", size[0], size[1], alpha=False, float_buffer=False)
        out.colorspace_settings.name = "Non-Color"
        rgba = np.ones((size[1], size[0], 4), dtype=np.float32)
        rgba[..., :3] = arr if arr.ndim == 3 else arr[..., None]
        out.pixels[:] = rgba.ravel()
        out.filepath_raw = str(OUT / f"{name}_{suffix}.png")
        out.file_format = "PNG"
        out.save()

    img, r = load("roughness")
    write("roughness", r[..., :3], img.size)
    img, d = load("depth")
    depth = d[..., 0] * 4.0 + 18.0
    hist, edges = np.histogram(depth, bins=400, range=(18.0, 22.0))
    plane = edges[int(np.argmax(hist))] + 0.005
    # the kit's inserts put the glass on the facade plane: set it back into its
    # opening (the glass is what is smooth), a window's depth is what reads
    glass = r[..., 0] < 0.3
    depth = np.where(glass, np.maximum(depth, plane + GLASS_SET_BACK_M), depth)
    # white: 0.2 m in front of the wall (cornices, sills); black: 0.5 m behind it (recesses)
    height = np.clip((plane + 0.5 - depth) / DEPTH_M, 0.0, 1.0)
    write("height", height, img.size)
    # the surface z = -depth; slopes per metre (a pixel is 1 / PX_PER_M m);
    # x to the right, y up (Blender's rows already run bottom to top)
    z = -np.clip(depth, plane - 0.3, plane + 0.6)
    dzdx = np.gradient(z, axis=1) * PX_PER_M
    dzdy = np.gradient(z, axis=0) * PX_PER_M
    n = np.stack([-dzdx, -dzdy, np.ones_like(z)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    write("normal", n * 0.5 + 0.5, img.size)
    (OUT / f"{name}_depth.png").unlink()
    print(f"{name}: wall plane at {plane - 20.0:+.2f} m")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for style in STOREY:
        for kind in ("upper", "ground", "shop", "top"):
            clear()
            w, h = tile(style, kind)
            setup_passes(w, h)
            roughness_aov()
            compositor(f"{style}_{kind}")
            bpy.context.scene.render.filepath = str(OUT / f"_beauty_{style}_{kind}.png")
            bpy.ops.render.render(write_still=True)
            # the file outputs add the item name and frame number: plain names
            for f in OUT.glob(f"{style}_{kind}_*_*.png"):
                base = f.name.split("_")
                tag = f.stem.rsplit("_", 1)[0].rstrip("_")
                f.replace(OUT / f"{tag}.png")
            post(f"{style}_{kind}")
            print(f"baked {style}_{kind}: {w} x {h} m")


main()
