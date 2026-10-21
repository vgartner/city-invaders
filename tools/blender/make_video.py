"""Videos for the in-game cinema. Godot plays Ogg Theora only and this
machine's ffmpeg has no Theora encoder, Blender's does.

    # convert any video Blender can read (mp4, mov, mkv...) to .ogv (default 854 px wide)
    Blender -b --factory-startup --python tools/blender/make_video.py -- convert in.mp4 out.ogv [width]

    # a placeholder trailer (title cards over a moving city skyline)
    Blender -b --factory-startup --python tools/blender/make_video.py -- trailer godot/assets/rio_grande_do_sul/video/cinema.ogv
"""
import math
import sys
from pathlib import Path

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
mode, rest = args[0], args[1:]


def output(scene, out, w=854, h=480, fps=24):
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.resolution_percentage = 100
    scene.render.fps = fps
    if hasattr(scene.render.image_settings, "media_type"):
        scene.render.image_settings.media_type = "VIDEO"     # Blender 5: video output is a media type
    scene.render.image_settings.file_format = "FFMPEG"
    scene.render.ffmpeg.format = "OGG"
    scene.render.ffmpeg.codec = "THEORA"
    scene.render.ffmpeg.constant_rate_factor = "MEDIUM"
    scene.render.ffmpeg.audio_codec = "VORBIS"
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(Path(out).resolve())
    bpy.ops.render.render(animation=True)
    print("wrote", out)


def convert(src, out, w=854):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.sequence_editor_create()
    strip = scene.sequence_editor.strips.new_movie("movie", str(Path(src).resolve()), 1, 1) \
        if hasattr(scene.sequence_editor, "strips") else \
        scene.sequence_editor.sequences.new_movie("movie", str(Path(src).resolve()), 1, 1)
    try:
        (scene.sequence_editor.strips if hasattr(scene.sequence_editor, "strips") else
         scene.sequence_editor.sequences).new_sound("sound", str(Path(src).resolve()), 2, 1)
    except Exception:
        pass                                   # no audio track
    scene.frame_start, scene.frame_end = 1, strip.frame_final_end - 1
    fps = round(strip.fps) if getattr(strip, "fps", 0) else 24
    h = int(round(w * strip.elements[0].orig_height / max(strip.elements[0].orig_width, 1) / 2) * 2) \
        if strip.elements and strip.elements[0].orig_width else 480
    output(scene, out, w, h, fps)


def trailer(out, seconds=16):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    fps = 24
    scene.frame_start, scene.frame_end = 1, seconds * fps
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.02, 0.02, 0.04, 1)
    scene.world = world
    # skyline: rows of towers sliding past, lit windows
    import random
    random.seed(3)
    glow = bpy.data.materials.new("glow")
    glow.use_nodes = True
    b = glow.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.05, 0.05, 0.07, 1)
    b.inputs["Emission Color"].default_value = (1.0, 0.55, 0.2, 1)
    b.inputs["Emission Strength"].default_value = 0.6
    for k in range(40):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(k * 1.6 - 32, 8 + random.uniform(0, 4), 0))
        o = bpy.context.object
        hgt = random.uniform(2, 9)
        o.scale = (1.2, 1.2, hgt)
        o.location.z = hgt / 2 - 3
        o.data.materials.append(glow)
        o.keyframe_insert("location", frame=1)
        o.location.x -= 14
        o.keyframe_insert("location", frame=scene.frame_end)
    # red robot eyes sweeping
    eye = bpy.data.materials.new("eye")
    eye.use_nodes = True
    e = eye.node_tree.nodes["Principled BSDF"]
    e.inputs["Emission Color"].default_value = (1, 0.1, 0.05, 1)
    e.inputs["Emission Strength"].default_value = 20
    for k, x in enumerate((-3.5, 3.5)):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.25, location=(x, 2, 2.6))
        s = bpy.context.object
        s.data.materials.append(eye)
        s.keyframe_insert("location", frame=1)
        s.location.x += 1.5 if k else -1.5
        s.keyframe_insert("location", frame=scene.frame_end)
    # title cards, one after the other
    cards = [("CINE IMPERIAL", 0, 4), ("apresenta", 4, 6), ("CITY INVADERS", 6, 11), ("Porto Alegre resiste", 11, 16)]
    white = bpy.data.materials.new("title")
    white.use_nodes = True
    w = white.node_tree.nodes["Principled BSDF"]
    w.inputs["Emission Color"].default_value = (1, 0.95, 0.85, 1)
    w.inputs["Emission Strength"].default_value = 3
    for text, t0, t1 in cards:
        bpy.ops.object.text_add(location=(0, 0, 0.3), rotation=(math.pi / 2, 0, 0))
        t = bpy.context.object
        t.data.body = text
        t.data.align_x = "CENTER"
        t.data.size = 1.6 if text.isupper() else 0.9
        t.data.materials.append(white)
        for f, vis in ((1, False), (t0 * fps + 1, True), (t1 * fps, False)):
            t.hide_render = not vis
            t.keyframe_insert("hide_render", frame=max(1, f))
        t.scale = (0.9, 0.9, 0.9)
        t.keyframe_insert("scale", frame=max(1, t0 * fps))
        t.scale = (1.05, 1.05, 1.05)
        t.keyframe_insert("scale", frame=t1 * fps)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    cam.location = (0, -14, 0.8)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    scene.camera = cam
    output(scene, out)


if mode == "convert":
    convert(rest[0], rest[1], int(rest[2]) if len(rest) > 2 else 854)
else:
    trailer(rest[0])
