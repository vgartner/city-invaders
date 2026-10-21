"""Shared helpers for the procedural Blender asset scripts: node-based
materials (wood, blued steel, meat, gourd) baked to image textures so the
glTF export carries the detail (glTF can't carry Blender node trees)."""
import bpy


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.samples = 4
    s.cycles.bake_type = "DIFFUSE"


def principled(name, colour=(0.5, 0.5, 0.5), rough=0.5, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*colour, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


def _nodes(m):
    return m.node_tree.nodes, m.node_tree.links, m.node_tree.nodes["Principled BSDF"]


def _ramp(nodes, stops):
    r = nodes.new("ShaderNodeValToRGB")
    els = r.color_ramp.elements
    els[0].position, els[0].color = stops[0][0], (*stops[0][1], 1)
    els[1].position, els[1].color = stops[-1][0], (*stops[-1][1], 1)
    for pos, col in stops[1:-1]:
        e = els.new(pos)
        e.color = (*col, 1)
    return r


def _bump(nodes, links, bsdf, height_socket, strength, distance=0.002):
    bp = nodes.new("ShaderNodeBump")
    bp.inputs["Strength"].default_value = strength
    bp.inputs["Distance"].default_value = distance
    links.new(height_socket, bp.inputs["Height"])
    links.new(bp.outputs["Normal"], bsdf.inputs["Normal"])


def wood(name, dark=(0.17, 0.08, 0.035), light=(0.42, 0.22, 0.1), scale=18.0, rough=0.45):
    """Walnut-like grain: stretched wave rings broken up by noise."""
    m = principled(name, rough=rough)
    nodes, links, bsdf = _nodes(m)
    tc = nodes.new("ShaderNodeTexCoord")
    mp = nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1.0, 1.0, 0.12)        # long grain along the part
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "RINGS"
    wave.inputs["Scale"].default_value = scale
    wave.inputs["Distortion"].default_value = 6.0
    wave.inputs["Detail"].default_value = 3.0
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 60.0
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "FLOAT"
    mix.inputs["Factor"].default_value = 0.25
    ramp = _ramp(nodes, [(0.0, dark), (0.55, light), (1.0, dark)])
    links.new(tc.outputs["Object"], mp.inputs["Vector"])
    links.new(mp.outputs["Vector"], wave.inputs["Vector"])
    links.new(mp.outputs["Vector"], noise.inputs["Vector"])
    links.new(wave.outputs["Fac"], mix.inputs[2])
    links.new(noise.outputs["Fac"], mix.inputs[3])
    links.new(mix.outputs[0], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    _bump(nodes, links, bsdf, wave.outputs["Fac"], 0.08)
    return m


def steel(name, base=(0.06, 0.065, 0.075), rough=0.32, wear=(0.42, 0.42, 0.44)):
    """Blued steel with lighter worn edges (pointiness) and fine noise."""
    m = principled(name, base, rough, 1.0)
    nodes, links, bsdf = _nodes(m)
    geo = nodes.new("ShaderNodeNewGeometry")
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 300.0
    ramp = _ramp(nodes, [(0.5, base), (0.62, wear)])
    links.new(geo.outputs["Pointiness"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    _bump(nodes, links, bsdf, noise.outputs["Fac"], 0.03)
    return m


def meat(name):
    """Fire-roasted beef: golden-brown flesh, charred patches, fat streaks."""
    m = principled(name, rough=0.42)
    nodes, links, bsdf = _nodes(m)
    tc = nodes.new("ShaderNodeTexCoord")
    n1 = nodes.new("ShaderNodeTexNoise")
    n1.inputs["Scale"].default_value = 9.0
    n1.inputs["Detail"].default_value = 8.0
    n1.inputs["Roughness"].default_value = 0.65
    vor = nodes.new("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = 22.0
    ramp = _ramp(nodes, [(0.0, (0.03, 0.012, 0.006)), (0.38, (0.12, 0.045, 0.02)),
                         (0.52, (0.33, 0.13, 0.04)), (0.68, (0.55, 0.27, 0.08)), (1.0, (0.78, 0.55, 0.25))])
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "FLOAT"
    mix.inputs["Factor"].default_value = 0.3
    links.new(tc.outputs["Object"], n1.inputs["Vector"])
    links.new(tc.outputs["Object"], vor.inputs["Vector"])
    links.new(n1.outputs["Fac"], mix.inputs[2])
    links.new(vor.outputs["Distance"], mix.inputs[3])
    links.new(mix.outputs[0], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    _bump(nodes, links, bsdf, n1.outputs["Fac"], 0.5, 0.01)
    return m


def gourd(name):
    """Dried porongo: orange-tan with darker mottling and fine pores."""
    m = principled(name, rough=0.55)
    nodes, links, bsdf = _nodes(m)
    tc = nodes.new("ShaderNodeTexCoord")
    n1 = nodes.new("ShaderNodeTexNoise")
    n1.inputs["Scale"].default_value = 6.0
    n1.inputs["Detail"].default_value = 6.0
    n2 = nodes.new("ShaderNodeTexNoise")
    n2.inputs["Scale"].default_value = 400.0
    ramp = _ramp(nodes, [(0.3, (0.32, 0.15, 0.05)), (0.55, (0.62, 0.34, 0.12)), (0.75, (0.72, 0.45, 0.2))])
    links.new(tc.outputs["Object"], n1.inputs["Vector"])
    links.new(tc.outputs["Object"], n2.inputs["Vector"])
    links.new(n1.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    _bump(nodes, links, bsdf, n2.outputs["Fac"], 0.06)
    return m


def bake(obj, size=1024, normal=True):
    """Unwrap `obj`, bake its (single) node material's colour and normal into
    images and swap in a plain image-textured material."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.01)
    bpy.ops.object.mode_set(mode="OBJECT")
    src = obj.active_material
    nodes = src.node_tree.nodes
    imgs = {}
    for kind in (["DIFFUSE", "NORMAL"] if normal else ["DIFFUSE"]):
        img = bpy.data.images.new(f"{obj.name}_{kind.lower()}", size, size)
        if kind == "NORMAL":
            img.colorspace_settings.name = "Non-Color"
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = img
        nodes.active = tex
        if kind == "DIFFUSE":
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=4)
        else:
            bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", margin=4)
        img.pack()
        imgs[kind] = img
        nodes.remove(tex)
    b = src.node_tree.nodes["Principled BSDF"]
    out = principled(src.name + "_baked", rough=b.inputs["Roughness"].default_value,
                     metal=b.inputs["Metallic"].default_value)
    n2, l2, b2 = _nodes(out)
    t = n2.new("ShaderNodeTexImage")
    t.image = imgs["DIFFUSE"]
    l2.new(t.outputs["Color"], b2.inputs["Base Color"])
    if normal:
        tn = n2.new("ShaderNodeTexImage")
        tn.image = imgs["NORMAL"]
        nm = n2.new("ShaderNodeNormalMap")
        l2.new(tn.outputs["Color"], nm.inputs["Color"])
        l2.new(nm.outputs["Normal"], b2.inputs["Normal"])
    obj.data.materials.clear()
    obj.data.materials.append(out)


def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.convert(target="MESH")         # apply modifiers
    bpy.ops.object.join()
    o = bpy.context.object
    o.name = name
    return o


def plaster(name, colour, rough=0.85):
    """Painted render: blotchy repaint, grime streaking down from the top and
    darker near the street, fine sand-float bump."""
    m = principled(name, colour, rough)
    nodes, links, bsdf = _nodes(m)
    tc = nodes.new("ShaderNodeTexCoord")
    blot = nodes.new("ShaderNodeTexNoise")
    blot.inputs["Scale"].default_value = 0.35
    blot.inputs["Detail"].default_value = 6.0
    streak = nodes.new("ShaderNodeTexNoise")
    streak.inputs["Scale"].default_value = 1.2
    mp = nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (3.0, 3.0, 0.15)          # long vertical grime streaks
    sand = nodes.new("ShaderNodeTexNoise")
    sand.inputs["Scale"].default_value = 90.0
    base = (*colour, 1)
    dark = (*(c * 0.62 for c in colour), 1)
    mix1 = nodes.new("ShaderNodeMix")
    mix1.data_type = "RGBA"
    mix1.inputs[6].default_value = base
    mix1.inputs[7].default_value = dark
    r1 = _ramp(nodes, [(0.42, (0, 0, 0)), (0.75, (0.55, 0.55, 0.55))])
    links.new(tc.outputs["Object"], blot.inputs["Vector"])
    links.new(tc.outputs["Object"], mp.inputs["Vector"])
    links.new(mp.outputs["Vector"], streak.inputs["Vector"])
    mx = nodes.new("ShaderNodeMath")
    mx.operation = "MAXIMUM"
    links.new(blot.outputs["Fac"], mx.inputs[0])
    links.new(streak.outputs["Fac"], mx.inputs[1])
    links.new(mx.outputs[0], r1.inputs["Fac"])
    links.new(r1.outputs["Color"], mix1.inputs[0])
    links.new(mix1.outputs[2], bsdf.inputs["Base Color"])
    links.new(tc.outputs["Object"], sand.inputs["Vector"])
    _bump(nodes, links, bsdf, sand.outputs["Fac"], 0.15)
    return m


def brick(name, colour=(0.45, 0.17, 0.1), mortar=(0.62, 0.58, 0.52), scale=4.0):
    """Running-bond brickwork with varied brick tones and recessed mortar."""
    m = principled(name, rough=0.85)
    nodes, links, bsdf = _nodes(m)
    tc = nodes.new("ShaderNodeTexCoord")
    br = nodes.new("ShaderNodeTexBrick")
    br.inputs["Scale"].default_value = scale
    br.inputs["Mortar Size"].default_value = 0.012
    br.inputs["Brick Width"].default_value = 0.5
    br.inputs["Row Height"].default_value = 0.17
    br.inputs["Color1"].default_value = (*colour, 1)
    br.inputs["Color2"].default_value = (*(c * 0.75 for c in colour), 1)
    br.inputs["Mortar"].default_value = (*mortar, 1)
    br.inputs["Bias"].default_value = 0.0
    links.new(tc.outputs["Object"], br.inputs["Vector"])
    links.new(br.outputs["Color"], bsdf.inputs["Base Color"])
    _bump(nodes, links, bsdf, br.outputs["Fac"], 0.4, 0.01)
    return m
