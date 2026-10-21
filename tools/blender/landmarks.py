"""Porto Alegre landmarks modelled to their OSM footprints, replacing the
photo-textured boxes: Mercado Público (1869, neoclassical ring around a
covered courtyard, corner pavilions with mansard roofs) and the Paço
Municipal (1901, eclectic: rusticated base, colonnaded centre with clock
pediment, mansard with oval dormers).

    Blender -b --factory-startup --python tools/blender/landmarks.py -- godot/assets/rio_grande_do_sul/landmarks

Each model: metres, centred on its footprint, main facade towards -Z in
glTF (Blender -Y), ground at y = 0.
"""
import math
import random
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bakeutil as bu  # noqa: E402

OUT = Path(sys.argv[sys.argv.index("--") + 1])
# geometry is accumulated straight into one bmesh per material: thousands of
# bpy objects (one per window, moulding, baluster) make Blender crawl
BMS = {}              # material key -> bmesh


def _bm(key):
    if key not in BMS:
        BMS[key] = bmesh.new()
    return BMS[key]


def box(key, size, loc, rot_z=0.0):
    M = Matrix.Translation(loc) @ Matrix.Rotation(rot_z, 4, "Z") @ Matrix.Diagonal((*size, 1.0))
    return list(bmesh.ops.create_cube(_bm(key), size=1.0, matrix=M)["verts"])


def cyl(key, r, h, loc, verts=12, r2=None, rot=None):
    M = Matrix.Translation(loc) @ (rot if rot is not None else Matrix.Identity(4))
    return list(bmesh.ops.create_cone(_bm(key), cap_ends=True, segments=verts, radius1=r,
                                      radius2=r if r2 is None else r2, depth=h, matrix=M)["verts"])


