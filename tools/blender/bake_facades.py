"""Bake facade tiles from the modular architecture kit (CC0 pack, kit_modular/):
each tile is assembled from the kit's real 3D panels and rendered straight on
with an orthographic camera into the maps a flat wall needs to look built:
base colour, normal (tangent space, OpenGL), height (white = out) and
roughness. The generated buildings' walls in the map pipeline use them
instead of the painted facades (docs/MAP_PIPELINE.md).

    Blender -b --factory-startup --python tools/blender/bake_facades.py -- KIT_GLB_DIR OUT_DIR [px_per_m]

Tiles, per style (STYLES below), each two 3 m bays wide so they repeat
without a seam:
    <style>_upper   two storeys of windows
    <style>_ground  the street storey: a door and a window
    <style>_shop    the street storey: a shop door and a shop window
    <style>_top     the band at the roof line: cornice and parapet
A style is a recipe over one of the kit's three panel families (antigo,
residencial, contemporaneo): which insert goes in which bay, balconies, air
conditioners. Storeys the kit has no panel for are built here from boxes
(`ribbon`: the slab as a band at every storey, a ribbon of windows between). The base colour's alpha is the wall mask (255 = the painted
wall, 0 = frames, glass, doors, trim): the map pipeline repaints the wall in
a building's own colour and leaves the rest as it is.
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

STOREY = {"antigo": 3.6, "residencial": 3.2, "contemporaneo": 3.2}      # per panel family
SILL_M = 0.9
# a bay: (panel, [(piece, height above the storey's floor), ...]); a tile has two.
WIN = lambda insert, *more: ("window", [(insert, SILL_M), *more])
DOOR = lambda door, *more: ("door", [(door, 0.0), *more])
AIRCON = ("ar_condicionado", 0.12)
STYLES = {
    # the old sobrado: wooden sashes, a wooden door
    "antigo": dict(family="antigo", upper=[WIN("janela_madeira")] * 2,
                   ground=[DOOR("porta_madeira"), WIN("janela_grade")],
                   shop=[DOOR("porta_vidro"), WIN("janela_madeira")]),
    # the eclectic one: arched openings on every storey
    "ecletico": dict(family="antigo", upper=[("arco", [("janela_arco", SILL_M)])] * 2,
                     ground=[DOOR("porta_madeira"), ("arco", [("janela_arco", SILL_M)])],
                     shop=[DOOR("porta_vidro"), ("arco", [("janela_arco", SILL_M)])]),
    # the 1960s block: shuttered windows
    "residencial": dict(family="residencial", upper=[WIN("janela_veneziana")] * 2,
                        ground=[DOOR("porta_madeira"), WIN("janela_grade")],
                        shop=[DOOR("porta_vidro"), WIN("janela_aluminio")]),
    # the apartment block: a balcony door next to a window with its air conditioner
    "sacada": dict(family="residencial",
                   upper=[DOOR("porta_vidro", ("sacada_3m", 0.0)), WIN("janela_aluminio", AIRCON)],
                   ground=[DOOR("porta_vidro"), WIN("janela_grade")],
                   shop=[DOOR("porta_aco"), WIN("janela_aluminio")]),
    # the contemporary one: aluminium frames, glass doors
    "contemporaneo": dict(family="contemporaneo", upper=[WIN("janela_aluminio")] * 2,
                          ground=[DOOR("porta_vidro"), WIN("janela_basculante")],
                          shop=[DOOR("porta_vidro"), WIN("janela_aluminio")]),
    # the office and shop building: tilting windows, steel shutters at the street
    "comercial": dict(family="contemporaneo", upper=[WIN("janela_basculante", AIRCON), WIN("janela_basculante")],
                      ground=[DOOR("porta_aco"), WIN("janela_basculante")],
                      shop=[DOOR("porta_aco"), DOOR("porta_vidro")]),
    # the slab-band tower: a light band at every storey, a ribbon of windows between
    "faixa": dict(family="contemporaneo", upper="ribbon",
                  ground=[DOOR("porta_vidro"), WIN("janela_aluminio")],
                  shop=[DOOR("porta_vidro"), DOOR("porta_aco")]),
}
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


def _srgb(c):
    """An sRGB colour (0..255) as the linear RGBA a material takes."""
    v = [x / 255.0 for x in c]
    return [((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in v] + [1.0]


def _material(name, colour, roughness):
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Base Color"].default_value = _srgb(colour)
        bsdf.inputs["Roughness"].default_value = roughness
    return mat


def box(x0, x1, z0, z1, front, depth, mat):
    """A box on the facade: x0..x1 along it, z0..z1 up, its face `front`
    metres in front of the wall plane (negative: set back), `depth` thick."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=((x0 + x1) / 2, front - depth / 2, (z0 + z1) / 2))
    o = bpy.context.object
    o.scale = (x1 - x0, depth, z1 - z0)
    o.data.materials.append(mat)


