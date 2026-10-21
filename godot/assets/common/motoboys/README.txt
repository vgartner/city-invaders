PORTO ALEGRE / FOUR MOTORCYCLE COURIERS

CONTENTS
Four generic 150–300 cc street motorcycles, each with a helmeted, jacketed
courier and a large rear delivery box. There are no real manufacturer logos
or brand names. Plates are explicitly marked FICTICIO / POA and JOGO / CARGA.
01 Red box, nominal 150 cc round-headlight commuter; navy jacket, white helmet.
02 Blue box, nominal 200 cc angular street bike; olive jacket, dark helmet.
03 Yellow box, nominal 250 cc sport commuter; charcoal jacket, red helmet.
04 Green box, nominal 300 cc utility street bike; burgundy jacket, white helmet.
The riders have varied builds, statures, ages and skin tones. The designs have
sculpted tanks, saddles, engine fins, exhausts, coil shocks, fork sliders,
mirrors, controls, brakes, cargo-box hardware and reflective strips. The
utility bike uses wire spokes; the others use cast wheels. Displacement labels
are design references for these fictional models, not mechanical simulations.

FORMAT
Self-contained glTF 2.0 binary (.glb), +Y up, front/travel direction -Z, metres.
Origin is at ground level midway between wheel contact patches, centred in
the visible default footprint. Axles are at (0, 0.31, -0.68) and (0, 0.31, +0.68).
Wheel radius is 0.31 m; wheelbase 1.36 m; total wheel footprint length 1.98 m.
Complete rider + helmet + motorcycle: 25,482–26,532 triangles per GLB.
No lights, cameras, background or ground mesh are embedded.

PBR MATERIALS
Two materials, each using one 2048 x 2048 UV atlas layout:
- Rider: base colour, tangent normal and metallic/roughness maps.
- Motorcycle, delivery box and helmet: base colour, tangent normal,
  metallic/roughness and emissive maps.
All seven PNG maps are embedded. Base colour/emissive use sRGB; normal and
metallic/roughness are linear. Metallic is B, roughness G. The visor is closed,
opaque smoked material with a glossy finish. Head/hair surfaces enclosed by
the full-face helmet have been removed to save triangles. Reflective strips
are bright PBR surfaces; headlight, tail lamp and indicator pixels are emissive.
No actual punctual light objects are present.

SHARED RIDER RIG
Exactly the same 52 mixamorig: joint names, order, bone parent hierarchy,
canonical local bone translations and inverse bind matrices as the pedestrian
pack. Stature uses a uniform rider_stature wrapper. Default visible pose is
ride at t=0; recover the common canonical A-pose using inverse bind data.
Jackets, trousers, boots and exposed skin are skinned. The helmet is attached
to the existing Head bone, without adding any human joints. Four weights per
skinned vertex; boot soles retain foot/toe influences for stable contact.

MOTORCYCLE NODES
bike_frame: frame, engine, bodywork, seat, exhaust, rear rack and delivery box.
wheel_front / wheel_rear: axle-centred meshes, local X roll axes.
handlebar: local Y steering pivot at (0, 0.88, -0.50). Carries the front fork,
mirrors, controls, instrument cluster, wheel_front and lights_front.
lights_front / lights_rear: separate meshes using emissive atlas regions.
helmet: rigid child of mixamorig:Head.
Keep the complete imported scene under your game prefab. rider_mesh is a
separate scene-root skinned mesh, following the glTF skinning recommendation;
its deformation follows the skeleton under courier_root. Move the complete
prefab, and preserve the skeleton and motorcycle hierarchy. Refresh skinned
bounds during fleeing if your engine uses fixed animation bounds.

ANIMATIONS / ALL CHANNELS AT 30 FPS
ride: 3.0 s, loop. Subtle common lean, small steering movement and suspension
sway; both hands track the actual grips, both feet remain on their pegs.
Each wheel makes 13 turns per loop. Move the game entity at about 8.44 m/s
(30.39 km/h) along -Z for matching wheel speed. This clip has no forward travel.
idle_stopped: 3.0 s, loop. Left foot planted on the street, right foot on its
peg, both hands on the grips, slight breathing/weight shift. Wheels stopped.
crash_fall: 2.7 s, one-shot. Rider releases the grips as the motorcycle and
rider fall onto the left side; ground clearance is solved for both together.
flee_on_foot: 3.2 s, one-shot. Rider releases the bars, swings the right leg
forward over the saddle, steps off to the left and runs forward. The motorcycle
stays in place. Rider-only hip motion travels about 0.92 m left and 5.5 m
forward; retain or extract this motion for your game controller.
Configure ride/idle_stopped to repeat and the other clips to clamp at the end.
Loop and fps settings are recorded in animation extras; glTF itself does not
force engine playback repeat settings.

PREVIEWS
Contact sheet, animation pose sheet and individual front/side/rear, riding,
stopped, crash, dismount and running PNGs are renders of the delivered GLBs.
Their studio lighting and background are preview settings, not asset content.

VALIDATION
All four pass Khronos glTF Validator with zero errors and zero warnings.
Independent binary inspection checks triangle budgets, indices, finite and
non-degenerate geometry, normals/tangents, normalized skinning, identical
pedestrian bone names/hierarchy/binds, node names and steering/roll axes,
2048 embedded maps, PBR/emissive materials, 30 fps keys, four required clip
names, loop seams, wheel cadence and fleeing direction.
Loaded-file tests sample riding and stopped contact at 60 Hz, including between
30 fps keys. Maximum hand-anchor error: 0.001 mm. Maximum actual
shoe-sole vertex-centroid error: 0.000 mm. Additional checks cover
steering hierarchy, wheel axle centres, loop closure, the planted idle foot,
fall orientation, forward fleeing and sampled ground clearance in all clips.
Minimum sampled geometry Y: -0.000000 m. Detailed JSON reports are included.

SOURCES
Human anatomy, morphs, source weights, fitted jackets/trousers/boots and surface
maps adapt the CC0 MakeHuman assets used by the pedestrian pack. Motorcycles,
full-face helmets, delivery boxes, atlas processing and baked motion solving
were created for this delivery. Source references and asset licence included.

FILE INVENTORY
motoboy_01_red_150.glb / 25,482 triangles
motoboy_02_blue_200.glb / 25,618 triangles
motoboy_03_yellow_250.glb / 26,532 triangles
motoboy_04_green_300.glb / 26,284 triangles
