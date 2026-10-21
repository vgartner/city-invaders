# Builds the first-person fists (godot/assets/common/melee/fists/) from the
# CC0 "fps arms (rigged only)" rig (opengameart.org/content/fps-arms-rigged-only,
# by para, MakeHuman base): scale to metres, the eye at the origin looking +Y
# (glTF -Z) with the 43-degree vertical lens of the arsenal pack, fists
# closed, six clips (idle_fists, jab_right, jab_left, hook_right, raise,
# lower; impacts at 0.15 / 0.15 / 0.25 s). Renders checks and exports.
#
#   Blender -b --factory-startup --disable-autoexec "FPS ARMS RIG 1.blend" \
#       --python tools/blender/fists_viewmodel.py -- \
#       '{"out": "/tmp/fists", "render": [["jab_right", 0.15]], "export": "/tmp/fists.glb"}'
import bpy, math, sys, json
from mathutils import Vector, Matrix, Quaternion, Euler

args = json.loads(sys.argv[sys.argv.index("--") + 1])
OUT = args["out"]
CURL = math.radians(args.get("curl", 85))
CURL_SIGN = args.get("curl_sign", 1)
PALM = args.get("palm", "z")          # hand-bone local axis that is the palm normal
PALM_SIGN = args.get("palm_sign", 1)
RENDER = args.get("render", [])
S = 0.114

scene = bpy.context.scene
arm = bpy.data.objects["caucasian_male_1"]
body = bpy.data.objects["caucasian_male_1:Body"]
for o in list(bpy.data.objects):
    if o.type in ("CAMERA", "LIGHT"):
        bpy.data.objects.remove(o)
# metres, facing +Y, shoulders just behind and below the eye
arm.rotation_euler = (0, 0, math.pi)
arm.scale = (S, S, S)
arm.location = (0, -0.10, -0.25)
bpy.context.view_layer.update()

cam_data = bpy.data.cameras.new("eye")
cam_data.sensor_fit = "VERTICAL"
cam_data.angle = math.radians(43.0)
cam_data.clip_start = 0.05
cam = bpy.data.objects.new("eye", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, 0, 0)
cam.rotation_euler = (math.pi / 2, 0, 0)       # looking +Y
scene.camera = cam
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3.0
so = bpy.data.objects.new("sun", sun); scene.collection.objects.link(so)
so.rotation_euler = (math.radians(50), math.radians(20), math.radians(30))

# the rig's own T-pose track would reset every pose on evaluation
if arm.animation_data:
    for t in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(t)
    arm.animation_data.action = None
# the rig's material predates nodes: a Principled one with its skin texture,
# so the glTF exporter embeds it (matte skin)
img = bpy.data.images.get("new_diff")
if img:
    img.filepath = bpy.path.abspath(img.filepath)
    img.reload()
    mat = bpy.data.materials.new("skin")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.75
    body.data.materials.clear()
    body.data.materials.append(mat)
for poly in body.data.polygons:
    poly.use_smooth = True                 # smooth skin, no facets
pb = arm.pose.bones
W = arm.matrix_world

def basis_for(side, fwd, palm_down_roll):
    """World rotation for the hand bone: bone Y along `fwd`, palm turned."""
    y = Vector(fwd).normalized()
    # palm normal wanted: down, rolled inwards by palm_down_roll radians
    n = Quaternion(y, palm_down_roll * (1 if side == "R" else -1)) @ Vector((0, 0, -1))
    n = (n - y * n.dot(y)).normalized()
    axes = {}
    if PALM == "z":
        z = n * PALM_SIGN; x = y.cross(z).normalized(); z = x.cross(y)
    else:
        x = n * PALM_SIGN; z = x.cross(y).normalized(); x = y.cross(z)
    return Matrix((x, y, z)).transposed()

def place(side, pos, fwd, roll):
    ctrl = pb["hand.%s.control" % side]
    hand = pb["hand.%s" % side]
    want = basis_for(side, fwd, roll).to_4x4()
    want.translation = Vector(pos)
    # hand rests on its control with a fixed offset
    rel = ctrl.bone.matrix_local.inverted() @ hand.bone.matrix_local
    ctrl_world = want @ rel.inverted()
    ctrl.matrix = W.inverted() @ ctrl_world

def fist():
    for side in "RL":
        for f in ("index", "middle", "ring", "pinky"):
            b = pb["f_%s.01.%s" % (f, side)]
            b.rotation_mode = "XYZ"
            b.rotation_euler = (CURL * CURL_SIGN, 0, 0)
        for t, rot in (("thumb.01", args.get("thumb1", [0.7, 0, 0.9])), ("thumb.02", args.get("thumb2", [0.3, 0, 0]))):
            b = pb["%s.%s" % (t, side)]
            b.rotation_mode = "XYZ"
            m = 1 if side == "R" else -1          # mirrored about X: Y and Z turns flip
            b.rotation_euler = (rot[0], rot[1] * m, rot[2] * m)