def torus(key, R, r, loc, rot=None, seg=24, ring=8, arc=1.0):
    """A torus (or an arc of one) in the XY plane, then rotated and moved."""
    bm = _bm(key)
    M = Matrix.Translation(loc) @ (rot if rot is not None else Matrix.Identity(4))
    n = seg + (1 if arc < 1.0 else 0)
    grid = []
    for i in range(n):
        a = math.tau * arc * i / seg
        row = []
        for j in range(ring):
            b = math.tau * j / ring
            p = Vector(((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r * math.sin(b)))
            row.append(bm.verts.new(M @ p))
        grid.append(row)
    rows = n if arc < 1.0 else n + 1
    for i in range(rows - 1):
        r0, r1 = grid[i], grid[(i + 1) % n]
        for j in range(ring):
            bm.faces.new((r0[j], r1[j], r1[(j + 1) % ring], r0[(j + 1) % ring]))
    return [v for row in grid for v in row]


def add(key, obj):
    """Absorb a bpy-built object (bmesh can't make it) into the material mesh."""
    bm = _bm(key)
    n = len(bm.verts)
    me = obj.data
    me.transform(obj.matrix_world)
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    verts = list(bm.verts[n:])
    bpy.data.objects.remove(obj)
    return verts


def _flat(handles):
    for h in handles:
        if isinstance(h, list):
            yield from _flat(h)
        else:
            yield h


def place(handles, angle, offset):
    """Rotate about Z (around the origin) and move: facade frame -> building."""
    R = Matrix.Rotation(angle, 3, "Z")
    off = Vector(offset)
    for v in set(_flat(handles)):
        v.co = R @ v.co + off


def translate(handles, offset):
    off = Vector(offset)
    for v in set(_flat(handles)):
        v.co += off


def window(ox, z0, w, h, arch=False, depth=0.45, frame="trim", glass="glass", shutters=False, roller=False):
    """Opening in the facade plane (outer face at y = 0): glass set back,
    frame and mullions, a moulded surround; arch adds a fanlight."""
    objs = []
    objs.append(box(glass, (w, 0.05, h), (ox, depth, z0 + h / 2)))
    if roller:                                   # roller shutter half down, as in the photos
        objs.append(box("shutter_roll", (w, 0.04, h * 0.42), (ox, depth - 0.08, z0 + h * 0.79)))
    t = 0.07
    for x in (ox - w / 2 + t / 2, ox + w / 2 - t / 2):
        objs.append(box(frame, (t, 0.08, h), (x, depth - 0.05, z0 + h / 2)))
    objs.append(box(frame, (w, 0.08, t), (ox, depth - 0.05, z0 + h * 0.62)))      # transom
    objs.append(box(frame, (t * 0.7, 0.08, h), (ox, depth - 0.05, z0 + h / 2)))    # mullion
    # reveal (the wall thickness inside the opening)
    for x in (ox - w / 2 - 0.02, ox + w / 2 + 0.02):
        objs.append(box("wall", (0.04, depth, h), (x, depth / 2, z0 + h / 2)))
    # surround: architrave and a sill
    s = 0.16
    objs.append(box("trim", (w + 2 * s, 0.1, s), (ox, -0.03, z0 + h + s / 2)))
    for x in (ox - w / 2 - s / 2, ox + w / 2 + s / 2):
        objs.append(box("trim", (s, 0.1, h), (x, -0.03, z0 + h / 2)))
    objs.append(box("trim", (w + 2 * s + 0.1, 0.22, 0.1), (ox, -0.08, z0 - 0.05)))
    if arch:
        rx = Matrix.Rotation(math.pi / 2, 4, "X")
        objs.append(cyl(glass, w / 2, 0.05, (ox, depth, z0 + h), verts=20, rot=rx))
        objs.append(torus("trim", w / 2 + 0.08, 0.09, (ox, -0.02, z0 + h), rot=rx, seg=12, ring=6, arc=0.5))
    if shutters:
        for sx in (-1, 1):
            objs.append(box("shutter", (w / 2, 0.04, h * 0.98), (ox + sx * (w * 0.75 + 0.18), -0.05, z0 + h / 2)))
    return objs


def facade(L, floors, bays, centre_portal=True, pilasters=True, rustic_base=True, balustrade=True,
           arch_ground=True, pediment=None, shutters=True, ground_depth=0.45, roller=False, ac=0.0):
    """One straight facade along x in [-L/2, L/2], outer face at y = 0 (the
    building is at +y), floors = [(height, window w, window h, sill)].
    Returns its objects."""
    objs = []
    b = L / bays
    z = 0.0
    for fi, (fh, ww, wh, sill) in enumerate(floors):
        ground = fi == 0
        key = "base" if ground and rustic_base else "wall"
        for i in range(bays):
            cx = -L / 2 + b * (i + 0.5)
            portal = centre_portal and ground and i == bays // 2
            w = ww * (1.35 if portal else 1.0)
            h = (wh * 1.15 if portal else wh) if not ground else wh
            s = 0.0 if (ground and arch_ground) or portal else sill
            top = s + h + (w / 2 if (ground and arch_ground) else 0.0)
            # piers either side of the opening, spandrels above and below
            pier = (b - w) / 2
            for x in (cx - b / 2 + pier / 2, cx + b / 2 - pier / 2):
                objs.append(box(key, (pier, 0.5, fh), (x, 0.25, z + fh / 2)))
            if s > 0:
                objs.append(box(key, (w, 0.5, s), (cx, 0.25, z + s / 2)))
            if fh - top > 0.01:
                objs.append(box(key, (w, 0.5, fh - top), (cx, 0.25, z + top + (fh - top) / 2)))
            objs += window(cx, z + s, w, h, arch=ground and arch_ground, shutters=shutters and not ground,
                           depth=ground_depth if ground else 0.45, roller=roller and not ground)
            if ac and not ground and random.random() < ac:     # an air conditioner under the window
                objs.append(box("ac", (0.8, 0.35, 0.55), (cx + random.uniform(-0.2, 0.2), -0.2, z + s - 0.45)))
            if rustic_base and ground:      # horizontal rustication grooves
                for g in range(1, int(fh / 0.45)):
                    for x in (cx - b / 2 + pier / 2, cx + b / 2 - pier / 2):
                        objs.append(box("groove", (pier, 0.02, 0.04), (x, -0.005, z + g * 0.45)))
            if pilasters and not ground:
                objs.append(box("trim", (0.42, 0.18, fh - 0.3), (cx - b / 2, -0.09, z + fh / 2 - 0.15)))
                objs.append(box("trim", (0.6, 0.24, 0.3), (cx - b / 2, -0.12, z + fh - 0.15)))   # capital
        if pilasters and not ground:
            objs.append(box("trim", (0.42, 0.18, fh - 0.3), (L / 2, -0.09, z + fh / 2 - 0.15)))
        z += fh
        # string course between floors
        objs.append(box("trim", (L + 0.3, 0.3, 0.32), (0, -0.12, z - 0.16)))
    # main cornice and parapet with balusters
    objs.append(box("trim", (L + 0.8, 0.8, 0.45), (0, -0.25, z + 0.22)))
    objs.append(box("trim", (L + 0.6, 0.6, 0.2), (0, -0.15, z + 0.55)))
    if balustrade:
        objs.append(box("trim", (L, 0.35, 0.18), (0, 0.0, z + 0.74)))
        objs.append(box("trim", (L, 0.4, 0.15), (0, 0.0, z + 1.42)))
        n = int(L / 0.32)
        for k in range(n):
            objs.append(cyl("trim", 0.075, 0.6, (-L / 2 + (k + 0.5) * L / n, 0.0, z + 1.05), verts=8))
    if pediment:
        pw, ph = pediment
        bm = _bm("trim")
        tri = [bm.verts.new(c) for c in ((-pw / 2, -0.3, z + 0.65), (pw / 2, -0.3, z + 0.65), (0, -0.3, z + 0.65 + ph))]
        back = [bm.verts.new(v.co + Vector((0, 0.6, 0))) for v in tri]
        bm.faces.new(tri)
        bm.faces.new(back[::-1])
        for i in range(3):
            bm.faces.new((tri[i], back[i], back[(i + 1) % 3], tri[(i + 1) % 3]))
        objs.append(tri + back)
    return objs, z


def mansard(w, d, z0, h, inset=1.2, dormers=0, oval=False):
    """Mansard roof: steep slate slopes and a flat top."""
    M = Matrix.Translation((0, 0, z0 + h / 2)) @ Matrix.Diagonal((w / math.sqrt(2), d / math.sqrt(2), 1.0, 1.0)) \
        @ Matrix.Rotation(math.pi / 4, 4, "Z")
    m = list(bmesh.ops.create_cone(_bm("slate"), cap_ends=True, segments=4, radius1=1.0,
                                   radius2=1 - inset / max(w, d) * 2, depth=h, matrix=M)["verts"])
    objs = [m]
    for side in range(4):
        L = w if side % 2 == 0 else d
        for k in range(dormers):
            x = -L / 2 + (k + 0.5) * L / dormers
            if oval:
                o1 = torus("trim", 0.45, 0.12, (x, -inset * 0.55, z0 + h * 0.45),
                           rot=Matrix.Rotation(math.pi / 2, 4, "X"), seg=16, ring=6)
                o2 = box("glass", (0.7, 0.05, 0.7), (x, -inset * 0.45, z0 + h * 0.45))
                ds = [o1, o2]
            else:
                ds = [box("trim", (1.2, inset, 1.6), (x, -inset * 0.4, z0 + h * 0.5)),
                      box("glass", (0.8, 0.05, 1.0), (x, -inset * 0.92, z0 + h * 0.48))]
            angle = [0, math.pi / 2, math.pi, -math.pi / 2][side]
            off = [(0, -d / 2, 0), (w / 2, 0, 0), (0, d / 2, 0), (-w / 2, 0, 0)][side]
            place(ds, angle, off)
            objs += ds
    return objs


def four_sides(w, d, build_side):
    """Run build_side(L, i) for the four sides and turn each into place."""
    for i, (L, angle, off) in enumerate([(w, 0, (0, -d / 2, 0)), (d, math.pi / 2, (w / 2, 0, 0)),
                                         (w, math.pi, (0, d / 2, 0)), (d, -math.pi / 2, (-w / 2, 0, 0))]):
        objs = build_side(L, i)
        place(objs, angle, off)


def finish(name, wall_colour, trim_colour, extra=None):
    m = {
        "wall": bu.principled(f"{name}_wall", wall_colour, 0.85),
        "base": bu.principled(f"{name}_base", tuple(c * 0.92 for c in wall_colour), 0.85),
        "trim": bu.principled(f"{name}_trim", trim_colour, 0.7),
        "groove": bu.principled("groove", tuple(c * 0.55 for c in wall_colour), 0.9),
        "glass": bu.principled("window_glass", (0.07, 0.09, 0.11), 0.08, 0.6),
        "shutter": bu.principled("shutter", (0.22, 0.3, 0.24), 0.6),
        "slate": bu.principled("slate", (0.16, 0.17, 0.19), 0.55, 0.2),
        "roof": bu.principled("roof", (0.35, 0.34, 0.33), 0.9),
        "metal": bu.principled("ironwork", (0.12, 0.13, 0.14), 0.4, 0.8),
        "skylight": bu.principled("skylight", (0.55, 0.65, 0.7), 0.05, 0.3),
        "brick": bu.principled(f"{name}_brick", (0.75, 0.42, 0.32), 0.85),
        "shutter_roll": bu.principled("roller_shutter", (0.86, 0.86, 0.84), 0.6),
        "ac": bu.principled("air_conditioner", (0.9, 0.9, 0.88), 0.45),
    }
    m.update(extra or {})
    objs = []
    for key, bm in BMS.items():
        me = bpy.data.meshes.new(f"{name}_{key}")
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        if key == "screen":
            # the film is mapped across the screen as seen from the seats
            # (looking +x: right is -y, top is +z)
            uv = bm.loops.layers.uv.new()
            ys = [v.co.y for v in bm.verts]
            zs = [v.co.z for v in bm.verts]
            for f in bm.faces:
                for lp in f.loops:
                    lp[uv].uv = ((max(ys) - lp.vert.co.y) / (max(ys) - min(ys)),
                                 (lp.vert.co.z - min(zs)) / (max(zs) - min(zs)))
        bm.to_mesh(me)
        bm.free()
        o = bpy.data.objects.new(f"{name}_{key}", me)
        bpy.context.scene.collection.objects.link(o)
        me.materials.append(m[key])
        # wall / base / brick get real PBR textures in the game (triplanar,
        # tinted with this colour - see main.gd _landmarks): no UVs to bake
        objs.append(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs + MARKERS:
        o.select_set(True)
    OUT.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(OUT / f"{name}.glb"), export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True)
    print("wrote", OUT / f"{name}.glb")
    BMS.clear()


# ---- Mercado Público: 88 x 87 m ring, 11 m deep, two floors, corner pavilions ---
def mercado():
    bu.reset()
    W, D, RING = 88.0, 87.0, 11.5
    floors = [(5.6, 2.4, 3.4, 0.0), (5.0, 1.5, 2.6, 0.9)]
    PAV = 13.0          # corner pavilion size

    def side(L, i):
        objs = []
        # straight run between the corner pavilions, then the pavilions' faces
        run, z = facade(L - 2 * PAV, floors, int((L - 2 * PAV) / 4.2), centre_portal=True,
                        pediment=(14.0, 3.2))
        objs += run
        for sx in (-1, 1):
            pav, zp = facade(PAV, floors + [(4.2, 1.4, 2.2, 0.9)], 3, centre_portal=False, balustrade=False)
            translate(pav, (sx * (L / 2 - PAV / 2), -0.6, 0))      # pavilions stand forward of the run
            objs += pav
        return objs

    four_sides(W, D, side)
    # wall mass behind the facades (ring), roofs, courtyard skylight
    h = sum(f[0] for f in floors)
    for (sx, sy, cx, cy) in [(W, RING, 0, -D / 2 + RING / 2), (W, RING, 0, D / 2 - RING / 2),
                             (RING, D - 2 * RING, -W / 2 + RING / 2, 0), (RING, D - 2 * RING, W / 2 - RING / 2, 0)]:
        box("wall", (sx - 1.0, sy - 1.0, h), (cx, cy, h / 2))
        box("roof", (sx - 0.4, sy - 0.4, 0.3), (cx, cy, h + 0.15))
    for cx in (-1, 1):
        for cy in (-1, 1):
            hp = h + 4.2
            box("wall", (PAV - 0.5, PAV - 0.5, hp), (cx * (W / 2 - PAV / 2), cy * (D / 2 - PAV / 2), hp / 2))
            ms = mansard(PAV + 0.6, PAV + 0.6, hp + 1.0, 4.0, inset=1.4, dormers=1, oval=True)
            place(ms, 0, (cx * (W / 2 - PAV / 2 + 0.3), cy * (D / 2 - PAV / 2 + 0.3), 0))
    # the courtyard's glass and iron roof
    cw, cd = W - 2 * RING, D - 2 * RING
    box("skylight", (cw, cd, 0.08), (0, 0, h + 2.5))
    for k in range(12):
        box("metal", (0.15, cd, 0.3), (-cw / 2 + (k + 0.5) * cw / 12, 0, h + 2.4))
    box("metal", (cw, 0.2, 0.4), (0, 0, h + 2.4))
    for cx in (-1, 1):
        for cy in (-1, 1):
            cyl("metal", 0.15, h + 2.5, (cx * cw / 4, cy * cd / 4, (h + 2.5) / 2))
    finish("mercado_publico", (0.86, 0.66, 0.33), (0.93, 0.89, 0.8))


# ---- Paço Municipal: 37 x 37 m, rusticated ground floor, two piani, mansard -----
def paco():
    bu.reset()
    W = D = 37.0
    floors = [(5.0, 1.6, 2.8, 0.8), (5.4, 1.6, 3.2, 0.6), (4.6, 1.4, 2.6, 0.7)]

    def side(L, i):
        objs, z = facade(L, floors, 9, centre_portal=True, pediment=(12.0, 3.4) if i == 0 else None,
                         arch_ground=False)
        if i == 0:
            # colonnaded central avant-corps with a clock in the pediment
            for k in range(4):
                x = -4.5 + k * 3.0
                objs.append(cyl("trim", 0.42, floors[1][0] + floors[2][0] - 0.6, (x, -1.0, 5.0 + 5.0 - 0.3), verts=16))
            objs.append(box("trim", (11.5, 1.6, 0.4), (0, -0.8, 5.2)))                   # balcony
            for k in range(20):
                objs.append(cyl("trim", 0.07, 0.8, (-5.4 + k * 0.57, -1.45, 5.8), verts=8))
            bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=1.1, depth=0.25, location=(0, -0.7, z + 2.2),
                                                rotation=(math.pi / 2, 0, 0))
            objs.append(add("trim", bpy.context.object))
            bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.9, depth=0.1, location=(0, -0.86, z + 2.2),
                                                rotation=(math.pi / 2, 0, 0))
            objs.append(add("shutter", bpy.context.object))                                # clock face
        return objs

    four_sides(W, D, side)
    h = sum(f[0] for f in floors)
    box("wall", (W - 1.0, D - 1.0, h), (0, 0, h / 2))
    mansard(W + 0.8, D + 0.8, h + 1.4, 4.5, inset=1.6, dormers=6, oval=True)
    finish("paco_municipal", (0.93, 0.84, 0.6), (0.96, 0.94, 0.88))


