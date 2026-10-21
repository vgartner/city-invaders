# Models and assets

All models are glTF binaries (`.glb`) in `godot/assets/<group>/`. A folder is
picked up automatically: drop a model that follows the conventions below into
it and it appears in the game.

## Collections

`godot/assets/collections.json` groups the asset folders into collections:
**Common** (generic, reusable by any city: Transport, People, Animals,
Furniture, Pickups, Weapons, Enemies) and regional ones such as **Rio Grande
do Sul** (Porto Alegre landmarks, gaúcho culture, local people and brands,
horses, Charrua and Fruki trucks, the tram, stalls, regional pickups, films).
The map editor's object picker is grouped by collection / category. A new
region gets its own collection; generic models go to Common.

Each collection is a folder:

```
godot/assets/
  common/              cars, buses, motoboys, cyclists, skaters, dogs, pigeons,
                       props (street furniture, bus shelter), enemies, weapons,
                       pickups/{ammo,medkit}, people (ped_01..15)
  rio_grande_do_sul/   landmarks, gaucho, horses, birds (quero-quero), trucks,
                       lorries, tram, war (harvester), stalls, vendors, police,
                       pickups/{churrasco,chimarrao,pala,fruki,laco},
                       weapons/laco, people (ped_16..20), video/cities/<map>
  audio/ ui/ materials/ kenney/   shared engine resources, outside collections
```

A new city reuses `common/` and adds its own folder (for example
`assets/santa_catarina/`) plus an entry in `collections.json`. Folder names
used below (`people/`, `cars/`...) are relative to their collection.

## Conventions

- Metres, +Y up, **front towards -Z**, origin on the ground at the centre
- Textures embedded, PBR (base colour, normal, metallic/roughness, emission)
- No lights, cameras or ground planes in the file
- Local brands are fine (see "Brands and trademarks" in LICENSING.md):
  credit the logo's source; no real police / military insignia
- Keep triangle counts reasonable: ~15-30k for characters and vehicles,
  more only for set pieces seen up close

### People (`people/`, `vendors/`, `police/`, riders)

The pedestrians share one rig: the 52 `mixamorig:` bones of the MakeHuman
pedestrian pack (same names, hierarchy and rest translations). Clips are
in place (no root motion), looping ones marked so:

| Folder | Clips |
|---|---|
| `people/` | `idle`, `walk`, `sprint`, `die` |
| `vendors/` | `idle_selling`, `flee`, `die` |
| `police/` | `idle_alert`, `walk`, `run`, `aim`, `fire`, `reload`, `hit`, `die` |
| `skaters/` | `ride`, `push`, ... |
| `dogs/` | own rig: `idle`, `walk`, `run`, `die` |

**Everyone moves the same way.** At runtime every person on the shared rig
(pedestrians, police, vendors) takes `idle`, `walk` and `sprint` from one
model per sex (`PEOPLE_GAIT` in `scripts/civilian.gd`: `ped_10_student_man_20s`,
`ped_01_student_woman_20s`), retargeted to its skeleton. A model only adds
what its role needs: the police their `idle_alert`, `aim`, `fire`, `reload`
and `hit` (on the shared walk and sprint their arms keep the rifle-ready
pose of `idle_alert`), the vendors `idle_selling`, and each model its own
`die`. A new character therefore needs no walk or run of its own; a
better gait goes into the donor models and every person gets it.

