#!/usr/bin/env python3
"""Crop Wikimedia Commons landmark photos (tools/map/commons_facades.py) to the
building itself before they become facade textures: a Commons photo is a
wide shot with sky, street, cars and neighbours, which pasted onto a wall
looks like a billboard.

SegFormer-B5 (ADE20K) marks building pixels; the largest connected building
region near the middle of the photo gives the crop box (its roofline is the
top), which is then trimmed to the wall's proportions around the region's
centre, keeping the ground floor. Writes commons/<name>.jpg for every entry
of facades_commons.json that has a `raw` photo. Needs the ML venv:

    ~/.local/share/city-invaders-ml/bin/python tools/map/crop_landmarks.py maps/poa/facades/facades_commons.json
"""
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

SEG_MODEL = "nvidia/segformer-b5-finetuned-ade-640-640"
BUILDING = {"building", "house", "skyscraper", "tower"}


def main():
    from scipy import ndimage
    from transformers import SegformerForSemanticSegmentation, SegformerImageProcessor
    path = Path(sys.argv[1])
    root = path.parent
    entries = json.loads(path.read_text())
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    proc = SegformerImageProcessor.from_pretrained(SEG_MODEL)
    seg = SegformerForSemanticSegmentation.from_pretrained(SEG_MODEL).to(dev).eval()
    ids = [i for i, n in seg.config.id2label.items() if any(p.strip() in BUILDING for p in n.split(";"))]
    for key, r in entries.items():
        if not r.get("raw") or not (root / r["raw"]).exists():
            continue
        img = Image.open(root / r["raw"]).convert("RGB")
        W, H = img.size
        with torch.no_grad():
            logits = seg(**proc(images=img, return_tensors="pt").to(dev)).logits
        lab = F.interpolate(logits, size=(H, W), mode="bilinear", align_corners=False).argmax(1)[0].cpu().numpy()
        mask = np.isin(lab, ids)
        comps, n = ndimage.label(mask)
        if n == 0:
            print(f"{r['file']}: no building found, kept the plain crop")
            continue
        # the landmark: big and central (photographers frame their subject)
        best, best_score = None, -1.0
        for k in range(1, n + 1):
            ys, xs = np.nonzero(comps == k)
            area = len(xs) / (W * H)
            centrality = 1.0 - abs(xs.mean() / W - 0.5) * 1.5
            if area * centrality > best_score:
                best, best_score = (xs.min(), ys.min(), xs.max(), ys.max(), xs.mean()), area * centrality
        x0, y0, x1, y1, cx = best
        aspect = r["w_px"] / r["h_px"]
        bw, bh = x1 - x0 + 1, y1 - y0 + 1
        if bw / bh > aspect:            # region wider than the wall: trim the sides around its centre
            w = int(bh * aspect)
            x0 = int(np.clip(cx - w / 2, x0, x1 - w))
            box = (x0, y0, x0 + w, y1 + 1)
        else:                           # taller: keep the ground floor, trim the top
            h = int(bw / aspect)
            box = (x0, y1 + 1 - h, x1 + 1, y1 + 1)
        tex = img.crop(box).resize((r["w_px"], r["h_px"]), Image.LANCZOS)
        tex.save(root / r["file"], quality=90)
        print(f"{r['file']}: building {bw}x{bh}px of {W}x{H} -> crop {box[2]-box[0]}x{box[3]-box[1]}")


if __name__ == "__main__":
    main()
