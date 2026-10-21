#!/usr/bin/env python3
"""Extract real facade textures from Mapillary street-level photos.

For every street-facing wall produced by osmcity.load() the tool ranks the
Mapillary images that see it, projects the wall rectangle into the best few
with each image's computed pose and OpenSfM camera model (perspective or
fisheye), aligns the undistorted crops to each other (phase correlation),
fuses them with a per-pixel median to drop cars and pedestrians, and extends
the result to the full building height by repeating the facade's own storey.

Output: <outdir>/facades.json mapping Build wall endpoints to texture files,
consumed by `osmcity.py --facades`. Imagery is CC-BY-SA (Mapillary).
"""
import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image
from shapely.geometry import LineString, Point
from shapely.ops import unary_union
from shapely.prepared import prep

sys.path.insert(0, str(Path(__file__).parent))
import osmcity  # noqa: E402

PX_PER_M = 40          # horizontal texture resolution
CAM_HEIGHT_M = 2.0
MAX_TEX_PX = 1024
GRAPH = "https://graph.mapillary.com"


def token():
    tok = os.environ.get("MAPILLARY_TOKEN")
    env = Path(__file__).resolve().parents[2] / ".env"
    if not tok and env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("MAPILLARY_TOKEN="):
                tok = line.split("=", 1)[1].strip().strip("\"'")
    if not tok:
        raise SystemExit("MAPILLARY_TOKEN missing (.env)")
    return tok


def retry(fn, tries=5):
    """Mapillary answers the odd 5xx / timeout; back off and try again."""
    import time
    for k in range(tries):
        try:
            return fn()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            if k == tries - 1 or (isinstance(e, urllib.error.HTTPError) and e.code < 500 and e.code != 429):
                raise
            time.sleep(2 ** k)