def offset_inward(pts, d):
    """Anticlockwise polygon moved inwards by d (edges shifted, corners met)."""
    n = len(pts)
    lines = []
    for i in range(n):
        (ax, ay), (bx, by) = pts[i], pts[(i + 1) % n]
        L = math.hypot(bx - ax, by - ay)
        lines.append(((ax - (by - ay) / L * d, ay + (bx - ax) / L * d), (bx - ax, by - ay)))
    out = []
    for i in range(n):
        (p, r), (q, t) = lines[i - 1], lines[i]
        den = r[0] * t[1] - r[1] * t[0]
        if abs(den) < 1e-9:
            out.append(q)
            continue
        k = ((q[0] - p[0]) * t[1] - (q[1] - p[1]) * t[0]) / den
        out.append((p[0] + r[0] * k, p[1] + r[1] * k))
    return out


def prism(key, pts, z0, z1):
    """Vertical prism over a polygon: building mass behind the facades."""
    bm = _bm(key)
    lo = [bm.verts.new((x, y, z0)) for x, y in pts]
    hi = [bm.verts.new((x, y, z1)) for x, y in pts]
    bm.faces.new(lo[::-1])
    bm.faces.new(hi)
    for i in range(len(pts)):
        j = (i + 1) % len(pts)
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))


def outline_facades(pts, floors, bay=3.6, **kw):
    """A facade along every edge of an anticlockwise outline; returns the pieces."""
    out = []
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        L = math.dist(a, b)
        if L < 2.5:
            continue
        objs, _ = facade(L, floors, max(1, int(L / bay)), **kw)
        place(objs, math.atan2(b[1] - a[1], b[0] - a[0]), ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, 0))
        out += objs
    return out


