"""Generate a made-up town as OpenStreetMap data (Overpass JSON with
geometry), for the Studio's "Generate a city": a street grid with a main
avenue and a square, lots along every block front with buildings of mixed
heights (taller towards the centre), shops on some ground floors
(pharmacies, markets, bakeries, banks, restaurants, repair shops), a fuel
station on a corner, a park with trees. tools/map/new_city.py --osm-file builds
the maps from it exactly like an imported town.

    tools/.venv/bin/python tools/map/gen_city.py out.json --size 500 --seed 7
"""
import argparse
import json
import math
import random

LAT0, LON0 = -29.70, -53.10           # somewhere in the pampa: only the projection uses it
STREETS = ["Rua Farroupilha", "Rua Bento Gonçalves", "Rua Garibaldi", "Rua Sete de Setembro",
           "Rua Duque de Caxias", "Rua Andradas", "Rua dos Gaúchos", "Rua Tiradentes",
           "Rua Júlio de Castilhos", "Rua Marechal Floriano", "Rua Pinheiro Machado", "Rua da Praia",
           "Rua General Osório", "Rua Coronel Vicente", "Rua Uruguai", "Rua Mostardeiro"]
AVENUES = ["Avenida Brasil", "Avenida Getúlio Vargas", "Avenida Borges de Medeiros"]
SHOPS = [({"amenity": "pharmacy"}, ["Farmácia Pampa", "Farmácia Popular do Sul", "Drogaria Gaúcha", "Farmácia São João"]),
         ({"shop": "supermarket"}, ["Mercado do Seu Zé", "Super Pampa", "Mercado Querência", "Armazém Tchê"]),
         ({"shop": "bakery"}, ["Padaria Pão Quente", "Panificadora Ouro", "Padaria da Praça"]),
         ({"amenity": "bank"}, ["Banco do Pampa", "Caixa Gaúcha", "Banco Cooperativo"]),
         ({"amenity": "restaurant"}, ["Churrascaria Fogo de Chão", "Lancheria do Gringo", "Restaurante Galpão", "Pizzaria Bah"]),
         ({"shop": "mobile_phone"}, ["Assistência Celular Tchê", "Conserta Tudo"])]


class Osm:
    def __init__(self):
        self.elements, self.nid = [], 1

    def deg(self, x, y):
        return {"lat": LAT0 + y / 111320.0, "lon": LON0 + x / (111320.0 * math.cos(math.radians(LAT0)))}

    def node(self, x, y, tags):
        p = self.deg(x, y)
        self.elements.append({"type": "node", "id": self.nid, "lat": p["lat"], "lon": p["lon"], "tags": tags})
        self.nid += 1

    def way(self, pts, tags):
        self.elements.append({"type": "way", "id": self.nid, "tags": tags, "geometry": [self.deg(x, y) for x, y in pts]})
        self.nid += 1


