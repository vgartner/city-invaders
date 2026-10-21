PORTO ALEGRE / FOUR BRAZILIAN STREET DOGS

CONTENTS AND VISUAL FINISH
Four original, procedurally modelled medium-sized mutts: caramel, black,
white with dark spots and brindle. Short coats use directional fur shading
and alpha-masked guard hairs. Body shapes and ear shapes vary slightly.
The meshes use manually shaped anatomical volumes, smoothed into a continuous
body, neck, head and limbs, with a separate moving lower jaw in the same skin.
These are crowd assets for medium-distance city scenes. The included renders
show the actual geometry, coats and baked motion finish.

FORMAT AND SCALE
Self-contained glTF 2.0 binary, +Y up, facing/travel direction -Z, metres.
Origin at ground between the four paws. One combined skinned mesh, one
primitive and one material per GLB, including eyes, mouth, claws and fur.
9,800–9,801 triangles per complete dog. Approximate standing withers heights
are 0.57–0.61 m; stature wrappers vary from 0.88 to 0.94 around the common rig.
No embedded light objects, cameras, ground geometry or background.

PBR / FUR ATLAS
One 2048 x 2048 UV atlas layout, with three embedded PNG maps: base colour
(sRGB RGBA), tangent normal (linear RGB), metallic/roughness (linear RGB,
G=roughness, B=metallic). Fur is non-metallic; the nose and eyes have lower
roughness than the coat. Alpha MASK, cutoff 0.40, double-sided surfaces.
155 short guard-hair cards (310 triangles, included in the total) soften the
body edge. Their opaque roots fade to narrow transparent tips in the same
base-colour atlas. There are no external textures or texture dependencies.

QUADRUPED RIG
33 joints, shared names/hierarchy and canonical inverse binds across all coats.
root, pelvis, spine, chest, neck, head, jaw;
tail_1 through tail_4; ear_l / ear_r;
front_upper / lower / carpus / paw / toes for l and r;
hind_thigh / shin / hock / paw / toes for l and r.
Digitigrade legs have separate carpal/hock and paw segments. The fore elbows
bend backward and hind knees forward. Jaw, ears and tail use dedicated joints.
Four normalized skin weights maximum per vertex. Uniform dog_stature scale
sets each animal's size. Default visible pose is idle at t=0. Recover the
canonical rest pose from inverse bind data. Full rig definition is included.

ANIMATIONS / 30 FPS / IN PLACE
idle: 3.0 s, seamless loop. Air sniffing, slight breathing, ear movement and
segmented tail wagging.
walk: 1.2 s, seamless loop, two 0.6 s gait cycles. Four-beat walk with planted
paws sweeping backward relative to the body at approximately 1.2 m/s. Move the
game entity along -Z at that speed to match the stance.
trot: 1.0 s, seamless loop, two 0.5 s cycles. Diagonal paw pairs, nominal 2.2 m/s.
run: 1.0 s, seamless loop, three gallop cycles. Fore and hind pairs are offset,
with spine flex and raised swing paws. Nominal movement speed 6 m/s along -Z. Its 30 fps keys use cubic
interpolation to preserve fast paw contact between samples.
bark: 1.0 s, one-shot. Head lifts and jaw opens, exposing tongue and teeth,
then returns to a closed muzzle. This is a visual clip; no audio is embedded.
sit: 1.8 s, one-shot transition into a held seated pose. Haunches lower, hind
legs fold and forepaws stay planted. Clamp at the final frame while sitting.
die: 2.0 s, one-shot. Limbs release, body rolls onto its side and settles.
Preserve the run clip's cubic interpolation on import. If an engine converts
curves to linear keys, resample at 60 fps or higher to retain fast paw contact.
Configure idle/walk/trot/run to repeat. Clamp bark/sit/die at their last frames.
Loop/fps flags are stored in animation extras; glTF does not force playback
repeat settings on engines.
The entity root stays at the ground origin in every clip. Pelvis bob, spinal
flex and small local offsets while sitting/falling are pose animation; no
forward travel is baked. Move the complete imported scene/prefab from your
controller. Keep the scene-root skinned mesh with the skeleton wrapper.

PREVIEWS
Individual front/side, gait, bark, seated and fallen renders, plus contact and
animation-pose sheets. The studio background and lighting exist only in the
preview renderer and are absent from the GLBs.

VALIDATION
All four: Khronos glTF Validator, zero errors and zero warnings.
Binary checks: one skinned mesh/material, triangle budget, index ranges,
non-degenerate geometry, finite values, normalized normals/tangents/weights,
shared rig/inverse binds, 2048 embedded PBR maps, alpha fur, seven exact clip
names, 30 fps timestamps, seamless loop endpoints and stationary entity root.
Loaded-file checks sample planted paw vertices at 60 Hz between the 30 fps
keys, compare paw sweep with walking/running speed, check loop transforms,
root position, jaw opening, sitting, final fall orientation and sampled mesh
ground clearance. Maximum planted-paw centroid error: 4.846 mm.
Minimum sampled surface Y: -0.004736 m. See the detailed JSON reports.

SOURCES
Meshes, coat textures, fur cards, rig and baked motion are original to this
pack. No third-party animal mesh, photograph or texture is embedded.

FILE INVENTORY
dog_caramelo.glb / 9,800 triangles
dog_black.glb / 9,801 triangles
dog_white_spotted.glb / 9,800 triangles
dog_brindle.glb / 9,801 triangles
