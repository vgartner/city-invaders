PORTO ALEGRE GENERIC CITY BUS FLEET

DELIVERY
Five glTF 2.0 binary files, covering three vehicle designs:
- Standard 12 m low-floor city bus in blue, red and green band variants.
- 18 m articulated city bus in white/grey with a yellow band.
- 9 m lotacao minibus in red/white.
Generic bodywork with no manufacturer logos, real operator branding or seals.
All have a fictional T5 CENTRO LED destination, fictional POA 0527 plates,
light road dirt, paint scuffs, transparent glazing, seats and yellow poles.

Each GLB has front, right-side and rear PNG previews, a front three-quarter
render and an operation preview showing the sliding doors (and joint yaw on
the articulated bus). These are renders of the delivered GLBs, not concept art.
Preview lights and background are not objects in the assets.

COORDINATES AND SCALE
Metres, +Y up, front -Z. Vehicle-left is -X when looking forward.
Origin: ground centre of the complete visible footprint in the neutral pose,
including mirrors, bumper trim and exhaust. Tyres touch Y=0. Body and other
node offsets already account for this centring; keep the vehicle_root at zero.
12/18/9 m describe nominal classes; measured visible lengths, including trim,
are 12.215 / 18.215 / 9.215 m. Mirror span is wider than the 2.55 / 2.36 m body.
The standard bus has a 0.34 m low-floor central aisle with raised wheel houses.
Actual neutral dimensions and node translations appear in fleet_manifest.json.

WHEEL NODES
wheel_fl, wheel_fr, wheel_rl, wheel_rr in every file.
wheel_ml and wheel_mr additionally on the articulated bus.
Every wheel has an axle-centred pivot, neutral local X roll axis and no baked
rotation or corrective scale. Roll via local X; steer the front wheels via Y.
Rear dual tyres on the large buses are included in the corresponding rear node.

OPERABLE DOORS
Standard and articulated buses: door_1, door_2, door_3.
Lotacao: door_1.
These are individual single-leaf plug-sliding door assemblies in real apertures.
To open, translate the named door node relative to its closed local position:
  large buses: (+0.13, 0, +1.30) metres
  lotacao:     (+0.13, 0, +1.07) metres
The first stage plugs outward (+X); the second slides toward the rear (+Z).
For a staged opening, apply X first, then Z. Reverse to close. Parent-relative
axes stay correct when the articulated rear section turns. Door-track hardware
and thresholds remain body-mounted. The offsets are also stored in node extras.
No animation clips are embedded.

ARTICULATED BUS
front_section and rear_section have coincident pivots at the bellows joint.
Keep front_section neutral and rotate rear_section about local Y for yaw.
Its rear body, wheel_rl/rr, door_3 and lights_rear follow automatically.
The front pair and middle pair of wheels belong to front_section.

The rubber bellows is a hollow accordion mesh. A two-joint glTF skin binds it to
front_section and rear_section, so it deforms across the articulation without
separating from the section ends. There are no animation clips. Preserve the
skin, joint hierarchy and inverse bind matrices on import. The bellows is a
separate scene-root mesh as recommended for glTF skinning; vehicle_root remains
the skeleton root. Move the imported complete scene to move the whole bus,
including the bellows. Tests cover +/-0.35 rad (about 20 degrees) rear yaw.

PBR RESOURCES
Three shared materials: surface atlas, line-colour atlas tint, transparent glass.
Exactly four embedded PNG images per file, each 2048 x 2048:
- basecolour: sRGB
- normal: linear, tangent-space
- metallic_roughness: linear; G=roughness, B=metallic, R=255
- emissive: sRGB; lamp lenses and destination LEDs
The atlas has separate regions for painted panels, rubber, steel, seats, floor,
bellows, signs and poles. The 12 m colour variants share exactly the same
geometry and textures; only the line-colour material tint changes.
lights_front and lights_rear are separate emissive mesh nodes. There are no
light objects, cameras, ground plane or background. No external texture files
are needed. Static files contain no animations; only the articulated bellows
uses a skin. Import using a glTF 2.0 importer at scale 1.0.

VALIDATION
Khronos glTF Validator: all five GLBs have zero errors and zero warnings.
Independent binary checks verify triangle budgets, size, footprint-centre origin,
wheel road contact and pivots, required node names, door offsets, rear hierarchy,
normalized normals, tangents, face winding, nondegenerate triangles, UV range,
texture dimensions and embedded resources. Identical geometry across variants.
Loaded-asset operation checks verify local X wheel roll, door aperture clearance,
rear wheel motion about the joint and front wheel stability. Bellows deformation
matches section transforms in both yaw directions, with sub-millimetre error.
JSON reports are included. No target-engine vehicle physics is supplied.

PALETTE REFERENCE
Original liveries use generic bands inspired by Porto Alegre's regional colour
palette (blue/red/green/yellow), documented by the city:
https://www.prefeitura.poa.br/smmu/consorcios
This is visual inspiration only; no real operator identity is reproduced.

INVENTORY
bus_12m_blue.glb / 43,322 triangles / X 3.340 x Y 3.519 x Z 12.215 m
bus_12m_red.glb / 43,322 triangles / X 3.340 x Y 3.519 x Z 12.215 m
bus_12m_green.glb / 43,322 triangles / X 3.340 x Y 3.519 x Z 12.215 m
bus_18m_articulated_yellow.glb / 53,966 triangles / X 3.340 x Y 3.559 x Z 18.215 m
lotacao_9m_red_white.glb / 38,132 triangles / X 3.150 x Y 3.359 x Z 9.215 m
