# Entity definitions (data-driven objects)

What an object *is* - a healing item, a weapon, a bus stop - lives in data
next to its model, not in the code. The game, the Director and the Studio
read the same definitions.

## Files

- `godot/assets/types.json` - the type tree. Each type may `extends` another
  and adds or overrides attributes:

  ```json
  {"Item":     {"pickup": true},
   "Healing":  {"extends": "Item", "category": "healing", "effect": {"heal": 25}},
   "Armour":   {"extends": "Item", "category": "armour",  "effect": {"armor": 100}},
   "Booster":  {"extends": "Item", "category": "booster", "effect": {"adrenaline": 12}},
   "Ammo":     {"extends": "Item", "category": "ammo",    "effect": {"ammo": true}},
   "Weapon":   {"extends": "Item", "category": "weapon"},
   "Grenade":  {"extends": "Item", "category": "grenade"},
   "Part":     {"extends": "Item", "category": "part",    "effect": {"part": true}}}
  ```

- `<model>.def.json` beside a model (or a `defs/<id>.def.json` for items
  without a file of their own) - one object:

  ```json
  {"id": "churrasco", "type": "Healing", "name": "Espeto de churrasco",
   "model": "res://assets/rio_grande_do_sul/pickups/churrasco/churrasco.glb",
   "effect": {"heal": 35}, "scale": 1.0, "glow": [1.0, 0.45, 0.2]}
  ```

  Attributes merge down the chain: type defaults, then the definition's own.
  `tags` add up (e.g. `bus_stop`, `edible`, `gaucho`).

- `godot/assets/<collection>/roles.json` - which item plays each **role** in
  that collection's cities (the Studio's per-map choice):

  ```json
  {"healing_big": "churrasco", "healing_small": "chimarrao", "booster": "fruki",
   "armour": "pala", "medicine": "remedio"}
  ```

  `common/roles.json` holds the defaults (`medkit`...); a map uses its
  collection's roles, falling back to common.

## Code

- `scripts/entities.gd` (static registry): scans `res://assets` for
  `*.def.json` once, resolves `extends`, and answers `get_def(id)`,
  `by_category(cat)`, `of_model(path)`, `is_a(id, type)`, `role(collection, role)`,
  `role_candidates(role)`.
- Pickups take model, scale and glow from the definition; the player applies
  `effect` (heal, armour, adrenaline, ammo, weapon, part) instead of a
  hard-coded `match`; the pickup counts are per role.
- **Sounds per model**: a definition's `sound` plays on the placed model -
  `{"station": "violao"}` plays that music station's tracks (street
  musicians, with an optional `fallback` station), `{"loop": "res://...wav"}`
  one clip on repeat; `range` (metres), `db` and `unit` tune it.
- Non-item types: `Scenery`, `Musician` (with a sound), `StreetFurniture`,
  `BusStop` (a `StreetFurniture`; tag `bus_stop`, links `bus_line`).
- **A front that faces the street**: a definition's `faces` says which side
  of the model is its front and what it turns to -
  `{"front": "+z", "towards": "street", "gap": 1.3}`. `front` is the
  model's own axis (`+z`, `-z`, `+x`, `-x`), `towards` is `street` (the
  nearest car street) or `walk` (the nearest car street, footway or
  promenade), `gap` the least distance in metres between the model's centre
  and the asphalt. `prop` names the map pipeline's prop kind it is
  (`bus_stop`, `bench`, `stall:newspaper_kiosk`). The pipeline turns and
  moves those props (`_face` in tools/map/osm2gltf.py), the map editor turns a
  placed model the same way (Q / E still turn it after), and
  tools/map/street_audit.py reports any that turned their back on the street
  or stand on a lane. Defined for the bus shelter, the bench and the
  newspaper kiosk.

## People and animals (the `Person` type)

Everyone on foot is data too. The types in `types.json`:

| Type | Extends | What it sets |
|---|---|---|
| `Person` | - | `health` 45, `speed` {walk 1.2, run 4.0} m/s, `react` "flee", `hunted` (robots go for it), `capsule` {radius, height}, `gait` "shared", `spawn` "street", `share` 1 |
| `Pedestrian` | Person | - |
| `Skater` | Person | `gait` "own" (push/ride clips), speed {walk 3.9, run 5.5}, `share` 0.15 |
| `Vendor` | Person | `spawn` "stall", `idle` "idle_selling" |
| `Police` | Person | `spawn` "patrol", `react` "fight", `health` 75, `armed`, `standoff` 22 m, `idle` "idle_alert" |
| `Animal` | - | `gait` "own", `hunted` false |
| `Dog` | Animal | speed {walk 1.2, run 6.0}, small capsule, `share` 0.08 |
| `Bird` | Animal | `spawn` "lawn", `react` "defend", `health` 30 |

A definition stands for a group of models: `models` lists folders (and
`fallback` one used when they are empty):

```json
{"id": "brigada_militar", "type": "Police", "name": "Brigada Militar officer",
 "models": ["res://assets/rio_grande_do_sul/police"]}
```

The current ones: `pedestrian` (common people, `drives`: they sit at the
wheel of the cars), `pedestrian_rs` (gaúchos and football fans, `share`
0.35), `skater`, `street_dog`, `street_vendor`, `brigada_militar`.

`quero_quero` (a `Bird`, `pigeon.gd` in its quero mode) carries the numbers
of its patch defence: `pairs` per map (on the lawns), `alarm_m` (closer
than this: the alarm display and a feint), `charge_m` (closer still: it
runs at the intruder at `run` m/s and pecks for `peck` every `peck_s`),
`give_up_s` and `patch_m` (it lets go after that long, or once the intruder
is that far from its patch), `cruise_m` (how high it flies), `health`,
`run_over_mps` (a vehicle faster than this over it kills it) and `corpse_s`.

- `spawn` says who places them: "street" are picked at random for the
  sidewalks, weighed by `share` and spread over the definition's models;
  "stall" stand at the vendors' stalls; "patrol" are the officers.
- `react` "fight": goes for robots it sees and towards gunfire, keeps
  `standoff` metres; "flee": runs away from robots and shots.
- `gait` "shared": the one walk every person uses (docs/ASSETS.md, People).
- Any attribute can be overridden by a definition: a slower, frailer
  `pedestrian_idosos` is a new `.def.json` with its own `models`, `speed`
  and `health`, no code.

`scripts/civilian.gd` reads the definition of its model (`person`); main
spawns by `spawn` (`Civilian.models_where`).

## Map editor (design mode)

- **By type (all collections)**: the palette lists the items by category
  (healing, armour, weapon...) and merges the collections' model categories
  by name. Placing an item saves a pickup spot, `"_pickups": [{id, x, y, z}]`
  in the map's `user/buildings_user.json`; it is there (and respawns) every round.
- **Items on this map**: one choice per role (`"_roles": {"healing_big":
  "remedio"}`), overriding the collection's `roles.json` for this map only.
- **Bus lines** (the first link between objects): a stop placed with
  "Bus line N" gets `"line": N`; each bus keeps to one line, the buses spread
  over the lines, every line in placing order.

The game reads these user edits at round start, no rebuild needed.

## Next

Other links (a shop and its stock, a camp's pieces), the Director reading
categories to know what a placed object is.
