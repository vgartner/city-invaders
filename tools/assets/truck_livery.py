#!/usr/bin/env python3
"""Liveries for the unbranded truck family (its livery_manifest.json): one
image per livery_* material, drawn into that material's UV rectangle (top-left
origin). tools/blender/brand_truck.py puts them on and exports the game model.

    tools/.venv/bin/python tools/assets/truck_livery.py <livery_manifest.json> charrua|fruki

Text that came out mirrored or upside down on a surface is fixed with the
FLIP table (found by looking at renders of the result).
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REF = Path(__file__).resolve().parents[1] / "blender" / "ref"
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
S = 2048
WHITE = (238, 238, 234)
CH_YELLOW, CH_RED = (250, 204, 5), (210, 30, 36)
FR_GREEN, FR_DARK = (0, 135, 62), (0, 84, 40)
# the delivery's flat surfaces all run right to left in UV: drawn art is
# mirrored before it goes in (the tank shell sorts out its two sides itself)
NO_FLIP = {"livery_tank_shell"}


def font(px):
    return ImageFont.truetype(FONT, max(8, int(px)))


def text(d, box, txt, colour, frac=0.6):
    x0, y0, x1, y1 = box
    f = font((y1 - y0) * frac)
    while d.textlength(txt, font=f) > (x1 - x0) * 0.92 and f.size > 8:
        f = font(f.size * 0.92)
    w = d.textlength(txt, font=f)
    asc, desc = f.getmetrics()
    d.text(((x0 + x1 - w) / 2, (y0 + y1) / 2 - (asc + desc) / 2 + desc * 0.2), txt, fill=colour, font=f)


def paste_fit(img, art, box, frac=0.85):
    x0, y0, x1, y1 = box
    w, h = (x1 - x0) * frac, (y1 - y0) * frac
    s = min(w / art.width, h / art.height)
    a = art.resize((max(1, int(art.width * s)), max(1, int(art.height * s))), Image.LANCZOS).convert("RGBA")
    img.alpha_composite(a, (int((x0 + x1 - a.width) / 2), int((y0 + y1 - a.height) / 2)))


def paste_fill(img, art, box):
    x0, y0, x1, y1 = (int(v) for v in box)
    img.paste(art.convert("RGB").resize((x1 - x0, y1 - y0), Image.LANCZOS), (x0, y0))


def surface(name, rect, draw):
    img = Image.new("RGBA", (S, S), WHITE + (255,))
    box = tuple(v * S for v in rect)
    draw(img, ImageDraw.Draw(img), box)
    if name not in NO_FLIP:
        b = tuple(int(v) for v in box)
        img.paste(img.crop(b).transpose(Image.FLIP_LEFT_RIGHT), b[:2])
    return img.convert("RGB")


def charrua(name):
    logo = Image.open(REF / "charrua_logo.png")

    def cab_front(img, d, b):
        d.rectangle(b, fill=CH_YELLOW)
        text(d, b, "CHARRUA", CH_RED, 0.7)

    def door(img, d, b):
        x0, y0, x1, y1 = b
        h = y1 - y0
        d.rectangle([x0, y1 - h * 0.28, x1, y1 - h * 0.12], fill=CH_YELLOW)
        d.rectangle([x0, y1 - h * 0.12, x1, y1 - h * 0.06], fill=CH_RED)
        paste_fit(img, logo, (x0, y0 + h * 0.05, x1, y1 - h * 0.32), 0.8)

    def shell(img, d, b):
        # around the tank: 0 = bottom seam, 0.25 / 0.75 = the two sides, 0.5 = top
        x0, y0, x1, y1 = b
        h = y1 - y0
        # renders showed the 0.25 side upside down and the 0.75 side mirrored
        for side, fix in ((0.25, Image.FLIP_TOP_BOTTOM), (0.75, Image.FLIP_LEFT_RIGHT)):
            yc = y0 + h * side
            band = (x0, yc - h * 0.07, x1, yc + h * 0.07)
            d.rectangle(band, fill=CH_YELLOW)
            d.rectangle([x0, band[3], x1, band[3] + h * 0.015], fill=CH_RED)
            d.rectangle([x0, band[1] - h * 0.015, x1, band[1]], fill=CH_RED)
            lab = Image.new("RGBA", (int(x1 - x0), int(band[3] - band[1])), CH_YELLOW + (255,))
            ld = ImageDraw.Draw(lab)
            text(ld, (lab.width * 0.2, 0, lab.width * 0.8, lab.height), "CHARRUA", CH_RED, 0.75)
            for lx in (0.0, 0.82):                     # a logo at each end: one is by the cab
                paste_fit(lab, logo, (lab.width * lx, 0, lab.width * (lx + 0.18), lab.height), 0.85)
            lab = lab.transpose(fix)
            img.alpha_composite(lab, (int(band[0]), int(band[1])))

    def tank_rear(img, d, b):
        paste_fit(img, logo, b, 0.5)

    plain = lambda img, d, b: None
    return {"livery_cab_front": cab_front, "livery_cab_door_left": door, "livery_cab_door_right": door,
            "livery_tank_shell": shell, "livery_tank_rear": tank_rear, "livery_tank_front": plain}.get(name, plain)


def fruki(name):
    logo = Image.open(REF / "fruki_logo_commons.jpg")
    box_side = Image.open(REF / "fruki_box_side.png")
    trailer_side = Image.open(REF / "fruki_trailer_side.png")

    def cab_front(img, d, b):
        d.rectangle(b, fill=FR_GREEN)
        text(d, b, "FRUKI", WHITE, 0.7)

    def door(img, d, b):
        x0, y0, x1, y1 = b
        h = y1 - y0
        d.rectangle([x0, y1 - h * 0.2, x1, y1 - h * 0.08], fill=FR_GREEN)
        paste_fit(img, logo, (x0, y0 + h * 0.05, x1, y1 - h * 0.25), 0.75)

    def side(art):
        return lambda img, d, b: paste_fill(img, art, b)

    def end(img, d, b):
        d.rectangle(b, fill=FR_GREEN)
        x0, y0, x1, y1 = b
        d.rectangle([x0 + (x1 - x0) * 0.08, y0 + (y1 - y0) * 0.3, x1 - (x1 - x0) * 0.08, y0 + (y1 - y0) * 0.7], fill=WHITE)
        paste_fit(img, logo, (x0, y0 + (y1 - y0) * 0.3, x1, y0 + (y1 - y0) * 0.7), 0.8)

    def rear_door(img, d, b):
        d.rectangle(b, fill=WHITE)
        x0, y0, x1, y1 = b
        d.rectangle([x0, y1 - (y1 - y0) * 0.15, x1, y1], fill=FR_GREEN)
        paste_fit(img, logo, (x0, y0 + (y1 - y0) * 0.25, x1, y0 + (y1 - y0) * 0.6), 0.85)

    plain = lambda img, d, b: None
    return {"livery_cab_front": cab_front, "livery_cab_door_left": door, "livery_cab_door_right": door,
            "livery_box_left": side(box_side), "livery_box_right": side(box_side),
            "livery_trailer_left": side(trailer_side), "livery_trailer_right": side(trailer_side),
            "livery_box_front": end, "livery_trailer_front": end,
            "livery_box_rear_left": rear_door, "livery_box_rear_right": rear_door,
            "livery_trailer_rear_left": rear_door, "livery_trailer_rear_right": rear_door}.get(name, plain)


if __name__ == "__main__":
    manifest, brand = json.loads(Path(sys.argv[1]).read_text()), sys.argv[2]
    pick = {"charrua": charrua, "fruki": fruki}[brand]
    out = REF / f"{brand}_truck_livery"
    out.mkdir(parents=True, exist_ok=True)
    for name, spec in manifest.items():
        if isinstance(spec, dict) and name.startswith("livery_"):
            surface(name, spec["rectangles"][0], pick(name)).save(out / f"{name}.png")
    print("wrote", len(list(out.glob("*.png"))), "images to", out)