def api(path, tok):
    def call():
        req = urllib.request.Request(f"{GRAPH}/{path}", headers={"Authorization": f"OAuth {tok}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    return retry(call)


def rodrigues(v):
    v = np.asarray(v, float)
    t = np.linalg.norm(v)
    if t < 1e-12:
        return np.eye(3)
    k = v / t
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + math.sin(t) * K + (1 - math.cos(t)) * K @ K


class Camera:
    def __init__(self, img, proj):
        lon, lat = img["computed_geometry"]["coordinates"]
        x, y = proj(lat, lon)
        self.id = img["id"]
        self.C = np.array([x, y, CAM_HEIGHT_M])
        self.R = rodrigues(img["computed_rotation"])
        self.kind = img.get("camera_type", "perspective")
        self.f, self.k1, self.k2 = (list(img.get("camera_parameters") or [0.8, 0, 0]) + [0, 0])[:3]
        self.w, self.h = img["width"], img["height"]
        self.year = int(img["captured_at"] / 1000 / 31557600 + 1970)
        fwd = self.R.T @ np.array([0, 0, 1.0])
        self.fwd2 = fwd[:2] / max(np.linalg.norm(fwd[:2]), 1e-9)

    def project(self, X, w=None, h=None):
        """World points (N,3) -> pixel coords (N,2) and validity mask."""
        w, h = w or self.w, h or self.h
        Xc = (X - self.C) @ self.R.T
        z = Xc[:, 2]
        ok = z > 0.3
        zs = np.where(ok, z, 1.0)
        x, y = Xc[:, 0] / zs, Xc[:, 1] / zs
        if self.kind in ("fisheye", "spherical_fisheye"):
            r = np.sqrt(x * x + y * y)
            th = np.arctan(r)
            thd = th * (1 + self.k1 * th ** 2 + self.k2 * th ** 4)
            s = np.where(r > 1e-9, thd / np.maximum(r, 1e-9), 1.0)
        else:
            r2 = x * x + y * y
            s = 1 + self.k1 * r2 + self.k2 * r2 * r2
        S = max(w, h)
        u = self.f * s * x * S + w / 2 - 0.5
        v = self.f * s * y * S + h / 2 - 0.5
        ok &= (u >= 0) & (u < w - 1) & (v >= 0) & (v < h - 1)
        return np.stack([u, v], 1), ok


def wall_quad(p0, p1, z0, z1):
    return np.array([[*p0, z1], [*p1, z1], [*p1, z0], [*p0, z0]], float)


def ranked_views(p0, p1, height, cams, blockers, prefer=(), tagged=()):
    """All usable views of a wall, best first: (score, cam, cap)."""
    p0, p1 = np.array(p0), np.array(p1)
    d = p1 - p0
    L = np.linalg.norm(d)
    n = np.array([d[1], -d[0]]) / L          # street side normal (see osmcity ring orientation)
    mid = (p0 + p1) / 2
    views = []
    xy = np.array([c.C[:2] for c in cams]) if cams else np.zeros((0, 2))
    near = np.nonzero(np.hypot(*(xy - mid).T) < L / 2 + 45)[0]
    for cam in (cams[k] for k in near):
        rel = cam.C[:2] - mid
        dist = rel @ n
        if not (2.5 <= dist <= 40) or abs(rel @ (d / L)) > L / 2 + 20:
            continue
        facing = -(cam.fwd2 @ n)  # 1 = camera pointed straight at the wall
        # actual viewing ray to the ends of the wall: reject grazing views,
        # which smear the facade when undistorted
        cosray = lambda q: (cam.C[:2] - q) @ n / max(np.linalg.norm(cam.C[:2] - q), 1e-6)
        ray = cosray(mid)
        # fisheye car cameras look along the street but still see the side
        # facades in their ~150 degree field of view
        min_facing = -0.2 if cam.kind in ("fisheye", "spherical_fisheye") else 0.35
        if facing < min_facing or ray < 0.5 or min(cosray(p0), cosray(p1)) < 0.25:
            continue
        sight = LineString([tuple(cam.C[:2]), tuple(mid + n * 0.6)])
        if blockers.intersects(sight):
            continue
        for cap in (height, 15, 12, 9, 6, 4):
            if cap > height:
                continue
            _, ok = cam.project(wall_quad(p0, p1, 0.3, cap))
            if ok.all():
                break
        else:
            continue
        score = (max(facing, 0) + 3 * ray - abs(dist - 12) / 15 + cap / 10 + (cam.year - 2016) * 0.05
                 + (0.6 if cam.id in prefer else 0)
                 + (4.0 if cam.id in tagged else 0))   # the photo OSM names for this building
        views.append((score, cam, cap))
    views.sort(key=lambda v: -v[0])
    return views


def vertical_scale(height):
    """Vertical texture scale: `yrepeat` (kept in facades.json for
    compatibility) and the texture height in pixels spanning the full wall,
    at 2.5 * yrepeat pixels per metre."""
    yrep = max(1, min(16, int(MAX_TEX_PX // (2.5 * height))))
    return yrep, yrep * 2.5 * height


def sample_wall(src, cam, p0, p1, W, ppm, cap, Hc):
    """Resample the wall for z in [0, cap] into the bottom of an (Hc, W) canvas.
    Returns float RGB with NaN where the photo has no data."""
    H = max(1, min(Hc, int(round(cap * ppm))))
    u, v = np.meshgrid((np.arange(W) + 0.5) / W, (np.arange(H) + 0.5) / H)
    p0, p1 = np.array(p0), np.array(p1)
    xy = p0 + (p1 - p0) * u.reshape(-1, 1)
    X = np.column_stack([xy, (1 - v.reshape(-1)) * cap])
    uv, ok = cam.project(X, src.shape[1], src.shape[0])
    x, y = uv[:, 0], uv[:, 1]
    x0 = np.clip(np.floor(x).astype(int), 0, src.shape[1] - 2)
    y0 = np.clip(np.floor(y).astype(int), 0, src.shape[0] - 2)
    fx, fy = (x - x0)[:, None], (y - y0)[:, None]
    out = (src[y0, x0] * (1 - fx) * (1 - fy) + src[y0, x0 + 1] * fx * (1 - fy)
           + src[y0 + 1, x0] * (1 - fx) * fy + src[y0 + 1, x0 + 1] * fx * fy)
    out[~ok] = np.nan
    canvas = np.full((Hc, W, 3), np.nan)
    canvas[Hc - H:] = out.reshape(H, W, 3)
    return canvas


def shift_between(ref, img, max_shift):
    """Translation (dy, dx) that best aligns img onto ref (phase correlation
    on the overlapping valid area, 4x downsampled)."""
    k = 4
    a, b = ref[::k, ::k].mean(2), img[::k, ::k].mean(2)
    valid = ~np.isnan(a) & ~np.isnan(b)
    if valid.mean() < 0.2:
        return 0, 0
    a = np.where(valid, a - np.nanmean(a[valid]), 0)
    b = np.where(valid, b - np.nanmean(b[valid]), 0)
    F = np.fft.fft2(a) * np.conj(np.fft.fft2(b))
    r = np.fft.ifft2(F / (np.abs(F) + 1e-9)).real
    m = max(1, int(max_shift / k))
    best, arg = -1e9, (0, 0)
    for dy in range(-m, m + 1):
        for dx in range(-m, m + 1):
            if r[dy % r.shape[0], dx % r.shape[1]] > best:
                best, arg = r[dy % r.shape[0], dx % r.shape[1]], (dy, dx)
    return arg[0] * k, arg[1] * k


def sharpness(img):
    """Mean gradient magnitude of the valid area; low for blurred, fogged or
    sun-glared captures (e.g. shot through a dirty windscreen)."""
    g = img.mean(2)
    gx, gy = np.abs(np.diff(g, axis=1))[:-1], np.abs(np.diff(g, axis=0))[:, :-1]
    m = gx + gy
    return float(np.nanmean(m)) if np.isfinite(m).any() else 0.0


def agreement(a, b):
    """Normalised cross-correlation of two crops over their common valid area."""
    ga, gb = a.mean(2), b.mean(2)
    valid = ~np.isnan(ga) & ~np.isnan(gb)
    if valid.sum() < 500:
        return 0.0
    x, y = ga[valid] - ga[valid].mean(), gb[valid] - gb[valid].mean()
    return float((x * y).sum() / (np.sqrt((x * x).sum() * (y * y).sum()) + 1e-9))


def translate(img, dy, dx):
    out = np.full_like(img, np.nan)
    H, W = img.shape[:2]
    if abs(dy) >= H or abs(dx) >= W:
        return img
    ys, yd = (slice(0, H - dy), slice(dy, H)) if dy >= 0 else (slice(-dy, H), slice(0, H + dy))
    xs, xd = (slice(0, W - dx), slice(dx, W)) if dx >= 0 else (slice(-dx, W), slice(0, W + dx))
    out[yd, xd] = img[ys, xs]
    return out


def fuse(stack):
    """Per-pixel median over aligned photos removes transient occluders
    (cars, buses, pedestrians) that differ between captures."""
    with np.errstate(all="ignore"):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            out = np.nanmedian(np.stack(stack), axis=0)
    return out


def repeat_band(crop, ppm, total):
    """Extend a bottom-anchored crop to `total` rows. The repeated storey is
    the band most similar to the one below it (the facade's own period),
    and everything above that band is discarded, so signs, poles and tree
    tops caught near the top of the photo are not stacked up the building."""
    H = crop.shape[0]
    if H >= total:
        return crop[H - total:]
    b = max(4, int(round(3.2 * ppm)))
    floor_rows = int(round(5.5 * ppm))   # keep ground floor and awnings out of the search
    best_y, best = 0, None
    for y in range(0, max(1, H - 2 * b - floor_rows), max(1, b // 8)):
        up, down = crop[y:y + b], crop[y + b:y + 2 * b]
        if up.shape[0] < b or down.shape[0] < b:
            break
        diff = np.nanmean(np.abs(up - down))
        if np.isnan(diff):
            continue
        # prefer periodic bands, penalise holes
        diff += 40 * np.isnan(up).mean()
        if best is None or diff < best:
            best_y, best = y, diff
    kept = crop[best_y:]
    band = crop[best_y:best_y + b]
    out = np.empty((total, crop.shape[1], 3))
    out[total - kept.shape[0]:] = kept
    y = total - kept.shape[0]
    while y > 0:
        n = min(b, y)
        out[y - n:y] = band[b - n:]
        y -= n
    return out


def match_colour(img, ref_stats, strength=0.6):
    mean, std = np.nanmean(img, (0, 1)), np.nanstd(img, (0, 1)) + 1e-6
    rm, rs = ref_stats
    adj = (img - mean) / std * rs + rm
    return img * (1 - strength) + adj * strength


def fill_holes(img):
    """Replace remaining NaN pixels with the column mean, then global mean."""
    out = img.copy()
    col = np.nanmean(out, axis=0, keepdims=True)
    col = np.where(np.isnan(col), np.nanmean(out, (0, 1)), col)
    mask = np.isnan(out)
    out[mask] = np.broadcast_to(col, out.shape)[mask]
    return np.nan_to_num(out, nan=128)


class ImageCache:
    def __init__(self, folder, tok, keep=24):
        self.folder, self.tok, self.keep, self.mem = folder, tok, keep, {}

    def get(self, cam_id):
        if cam_id in self.mem:
            return self.mem[cam_id]
        jpg = self.folder / f"{cam_id}.jpg"
        if not jpg.exists():
            try:
                url = api(f"{cam_id}?fields=thumb_2048_url", self.tok)["thumb_2048_url"]
                part = jpg.with_suffix(".part")
                retry(lambda: urllib.request.urlretrieve(url, part))
                part.rename(jpg)
            except (urllib.error.URLError, KeyError) as e:
                print(f"  image {cam_id} unavailable ({e}), skipped")
                self.mem[cam_id] = None
                return None
        arr = np.asarray(Image.open(jpg).convert("RGB"), float)
        if len(self.mem) >= self.keep:
            self.mem.pop(next(iter(self.mem)))
        self.mem[cam_id] = arr
        return arr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm")
    ap.add_argument("--images", required=True, help="Mapillary images.json (list query)")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=150)
    ap.add_argument("--bounds", type=float, nargs=4, metavar=("MIN_X", "MIN_Y", "MAX_X", "MAX_Y"),
                    help="rectangular map in metres from the centre (y north); overrides --half")
    ap.add_argument("--focus", type=float, nargs=2, default=(0, 0), help="x y metres from centre")
    ap.add_argument("--radius", type=float, default=1e9, help="only walls within this distance of focus")
    ap.add_argument("--views", type=int, default=5, help="photos fused per wall")
    ap.add_argument("--outdir", type=Path, required=True)
    args = ap.parse_args()

    tok = token()
    proj = osmcity.project(args.lat, args.lon)
    imgs = [i for i in json.load(open(args.images))["data"]
            if i.get("computed_rotation") and i.get("computed_geometry") and not i.get("is_pano")]
    cams = [Camera(i, proj) for i in imgs]
    area, buildings, parks, streets = osmcity.load(args.osm, args.lat, args.lon, args.half, args.bounds)
    # buildings tagged mapillary=<image id> in OSM: that photo is preferred for
    # their walls; fetch its pose if it isn't in the area listing
    known = {c.id for c in cams}
    fields = ("id,computed_geometry,computed_compass_angle,computed_rotation,captured_at,"
              "is_pano,camera_type,camera_parameters,width,height")
    for _, _, tags in buildings:
        for mid in str(tags.get("mapillary", "")).replace(",", ";").split(";"):
            mid = mid.strip()
            if mid.isdigit() and mid not in known:
                try:
                    img = api(f"{mid}?fields={fields}", tok)
                    if img.get("computed_rotation") and not img.get("is_pano"):
                        cams.append(Camera(img, proj))
                        known.add(mid)
                except (urllib.error.URLError, KeyError) as e:
                    print(f"  OSM-tagged image {mid} unavailable ({e})")
    focus = Point(*args.focus)
    U = osmcity.UNITS_PER_M

    (args.outdir / "img").mkdir(parents=True, exist_ok=True)
    (args.outdir / "tex").mkdir(exist_ok=True)
    images = ImageCache(args.outdir / "img", tok)
    result, misses = {}, 0
    all_union = unary_union([b[0] for b in buildings])
    for bi, (poly, height, tags) in enumerate(buildings):
        if poly.distance(focus) > args.radius:
            continue
        blockers = prep(all_union.difference(poly.buffer(0.2)).buffer(-0.2))
        pts = osmcity.ring_points(poly, outer=False)
        yrep, full_px = vertical_scale(height)
        ppm = full_px / height
        total = int(round(full_px))
        prefer, ref_stats = set(), None
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            p0, p1 = (a[0] / U, -a[1] / U), (b[0] / U, -b[1] / U)
            L = math.dist(p0, p1)
            if L < 2.5:
                continue
            tagged = {m.strip() for m in str(tags.get("mapillary", "")).replace(",", ";").split(";") if m.strip()}
            views = ranked_views(p0, p1, height, cams, blockers, prefer, tagged)
            if not views:
                misses += 1
                continue
            # fuse only views of comparable quality to the best one
            views = [v for v in views if v[0] >= views[0][0] - 1.0][:args.views + 3]
            W = max(8, min(MAX_TEX_PX, int(round(L * PX_PER_M / 8)) * 8))
            cap = max(v[2] for v in views)
            Hc = max(1, min(total, int(round(cap * ppm))))
            views = [v for v in views if images.get(v[1].id) is not None]
            if not views:
                misses += 1
                continue
            stack = [sample_wall(images.get(cam.id), cam, p0, p1, W, ppm, c, Hc) for _, cam, c in views]
            sharp = [sharpness(s) for s in stack]
            top = max(sharp)
            # rank by geometry score plus image quality; drop murky captures
            order = sorted(range(len(stack)), key=lambda k: -(views[k][0] + 2 * sharp[k] / max(top, 1e-6)))
            order = [k for k in order if sharp[k] >= 0.5 * top][:args.views]
            views, stack = [views[k] for k in order], [stack[k] for k in order]
            ref = stack[0]
            aligned = [ref]
            for s in stack[1:]:
                s = translate(s, *shift_between(ref, s, 2.0 * ppm))
                if agreement(ref, s) > 0.35:   # drop views that still disagree (misregistered)
                    aligned.append(s)
            fused = fuse(aligned) if len(aligned) > 2 else ref
            if ref_stats is None:
                ref_stats = (np.nanmean(fused, (0, 1)), np.nanstd(fused, (0, 1)) + 1e-6)
            else:
                fused = match_colour(fused, ref_stats)
            tex = fill_holes(repeat_band(fused, ppm, total))
            name = f"b{bi}_w{i}.png"
            Image.fromarray(tex.clip(0, 255).astype(np.uint8)).save(args.outdir / "tex" / name)
            prefer = {cam.id for _, cam, _ in views[:2]}
            result[f"{a[0]},{a[1]},{b[0]},{b[1]}"] = dict(
                file=f"tex/{name}", w_px=W, h_px=total, yrepeat=yrep, height_m=height, cap_m=cap,
                images=[cam.id for _, cam, _ in views], fused=len(aligned), score=round(views[0][0], 2))
        print(f"building {bi + 1}/{len(buildings)}: {len(result)} facades so far", flush=True)
    (args.outdir / "facades.json").write_text(json.dumps(result, indent=1))
    used = {i for r in result.values() for i in r["images"]}
    print(f"{len(result)} facades textured from {len(used)} photos, "
          f"{misses} walls without a usable view")


if __name__ == "__main__":
    main()
