URBAN SHOOTER EQUIPMENT PACK

DELIVERABLES
AX-07_Rifle_Viewmodel.glb          21,104 triangles, 14,863 vertices
HP-08_Pistol_Viewmodel.glb        17,760 triangles, 12,075 vertices
Emergency_Medical_Kit.glb          3,584 triangles,  2,968 vertices
Military_Ammunition_Crate.glb      4,560 triangles,  4,320 vertices

Each GLB is self-contained: one mesh, one primitive, one opaque PBR material.
Four embedded PNG maps: basecolor, tangent-space normal, metallic_roughness,
emissive. Weapon maps are 2048 x 2048; pickup maps are 1024 x 1024.
Roughness is in G and metallic in B, following standard glTF packing.
The padded texture atlas deliberately reuses regions for repeated surfaces.
Preserve the supplied linear texture sampling to avoid emissive atlas bleed
on very thin details. Normal maps are OpenGL/glTF tangent-space maps.

COORDINATES AND SCALE
All assets use metres and Y-up. No lights, cameras, ground, or background
geometry are embedded. Preview lighting/background exist only in the renders.

Viewmodel roots are at (0,0,0), the intended camera origin. Both weapons point
along -Z. The Weapon bone's bind position is (+0.25,-0.22,-0.45) m, placing the
weapon to the right and below the camera. Attach the scene root to the game
camera with an identity transform; keep its scale at 1. The dedicated
first_person previews use a 100-degree vertical viewmodel field of view so
both hands are visible. Choose the game's viewmodel FOV as desired; narrower
FOVs crop more of the arms and stock. Beauty previews show the whole assembly.

Pickups have bottom-centre origins, including external hardware in the bounds:
Medical kit: width 0.50 m, height 0.35 m, depth 0.25 m.
Ammo crate:  width 0.45 m, height 0.30 m, depth 0.28 m.
Both are static meshes with no skeleton or animation.

VIEWMODEL RIGS
One combined 11-bone skeleton per weapon:
ViewRoot, Weapon, Magazine, SpareMagazine, Bolt,
LeftUpperArm, LeftForeArm, LeftHand,
RightUpperArm, RightForeArm, RightHand.
Gloved hands have modelled curled fingers; finger shapes follow the Hand
bones. Sleeves and arms are part of the skinned mesh. Weapon parts use rigid
weights, keeping the metal surfaces intact. No humanoid character body is
included or required.

ANIMATIONS (60 FPS)
                 AX-07 rifle       HP-08 pistol
idle             2.00 s loop       2.00 s loop
fire             0.10 s            0.15 s
reload           2.00 s            1.20 s
draw             0.40 s            0.40 s

Enable repeat playback for idle in the game engine; glTF has no universal
runtime repeat flag. extras.loop records the intended behavior. The idle
endpoints match. Other clips are one-shots. Reload removes the old magazine,
hides it below view, raises the replacement, seats it, and returns the
support hand. Scale animation switches magazine visibility. Preserve those
scale channels on import. At the end of reload the replacement is visible;
returning to idle restores the original magazine in the same socket.
The rifle's green ammo counter is a fixed illustrative '048' texture, not
scripted game logic. The pistol has green front and rear sight beads.
Sparks, muzzle flashes, projectiles, audio, camera shake, pickup effects and
collision shapes are game-engine responsibilities and are not embedded.

VALIDATION
All four delivered binaries pass Khronos glTF Validator with zero errors,
zero warnings, zero infos and zero hints. Equipment_Validation.json records
file hashes, triangle counts, texture dimensions, clip timings and checks.
Independent binary checks cover index ranges, finite geometry, degenerates,
triangle winding, normals/tangents, UVs, texture embedding, material counts,
normalized skin weights, valid joints, inverse bind transforms, every sampled
animation pose, idle loop seams, and magazine replacement at reload completion.
The final files were rendered through Three.js GLTFLoader for visual review.