# ---- Sulacap (Av. Borges de Medeiros): gallery of pilotis, terracotta-framed
# windows with roller shutters and air conditioners, set-back top floor ----------
def sulacap():
    bu.reset()
    random.seed(11)
    theta = math.radians(3.7)
    raw = [(-8.4, -17.6), (-11.2, 1.9), (-10.4, 2.0), (-12.4, 16.3), (10.2, 17.7), (10.9, 4.0), (8.5, 3.6), (11.1, -14.6)]
    c, s_ = math.cos(-theta), math.sin(-theta)
    pts = [(x * c - y * s_, x * s_ + y * c) for x, y in raw]
    if sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts))) < 0:
        pts = pts[::-1]
    G = 6.5
    floors = [(G, 3.2, 5.0, 0.0)] + [(3.4, 1.5, 1.9, 0.9)] * 4
    outline_facades(pts, floors, centre_portal=False, pilasters=False, rustic_base=False, balustrade=False,
                    arch_ground=False, shutters=False, ground_depth=3.0, roller=True, ac=0.45)
    H = sum(f[0] for f in floors)
    prism("wall", offset_inward(pts, 3.2), 0.0, G)              # shops behind the gallery
    prism("wall", offset_inward(pts, 0.9), G, H)                 # behind the upper windows
    prism("trim", offset_inward(pts, -0.6), G - 0.05, G + 0.3)   # the gallery's slab edge / marquee
    # set-back top floor with plain windows, lifted onto the roof
    top = offset_inward(pts, 2.0)
    translate(outline_facades(top, [(3.2, 1.4, 1.7, 0.9)], centre_portal=False, pilasters=False, rustic_base=False,
                              balustrade=False, arch_ground=False, shutters=False, roller=True), (0, 0, H))
    prism("wall", offset_inward(top, 0.9), H, H + 3.2)
    prism("roof", offset_inward(pts, 0.4), H - 0.05, H + 0.25)
    finish("sulacap", (0.8, 0.73, 0.6), (0.62, 0.36, 0.24))


def marker(name, loc):
    """An empty the game reads: pickup_<kind> spawns that pickup, lamp_* a light."""
    e = bpy.data.objects.new(name, None)
    e.location = loc
    bpy.context.scene.collection.objects.link(e)
    MARKERS.append(e)


MARKERS = []


def sign_text(text, loc, size, depth=0.04, key="sign_text"):
    """Raised lettering (a font converted to a mesh), reading along +x, facing -y."""
    bpy.ops.object.text_add(location=loc, rotation=(math.pi / 2, 0, 0))
    t = bpy.context.object
    t.data.body = text
    t.data.size = size
    t.data.extrude = depth
    t.data.align_x = "CENTER"
    t.data.align_y = "CENTER"
    bpy.ops.object.convert(target="MESH")
    return add(key, bpy.context.object)


# ---- Ed. Missões with the Farmácias São João on its ground floor (enterable) ----
def farmacia():
    bu.reset()
    MARKERS.clear()
    # the footprint's bounding rectangle is 12.8 m deep, but the neighbour's
    # wall (Antiga Livraria do Globo) stands 0.6 m into it at the back: build
    # 11.6 m deep and shift towards the street so the shop front stays put
    W, D = 28.5, 11.6
    SHIFT = 0.6
    G = 4.2                                    # shop storey
    up = [(3.25, 1.7, 1.5, 0.95)] * 17
    # the tower: upper storeys on all four sides, raised above the shop
    def side(L, i):
        objs, z = facade(L, up, max(3, int(L / 3.2)), centre_portal=False, pilasters=False, rustic_base=False,
                         balustrade=False, arch_ground=False, shutters=False)
        translate(objs, (0, 0, G))
        if i != 2:                             # blind ground floor on the other sides
            objs.append(box("wall", (L, 0.5, G), (0, 0.25, G / 2)))
        objs.append(box("trim", (L + 0.4, 1.2, 0.35), (0, -0.4, G + 0.1)))      # canopy slab over the street
        return objs
    four_sides(W, D, side)
    top = G + sum(f[0] for f in up)
    box("wall", (W - 1.8, D - 1.8, top - G - 0.3), (0, 0, G + 0.3 + (top - G - 0.3) / 2))   # tower mass behind the windows
    box("roof", (W - 0.6, D - 0.6, 0.3), (0, 0, top + 0.15))
    box("roof", (5.0, 4.0, 3.0), (3.0, 1.0, top + 1.5))                        # lift machine room
    # shop front on the +y side (the street): slim columns, glass, an open door
    y = D / 2
    cols = 7
    for k in range(cols + 1):
        x = -W / 2 + k * W / cols
        box("trim", (0.35, 0.4, G), (x, y - 0.2, G / 2))
    door = 2.6
    for k in range(cols):
        x0, x1 = -W / 2 + k * W / cols + 0.2, -W / 2 + (k + 1) * W / cols - 0.2
        if x0 < door / 2 and x1 > -door / 2:   # the bay with the door: glass either side
            for a, b in ((x0, -door / 2), (door / 2, x1)):
                if b - a > 0.2:
                    box("glass", (b - a, 0.04, 3.0), ((a + b) / 2, y - 0.25, 1.5))
            box("metal", (door + 0.2, 0.08, 0.12), (0, y - 0.25, 3.0))          # door frame head
        else:
            box("glass", (x1 - x0, 0.04, 3.0), ((x0 + x1) / 2, y - 0.25, 1.5))
            box("trim", (x1 - x0, 0.3, 0.45), ((x0 + x1) / 2, y - 0.2, 0.22))   # stall riser
    # sign band: blue with white lettering and the red cross
    box("sign", (W * 0.7, 0.25, 1.3), (0, y + 0.05, 3.55))
    # the Farmácias São João logo (Wikimedia Commons, CC BY-SA 4.0) on a white panel
    logo = bpy.data.materials.new("sao_joao_logo")
    logo.use_nodes = True
    lt = logo.node_tree
    li = lt.nodes.new("ShaderNodeTexImage")
    li.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / "sao_joao_logo_commons.jpg"))
    li.image.pack()
    lt.links.new(li.outputs["Color"], lt.nodes["Principled BSDF"].inputs["Base Color"])
    lt.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.4
    bpy.ops.mesh.primitive_plane_add(size=1, location=(0, y + 0.19, 3.55), rotation=(math.pi / 2, 0, math.pi))
    panel = bpy.context.object
    panel.name = "sign_logo"
    panel.scale = (1.2 * 960 / 258, 1.2, 1)      # the logo's 960:258 aspect, 1.2 m tall
    panel.data.materials.append(logo)
    MARKERS.append(panel)                       # exported as it is (it has its own UVs)
    # interior: floor, ceiling with light panels, white walls
    box("floor", (W - 1.0, D - 1.0, 0.04), (0, 0, 0.02))
    box("ceiling", (W - 1.0, D - 1.0, 0.1), (0, 0, G - 0.05))
    for x in (-9, -3, 3, 9):
        for yy in (-2.5, 2.5):
            box("light", (1.2, 0.6, 0.04), (x, yy, G - 0.11))
            marker(f"lamp_{x}_{yy}", (x, yy, G - 0.4))
    # gondolas: along the back wall and two islands, stocked with boxes
    import random
    random.seed(4)
    colours = ["prod_red", "prod_blue", "prod_white", "prod_green", "prod_yellow", "prod_pink"]
    def gondola(cx, cy, length, rot=0.0):
        objs = [box("shelf", (length, 0.5, 0.05), (cx, cy, 0.12 + k * 0.42)) for k in range(5)]
        objs.append(box("shelf", (length, 0.06, 1.95), (cx, cy + 0.25, 0.97)))
        for k in range(5):
            x = cx - length / 2 + 0.05
            while x < cx + length / 2 - 0.12:
                w = random.uniform(0.07, 0.16)
                h = random.uniform(0.1, 0.3)
                objs.append(box(random.choice(colours), (w, 0.16, h), (x + w / 2, cy - 0.1, 0.15 + k * 0.42 + h / 2)))
                x += w + 0.015
        if rot:
            place(objs, rot, (0, 0, 0))
        return objs
    gondola(-7.5, -D / 2 + 1.0, 9.0)
    gondola(7.5, -D / 2 + 1.0, 9.0)
    gondola(-6.0, 0.6, 7.0)
    gondola(6.0, 0.6, 7.0)
    # counter with the pharmacist's till; the remedy waits on it
    box("counter", (5.0, 0.8, 1.05), (0, -D / 2 + 2.2, 0.52))
    box("trim", (5.2, 0.9, 0.05), (0, -D / 2 + 2.2, 1.07))
    box("metal", (0.4, 0.35, 0.3), (-1.5, -D / 2 + 2.2, 1.25))
    marker("pickup_remedio", (0.6, -D / 2 + 2.2, 1.1))
    for bm in BMS.values():
        for v in bm.verts:
            v.co.y += SHIFT
    for e in MARKERS:
        e.location.y += SHIFT
    finish("farmacia_missoes", (0.8, 0.78, 0.74), (0.9, 0.9, 0.88), extra={
        "sign": bu.principled("sign_white", (0.96, 0.96, 0.95), 0.4),
        "sign_text": bu.principled("sign_letters", (1, 1, 1), 0.3),
        "cross": bu.principled("sign_cross", (0.85, 0.05, 0.08), 0.4),
        "floor": bu.principled("floor_tiles", (0.88, 0.88, 0.86), 0.25),
        "ceiling": bu.principled("ceiling", (0.95, 0.95, 0.95), 0.9),
        "light": _emissive("panel_light", (1, 0.98, 0.92), 4.0),
        "shelf": bu.principled("gondola", (0.92, 0.93, 0.95), 0.4, 0.3),
        "counter": bu.principled("counter", (0.2, 0.32, 0.6), 0.5),
        **{c: bu.principled(c, col, 0.5) for c, col in zip(colours, [(0.8, 0.1, 0.1), (0.1, 0.3, 0.8), (0.95, 0.95, 0.95),
                                                                     (0.1, 0.6, 0.3), (0.95, 0.8, 0.1), (0.95, 0.5, 0.7)])}})


