#!/usr/bin/env python3
"""Remove what stands in front of the real facades (people, vehicles, poles,
street lights, traffic lights, trees) from the Mapillary facade textures.

1. SegFormer-B5 (ADE20K, 150 classes) labels every pixel; the occluder
   classes become a mask, dilated a little so edges and shadows go too.
2. LaMa (big-lama, TorchScript) inpaints the mask by continuing the facade.

Facades mostly hidden are not worth inpainting (it turns to mush): above
MAX_COVER they are left out of facades_clean.json, so those walls get the
generated textures, and listed in manual_review.txt (e.g. for Codex).

Writes cleaned copies next to the originals (<facades>/tex_clean/), a
facades_clean.json pointing at them (pass it to osm2gltf --facades), and a
before/after contact sheet. Needs the ML venv (torch, transformers):

    ~/.local/share/city-invaders-ml/bin/python tools/map/clean_facades.py maps/poa/facades/facades.json
"""
import argparse
import json
import urllib.request
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageDraw

SEG_MODEL = "nvidia/segformer-b5-finetuned-ade-640-640"
LAMA_URL = "https://github.com/enesmsahin/simple-lama-inpainting/releases/download/v0.1.0/big-lama.pt"
OCCLUDERS = {"person", "car", "bus", "truck", "van", "bicycle", "minibike", "pole", "streetlight",
             "traffic light", "flag"}
# vegetation is also confused with repetitive glass/balcony towers: only green
# pixels count, and a tree hiding much of the wall is left alone (inpainting
# that much turns to mush)
VEGETATION = {"tree", "plant", "palm"}
MAX_VEGETATION = 0.2
MAX_COVER = 0.45
DILATE_PX = 9


def device():
    return "mps" if torch.backends.mps.is_available() else "cpu"


def load_lama(cache: Path):
    path = cache / "big-lama.pt"
    if not path.exists():
        cache.mkdir(parents=True, exist_ok=True)
        print("downloading", LAMA_URL)
        urllib.request.urlretrieve(LAMA_URL, path)
    return torch.jit.load(str(path), map_location="cpu").eval()


def occluder_mask(img, proc, seg, ids, veg_ids):
    inputs = proc(images=img, return_tensors="pt").to(device())
    with torch.no_grad():
        logits = seg(**inputs).logits
    logits = F.interpolate(logits, size=(img.height, img.width), mode="bilinear", align_corners=False)
    labels = logits.argmax(1)[0].cpu().numpy()
    mask = np.isin(labels, ids)
    rgb = np.asarray(img, np.float32)
    green = (rgb[..., 1] > rgb[..., 0] + 8) & (rgb[..., 1] > rgb[..., 2] + 4)
    veg = np.isin(labels, veg_ids) & green
    if veg.mean() <= MAX_VEGETATION:
        mask |= veg
    if DILATE_PX:
        t = torch.from_numpy(mask.astype(np.float32))[None, None]
        t = F.max_pool2d(t, 2 * DILATE_PX + 1, stride=1, padding=DILATE_PX)
        mask = t[0, 0].numpy() > 0.5
    return mask


def inpaint(lama, img, mask):
    x = torch.from_numpy(np.asarray(img, np.float32) / 255.0).permute(2, 0, 1)[None]
    m = torch.from_numpy(mask.astype(np.float32))[None, None]
    h, w = x.shape[2:]
    ph, pw = (8 - h % 8) % 8, (8 - w % 8) % 8
    x = F.pad(x, (0, pw, 0, ph), mode="reflect")
    m = F.pad(m, (0, pw, 0, ph), mode="constant")
    with torch.no_grad():
        out = lama(x, m)[0, :, :h, :w]
    out = (out.permute(1, 2, 0).clamp(0, 1).numpy() * 255).astype(np.uint8)
    keep = np.asarray(img)
    return Image.fromarray(np.where(mask[..., None], out, keep))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("facades", type=Path, help="facades.json")
    ap.add_argument("--cache", type=Path, default=Path.home() / ".cache" / "city-invaders-ml")
    ap.add_argument("--only", nargs="*", help="limit to these texture names (e.g. b1_w3.png)")
    ap.add_argument("--name", default="clean",
                    help="output name: tex_<name>/ and facades_<name>.json (e.g. commons_clean)")
    args = ap.parse_args()
    from transformers import SegformerForSemanticSegmentation, SegformerImageProcessor
    proc = SegformerImageProcessor.from_pretrained(SEG_MODEL)
    seg = SegformerForSemanticSegmentation.from_pretrained(SEG_MODEL).to(device()).eval()
    def class_ids(names):
        return [i for i, n in seg.config.id2label.items() if any(part.strip() in names for part in n.split(";"))]
    ids, veg_ids = class_ids(OCCLUDERS), class_ids(VEGETATION)
    print("occluder classes:", sorted(seg.config.id2label[i] for i in ids + veg_ids))
    lama = load_lama(args.cache)

    root = args.facades.parent
    out_dir = root / f"tex_{args.name}"
    out_dir.mkdir(exist_ok=True)
    facades = json.loads(args.facades.read_text())
    report, sheet_rows, manual = [], [], []
    for key, r in facades.items():
        src = root / r["file"]
        if args.only and src.name not in args.only:
            continue
        img = Image.open(src).convert("RGB")
        mask = occluder_mask(img, proc, seg, ids, veg_ids)
        cover = float(mask.mean())
        dst = out_dir / src.name
        if cover == 0 or cover > MAX_COVER:
            img.save(dst)
            if cover > MAX_COVER:
                manual.append(src.name)
            out = img
        else:
            out = inpaint(lama, img, mask)
            out.save(dst)
        report.append((src.name, cover))
        if 0 < cover:
            sheet_rows.append((img, mask, out, src.name, cover))
        print(f"{src.name:16s} occluded {cover:5.1%}" + ("  -> kept, manual" if cover > MAX_COVER else ""))
    # a photo that is mostly a car is no facade: leave those walls to the generated textures
    clean = {k: dict(r, file=f"tex_{args.name}/" + Path(r["file"]).name) for k, r in facades.items()
             if Path(r["file"]).name not in manual}
    (root / f"facades_{args.name}.json").write_text(json.dumps(clean, ensure_ascii=False))
    review = "manual_review.txt" if args.name == "clean" else f"manual_review_{args.name}.txt"
    (root / review).write_text("\n".join(manual) + "\n")
    _sheet(sorted(sheet_rows, key=lambda r: -r[4])[:24], root / f"{args.name}_contact.png")
    print(f"{len(report)} facades, {sum(1 for _, c in report if 0 < c <= MAX_COVER)} cleaned, "
          f"{len(manual)} too occluded, dropped (manual_review.txt)")


def _sheet(rows, path, w=360):
    """before | occluder mask | after, most occluded first."""
    if not rows:
        return
    tiles = []
    for img, mask, out, name, cover in rows:
        h = int(img.height * w / img.width)
        red = img.copy()
        red.paste((255, 0, 0), mask=Image.fromarray((mask * 160).astype(np.uint8)))
        row = Image.new("RGB", (w * 3, h + 16), (20, 20, 20))
        for i, im in enumerate((img, red, out)):
            row.paste(im.resize((w, h)), (i * w, 16))
        ImageDraw.Draw(row).text((4, 2), f"{name} {cover:.0%}", fill=(255, 255, 255))
        tiles.append(row)
    sheet = Image.new("RGB", (w * 3, sum(t.height for t in tiles)))
    y = 0
    for t in tiles:
        sheet.paste(t, (0, y))
        y += t.height
    sheet.save(path)


if __name__ == "__main__":
    main()
