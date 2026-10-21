URB-07 COMBAT ROBOT

Main file: URB-07_Combat_Robot.glb
Self-contained glTF 2.0 binary; all four PNG texture maps are embedded.

MODEL
- 2.000 m tall in the A-pose; metres, Y-up, facing -Z.
- Foot soles at Y=0; scene/mesh origin is (0,0,0), centered between the feet.
- Right-side equipment is on +X: integrated green-energy forearm rifle.
- One skinned mesh, one primitive, one opaque PBR material.
- 29,692 triangles, 24,516 exported vertices (including UV/normal seams).
- 52-bone humanoid hierarchy with mixamorig: names, including fingers/toes.
- Hard armor is rigidly weighted to bones, preserving mechanical panels.
- No camera, light, ground plane, background, or external dependency in GLB.

MATERIAL
2048 x 2048 maps: basecolor, tangent-space normal, metallic_roughness, emissive.
Metallic/roughness map uses standard glTF packing: roughness G, metallic B.
The red paint, exposed steel, rubber, hazard markings, stencil, and green
emission share a padded atlas. Emission is baked into the material, with no
light objects or postprocessing requirement. Bloom is an engine preference.

ANIMATION
All clips are sampled at 30 fps and embedded in the same GLB.
idle   3.0 s   loop
walk   1.0 s   loop, in place
run    0.6 s   loop, in place
shoot  1.4 s   one-shot, three recoil pulses
hit    0.8 s   one-shot
 death 2.0 s   one-shot, backward collapse; hold the final pose

Enable repeat playback for idle/walk/run in your engine. glTF does not define
a universal runtime loop flag; the endpoints match and extras.loop records
the intended behavior. Use clamp/hold for death. Locomotion is in place;
movement speed is controlled by the game. Firing effects and projectiles
are engine-side behavior.

The skeleton uses Mixamo-compatible humanoid names/hierarchy, with a
mechanical A-pose. Engine-specific retargeting may require bone mapping and
rest-pose calibration; it has not been uploaded to the Mixamo service.

VALIDATION
The final GLB was loaded and rendered using the Three.js GLTFLoader.
Khronos glTF Validator: 0 errors, 0 warnings, 0 infos, 0 hints.
Independent checks read the delivered binary and verify triangle budget,
geometry winding, nondegenerate triangles, normal/tangent normalization,
UV ranges, embedded texture dimensions, skin weights, joint indices,
inverse bind transforms, 30-fps clip samples, loop endpoints and every
sampled pose's floor contact and rigid armor preservation.
Floor contact tolerance is 0.00001 m to allow floating-point roundoff.
See asset-validation.json and gltf-validation.json for the detailed results.

URB-07_preview.png shows the actual asset in a studio preview scene.
The preview lighting and background are not part of the GLB.