def _see_through(name, colour, alpha):
    """Clear glass: blended, so glTF exports it with alphaMode BLEND."""
    m = bu.principled(name, colour, 0.05)
    m.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = alpha
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = "BLENDED"
    else:
        m.blend_method = "BLEND"
    return m


def _emissive(name, colour, strength):
    m = bu.principled(name, colour, 0.5)
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Emission Color"].default_value = (*colour, 1)
    b.inputs["Emission Strength"].default_value = strength
    return m


# ---- Cine Imperial (Praça da Alfândega): art deco street cinema, enterable ----
def cinema():
    bu.reset()
    MARKERS.clear()
    W, D, H = 25.0, 17.3, 10.0          # front on the short -x side, facing the praça
    LOBBY = 6.5

    def side(L, i):
        objs = []
        if i == 3:
            # the front: two storeys of art deco piers and fins around the entrance
            for k in range(7):
                x = -L / 2 + 0.6 + k * (L - 1.2) / 6
                objs.append(box("wall", (0.9, 0.6, H), (x, 0.3, H / 2)))
                objs.append(box("trim", (0.35, 0.3, H - 5.2), (x, -0.12, 5.2 + (H - 5.2) / 2)))
            for k in range(6):
                x0 = -L / 2 + 0.6 + k * (L - 1.2) / 6 + 0.45
                x1 = -L / 2 + 0.6 + (k + 1) * (L - 1.2) / 6 - 0.45
                cx, w = (x0 + x1) / 2, x1 - x0
                objs.append(box("wall", (w, 0.6, 0.8), (cx, 0.3, 4.6)))                 # band under the marquee
                objs.append(box("glass", (w, 0.05, 3.2), (cx, 0.5, 6.9)))               # tall upper windows
                objs.append(box("wall", (w, 0.6, 1.0), (cx, 0.3, H - 0.5)))
                if k in (2, 3):
                    continue                                                            # the doors: open
                objs.append(box("poster", (w * 0.7, 0.05, 2.2), (cx, -0.04, 2.2)))       # film posters
                objs.append(box("wall", (w, 0.6, 4.2), (cx, 0.33, 2.1)))
            # stepped parapet with a central tower panel
            for st, (w, h) in enumerate([(L, 0.8), (L * 0.55, 1.6), (L * 0.25, 2.8)]):
                objs.append(box("trim", (w, 0.7, h), (0, 0.15, H + h / 2)))
            # the marquee: lit underside, bulbs along the edge, CINE IMPERIAL on top
            objs.append(box("trim", (L * 0.82, 2.6, 0.5), (0, -1.3, 4.3)))
            objs.append(box("light", (L * 0.78, 2.3, 0.04), (0, -1.3, 4.03)))
            for k in range(40):
                x = -L * 0.4 + k * L * 0.8 / 39
                objs.append(cyl("bulb", 0.07, 0.07, (x, -2.62, 4.3), verts=6))
            objs.append(box("sign", (L * 0.7, 0.2, 1.3), (0, -2.0, 5.25)))
            txt = sign_text("CINE IMPERIAL", (0, -2.12, 5.25), 0.95, key="neon")
            objs.append(txt)
        else:
            objs.append(box("wall", (L, 0.5, H), (0, 0.25, H / 2)))
            objs.append(box("trim", (L + 0.3, 0.4, 0.5), (0, -0.05, H - 0.25)))
        return objs

    four_sides(W, D, side)
    box("roof", (W - 0.6, D - 0.6, 0.3), (0, 0, H - 0.15))
    # lobby: red carpet, ticket booth, wall to the hall with an open doorway
    x0 = -W / 2 + 0.6
    box("carpet", (LOBBY, D - 1.2, 0.03), (x0 + LOBBY / 2, 0, 0.015))
    box("counter", (1.2, 3.0, 1.15), (x0 + LOBBY - 1.4, -D / 2 + 2.6, 0.58))
    box("glass", (0.04, 3.0, 1.0), (x0 + LOBBY - 2.0, -D / 2 + 2.6, 1.7))
    xw = x0 + LOBBY
    for (y0, y1) in ((-D / 2 + 0.5, -1.4), (1.4, D / 2 - 0.5)):
        box("inner", (0.3, y1 - y0, H - 0.5), (xw, (y0 + y1) / 2, (H - 0.5) / 2))
    box("inner", (0.3, 2.8, H - 3.2), (xw, 0, 3.2 + (H - 3.2) / 2))
    for k, yy in enumerate((-3.5, 3.5)):
        marker(f"lamp_lobby{k}", (x0 + LOBBY / 2, yy, 3.6))
    # the hall: stepped floor rising to the back, rows of red seats, the screen
    hx0, hx1 = xw + 0.3, W / 2 - 0.6
    box("hall", (hx1 - hx0, D - 1.2, 0.03), ((hx0 + hx1) / 2, 0, 0.015))
    rows = 9
    for r in range(rows):
        x = hx1 - 5.0 - r * 1.1                      # first row 5 m from the screen
        step = 0.22 * r
        if step > 0:
            box("hall", (1.1, D - 1.2, step), (x, 0, step / 2))
        for k in range(12):
            y = -D / 2 + 1.8 + k * (D - 3.6) / 11
            if abs(y) < 0.7:
                continue                              # centre aisle
            box("seat", (0.5, 0.5, 0.42), (x, y, step + 0.21))
            box("seat", (0.12, 0.5, 0.6), (x - 0.25, y, step + 0.62))
    # dark lining: side walls, the screen wall and the ceiling of the hall
    for sy in (-1, 1):
        box("inner", (hx1 - hx0, 0.1, H - 0.6), ((hx0 + hx1) / 2, sy * (D / 2 - 0.65), (H - 0.6) / 2))
    box("inner", (0.1, D - 1.2, H - 0.6), (hx1 - 0.05, 0, (H - 0.6) / 2))
    box("inner", (hx1 - hx0, D - 1.2, 0.1), ((hx0 + hx1) / 2, 0, H - 0.65))
    box("screen", (0.05, 8.0, 3.6), (hx1 - 0.15, 0, 3.6))
    box("trim", (0.2, 8.6, 0.3), (hx1 - 0.12, 0, 5.55))
    box("trim", (0.2, 8.6, 0.3), (hx1 - 0.12, 0, 1.65))
    for k, yy in enumerate((-6.5, 6.5)):
        marker(f"lamp_hall{k}", ((hx0 + hx1) / 2, yy, 6.0))
    finish("cine_imperial", (0.9, 0.84, 0.7), (0.78, 0.6, 0.4), extra={
        "poster": bu.principled("posters", (0.55, 0.2, 0.15), 0.5),
        "light": _emissive("marquee_light", (1, 0.92, 0.75), 3.0),
        "bulb": _emissive("bulbs", (1, 0.85, 0.5), 8.0),
        "sign": bu.principled("sign_board", (0.08, 0.05, 0.05), 0.4),
        "neon": _emissive("neon", (1, 0.12, 0.1), 6.0),
        "carpet": bu.principled("carpet", (0.45, 0.04, 0.05), 0.95),
        "counter": bu.principled("booth", (0.35, 0.18, 0.08), 0.5),
        "inner": bu.principled("hall_walls", (0.22, 0.05, 0.06), 0.9),
        "hall": bu.principled("hall_floor", (0.12, 0.05, 0.05), 0.95),
        "seat": bu.principled("seats", (0.55, 0.03, 0.05), 0.8),
        "screen": bu.principled("screen", (0.9, 0.9, 0.9), 0.9),
    })


