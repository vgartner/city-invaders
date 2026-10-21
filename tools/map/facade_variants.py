"""Painted variants of the low-rise brick facade (ambientCG Facade018A, CC0):
the windows and their frames stay, the brick between them becomes painted
plaster (PaintedPlaster017's grain) in the colours of the region's houses.
Writes godot/assets/materials/Facade018A_<name>/ (color, normalgl, roughness).

    tools/.venv/bin/python tools/map/facade_variants.py
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
MAT = ROOT / "godot" / "assets" / "materials"
COLOURS = {                     # painted plaster, as seen on streets in Rio Grande do Sul
    "cream": (226, 212, 178), "ochre": (214, 172, 96), "salmon": (214, 150, 128),
    "mint": (168, 196, 170), "white": (236, 234, 226), "sky": (160, 186, 206),
    "rose": (206, 160, 170), "terracotta": (184, 108, 76),
}


def main():
    src = MAT / "Facade018A"
    col = np.asarray(Image.open(src / "color.jpg").convert("RGB"), float)
    nrm = np.asarray(Image.open(src / "normalgl.jpg").convert("RGB"), float)
    rgh = np.asarray(Image.open(src / "roughness.jpg").convert("L"), float)
    h, w, _ = col.shape
    r, g, b = col[..., 0], col[..., 1], col[..., 2]
    # brick: warm and fairly saturated; glass and frames are grey / bluish
    brick = ((r - b) > 18) & (r > 60) & ((r - g) > 6)
    mask = Image.fromarray((brick * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3)) \
        .filter(ImageFilter.MinFilter(5)).filter(ImageFilter.GaussianBlur(1.2))
    m = np.asarray(mask, float)[..., None] / 255.0
    # plaster grain, tiled to the facade's size
    pl = Image.open(MAT / "PaintedPlaster017" / "color.jpg").convert("L")
    tile = np.asarray(pl.resize((w // 4, h // 4)), float)
    grain = np.tile(tile, (4, 4))[:h, :w]
    grain = (grain - grain.mean()) / (grain.std() + 1e-6)
    lum = (0.299 * r + 0.587 * g + 0.114 * b)
    shade = np.clip(lum / (np.median(lum[brick]) + 1e-6), 0.55, 1.25)[..., None]   # keeps soot and edges
    flat_n = np.zeros_like(nrm); flat_n[...] = (128, 128, 255)
    for name, c in COLOURS.items():
        paint = np.asarray(c, float)[None, None, :] * (1.0 + grain[..., None] * 0.035) * (0.75 + 0.25 * shade)
        out = col * (1 - m) + paint * m
        n_out = nrm * (1 - m * 0.85) + flat_n * (m * 0.85)
        r_out = rgh * (1 - m[..., 0]) + 225.0 * m[..., 0]
        d = MAT / f"Facade018A_{name}"
        d.mkdir(exist_ok=True)
        Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(d / "color.jpg", quality=90)
        Image.fromarray(np.clip(n_out, 0, 255).astype(np.uint8)).save(d / "normalgl.jpg", quality=92)
        Image.fromarray(np.clip(r_out, 0, 255).astype(np.uint8)).save(d / "roughness.jpg", quality=92)
    print("wrote", ", ".join(f"Facade018A_{n}" for n in COLOURS))


if __name__ == "__main__":
    main()


# ---- ground floors: doors and shop windows at street level -------------------
# One storey (4 m) over 8 m of front: a plinth, two shop windows and a glass
# door between them, a trim band on top - in the plaster colour of the
# building above (or brick / concrete). Writes GroundFloor_<name>/.
GROUND = dict(COLOURS, brick=None, concrete=None)


def ground_floor(name, rgb):
    W, H = 1024, 512                        # 128 px per metre
    px = lambda m: int(round(m * 128))
    if name == "brick":
        base = np.asarray(Image.open(MAT / "Bricks059" / "color.jpg").convert("RGB").resize((W // 2, H // 2)), float)
        wall = np.tile(base, (2, 2, 1))[:H, :W]
    else:
        src = "Concrete034" if name == "concrete" else "PaintedPlaster017"
        g = np.asarray(Image.open(MAT / src / "color.jpg").convert("L").resize((W // 2, H // 2)), float)
        g = np.tile(g, (2, 2))[:H, :W]
        g = (g - g.mean()) / (g.std() + 1e-6)
        c = np.asarray(rgb if rgb else (178, 176, 170), float)
        wall = c[None, None, :] * (1.0 + g[..., None] * (0.05 if name != "concrete" else 0.09))
    img = wall.copy()
    rough = np.full((H, W), 230.0)
    y = lambda m: H - px(m)                 # metres above the pavement -> image row

    def rect(x0, x1, z0, z1, colour, r=None):
        img[y(z1):y(z0), px(x0):px(x1)] = colour
        if r is not None:
            rough[y(z1):y(z0), px(x0):px(x1)] = r

    def glass(x0, x1, z0, z1):
        rows = y(z0) - y(z1)
        grad = np.linspace(1.0, 0.55, rows)[:, None, None]
        img[y(z1):y(z0), px(x0):px(x1)] = np.array([62, 78, 92])[None, None, :] * grad + 18
        rough[y(z1):y(z0), px(x0):px(x1)] = 25

    frame = np.array([46, 48, 52])
    plinth = (np.asarray(rgb, float) * 0.62) if rgb else np.array([105, 100, 95])
    rect(0, 8, 0, 0.35, plinth, 200)                              # plinth
    for x0, x1 in ((0.55, 3.55), (5.45, 7.45)):                   # shop windows
        rect(x0 - 0.08, x1 + 0.08, 0.35, 3.05, frame, 120)
        glass(x0, x1, 0.45, 2.97)
        rect((x0 + x1) / 2 - 0.03, (x0 + x1) / 2 + 0.03, 0.45, 2.97, frame, 120)
    rect(3.95, 5.05, 0.0, 2.7, frame, 120)                        # door frame
    glass(4.03, 4.97, 0.02, 2.62)
    rect(4.47, 4.53, 0.02, 2.62, frame, 120)
    rect(4.84, 4.9, 1.0, 1.3, np.array([190, 190, 185]), 60)      # handle
    trim = (np.asarray(rgb, float) * 0.8 + 30) if rgb else np.array([200, 196, 188])
    rect(0, 8, 3.25, 3.55, np.clip(trim, 0, 255), 190)            # cornice band
    d = MAT / f"GroundFloor_{name}"
    d.mkdir(exist_ok=True)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(d / "color.jpg", quality=90)
    Image.fromarray(np.full((H, W, 3), (128, 128, 255), np.uint8)).save(d / "normalgl.jpg", quality=95)
    Image.fromarray(np.clip(rough, 0, 255).astype(np.uint8)).save(d / "roughness.jpg", quality=92)


if __name__ == "__main__":
    for n, c in GROUND.items():
        ground_floor(n, c)
    print("wrote", ", ".join(f"GroundFloor_{n}" for n in GROUND))