def rect(cx, cy, ux, uy, w, d):
    """A rectangle w wide along (ux, uy), d deep into the block (its left side)."""
    nx, ny = -uy, ux
    a = (cx - ux * w / 2, cy - uy * w / 2)
    b = (cx + ux * w / 2, cy + uy * w / 2)
    return [a, b, (b[0] + nx * d, b[1] + ny * d), (a[0] + nx * d, a[1] + ny * d), a]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--size", type=float, default=500.0, help="side of the town in metres")
    ap.add_argument("--block", type=float, default=80.0, help="block size in metres")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--shops", type=float, default=0.12, help="share of lots with a shop")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    osm = Osm()
    half = a.size / 2 + 60
    n = int(a.size // a.block) + 2
    xs = [-(n // 2) * a.block + i * a.block + rng.uniform(-6, 6) for i in range(n + 1)]
    ys = [-(n // 2) * a.block + j * a.block + rng.uniform(-6, 6) for j in range(n + 1)]
    mid_x, mid_y = n // 2, n // 2
    names = iter(rng.sample(STREETS, len(STREETS)) * 3)
    for i, x in enumerate(xs):
        main_av = i == mid_x
        osm.way([(x, -half), (x, half)], {"highway": "secondary" if main_av else "residential",
                                          "name": AVENUES[0] if main_av else next(names), "surface": "asphalt"})
    for j, y in enumerate(ys):
        main_av = j == mid_y
        osm.way([(-half, y), (half, y)], {"highway": "secondary" if main_av else "residential",
                                          "name": AVENUES[1] if main_av else next(names), "surface": "asphalt"})
    shop_left = {k: list(v) for k, v in [(json.dumps(t), names_) for t, names_ in SHOPS]}
    fuel_done = False
    for i in range(n):
        for j in range(n):
            x0, x1, y0, y1 = xs[i], xs[i + 1], ys[j], ys[j + 1]
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            if abs(cx) > a.size / 2 or abs(cy) > a.size / 2:
                continue
            dist = math.hypot(cx, cy) / (a.size / 2)
            setback = 9.5                           # street centre to the building front
            bx0, bx1, by0, by1 = x0 + setback, x1 - setback, y0 + setback, y1 - setback
            if i == mid_x and j == mid_y - 1:
                # the square: paved, trees, a church on one side
                osm.way([(bx0, by0), (bx1, by0), (bx1, by1), (bx0, by1), (bx0, by0)], {"place": "square", "highway": "pedestrian", "area": "yes"})
                for _ in range(10):
                    osm.node(rng.uniform(bx0 + 4, bx1 - 4), rng.uniform(by0 + 4, by1 - 4), {"natural": "tree"})
                continue
            if (i, j) == (mid_x - 2, mid_y + 1):
                osm.way([(bx0, by0), (bx1, by0), (bx1, by1), (bx0, by1), (bx0, by0)], {"leisure": "park", "name": "Parque da Querência"})
                for _ in range(26):
                    osm.node(rng.uniform(bx0 + 3, bx1 - 3), rng.uniform(by0 + 3, by1 - 3), {"natural": "tree"})
                continue
            if not fuel_done and dist > 0.45 and rng.random() < 0.25:
                # a fuel station on the block's corner, the rest still built up
                fuel_done = True
                osm.way([(bx0, by0), (bx0 + 30, by0), (bx0 + 30, by0 + 28), (bx0, by0 + 28), (bx0, by0)],
                        {"amenity": "fuel", "name": rng.choice(["Posto do Gringo", "Posto Querência", "Posto Pampa"])})
                corner_taken = True
            else:
                corner_taken = False
            # lots along the four fronts of the block
            fronts = [((bx0, by0), (bx1, by0), (1, 0)), ((bx1, by1), (bx0, by1), (-1, 0)),
                      ((bx1, by0), (bx1, by1), (0, 1)), ((bx0, by1), (bx0, by0), (0, -1))]
            depth = min(22.0, (by1 - by0) / 2 - 1, (bx1 - bx0) / 2 - 1)
            for (sx, sy), (ex, ey), (ux, uy) in fronts:
                L = math.hypot(ex - sx, ey - sy)
                side = (ux, uy) in ((0, 1), (0, -1))      # the short sides leave the corners to the long ones
                t, end = (depth, L - depth) if side else (0.0, L)
                while end - t > 6.0:
                    w = min(rng.uniform(8.0, 15.0), end - t)
                    cxl, cyl = sx + ux * (t + w / 2), sy + uy * (t + w / 2)
                    t += w
                    if corner_taken and cxl < bx0 + 34 and cyl < by0 + 32:
                        continue
                    levels = max(1, int(rng.triangular(1, 12 if dist < 0.35 else 5, 2 if dist > 0.5 else 4)))
                    tags = {"building": "yes", "building:levels": str(levels)}
                    if rng.random() < 0.18:
                        tags["building:colour"] = rng.choice(["white", "beige", "yellow", "pink", "blue", "green", "orange"])
                    if levels <= 2 and rng.random() < a.shops * (2.0 if dist < 0.4 else 1.0):
                        st, pool = rng.choice(SHOPS)
                        key = json.dumps(st)
                        tags.update(st)
                        tags["name"] = shop_left[key].pop(0) if shop_left[key] else rng.choice(pool)
                    d = depth if levels > 2 else min(depth, 14.0)
                    osm.way(rect(cxl, cyl, ux, uy, w - 0.2, d), tags)
    with open(a.out, "w") as f:
        json.dump({"elements": osm.elements, "generator": "City Invaders gen_city.py", "seed": a.seed,
                   "lat": LAT0, "lon": LON0}, f, ensure_ascii=False)
    print(f"generated {len(osm.elements)} elements ({a.size:.0f} m, seed {a.seed}) -> {a.out}")


if __name__ == "__main__":
    main()