The generated pedestrians needed fixes, done in place with these tools. **Run
them on every new character pack** (otherwise they slide and walk
splayed), in this order: `unshare_anim.py` (exporters share key arrays
between tracks; the in-place fixes need each track's own), `gait.py`,
`fix_stance.py [--clips=...]`, `fix_arms.py`, `arm_swing.py`. Check with
`fix_arms.py --measure`.

- `tools/assets/gait.py` – measures the ground speed of `walk` / `sprint` (stride)
- `tools/assets/fix_stance.py [--clips=...]` – brings splayed legs to the hip width
- `tools/assets/fix_arms.py` – arms closer to the body
- `tools/assets/arm_swing.py` – stronger arm swing in `sprint`
- `tools/assets/fix_cyclist_crank.py` – cyclists pedalling backwards
- `tools/assets/team_shirts.py <ped.glb> gremio|inter <out.glb>` – a fan in club colours

### Vehicles (`cars/`, `buses/`, `trucks/`, `motoboys/`, `cyclists/`, `horses/`)

Wheels are their own nodes `wheel_*` pivoting on the axle (roll about local
X); `lights_front` / `lights_rear` carry emissive materials. Riders of bikes
and motorbikes are a mesh named `rider_mesh` (hidden when they bail out). The
traffic share of each kind is in `KINDS` in `car.gd`.

### Placed models and landmarks

A mesh whose material name contains `flag` is a flag cloth: it waves in the
game (`godot/shaders/flag_wave.gdshader`), from the pole at its smallest
local X out along +X, more towards the free end. Meshes named
`*_ground_pad` are laid on the terrain, `*_island` and names ending in
`glass` get no collision, `lamp_*` and `pickup_<kind>` empties become lights
and pickups.

A landmark in parts - far, near and inside versions, doors on hinges - is
described by a `site.json` (docs/MAP_PIPELINE.md, "Landmarks in parts"):
`rio_grande_do_sul/landmarks/centro_historico/` (CC0, see its LICENSE.txt
and REFERENCES.txt).

### Robots (`enemies/`)

The URB-07 rig (also used by the mech at 2x). The robot mesh is segmented:
every plate follows one bone, which is how `wreck.gd` breaks it apart.
Clips: `idle`, `walk`, `run`, `shoot`, `hit`, `death` (mech: `fire_left`,
`fire_right`, `die`, ...).

### Weapons (`weapons/`)

A first-person model is the arms and the gun in one skinned mesh with bones
`Weapon`, `Magazine`, `SpareMagazine`, `Bolt` and the arm bones, and clips
`idle`, `fire`, `reload`, `draw`. The camera is at the origin. A world pickup
version (`<gun>_pickup.glb`) is the gun alone.

## Blender scripts (`tools/blender/`)

Everything there is procedural and reproducible:

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python tools/blender/<script>.py -- <out> [what]
```

| Script | Builds |
|---|---|
| `pickups_gaucho.py` | costela on the espeto, chimarrão, pala on its stand, Fruki can (label from `tools/blender/ref/`) |
| `weapons_fp.py` | .38 revolver and double-barrel shotgun into the original arm rigs (`tools/blender/arms/`) |
| `weapons_fp2.py` | polymer 9 mm pistol and AR carbine, with magazine and bolt on their bones |
| `landmarks.py` | Mercado Público, Paço Municipal, Ed. Missões with Farmácias São João, Sulacap, Cine Imperial (a classical facade generator: windows, mouldings, pilasters, cornices, balustrades, pediments, mansards, galleries) |
| `gasometro.py` | Usina do Gasômetro and its chimney |
| `landmarks.py kiosk` | the newspaper kiosk (`stalls/prop_newspaper_kiosk.glb`): open counter, side door, covers inside; collides with its real walls, the vendor stands inside |
| `landmarks.py posto` | the first, simple Charrua station (superseded) |
| `brand_truck.py` + `tools/assets/truck_livery.py` | the trucks in use: an unbranded modular truck family (6x2 chassis-cab + tank or 6 m box, 4x2 tractor + 13.5 m semi-trailer) with 16 `livery_*` surfaces; `truck_livery.py <manifest> charrua|fruki` draws a livery, `brand_truck.py` puts it on an assembled truck. Flat livery UVs run right to left (art is mirrored going in); a new company = a new function in `truck_livery.py` |
| `brand_station.py` + `tools/assets/charrua_livery.py` | the station in use: an unbranded model delivery with 19 `brand_*` livery surfaces; `charrua_livery.py` draws the Charrua images from its branding manifest, `brand_station.py` puts them on and exports `landmarks/posto_charrua.glb`. Another distributor = another livery script |
| `vehicles.py` | the Charrua fuel tanker (`truck`), Fruki box truck and tractor-trailer (`fruki_box`, `fruki_trailer`), the armoured combine harvester (`harvester`, with a `reel` node that spins while driven) |
| `make_video.py` | the cinema trailer; converts any video to Ogg Theora (`convert in.mp4 out.ogv`) |
| `preview.py` | renders a quick look at any `.glb` |
| `bakeutil.py` | shared materials (wood, steel, meat, gourd, plaster, brick) and baking |

Godot plays video only as Ogg Theora: convert with `make_video.py convert in.mp4 out.ogv [width]`.

## Music

Tracks (mp3 or ogg) go in `assets/<collection>/music/<station>/`. Every
station folder is a car-radio station (key N while driving): `gaita/`,
`gaita_solo/` (accordion only - what the gaiteiro plays), `violao/` (what a
guitarist will play), `colheitadeira/` (where the harvester's radio starts),
`radio_campeira/`, `rock_gaucho/`; `loading/` plays on the loading screen and
is not a station. File names are plain ASCII; station names and song titles
as shown on the radio are in `scripts/music.gd`.

## Films per city

`godot/assets/rio_grande_do_sul/video/cities/<first map of the city>/` holds a city's films
(Porto Alegre: `cities/gasometro/`). `intro.ogv` is the opening cutscene
(full screen when the city starts at its first phase, skippable); every
`.ogv` there can be chosen for a cinema in the map editor (saved as `"film"`
on the building in `user/buildings_user.json`). 1280x720 is plenty.

## Credits

Every third-party asset and its licence is listed in
[`godot/assets/CREDITS.md`](../godot/assets/CREDITS.md). Add yours there when
you contribute a model.

## Fruki pickup can (21 October 2026)

`pickups/fruki/fruki.glb` is a single-mesh, single-material 350 ml can
(0.066 m diameter, 0.122 m height, 3,256 triangles). Its original path,
ground-centred origin and entity scale of 3.0 are unchanged. The closed
scored lid, rolled seams, domed underside, rivet and offset-hole pull-tab
are geometry. No lights, cameras, rig or animations are exported.

The old default cylinder UV used only half the label height. The new body
unwrap uses the complete wrap region, with upright wordmarks centred at
U=0.25 and U=0.75 (180 degrees apart). Base colour, OpenGL normal and
metallic/roughness maps are 2048 square and embedded. The upper atlas half
is printed packaging; the lower half is aluminium. Ink is rougher and less
metallic so reflections do not erase the logo. The two-sided layout is a
game adaptation, not an official packaging print master.

Build through `pickups_gaucho.py ... fruki` as before, or run
`Blender -b --python tools/blender/fruki_can.py -- OUTPUT_DIR
tools/blender/ref/fruki_can_v2 --previews`. The builder saves an editable
packed `.blend`, the GLB and a model report to OUTPUT_DIR. `--previews`
adds front/back/three-quarter/lid renders after saving the clean source.

The committed vector artwork and PNGs are under
`tools/blender/ref/fruki_can_v2/`. Optional label regeneration uses Node
with `sharp`: `node tools/assets/fruki_label.cjs OUTPUT_DIR
tools/blender/ref/fruki_logo_commons.jpg`. Only the existing public-domain
wordmark lettering is reused; retailer photographs were observed, not
incorporated into textures. See the asset credits for brand provenance.

Validation of the rebuild: Khronos Validator reported zero errors and zero
warnings; Godot imported the GLB and rendered both opposite faces through
the real pickup scene in Gasometro. The existing scale remained (3,3,3).
A real physics overlap removed the non-respawning pickup, healed 70 to 95
and activated the existing approximately 12-second adrenaline effect.
No pickup/player logic or entity definition was changed.