def image_panel(name, image, w, h, loc, rot_z):
    """An image (logo) on a flat panel facing -y, turned by rot_z; exported as is."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images.load(str(Path(__file__).resolve().parent / "ref" / image))
    t.image.pack()
    b = nt.nodes["Principled BSDF"]
    nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    nt.links.new(t.outputs["Alpha"], b.inputs["Alpha"])
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc, rotation=(math.pi / 2, 0, rot_z))
    o = bpy.context.object
    o.name = name
    o.scale = (w, h, 1)
    o.data.materials.append(m)
    MARKERS.append(o)
    return o


# ---- Posto Charrua (after the network's stations): yellow canopy, pumps, shop, totem ----
def posto():
    bu.reset()
    MARKERS.clear()
    CW, CD, CH = 22.0, 13.0, 5.6        # canopy
    box("ground_pad", (34.0, 26.0, 0.6), (0, 0, -0.22))      # sinks into a sloping street; no collision in game
    # canopy: white ceiling with lights, yellow fascia band, logos + CHARRUA in red
    box("ceiling", (CW, CD, 0.15), (0, 0, CH))
    box("roof", (CW - 0.1, CD - 0.1, 0.12), (0, 0, CH + 0.95))    # the flat top inside the fascia
    for sx, sy, L, rz in ((0, -1, CW, 0.0), (0, 1, CW, math.pi), (-1, 0, CD, -math.pi / 2), (1, 0, CD, math.pi / 2)):
        box("yellow", (L + 0.3 if sy else 0.3, 0.3 if sy else L + 0.3, 1.2) if sy else (0.3, L + 0.3, 1.2),
            (sx * CW / 2, sy * CD / 2, CH + 0.5))
    for sy, rz in ((-1, 0.0), (1, math.pi)):
        y = sy * (CD / 2 + 0.16)
        image_panel(f"logo{sy}", "charrua_logo.png", 1.6, 1.15, (-CW / 2 + 2.0 if sy < 0 else CW / 2 - 2.0, y, CH + 1.15), rz)
        t = sign_text("CHARRUA", (0, -0.0, 0), 0.85, key="red")
        place([t], rz, (0, y - 0.02 * sy, CH + 0.5))
    for x in (-7.0, 0.0, 7.0):
        for y in (-3.0, 3.0):
            box("light", (0.6, 0.6, 0.03), (x, y, CH - 0.09))
            marker(f"lamp_{x}_{y}", (x, y, CH - 0.5))
    # columns and two pump islands
    for x in (-5.0, 5.0):
        for y in (-3.0, 3.0):
            cyl("column", 0.22, CH, (x, y, CH / 2), verts=16)
    for y in (-3.0, 3.0):
        box("island", (6.0, 1.3, 0.65), (0, y, 0.15 - 0.325))      # 15 cm kerb, sunk where the forecourt falls
        for x in (-1.6, 1.6):
            box("yellow", (0.7, 0.5, 1.5), (x, y, 1.05))
            box("pump_top", (0.75, 0.55, 0.35), (x, y, 1.95))
            box("display", (0.4, 0.02, 0.25), (x, y - 0.26, 1.5))
            box("display", (0.4, 0.02, 0.25), (x, y + 0.26, 1.5))
            cyl("hose", 0.03, 1.1, (x + 0.38, y, 1.1), verts=8)
        box("dark", (0.4, 0.4, 0.6), (3.5, y, 0.5))           # bin
    # convenience shop behind the canopy: glass front, yellow and red band, sign
    sx0, sy0 = 0.0, CD / 2 + 6.0
    shop_interior(sx0, sy0 - 2.5, F=-0.46)      # the square falls away behind the canopy (gasometro site)
    box("yellow", (16.2, 0.25, 0.55), (sx0, sy0 - 2.6, 3.3 - 0.46))
    box("red", (16.2, 0.26, 0.12), (sx0, sy0 - 2.6, 3.0 - 0.46))
    t = sign_text("CONVENIÊNCIA", (0, 0, 0), 0.4, key="red")
    place([t], 0.0, (sx0 + 3.5, sy0 - 2.75, 3.3 - 0.46))
    # price totem at the street corner
    tx, ty = -CW / 2 - 3.5, -CD / 2 - 1.5
    box("yellow", (1.6, 0.5, 5.2), (tx, ty, 2.6))
    image_panel("totem_logo", "charrua_logo.png", 1.2, 0.86, (tx, ty - 0.26, 4.5), 0.0)
    t = sign_text("CHARRUA", (0, 0, 0), 0.3, key="red")
    place([t], 0.0, (tx, ty - 0.27, 3.75))
    for k, (fuel, price) in enumerate((("GASOLINA", "6,29"), ("ADITIVADA", "6,49"), ("DIESEL S10", "6,09"), ("ETANOL", "4,59"))):
        z = 3.2 - k * 0.5
        box("dark", (1.3, 0.04, 0.4), (tx, ty - 0.26, z))
        t = sign_text(f"{fuel}  {price}", (0, 0, 0), 0.13, key="led")
        place([t], 0.0, (tx, ty - 0.29, z))
    # turn it round: pumps and totem to the front (-Z in the game), the shop at the back
    for bm in BMS.values():
        for v in bm.verts:
            v.co.x, v.co.y = -v.co.x, -v.co.y
    for e in MARKERS:
        e.location.x, e.location.y = -e.location.x, -e.location.y
        e.rotation_euler.z += math.pi
    finish("posto_charrua", (0.9, 0.9, 0.88), (0.95, 0.95, 0.95), extra={
        "ground_pad": bu.principled("concrete_pad", (0.62, 0.62, 0.6), 0.85),
        "ceiling": bu.principled("canopy_ceiling", (0.95, 0.95, 0.95), 0.6),
        "roof": bu.principled("canopy_roof", (0.78, 0.78, 0.76), 0.8),
        "yellow": bu.principled("charrua_yellow", (0.98, 0.8, 0.02), 0.35),
        "red": bu.principled("charrua_red", (0.85, 0.12, 0.14), 0.35),
        "light": _emissive("canopy_lights", (1, 0.98, 0.92), 6.0),
        "column": bu.principled("column_grey", (0.35, 0.36, 0.38), 0.4, 0.6),
        "island": bu.principled("island", (0.4, 0.4, 0.4), 0.8),
        "pump_top": bu.principled("pump_grey", (0.25, 0.26, 0.28), 0.4, 0.4),
        "display": _emissive("pump_display", (0.4, 0.8, 1.0), 1.5),
        "hose": bu.principled("hose", (0.05, 0.05, 0.05), 0.6),
        "dark": bu.principled("dark", (0.08, 0.08, 0.09), 0.5),
        "shop": bu.principled("shop_wall", (0.92, 0.92, 0.9), 0.85),
        "shop_ground_pad": bu.principled("shop_floor_tiles", (0.8, 0.8, 0.78), 0.3),
        "shop_ceiling": bu.principled("shop_ceiling", (0.97, 0.97, 0.97), 0.8),
        "shop_window": _see_through("shop_window", (0.75, 0.85, 0.9), 0.2),
        "counter": bu.principled("shop_counter", (0.55, 0.12, 0.12), 0.4),
        "goods_blue": bu.principled("goods_blue", (0.1, 0.3, 0.8), 0.4),
        "goods_green": bu.principled("goods_green", (0.1, 0.6, 0.25), 0.4),
        "led": _emissive("led_prices", (1.0, 0.5, 0.1), 3.0),
    })


def shop_interior(cx, yf, W=16.0, D=7.0, H=3.6, T=0.2, F=0.0):
    """The convenience shop as a room you can walk into: front at y = yf
    (facing -y, the forecourt), see-through glass with an open doorway,
    shelves of goods, drinks fridges, a counter with the till. F is the
    height of the ground at the door (the floor, level with it, no step);
    walls run 0.5 m into the ground where the site falls away."""
    yc = yf + D / 2
    # the floor is laid on the ground in the game (named *_ground_pad)
    box("shop_ground_pad", (W - 2 * T, D - 2 * T, 0.1), (cx, yc, F - 0.05))
    box("shop", (W, T, H + 1.0), (cx, yf + D - T / 2, F + H / 2 - 0.5))        # back
    for s in (-1, 1):
        box("shop", (T, D, H + 1.0), (cx + s * (W / 2 - T / 2), yc, F + H / 2 - 0.5))   # sides
    box("shop", (W + 0.3, D + 0.3, 0.25), (cx, yc, F + H + 0.12))             # roof
    box("shop_ceiling", (W - 2 * T, D - 2 * T, 0.04), (cx, yc, F + H - 0.02))
    # front: a band over the glass, a low kerb, mullions, panes and the door gap
    G0, G1 = 0.3, 2.6
    box("shop", (W, T, H - G1), (cx, yf + T / 2, F + G1 + (H - G1) / 2))
    door_x, door_w = cx - 3.0, 1.8
    edges = [cx - W / 2 + T, door_x - door_w / 2, door_x + door_w / 2, cx + W / 2 - T]
    for a, b in ((edges[0], edges[1]), (edges[2], edges[3])):
        box("shop", (b - a, T, G0), ((a + b) / 2, yf + T / 2, F + G0 / 2))
        n = max(1, round((b - a) / 2.4))
        for k in range(n):
            x0, x1 = a + (b - a) * k / n, a + (b - a) * (k + 1) / n
            box("shop_window", (x1 - x0 - 0.08, 0.03, G1 - G0), ((x0 + x1) / 2, yf + T / 2, F + (G0 + G1) / 2))
            box("column", (0.08, 0.12, G1 - G0), (x1, yf + T / 2, F + (G0 + G1) / 2))
    for x in (door_x - door_w / 2, door_x + door_w / 2):
        box("column", (0.1, 0.14, G1), (x, yf + T / 2, F + G1 / 2))
    box("column", (door_w + 0.2, 0.14, 0.1), (door_x, yf + T / 2, F + G1))        # door head
    # inside: two shelf rows with goods, fridges on the back wall, the counter
    goods = ("red", "yellow", "goods_blue", "goods_green", "dark")
    for row, x0 in enumerate((cx + 0.5, cx + 4.0)):
        box("dark", (1.8, 0.06, 1.6), (x0, yc + 0.03, F + 0.8))                 # back panel
        box("dark", (1.8, 0.6, 0.6), (x0, yc + 0.3, F - 0.2))                    # plinth, into the ground
        for lvl in range(3):
            box("dark", (1.8, 0.6, 0.04), (x0, yc + 0.3, F + 0.18 + lvl * 0.5))  # the shelf boards
        for lvl in range(3):
            for k in range(6):
                box(goods[(k + lvl + row) % len(goods)], (0.25, 0.5, 0.3),
                    (x0 - 0.75 + k * 0.3, yc + 0.3, F + 0.35 + lvl * 0.5))
    for k in range(5):
        x = cx - W / 2 + 1.6 + k * 1.5
        if abs(x - door_x) < 1.2:
            continue
        box("column", (1.3, 0.15, 2.2), (x, yf + D - T - 0.08, F + 1.1))        # fridge back
        for s2 in (-1, 1):
            box("column", (0.05, 0.75, 2.2), (x + s2 * 0.63, yf + D - T - 0.4, F + 1.1))
        box("column", (1.3, 0.75, 0.12), (x, yf + D - T - 0.4, F + 2.14))       # its top
        box("column", (1.3, 0.75, 0.6), (x, yf + D - T - 0.4, F - 0.2))         # plinth
        box("light", (1.1, 0.05, 0.03), (x, yf + D - T - 0.7, F + 2.05))        # lit inside
        box("shop_window", (1.15, 0.03, 1.9), (x, yf + D - T - 0.77, F + 1.15))  # its glass door
        for lvl in range(4):
            box(goods[(k + lvl) % len(goods)], (1.0, 0.35, 0.25), (x, yf + D - T - 0.45, F + 0.4 + lvl * 0.45))
    box("counter", (3.0, 0.8, 1.5), (cx - W / 2 + 2.2, yf + 1.6, F + 0.25))
    box("dark", (0.4, 0.35, 0.3), (cx - W / 2 + 1.4, yf + 1.6, F + 1.15))      # the till
    marker("pickup_fruki", (cx - W / 2 + 2.8, yf + 1.6, F + 1.05))
    for x in (cx - 4.0, cx + 4.0):
        box("light", (1.2, 0.3, 0.03), (x, yc, F + H - 0.06))
        marker(f"lamp_shop_{x}", (x, yc, F + H - 0.5))


# ---- banca de jornais (Porto Alegre style): open front with a counter, a door
# on the side, covers on the back wall and on the outside of the side walls,
# the vendor inside. Front (-Z in the game) to the customers --------------------
def kiosk():
    bu.reset()
    MARKERS.clear()
    W, D, H, T = 2.8, 2.0, 2.45, 0.06            # outer width, depth, wall height, wall thickness
    door = 0.95
    # floor, back wall, side walls (the +x one with a door), roof with overhang
    box("floor", (W, D, 0.08), (0, 0, 0.04))
    box("metal", (W, T, H), (0, -D / 2 + T / 2, H / 2))
    box("metal", (T, D, H), (-W / 2 + T / 2, 0, H / 2))
    side_solid = D - door - 0.15
    box("metal", (T, side_solid, H), (W / 2 - T / 2, -D / 2 + side_solid / 2, H / 2))
    box("metal", (T, 0.15, H), (W / 2 - T / 2, D / 2 - 0.075, H / 2))
    box("metal", (T, door, H - 2.05), (W / 2 - T / 2, -D / 2 + side_solid + door / 2, 2.05 + (H - 2.05) / 2))
    box("roof", (W + 0.6, D + 0.7, 0.12), (0, 0.2, H + 0.06))
    box("trim", (W + 0.62, 0.08, 0.32), (0, D / 2 + 0.55, H - 0.04))          # front fascia
    # front: counter below, open above, a rolled-up shutter box at the top
    box("metal", (W, T, 1.0), (0, D / 2 - T / 2, 0.5))
    box("counter", (W, 0.45, 0.05), (0, D / 2 - 0.2, 1.02))
    box("metal", (W, T, 0.35), (0, D / 2 - T / 2, H - 0.175))
    box("shutter", (W - 0.1, 0.25, 0.25), (0, D / 2 - 0.15, H - 0.2))
    # magazine racks along the inside of the side walls and a stool
    for sx in (-1, 1):
        for k in range(4):
            box("rack", (0.3, D * 0.55 if sx < 0 else side_solid * 0.9, 0.03), (sx * (W / 2 - 0.2), -0.25 if sx < 0 else -D / 2 + side_solid / 2,
                                                                                0.7 + k * 0.38))
    cyl("stool", 0.18, 0.65, (-0.4, -0.35, 0.33), verts=12)
    # covers: on the back wall inside and on the outside of the closed side wall
    image_panel("covers_back", "kiosk_covers.png", W - 0.2, 1.3, (0, -D / 2 + T + 0.01, 1.55), math.pi)
    image_panel("covers_left", "kiosk_covers.png", D - 0.2, 1.1, (-W / 2 - 0.01, 0, 1.45), -math.pi / 2)
    image_panel("covers_front", "kiosk_covers.png", W - 0.3, 0.55, (0, D / 2 + 0.01, 0.55), 0.0)
    t = sign_text("BANCA", (0, 0, 0), 0.22, key="sign_text")
    place([t], math.pi, (0, D / 2 + 0.6, H - 0.04))   # reads from the front
    marker("lamp_kiosk", (0, -0.1, H - 0.3))
    marker("vendor_spot", (-0.2, -0.25, 0.05))      # where the vendor stands, facing the counter
    # Blender +y is the game's -Z: the open counter already faces the front
    global OUT
    out_prev = OUT
    OUT = OUT.parent / "stalls"
    finish("prop_newspaper_kiosk", (0.3, 0.42, 0.33), (0.85, 0.85, 0.82), extra={
        "floor": bu.principled("kiosk_floor", (0.35, 0.33, 0.3), 0.8),
        "metal": bu.principled("kiosk_green", (0.16, 0.36, 0.22), 0.45, 0.5),
        "roof": bu.principled("kiosk_roof", (0.2, 0.22, 0.22), 0.5, 0.6),
        "counter": bu.principled("counter_wood", (0.45, 0.28, 0.14), 0.5),
        "shutter": bu.principled("shutter_box", (0.6, 0.62, 0.62), 0.4, 0.6),
        "rack": bu.principled("rack", (0.7, 0.7, 0.72), 0.35, 0.8),
        "stool": bu.principled("stool", (0.15, 0.15, 0.15), 0.6),
        "sign_text": bu.principled("banca_letters", (1, 1, 1), 0.4),
    })
    OUT = out_prev


if __name__ == "__main__":
    which = sys.argv[sys.argv.index("--") + 2:] or ["mercado", "paco", "farmacia"]
    for w in which:
        globals()[w]()
