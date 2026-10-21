#!/usr/bin/env python3
"""Charrua livery images for the unbranded petrol station (branding_uv
manifest of the delivery): yellow fascia with red CHARRUA lettering and the
logo, the shop's CONVENIÊNCIA band, totem, pump sides and column cladding.

    tools/.venv/bin/python tools/assets/charrua_livery.py <branding_manifest.json>

Strips (fascia, shop sign) are drawn as long images; tools/blender/brand_station.py
stretches their UV band over the whole image. Everything else is drawn into
the delivered UV rectangles (top-left origin).
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REF = Path(__file__).resolve().parents[1] / "blender" / "ref"
OUT = REF / "charrua_livery"
YELLOW = (250, 204, 5)
RED = (210, 30, 36)
WHITE = (240, 240, 236)
DARK = (28, 30, 34)
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
LOGO = Image.open(REF / "charrua_logo.png").convert("RGBA")


def font(px):
    return ImageFont.truetype(FONT, int(px))


def text_centre(d, box, txt, colour, height_frac):
    x0, y0, x1, y1 = box
    f = font((y1 - y0) * height_frac)
    w = d.textlength(txt, font=f)
    while w > (x1 - x0) * 0.9 and f.size > 8:
        f = font(f.size * 0.92)
        w = d.textlength(txt, font=f)
    asc, desc = f.getmetrics()
    d.text(((x0 + x1 - w) / 2, (y0 + y1) / 2 - (asc + desc) / 2 + desc * 0.25), txt, fill=colour, font=f)


def logo(img, box, frac=0.82):
    x0, y0, x1, y1 = box
    s = int(min(x1 - x0, y1 - y0) * frac)
    lg = LOGO.resize((int(s * LOGO.width / LOGO.height), s), Image.LANCZOS)
    img.alpha_composite(lg, (int((x0 + x1 - lg.width) / 2), int((y0 + y1 - lg.height) / 2)))


def strip(name, length_m, text, logos_at_ends):
    """A fascia band: yellow, a red line along the bottom, red lettering, logos."""
    W, H = 4096, 128
    img = Image.new("RGBA", (W, H), YELLOW + (255,))
    d = ImageDraw.Draw(img)
    d.rectangle([0, H * 0.84, W, H], fill=RED)
    px_per_m = W / length_m
    text_centre(d, (0, 0, W, H * 0.84), text, RED, 0.72)
    if logos_at_ends:
        for cx in (1.2, length_m - 1.2):
            logo(img, (cx * px_per_m - H, 0, cx * px_per_m + H, H * 0.84), 0.9)
    img.convert("RGB").save(OUT / f"{name}.png")


def into_rects(name, rects, draw_fn, base=WHITE):
    S = 2048
    img = Image.new("RGBA", (S, S), base + (255,))
    for r in rects:
        box = (r[0] * S, r[1] * S, r[2] * S, r[3] * S)
        draw_fn(img, ImageDraw.Draw(img), box)
    img.convert("RGB").save(OUT / f"{name}.png")


def pump(img, d, box):
    x0, y0, x1, y1 = box
    h = y1 - y0
    d.rectangle(box, fill=YELLOW)
    d.rectangle([x0, y0, x1, y0 + h * 0.1], fill=RED)       # symmetric bands: no up/down to get wrong
    d.rectangle([x0, y1 - h * 0.1, x1, y1], fill=RED)
    logo(img, (x0, y0 + h * 0.15, x1, y1 - h * 0.15), 0.8)


def column(img, d, box):
    x0, y0, x1, y1 = box
    h = y1 - y0
    d.rectangle(box, fill=WHITE)
    for yc in (0.06, 0.94):                                     # a yellow and red collar at each end
        d.rectangle([x0, y0 + h * (yc - 0.035), x1, y0 + h * (yc + 0.035)], fill=YELLOW)
        d.rectangle([x0, y0 + h * (yc - 0.008), x1, y0 + h * (yc + 0.008)], fill=RED)


def totem_top(img, d, box):
    x0, y0, x1, y1 = box
    d.rectangle(box, fill=YELLOW)
    h = y1 - y0
    logo(img, (x0, y0, x1, y0 + h * 0.72), 0.8)
    text_centre(d, (x0, y0 + h * 0.7, x1, y1 - h * 0.04), "CHARRUA", RED, 0.75)


def mirrored(fn):
    """Draw, then flip the rectangle left-right (the totem panel's UVs run mirrored)."""
    def draw(img, d, box):
        fn(img, d, box)
        b = tuple(int(v) for v in box)
        img.paste(img.crop(b).transpose(Image.FLIP_LEFT_RIGHT), b[:2])
    return draw


def totem_prices(img, d, box):
    d.rectangle(box, fill=DARK)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    m = json.loads(Path(sys.argv[1]).read_text())
    strip("brand_canopy_front", 22, "CHARRUA", True)
    strip("brand_canopy_back", 22, "CHARRUA", True)
    strip("brand_canopy_left", 13, "CHARRUA", False)
    strip("brand_canopy_right", 13, "CHARRUA", False)
    strip("brand_shop_sign", 15.8, "CONVENIÊNCIA  CHARRUA", True)
    for k, v in m.items():
        if k.startswith("brand_pump"):
            into_rects(k, v["rectangles"], pump, YELLOW)
        elif k.startswith("brand_column"):
            into_rects(k, v["rectangles"], column)
    into_rects("brand_totem_top", m["brand_totem_top"]["rectangles"], mirrored(totem_top), YELLOW)
    into_rects("brand_totem_prices", m["brand_totem_prices"]["rectangles"], totem_prices, DARK)
    print("wrote", len(list(OUT.glob("*.png"))), "images to", OUT)
