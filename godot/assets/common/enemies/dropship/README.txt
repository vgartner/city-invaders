URB-07 HEAVY LIFT ROBOT DROPSHIP

Original hard-surface model and PBR textures created for this delivery.
Dark gunmetal pressure hull, oxidized red armour, chipped paint, panel seams,
rivets, hazard stripes, soot-darkened nozzles, cooling fins and exposed braces.
Four independently addressable VTOL pods. Cargo bay is physically open, with
folded hatch doors, recessed interior and suspended green emitter ring.

DELIVERY
URB07_Heavy_Lift_Dropship.glb
Front, side, underside and front three-quarter preview PNGs (1920 x 1440).
Four-view preview sheet, asset manifest and two machine-readable validations.

GEOMETRY AND COORDINATES
66,648 indexed triangles; 8 mesh nodes; 1 shared PBR material.
+Y up, nose -Z, metres; root and pressure-hull centre at (0,0,0).
Overall visible dimensions: X=20.000 m, Y=5.370 m, Z=18.236 m.
Pressure hull itself is 18 m long; sensors and exhaust trim extend slightly.
The origin is the pressure-hull centre, not the centre of appendage bounds.
No animations, skin, cameras, light objects, ground or background in the GLB.

NAMED NODES / ENGINE PIVOTS
engine_fl  (-6.35, 0.25, -4.65)
engine_fr  ( 6.35, 0.25, -4.65)
engine_rl  (-6.35, 0.25,  4.65)
engine_rr  ( 6.35, 0.25,  4.65)
All engine origins are at their inboard bearing mounts. Their local axes match
the ship's axes in the exported neutral hover pose. Rotate a pod node about
local X to vector it; all pod armour, nozzle and turbine geometry follows.
Front and rear refer to -Z and +Z; left is negative X when looking forward.

bay_emitter  (0, -1.5, 0)
The annular assembly's reference centre is exactly at this coordinate. Its
surface tubes and lower glowing trace extend around and below the centre.
nav_light_l  (-9.91, 0.45, 5.30)
nav_light_r  ( 9.91, 0.45, 5.30)
The red navigation lenses are separate mesh nodes at the wing tips.
Other nodes: dropship_root, hull.

PBR TEXTURES
Exactly four embedded PNG images, each 2048 x 2048:
basecolour (sRGB), normal (linear tangent space), metallic_roughness
(linear, G=roughness, B=metallic, R=255), emissive (sRGB).
A shared 4 x 4 material atlas supplies metal, armour, hazards, soot, markings,
nozzle emission, green ring and red sensors. Normal tangents are embedded.
Material uses glTF metallic/roughness and KHR_materials_emissive_strength (3).
The base emissive texture/factor remains available in engines without that
extension. Preview bloom and studio lighting are renderer settings, not scene
objects or embedded animation. Enable engine bloom for a similar visible halo.

VALIDATION
Khronos glTF Validator: zero errors, zero warnings, zero informational issues.
Independent binary inspection: triangle budget, real-world size, origin at
pressure hull centre, exact emitter translation, named nodes, mount pivots,
rigid local-X tilt, face winding, no degenerate faces, normalized normals,
orthogonal tangent frames, UV range, embedded image dimensions and no external
resources. Upward rays through three cargo aperture locations reach the
recessed ceiling, confirming there is no opaque false floor under the ring.
Actual GLB was loaded in Three.js and rendered from front, side, underside and
three-quarter views; pod tilt was also rendered and inspected.
