PORTO ALEGRE EXPANSION — 18 GLB ASSETS

DELIVERY STATUS
These are actual importable glTF 2.0 binaries with embedded PBR maps, rigs and named clips. They are a procedural first-pass asset pack. The hard-surface forms, pigeon feather planes, tactical equipment, hand grips and animation acting are visibly simplified. This delivery does not achieve the requested photoreal art standard. Preview PNGs show the exported models, not concept illustrations.

CONTENTS
3 rock-pigeon coats; 4 independent street-vendor props; 4 independently placeable vendors; a decorative open wooden tram and tracks; URB-D3 drone; URB-H9 heavy mech; 4 officers (2 women, 2 men).

IMPORT
Metres; +Y up; front -Z. Assets carry no lights, cameras, environment or ground plane. The tram's short rails and sleepers are intentional geometry. Keep scene-level asset_root and skinned_character together when importing, because skinned mesh and skeleton are sibling scene branches. Preserve rig_scale. Do not apply an additional 100x conversion.

Human rigs share exactly the pedestrian pack's 52 mixamorig: bone names, hierarchy and canonical rest translations. Their imported default pose is a role pose; it is not a replacement bind pose. Use the inverse bind matrices for retargeting. The heavy mech uses the original URB-07 robot rig at 2x scale, not the pedestrian rest rig.

All clips are sampled at 30 fps. Loop intent is stored in animation.extras.loop; glTF itself has no automatic playback-loop switch. Enable looping in your game for clips marked true. Human locomotion is in place. The mech walk is designed for approximately 1.5 m/s game travel; foot contacts use approximate IK and are not a full locomotion-controller solution. Death/fall clips change body height and pose; they do not create gameplay ragdolls or collision bodies.

Pigeons: 1,628 triangles each, one skinned mesh and one 512x512 base-colour image, scalar nonmetallic roughness. Other assets: a single 2048 atlas UV layout with base colour, normal and packed metallic/roughness maps, and an emissive map where used. Packed MR: G=roughness, B=metallic. Transparent cart glass uses a second material sharing the atlas. No external image dependencies.

Pigeon takeoff rises about 0.6 m within the entity; fly holds that altitude; land returns. Do not add the same altitude twice in a gameplay flight controller. The animation is not a physically simulated flight or gait system. Drone origin is its hover centre; crash assumes terrain roughly 0.85 m beneath that origin. Position the drone accordingly, or adapt that clip for your terrain. Drone rotor nodes spin about local Y; turret quaternion tracks combine local yaw and pitch. Human weapons remain attached during falls.

PLACEMENT AND NODES
Props and vendors are separate so they can be arranged at counters. Kiosk shutter is its own node with pivot at the top. Tram wheel_fl/fr/rl/rr have local X wheel axes; trolley_pole is separate. Drone rotor_1..4 and turret are separate. Each officer has a separate weapon node parented to mixamorig:RightHand; magazine and flash are child nodes. No real insignia or manufacturer logos were included. Plain BRIGADA MILITAR lettering is present on the generic vests. CENTRO is the tram's fictional destination display.

VALIDATION
validation_khronos.json: official Khronos validator reports zero errors and zero warnings for every file.
validation_structure.json: binary format, triangle budgets, finite vertices, unit normals, UV bounds, image dimensions, skin weight sums/joint ranges, exact clip names and 30-fps sampling.
validation_shared_rig.json: eight humans match pedestrian names/hierarchy/rest translations exactly.
validation_playback.json: actual Three.js loading, sampled animated bounds, finite playback and endpoint transform differences. Non-looping clip endpoints are expected to differ. These checks do not certify artistic realism, game-engine-specific performance, collision geometry, or perfect anatomy/contact in every interpolated frame.

TRIANGLES
pigeon_grey.glb: 1,628
pigeon_darker.glb: 1,628
pigeon_white_spotted.glb: 1,628
prop_newspaper_kiosk.glb: 7,904
prop_popcorn_cart.glb: 8,034
prop_churros_cart.glb: 6,206
prop_mate_thermos_stall.glb: 5,462
historic_open_tram_centro.glb: 39,344
vendor_kiosk_woman.glb: 11,020
vendor_popcorn_man.glb: 12,188
vendor_churros_woman.glb: 13,874
vendor_mate_man.glb: 9,884
police_woman_cap.glb: 17,822
police_man_helmet.glb: 16,146
police_woman_helmet.glb: 16,476
police_man_cap.glb: 13,530
URB_D3_surveillance_drone.glb: 8,670
URB_H9_heavy_assault_mech.glb: 47,482