# key poses (camera space metres: x right, y forward, z up)
GUARD = {"R": ((0.15, 0.40, -0.10), (-0.15, 1, 0.35), 0.9), "L": ((-0.15, 0.40, -0.10), (0.15, 1, 0.35), 0.9)}
def pose(d):
    for side, (pos, fwd, roll) in d.items():
        place(side, pos, fwd, roll)

def key_all(frame):
    for side in "RL":
        c = pb["hand.%s.control" % side]
        c.keyframe_insert("location", frame=frame)
        c.rotation_mode = "QUATERNION"
        c.keyframe_insert("rotation_quaternion", frame=frame)
    for b in pb:
        if b.name.startswith(("f_", "thumb")) and b.name.endswith((".01.R", ".01.L", ".02.R", ".02.L")):
            b.keyframe_insert("rotation_euler", frame=frame)

for side in "RL":
    pb["hand.%s.control" % side].rotation_mode = "QUATERNION"
fist()

FPS = 30
scene.render.fps = FPS
def clip(name, keys):
    """keys: [(seconds, {side: (pos, fwd, roll)} or None for guard)]"""
    act = bpy.data.actions.new(name)
    arm.animation_data_create()
    arm.animation_data.action = act
    for t, d in keys:
        g = dict(GUARD)
        if d:
            g.update(d)
        pose(g)
        bpy.context.view_layer.update()
        key_all(t * FPS)
    act.use_fake_user = True
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, 0, act)
    arm.animation_data.action = None
    return act

def dip(side, dz):
    p, f, r = GUARD[side]
    return (p[0], p[1], p[2] + dz), f, r

clip("idle_fists", [(0, None), (0.6, {"R": dip("R", -0.012), "L": dip("L", -0.010)}), (1.2, None)])
JR = ((0.035, 0.60, -0.06), (-0.05, 1, 0.05), 0.15)
JL = ((-0.035, 0.60, -0.06), (0.05, 1, 0.05), -0.15)
clip("jab_right", [(0, None), (0.15, {"R": JR}), (0.24, {"R": JR}), (0.40, None)])
clip("jab_left", [(0, None), (0.15, {"L": JL}), (0.24, {"L": JL}), (0.40, None)])
HW = ((0.30, 0.40, -0.10), (0.6, 1, 0.1), 1.6)
HI = ((-0.02, 0.52, -0.05), (-1, 0.7, 0.05), 1.6)
clip("hook_right", [(0, None), (0.12, {"R": HW}), (0.25, {"R": HI}), (0.36, {"R": HI}), (0.55, None)])
LOW = {"R": ((0.18, 0.30, -0.55), (0, 1, 0.6), 0.9), "L": ((-0.18, 0.30, -0.55), (0, 1, 0.6), 0.9)}
clip("raise", [(0, LOW), (0.25, None)])
clip("lower", [(0, None), (0.20, LOW)])

# checks: render frames
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.render.resolution_x = 960
scene.render.resolution_y = 540
scene.render.resolution_percentage = 100
world = bpy.data.worlds.new("w"); scene.world = world
for x in arm.animation_data.nla_tracks:
    x.mute = True
if args.get("closeup"):
    # the right fist from the knuckles' side and from the thumb's side
    arm.animation_data.action = bpy.data.actions["idle_fists"]
    scene.frame_set(0)
    bpy.context.view_layer.update()
    hm = W @ pb["hand.R"].matrix
    c = hm.translation + (hm.col[1].xyz * 0.045)
    for tag, d in (("front", hm.col[1].xyz), ("thumb", -hm.col[0].xyz), ("top", hm.col[2].xyz)):
        cam.location = c + d.normalized() * 0.34
        cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam_data.angle = math.radians(40)
        scene.render.filepath = OUT + "/close_%s.png" % tag
        bpy.ops.render.render(write_still=True)
    cam.location = (0, 0, 0)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    cam_data.angle = math.radians(43.0)
for name, t in RENDER:
    arm.animation_data.action = bpy.data.actions[name]
    scene.frame_set(int(round(t * FPS)))
    bpy.context.view_layer.update()
    print("CURL", name, round(pb["f_index.01.R"].rotation_euler[0], 2))
    scene.render.filepath = OUT + "/r_%s_%.2f.png" % (name, t)
    bpy.ops.render.render(write_still=True)
arm.animation_data.action = None
for x in arm.animation_data.nla_tracks:
    x.mute = False
if args.get("export"):
    bpy.ops.export_scene.gltf(filepath=args["export"], export_format="GLB", export_animations=True,
        export_animation_mode="NLA_TRACKS", export_force_sampling=True, export_frame_step=1,
        export_cameras=False, export_lights=False, use_selection=False, export_apply=False)
    print("EXPORTED", args["export"])