# the colours of the built storeys: the wall is the contemporaneo panels' own
# (the wall mask is measured on it), the glass the kit's
WALL = (199, 188, 162)
BAND = (236, 233, 224)
GLASS = (104, 120, 112)
FRAME = (72, 76, 80)
SILL = (160, 158, 150)


def ribbon(h):
    """Two storeys of a slab-band facade, 6 m wide: the slab's edge as a
    light band at the top of each storey, a ribbon of windows the whole
    width (a mullion every metre, so it repeats) over a plain spandrel."""
    wall, band = _material("wall", WALL, 0.85), _material("band", BAND, 0.8)
    glass, frame = _material("glass", GLASS, 0.1), _material("frame", FRAME, 0.45)
    sill = _material("sill", SILL, 0.7)
    x0, x1 = -3.4, 3.4                       # past the tile: trimmed by the camera
    slab, win0, win1 = 0.45, 0.95, 2.35      # the band's height; the window from sill to head
    for k in range(2):
        z = k * h
        box(x0, x1, z, z + win0, 0.0, 0.3, wall)                    # spandrel
        box(x0, x1, z + win1, z + h - slab, 0.0, 0.3, wall)         # over the window
        box(x0, x1, z + h - slab, z + h, 0.07, 0.37, band)          # the slab's edge
        box(x0, x1, z + win0, z + win1, -0.12, 0.05, glass)
        box(x0, x1, z + win0 - 0.05, z + win0, 0.04, 0.2, sill)
        box(x0, x1, z + win0, z + win0 + 0.06, -0.04, 0.1, frame)   # bottom and top rails
        box(x0, x1, z + win1 - 0.06, z + win1, -0.04, 0.1, frame)
        for i in range(-3, 4):                                      # mullions at -2.5 .. 2.5 and the tile's edges
            for x in ((i + 0.5,) if i < 3 else ()):
                box(x - 0.03, x + 0.03, z + win0, z + win1, -0.04, 0.1, frame)
    return 2 * BAY_M, 2 * h


def tile(style, kind):
    """Assemble one tile; returns its (width, height) in metres."""
    recipe = dict(STYLES[style])
    if isinstance(recipe.get(kind), str):
        recipe[kind] = globals()[recipe[kind]]       # a storey built here (ribbon)
    family = recipe["family"]
    h = STOREY[family]
    xs = [-BAY_M / 2, BAY_M / 2]                 # the two bays' centres, tile from -3 to +3
    if callable(recipe.get(kind)):
        return recipe[kind](h)
    if kind in ("upper", "ground", "shop"):
        for k in range(2 if kind == "upper" else 1):
            for x, (panel, pieces) in zip(xs, recipe[kind]):
                place(f"{family}_{panel}_3m", x, k * h)
                for piece, z in pieces:
                    place(piece, x, k * h + z)
                if kind == "shop":
                    place("marquise_3m", x, 2.75)
        return 2 * BAY_M, (2 * h if kind == "upper" else h)
    if kind == "top":
        place(f"{family}_blank_3m", xs[0], -h + 1.4)     # the top of a storey's wall behind the band
        place(f"{family}_blank_3m", xs[1], -h + 1.4)
        place(f"{family}_cornice", xs[0], 1.4)
        place(f"{family}_cornice", xs[1], 1.4)
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


WALL_TOLERANCE = 0.08     # how far (0..1 RGB) a pixel may be from the wall's colour and still be wall
_wall_colour = {}         # style -> its wall's colour, measured on the upper tile


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

    def write(suffix, arr, size, alpha=None):
        out = bpy.data.images.new(f"{name}_{suffix}_raw", size[0], size[1], alpha=alpha is not None, float_buffer=False)
        out.colorspace_settings.name = "Non-Color"
        out.alpha_mode = "CHANNEL_PACKED"          # the alpha is a mask: the colour is not multiplied by it
        rgba = np.ones((size[1], size[0], 4), dtype=np.float32)
        rgba[..., :3] = arr if arr.ndim == 3 else arr[..., None]
        if alpha is not None:
            rgba[..., 3] = alpha
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
    # the wall mask, in the base colour's alpha: the pixels of the wall's own
    # colour (the most common one on the wall plane of the style's upper tile)
    img, c = load("basecolor")
    style = name.split("_")[0]
    if style not in _wall_colour:
        on_plane = c[np.abs(depth - plane) < 0.012][:, :3]
        _wall_colour[style] = np.median(on_plane, axis=0)
    dist = np.linalg.norm(c[..., :3] - _wall_colour[style], axis=-1)
    mask = np.clip((WALL_TOLERANCE - dist) / (WALL_TOLERANCE * 0.5), 0.0, 1.0)
    mask[glass] = 0.0
    write("basecolor", c[..., :3], img.size, alpha=mask)
    (OUT / f"{name}_depth.png").unlink()
    print(f"{name}: wall plane at {plane - 20.0:+.2f} m")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for style in STYLES:
        for kind in ("upper", "ground", "shop", "top"):      # upper first: it gives the wall's colour
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
