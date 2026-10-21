PORTO ALEGRE GENERIC TRAFFIC FLEET

Contents
22 self-contained glTF 2.0 binary vehicle files: 14 primary designs and two
additional paint colours for designs 01, 03, 04 and 06. The taxi is red,
following the user's explicit selection. Individual preview PNGs and a labelled
contact sheet show the actual exported geometry rendered with studio lighting.

VISUAL LIMITATION
These are original procedurally modelled, simplified generic vehicles. Their
shapes and surface detail do not achieve the requested photorealistic production
finish or close visual fidelity to each named real-world reference. Format and
geometry checks below do not certify artistic realism or engine performance.
Inspect the included actual renders before deciding suitability for your game.

Technical delivery
- glTF 2.0 binary, +Y up, front -Z, metres, real-world vehicle dimensions.
- Origin: centre of visible X/Z bounds, road contact at Y=0.
- 25,636–29,196 triangles per vehicle, counted from stored indexed triangles.
- Four embedded 2048 x 2048 PNG maps in each file: base colour, tangent-space
  normal, packed metallic/roughness (G=roughness, B=metallic), emissive.
  Map colour spaces: base colour and emissive sRGB; normal and MR linear.
- 11 PBR material definitions for paint, trim, chrome, rubber, lamps, interior,
  plate, glass, sign, livery and secondary paint. Atlas regions are shared by
  surfaces of the corresponding material. Paint uses KHR_materials_clearcoat;
  ordinary glTF metallic/roughness provides a fallback.
- Separate mesh nodes wheel_fl, wheel_fr, wheel_rl, wheel_rr, with local axle
  pivots and local X roll axes. Vehicle-left is negative X when facing -Z.
  Steer front wheels around their local Y axes, roll around local X.
- Separate lights_front and lights_rear mesh nodes, using an emissive material.
  Roof beacons are in roof_equipment. No actual light objects are embedded.
- Static, no rig/animation. Simple cabin seat, dashboard and steering silhouettes.
- No cameras, lights, ground plane, background or external asset dependencies.
- Generic geometric emblem, fictional registration plates and service text;
  no real manufacturer logos, brand names, official insignia or agency seals.
- No collision meshes, LODs, suspension, damage states or vehicle physics are
  included; these are not specified by the requested glTF asset format.

Validation
Every file passes the Khronos glTF Validator with zero errors and zero warnings.
Independent binary inspection verifies triangle counts, nondegenerate faces,
finite positions, normalized normals and tangent frames, UV range, embedded
texture dimensions, actual ground-centre bounds, wheel pivots, and emissive light
materials. Colour variants have identical geometry checksums and distinct paint.
The attached machine-readable reports record each check and actual dimensions.
Front, side and rear render inspection was performed using Three.js.
Validation concerns file structure and stated geometric properties; it does not
replace testing inside your target game engine or establish photorealism.

Import
Load any .glb using a glTF 2.0 importer at scale 1.0. Preserve mesh node names.
If the target engine's forward direction differs, apply a parent rotation.
Use a physically based renderer with environment lighting and sRGB colour maps.
The preview lighting and background are not part of the exported assets.

File inventory
car_01_small_hatch_silver.glb  |  26,148 triangles
car_01_small_hatch_midnight_blue.glb  |  26,148 triangles
car_01_small_hatch_cream.glb  |  26,148 triangles
car_02_boxy_hatch_cherry_red.glb  |  25,716 triangles
car_03_modern_hatch_pearl_white.glb  |  26,364 triangles
car_03_modern_hatch_ruby_red.glb  |  26,364 triangles
car_03_modern_hatch_steel_grey.glb  |  26,364 triangles
car_04_compact_sedan_graphite.glb  |  26,364 triangles
car_04_compact_sedan_champagne.glb  |  26,364 triangles
car_04_compact_sedan_burgundy.glb  |  26,364 triangles
car_05_midsize_sedan_dark_blue.glb  |  27,228 triangles
car_06_compact_crossover_forest_green.glb  |  27,340 triangles
car_06_compact_crossover_obsidian.glb  |  27,340 triangles
car_06_compact_crossover_burnt_orange.glb  |  27,340 triangles
car_07_midsize_suv_sand_beige.glb  |  27,340 triangles
car_08_small_pickup_bronze.glb  |  28,092 triangles
car_09_double_cab_pickup_charcoal_black.glb  |  29,196 triangles
car_10_city_taxi_iberian_red.glb  |  26,988 triangles
car_11_police_suv_blue_white.glb  |  28,048 triangles
car_12_ambulance_van_ivory_red.glb  |  29,000 triangles
car_13_delivery_van_glacier_blue.glb  |  26,856 triangles
car_14_classic_van_cream_teal.glb  |  25,636 triangles
