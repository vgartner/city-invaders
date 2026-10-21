PORTO ALEGRE / SIX URBAN CYCLISTS

CONTENTS
Six self-contained glTF 2.0 binary characters, each with a bicycle and five
embedded 30 fps clips. Three women and three men, ages 21–68, varied builds,
faces, hair, skin tones, clothing and bike types.
01 Commuter woman, backpack and glasses, teal city bicycle.
02 Delivery man, insulated food backpack and helmet, utility bicycle.
03 Sporty woman, blue jersey, shorts and helmet, red road-style bicycle.
04 Older man, grey hair, green T-shirt, worn steel bicycle and leather saddle.
05 Student man, T-shirt, shorts and backpack, blue compact city bicycle.
06 Middle-aged woman, orange T-shirt, step-through bicycle and wire basket.

FORMAT AND GEOMETRY
Metres, +Y up, forward -Z. Scene origin is at ground level halfway between the
wheel axles. Wheel centres: (0, 0.33, -0.57) and (0, 0.33, +0.57) metres.
Each complete rider+bicycle contains 16,518–21,858 triangles.
One material, one shared 2048 x 2048 UV atlas layout. The PBR texture set has
three embedded images of that same layout: base colour (sRGB RGBA), tangent
normal (linear RGB) and metallic/roughness (linear RGB; G=roughness, B=metallic).
Alpha-mask hair/eyelashes and double-sided surfaces use the shared material.
No external textures, lights, cameras, background or ground geometry.

SHARED HUMANOID RIG
The skin has exactly the same 52 mixamorig: bone names, order, parent hierarchy,
canonical bone translations and inverse bind matrices as the pedestrian pack.
No extra human bones were added. Stature uses a uniform rider_stature wrapper,
as in the pedestrian files. The initial visible pose is coast at time zero;
bone rotations are therefore already posed, while the canonical bind data is
unchanged. Use the inverse bind data when recovering the common A-pose.
Skin includes anatomy, garments, hair, accessories and helmets where applicable.
Shoe soles are bound to foot/toe bones to keep them rigid on the platforms.

BICYCLE NODES
bike_frame: static frame, saddle, chain, reflectors, rack/basket where present.
wheel_front, wheel_rear: axle-centred, local X roll axes, radius 0.33 m.
crank: local X axis at (0, 0.34, 0). Both crank arms and chainring rotate here.
pedal_l, pedal_r: attached children of crank, with counter-rotation to keep the
platforms level. The feet follow these actual animated platform positions.
handlebar: local Y steering axis; includes stem, bars, fork and brake hardware.
wheel_front is a child of handlebar, so steering carries the fork/front wheel.
The rider and bike are under cyclist_root for coordinated falling. rider_mesh
is a separate scene-root skinned mesh as recommended for glTF skinning; move
the complete imported scene/prefab to move the complete asset.

ANIMATIONS (ALL KEYS AT 30 FPS)
ride: 5.0 s, loop. Exactly 1 crank revolution per second (30 frames), 5 turns
per loop. Wheels make 12 revolutions per loop, gearing 2.4:1. At radius 0.33 m
this corresponds to 17.915 km/h. Motion is in place; move the game entity at
about 4.976 m/s along -Z for matching road speed. The five-second period closes
both crank and wheel phases without a wheel reset or visible loop jump.
coast: 2.5 s, loop. Wheels turn, crank and feet hold a level coasting position.
idle_on_bike: 3.0 s, loop. Left foot planted on the ground, right foot on a pedal;
rider shifts off the saddle slightly and keeps hands on the bars.
dismount_flee: 3.2 s, one-shot. Jumps to the left of the bicycle, releases the
bars, lands and starts running forward (-Z). Rider-only hip root motion moves
about 5 m forward; the bicycle stays in place. Preserve or extract that motion
according to your controller. Refresh skinned bounds if your engine uses fixed
bounds for root-motion clips.
die: 2.6 s, one-shot. Rider and bicycle fall to the left and settle on the ground.
Clamp this clip at the end rather than looping it.
The loop flag and fps are stored in clip extras; configure your engine's repeat
mode for ride/coast/idle_on_bike and one-shot/clamp for dismount_flee/die.

PREVIEWS
Individual riding, side, coasting, foot-down idle, dismount jump, running and
fallen PNGs are included, plus a contact sheet and action-pose sheet. These are
renders of the actual GLB files, not concept art. Preview lighting/background
are renderer settings and are not embedded in the assets.

VALIDATION
All six files: Khronos glTF Validator, zero errors and zero warnings.
Independent binary inspection: triangle budgets, 52-bone compatibility, weights,
finite geometry, normals/tangents, UVs, texture sizes, node names, axle hierarchy,
30 fps timestamps, cadence, approximately 18 km/h wheel speed, closed loops and
five required clip names. Rig checks compare against the actual pedestrian GLB.
Loaded-file checks sample riding/coasting/idle motion at 60 Hz, including the
intervals between 30 fps keys. Maximum grip-anchor error: 0.000 mm;
foot-anchor error: 1.367 mm; actual shoe-sole vertex-centroid error:
1.367 mm. Additional checks cover a planted idle foot, level pedals,
loop-transform closure, forward fleeing, steering hierarchy, and sampled ground
clearance during dismount and falling. See the included JSON reports.

SOURCES
Rider anatomy, fitted garments, hair, skin textures and native source weights
adapted from the CC0 MakeHuman asset sources already used by the pedestrian
pack. Bicycles, cycling helmets, motion, IK contact solving and export work are
original for this delivery. Source references and a licence copy are included.

FILE INVENTORY
cyclist_01_commuter_woman_30s.glb / 19,078 triangles
cyclist_02_delivery_man_20s.glb / 19,467 triangles
cyclist_03_sporty_woman_20s.glb / 21,858 triangles
cyclist_04_older_man_60s.glb / 16,518 triangles
cyclist_05_student_man_20s.glb / 18,147 triangles
cyclist_06_basket_woman_50s.glb / 20,706 triangles
