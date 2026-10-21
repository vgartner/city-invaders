PORTO ALEGRE / FOUR STREET SKATEBOARDERS

CONTENTS
Four self-contained glTF 2.0 binary characters, two young men and two young
women, each with a detailed skateboard and six embedded 30 fps clips.
01 Man, age 24: teal T-shirt, dark trousers, cap, blue sneakers.
02 Woman, age 22: rust T-shirt, denim, ponytail and cap, white sneakers.
03 Man, age 26: sand T-shirt, dark trousers, over-ear headphones, blue sneakers.
04 Woman, age 21: plum T-shirt, denim, short curly hair, white sneakers.
Body shapes, faces, skin tones, hair and clothing colours differ.

FORMAT
Metres, +Y up, travel direction -Z; origin at ground under the board centre.
The skating stance is sideways with the rider looking towards travel direction.
The complete rider and board contain 16,246–19,738 triangles per file.
One material and one shared 2048 x 2048 UV atlas layout. Three embedded PNGs
use that same layout: base colour (sRGB RGBA), tangent normal (linear RGB),
metallic/roughness (linear RGB; G=roughness, B=metallic). Alpha-mask hair and
other thin surfaces use this same double-sided material. No external textures,
lights, cameras, backgrounds or ground planes are included.

RIG
Exactly the same 52 mixamorig: joint names, order, parent relationships,
canonical local bone translations and inverse binds as the pedestrian pack.
Rider stature uses a uniform rider_stature wrapper. Visible default pose is
ride at t=0; canonical bind data remains the shared pedestrian skeleton.
The skin includes garments, shoes, hair, caps and the headphones where present.
There are no additional humanoid bones. Shoes retain rigid sole contact.

BOARD NODES
skateboard: separate node; concave griptape deck, kicktails, maple ply edge,
underside stripe graphic, cast metal trucks, bushings, bolts and axle hardware.
wheels_front and wheels_rear: children of skateboard. Each contains its two
wheels and bearings and pivots at the axle midpoint about local X.
Wheel radius is 0.029 m; axle centres are at (0, 0.029, -0.25) and
(0, 0.029, +0.25) metres. The deck pivot is at (0, 0.098, 0).
Board length is 0.81 m, maximum width 0.212 m.

ANIMATIONS / ALL CHANNELS AT 30 FPS
push: 1.2 s, loop. Right foot stays on the deck, left foot recovers forward,
presses against the street and sweeps backward at approximately 4 m/s, then
returns to the deck. Use about 4 m/s of game-controlled movement along -Z.
Wheel orientations sample 26 revolutions per loop, equivalent to 3.948 m/s.
Fast small wheels may show the usual temporal aliasing at 30 fps.
ride: 2.4 s, loop. Both feet planted; subtle pelvis and spine balance sway.
Wheel orientations sample 52 turns per loop, the same nominal speed as push.
ollie: 1.2 s, one-shot. Crouch, nose pop, approximately 0.4 m deck lift and land.
kickflip: 1.4 s, one-shot. Pop, release/flick, one full longitudinal board flip,
catch and land. Maximum deck lift is 0.48 m.
jump_off_flee: 2.4 s, one-shot. Rider steps off to the left and begins running
in place, ending about 0.66 m left of the board. No accumulating forward travel.
die: 2.2 s, one-shot. Rider collapses onto the street beside the stationary board.
Configure push/ride to repeat, and clamp the other clips at their final frames.
Loop/fps flags are recorded in animation extras; glTF does not impose playback
repeat settings on engines.

ROOT MOTION OFF
There are no animation channels on skater_root. The board's horizontal X/Z
position stays fixed in all six clips. Tricks animate only its vertical lift
and rotation. Rider hip sway, jumps and local separation during fleeing/falling
are pose animation; they do not propel the game entity. Move the complete
imported scene/prefab from your controller. rider_mesh is a separate scene-root
skinned mesh, following glTF's skinning recommendation; keep it together with
the skeleton and board under your prefab. Refresh skinned bounds where needed.

PREVIEWS
Contact sheet, six-state animation sheet and individual PNG views are renders
of the delivered GLBs. Studio lighting and background are preview settings
and do not exist inside the files.

VALIDATION
Khronos glTF Validator: zero errors and zero warnings for all four files.
Binary checks cover triangle budgets, valid indices, finite geometry,
non-degenerate faces, normalized normals/tangents, skin weights, shared rig,
UVs, embedded texture sizes, board/wheel hierarchy, axes, exact clip names,
30 fps timestamps, loop seams and stationary board X/Z coordinates.
Rig compatibility is compared against the actual pedestrian GLB.
Loaded-file checks sample planted shoe contact at 60 Hz, between the 30 fps
animation keys. Maximum sampled planted sole-centroid error is
1.826 mm. Minimum rider surface Y in the ground-clearance samples is
-0.000000 m. Checks also cover backward pushing-foot speed, loop transform
closure, board lift, inverted kickflip, landings, fleeing, final fall pose,
wheel hierarchy and axle centres. See the three detailed validation reports.

SOURCES AND RIGHTS
Human anatomy, morphs, source weights, clothing, shoes, hair and skin surfaces
adapted from CC0 MakeHuman graphical assets, as in the pedestrian pack.
Skateboards, headphone geometry, motion solving, atlas processing and export
work were created for this delivery. See SOURCES.txt and the included asset
licence. The models are generic and contain no scanned real-person likenesses.

FILE INVENTORY
skater_01_man_teal_cap.glb / 17,732 triangles
skater_02_woman_rust_cap.glb / 19,738 triangles
skater_03_man_sand_headphones.glb / 16,766 triangles
skater_04_woman_plum.glb / 16,246 triangles
