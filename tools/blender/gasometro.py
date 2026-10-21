"""Usina do Gasômetro (1928 power station, now a cultural centre) and its
117 m chimney, modelled to the OSM footprint and the Commons photo "Usina do
Gasômetro in 2025 (zoom)" (Lenny Maidana, CC BY-SA 4.0): salmon-rendered
three-storey hall with pilasters and tall windows, a higher red-brick
turbine hall with stepped gables and a glass clerestory, the "USINA CEEE"
pediment with its round medallion, and the tapering brick chimney.

    Blender -b --factory-startup --python tools/blender/gasometro.py -- godot/assets/rio_grande_do_sul/landmarks
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402
import landmarks as lm  # noqa: E402

THETA = math.radians(18.0)      # the footprint's long side (game yaw of the model)
# OSM outline around the footprint rectangle's centre, metres (x east, y north)
OUTLINE = [(-41.9, -32.3), (-53.0, 1.5), (22.0, 25.8), (24.6, 17.8), (44.6, 24.3), (47.9, 14.3),
           (35.2, 10.1), (37.9, 1.7), (30.7, -0.6), (33.1, -7.9)]


def local(p):
    """World-aligned offset -> model frame (long side along x)."""
    c, s = math.cos(-THETA), math.sin(-THETA)
    return (p[0] * c - p[1] * s, p[0] * s + p[1] * c)


def offset_inward(pts, d):
    """Anticlockwise polygon moved inwards by d: each edge shifted along its
    left normal, corners where neighbouring shifted edges meet."""
    n = len(pts)
    lines = []
    for i in range(n):
        (ax, ay), (bx, by) = pts[i], pts[(i + 1) % n]
        L = math.hypot(bx - ax, by - ay)
        nx, ny = -(by - ay) / L, (bx - ax) / L
        lines.append(((ax + nx * d, ay + ny * d), (bx - ax, by - ay)))
    out = []
    for i in range(n):
        (p, r), (q, s) = lines[i - 1], lines[i]
        den = r[0] * s[1] - r[1] * s[0]
        if abs(den) < 1e-9:
            out.append(q)
            continue
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / den
        out.append((p[0] + r[0] * t, p[1] + r[1] * t))
    return out


def usina():
    bu.reset()
    pts = [local(p) for p in OUTLINE]
    # facades put the building on their left (+y): walk the outline anticlockwise
    area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    if area < 0:
        pts = pts[::-1]
    floors = [(7.0, 2.2, 4.6, 0.9), (6.0, 2.0, 4.2, 0.8), (5.5, 1.8, 3.4, 0.8)]
    H = sum(f[0] for f in floors)
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        L = math.dist(a, b)
        if L < 3:
            continue
        bays = max(1, int(L / 4.6))
        objs, _ = lm.facade(L, floors, bays, centre_portal=L > 30, arch_ground=True, rustic_base=False,
                            balustrade=False, pediment=(16.0, 4.5) if 30 < L < 40 else None, shutters=False)
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        lm.place(objs, ang, (mid[0], mid[1], 0))
    # solid mass and flat roof inside the outline
    import bmesh
    bm = bmesh.new()
    inner = offset_inward(pts, 0.9)            # behind the window glass
    vs = [bm.verts.new((x, y, 0.0)) for x, y in inner]
    f = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    for v in [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]:
        v.co.z = H
    me = bpy.data.meshes.new("mass")
    bm.to_mesh(me)
    bm.free()
    mass = bpy.data.objects.new("mass", me)
    bpy.context.scene.collection.objects.link(mass)
    lm.add("wall", mass)
    # raised turbine hall over the western main block: red brick, gabled roof
    hx0, hx1, hw = -38.0, 12.0, 20.0
    hz = H + 9.0
    lm.box("brick", (hx1 - hx0, hw, 9.0), ((hx0 + hx1) / 2, 0.0, H + 4.5))
    for k in range(int((hx1 - hx0) / 4)):          # brick pilasters along the hall
        for sy in (-1, 1):
            lm.box("brick", (0.6, 0.4, 9.0), (hx0 + 2 + k * 4, sy * (hw / 2 + 0.2), H + 4.5))
            lm.box("glass", (2.4, 0.05, 5.0), (hx0 + 4 + k * 4, sy * (hw / 2 + 0.03), H + 4.8))
    # gable ends: stepped brick gables
    for x in (hx0, hx1):
        for st in range(5):
            w = hw - st * 3.6
            lm.box("brick", (0.8, w, 1.6), (x, 0.0, hz + 0.8 + st * 1.6))
    # pitched roof with a glass clerestory ridge
    for sy in (-1, 1):
        bpy.ops.mesh.primitive_cube_add(size=1, location=((hx0 + hx1) / 2, sy * hw / 4, hz + 3.2),
                                        rotation=(-sy * math.radians(33), 0, 0))   # each slope falls towards its eave
        r = bpy.context.object
        r.scale = (hx1 - hx0 - 1.0, hw / 2 / math.cos(math.radians(33)), 0.3)
        bpy.ops.object.transform_apply(scale=True)
        lm.add("roof", r)
    lm.box("skylight", (hx1 - hx0 - 6, 2.4, 1.2), ((hx0 + hx1) / 2, 0.0, hz + 6.6))
    # "USINA CEEE" medallion on the eastern annex's river front (round, cream)
    lm.cyl("trim", 1.2, 0.3, (46.0, -6.0, H + 2.4), verts=32,
           rot=Matrix.Rotation(math.pi / 2, 4, "Y"))
    lm.finish("usina_gasometro", (0.86, 0.56, 0.46), (0.94, 0.87, 0.78))


def chimney(height=117.0, r0=2.2, r1=1.55):
    bu.reset()
    lm.box("brickc", (6.0, 6.0, 12.0), (0, 0, 6.0))                   # square pedestal
    lm.box("trim", (6.6, 6.6, 0.6), (0, 0, 12.3))
    lm.cyl("brickc", r0, height - 12.6, (0, 0, 12.6 + (height - 12.6) / 2), verts=48, r2=r1)
    for k in range(1, 6):                                                # iron bands
        z = 12.6 + k * (height - 12.6) / 6
        r = r0 + (r1 - r0) * (z - 12.6) / (height - 12.6)
        lm.torus("metal", r + 0.05, 0.08, (0, 0, z), seg=48, ring=6)
    # crown: corbelled brick ring and a cap
    for k, (rr, h) in enumerate([(r1 + 0.25, 0.8), (r1 + 0.4, 0.6), (r1 + 0.25, 0.5)]):
        lm.cyl("brickc", rr, h, (0, 0, height - 2.0 + k * 0.7), verts=48)
    lm.finish("chimney_gasometro", (0.62, 0.36, 0.28), (0.72, 0.68, 0.6),
              extra={"brickc": bu.principled("chimney_brick", (0.62, 0.36, 0.28), 0.85)})


if __name__ == "__main__":
    chimney()
    usina()
