# Handover: a scripted gameplay video

From: Claude Code session (2026-10-27) · To: Codex (or any coding agent) ·
Owner: Vilson

Read [AGENTS.md](../../AGENTS.md) first (setup, rules, ports, working next
to other agents). Work in your own git worktree; the owner may be playing
on port 24690 while you test on 24691.

## Goal

A 2-3 minute gameplay video of City Invaders that shows almost everything
the game can do, made from a **script**, not from the autoplay bot: the bot
decides by itself and sometimes gets stuck or idles; a script says exactly
what happens in each shot. The owner wants to use it to present the project.

## Recommended approach (agreed in the session)

**Phase 1 - staged scenes, the owner plays** (do this first):

- One command per scene that sets it up in the test or the owner's game:
  map, player position and view, weapon and items given, robots / mech /
  drones / swarm spawned in the right place, a dropship called, god mode,
  the AI Director off so nothing else interferes. The owner then plays the
  scene and records it (OBS), or a short scripted action runs in it.
- Put the scenes in data (e.g. `tools/devagent/scenes/*.json` or one
  `scenes.json`), run them with a DevAgent method such as `stage name=...`
  or a small CLI (`tools/devagent/stage.py <scene>`).
- Test the **Godot Movie Maker** on one scene: `godot --path godot
  --write-movie out.avi --fixed-fps 60 -- --devagent` renders every frame
  off real time, so the video has no hitches even on a slow machine, with
  the audio. Check the size/quality (`.avi` MJPEG or a PNG sequence) and
  whether the DevAgent still drives the game while it renders.

**Phase 2 - fully scripted shots** (if phase 1 works out):

- A "director" (`godot/scripts/demo.gd`) that plays a timeline of shots:
  each shot = setup (as phase 1) + timed actions.
- **Smooth camera**: `teleport` / `look_at` cut instantly; video needs
  eased moves between keyframes (position + look target over N seconds),
  plus a free "cinema" camera for fly-overs that is not the player's head.
- **Actions**, reusing the autoplay bot (`godot/scripts/autoplay.gd`):
  aim and fire at a target (`_face`, `_fight`), throw a grenade
  (`_grenades` / `player._throw_grenade`), get in and drive along the lanes
  (`_road_follow`, `_drive`, car-park `drive_out` routes), plus new ones:
  catch a drone with the laço and fly it (`player._lasso_target`,
  `player._fly_drone`), take and fire a mech's cannon (`canhao`), open a
  people container (`main.open_container`), open the tablet apps.
- Each shot short and independent, so a bad take is re-rendered alone.

## Shot list (a starting point; the owner can reorder)

1. Opening: the Usina do Gasômetro from above, flying down to the street.
2. Pick up the pistol, a Fruki and a pala (armour).
3. A dropship arrives and drops robots (`main.call_dropship(near, n)`);
   a firefight in a Centro street (the long straight one: road edge 11,
   x 95 -> -51, z ~277).
4. A Bergamota de Aço into a group; a Porongo EMP bringing drones down.
5. A swarm (`main._swarms`, variant `swarm` in `enemy.gd`).
6. A mech and its missile; then take the mech's cannon and use it.
7. Laço a drone, fly it, spot the relay antenna (red column).
8. A Coletor carrying a captive; open a people container, everyone runs out.
9. The armoured harvester driving over robots (its reel, `car.gd _reel_tick`).
10. The bus, the Acampamento Farroupilha (fire, musicians, flag), the Laçador.
11. The tablet: GPS route, Bah, the radio.
12. Closing: the map editor (F2), an aerial view of the Centro, the title.

The owner's screenshots of many of these places (with positions in the F1
messages) are in `docs/images/` once committed; positions are also easy to
read with `devagent.py get_state` while standing there.

## What exists (names to start from)

- DevAgent methods (`godot/scripts/dev_agent.gd`, `_m_*`): `start_solo`,
  `teleport`, `look_at`, `hold_keys`, `tap`, `arm`, `spawn_enemy`
  (variants `trooper`, `mech`, `drone`, `collector`, `swarm`),
  `spawn_pickup`, `kill_enemies`, `set_director`, `set_god`, `set_sun`,
  `design`, `screenshot`, `eval`, `autoplay`, `nav_probe`, `say`.
  See [docs/DEVAGENT.md](../DEVAGENT.md).
- `main.gd`: `call_dropship(near, n)`, `_spawn_pickup(kind, pos, respawns)`,
  `throw_grenade(kind, origin, dir)`, `open_container(path)`,
  `_park_war_machine()`, `_containers`, `road_graph` (streets for driving).
- `enemy.gd` `VARIANTS`; `dropship.gd`; `swarm.gd`; `people_container.gd`;
  `player.gd` (`give`, `_switch`, `_throw_grenade`, `_use_vehicle`,
  `_lasso_target`, `_fly_drone`); `tablet.gd`.
- Entity definitions (items, weapons): `godot/assets/**/**.def.json`,
  [docs/ENTITIES.md](../ENTITIES.md).

## Pitfalls seen in this project

- DevAgent `eval` is a Godot `Expression`: no assignments, no lambdas, no
  engine singletons (`NavigationServer3D` is not reachable - add a method,
  as `nav_probe` did); `Vector3.ZERO` does not parse, write `Vector3(0,0,0)`;
  `obj.set("prop", value)` works where `obj.prop = value` doesn't.
- GDScript warnings are errors: type variables inferred from a Variant.
- `start_solo` marks the round as script-driven (`main.driven`): no
  developer-keys panel, mouse left free. Starting it with `eval
  main._solo('<map>')` instead behaves like a player's round.
- Robots spawned with `spawn_enemy` land with a dust burst for a few
  seconds - wait ~8 s before a shot.
- A covered or minimised game window stops drawing on macOS: keep the test
  window visible when taking screenshots or measuring.
- Never start rounds, teleport or quit the owner's game (port 24690)
  unless he asks; test on 24691 (`DEVAGENT_PORT=24691`).

## Small bug noticed on the way (optional)

The tablet's home screen header says "Centro Histórico · Porto Alegre"
while playing the Gasômetro map: the place name looks fixed instead of
coming from the current map (`tablet.gd` / the tablet's UI).

## Done means

- Phase 1: a handful of scenes (3-4 to start) that the owner can call and
  play, and a note on how the Movie Maker test went (a sample file).
- Docs updated in the same commits: [docs/DEVAGENT.md](../DEVAGENT.md)
  (the new methods / CLI), a short "Making a gameplay video" section.
- Report what was tested and how, and what was not.


## Phase-one implementation (Codex, 2026-10-27)

Implemented on branch `gameplay-video`, in an isolated git worktree.
No owner map edits were copied, reverted or committed. See the new "Making a
gameplay video" section in DEVAGENT.md for commands and scope.

- Four JSON presets and explicit stage/take/status/clear/drop RPCs.
- `usina_walk` has a simulation-clock 12 s take; the other three are manual.
- Opt-in analog movement uses the real player collision/footstep path, quintic
  acceleration/braking and shortest-arc eased camera turns. Cancellation restores
  ordinary controls. No in-take teleports.
- Movie Maker tested: 1920x1080, 60 fps; final trimmed MP4 has exactly 720 decoded
  frames, 12.0 s and audio. Master mute and Retina viewport mismatch were caught
  and fixed using the `movie` feature tag and matching capture/window sizes.
- DevAgent remained reachable during offline capture. AVI includes a loading
  prefix; trim using the logged start frame. AVI could not be read by macOS
  avconvert here; the sample was encoded/muxed with native AVFoundation instead.
- Native movement test and three Python scene/safety tests pass. All four setups
  were checked in the rendered game, with screenshots and no runtime errors.
- Movie recording had a pre-stage Metal fence timeout during map loading and
  existing exit resource warnings. The selected 720-frame take was verified
  individually; no consecutive identical encoded input frames or position jumps.

Artifacts are in the Codex workspace `outputs/gameplay_video/`: final
`usina_preview.mp4`, raw AVI, take logs, encoded-frame QA and validation notes.
This is a rehearsal sample, **not** the complete 2–3 minute presentation.
Remaining: scripted combat/interaction/flight shots, a free flyover camera,
precise dropship choreography, full montage/titles and the optional tablet place
name fix. The dropship helper is exposed, but its complete arrival/unloading was
not included in the tested sample. World/traffic RNG is still live.


## Pickup continuation and pacing revision (2026-10-28)

The owner requested real Fruki/pala collection, then rejected the first slow
32 s rehearsal and explicitly required Fruki to increase movement speed.
The final `usina_walk` preset is **14 s**. It uses normal 5 m/s movement and
retains the real 1.4x adrenaline multiplier (7 m/s after Fruki); no compensation
cancels the booster. Starts/braking stay eased, and looking remains continuous.
The items are moved ahead of the initial walking path so the camera can show
them before collecting them. Normal pickup collision grants them; stage code
only observes collection for telemetry. Setup resets armour and adrenaline to
make repeated preparations eligible for both items.

Final rendered Movie Maker run: Fruki collected at 7.8667 s (12 s adrenaline),
pala at 10.8667 s (armour 100), `missing_pickups=[]`. Horizontal telemetry peaks
were 5.003 m/s before and 7.014 m/s after Fruki. 840 take samples, maximum 3D
step 0.11951 m, no consecutive identical encoded input frames. Native movement,
world-space approach direction, real booster speed, restored controls and four
Python scene/safety tests passed. Existing five-resource exit warning remains;
no runtime script error occurred in the final capture.

Final movie and QA: Codex workspace `outputs/gameplay_video/pickups_fast/`,
`usina_fruki_pala.mp4` (1080p, 60 fps, 14 s, audio), raw AVI, per-tick JSON,
frame images and validation logs. The `pickups/` folder is the superseded slow
draft. Rendering can run slower than real time in the window; the exported
fixed-60-fps movie plays at simulation speed. No world movement tuning changed.


## Full presentation continuation (2026-10-28)

The owner clarified that the deliverable must be three minutes, not a sample.
The edit is now `tools/video/presentation.json`: 12 independently reproducible
shots totalling 180 s (10,800 frames at 60 fps). The dev-only action director
covers real trigger combat, grenades/swarm, mech cannon, laço/drone flight and
rays, container rescue, combine controls/grain fire, camp, Laçador, tablet apps,
and free-camera opening/closing. All tests use port 24691 in the isolated
`gameplay-video` worktree. The original 14 s pickup scene retains 5/7 m/s pacing.

Normal rendered rehearsals checked every setup and screenshots. A failed combine
entry exposed overlap between player and body: its setup now parks 7 m away,
within the normal 10 m entry range, and a repeat verified real vehicle ownership
and movement. A four-person container rescue was verified; final choreography
also walks into normal interaction range before invoking release. No damage,
health or speed tuning was changed. Cinematic motion is explicitly a free camera,
not a claim of player flight. Staged enemy spawns/equipment are preparation.

Use the complete render command in DEVAGENT.md. It compiles a native macOS media
helper, renders short shots, indexes the raw AVI, encodes H.264/AAC with chapter
captions, audits every decoded clip, and joins only after all 12 succeed. It
retains scene JSON/logs/audits/preview frames; it removes only its own raw/silent
intermediates after successful clip QA to bound disk use. No third-party media,
models or music were downloaded. Existing game sounds/music are recorded.


Final refinement notes: the first drone take was rejected because it launched a
spare after missing the lasso. Timed actions now execute after the current tick's
aim, the drone is aimed at its real centre, and the shot starts with zero spares.
The corrected take records `lasso=drone`, `drone=flying`, one captured drone and
150 points. Assembly now rejects failed lasso/launch/vehicle/rescue outcomes.
The combine's long straight drive was also rejected: the old handover's road
index/coordinates do not describe a safe continuous corridor in this map build.
The final shot uses the verified clear initial stretch, brakes before obstacles,
then shows normal grain fire and a smoothly orbited chase view. Nearby AI traffic
is cleared only for this rehearsal. World collisions are never disabled; this
is not a fix or benchmark for general autonomous traffic.


Delivered file: Codex workspace
`outputs/gameplay_video/full_3min/city_invaders_gameplay_3min.mp4` (about 312 MiB).
Final native decode audit: **180.000 s, 10,800 frames, 1920x1080, 60 fps, one audio
track**. The joined file was sampled at drone flight, combine motion and the
closing title; all 12 source clips were separately decoded and previewed. The
final output folder includes chapters, LEIA-ME, per-shot logs, take JSON, capture
QA, decoded previews and FINAL_QA.json. Five Python tests and the native 12 s
movement/cancellation regression passed. Existing macOS Metal load-fence and
Godot exit-resource warnings are retained; no final take had a runtime script
error. This is a staged presentation with god mode and a disabled Director,
using the game build in this worktree, not a performance benchmark or an
uninterrupted human playthrough. No changes were merged into the owner's tree.


## Encounter continuity revision (2026-10-28)

The owner liked the full video but rejected stationary shooting with enemies
materialising in front of the player. Revised five encounters: battle, grenades,
mech, drone and rescue. All enemies are prepared before recording and settled for
8 s; no timeline spawn/dropship actions remain. The stage temporarily withholds
actor physics/robot group membership during preparation, then restores normal AI
at take start. The player walks into the existing encounters. Battle, grenades
and mech start at separate locations; measured approaches cover about 41.8 m,
9.7 m and 10.8 m respectively. Fruki pacing and the other approved clips remain.

Assembly adds 0.3 s fades at scene boundaries and short audio ramps within the
existing shot durations. A two-clip native test decoded 1,440 frames at 60 fps
for 24 s with audio; the exact 10 s boundary was RGB (0,0,0). Exact-time preview
requests avoid mistaking a nearby decoded keyframe for the actual black frame.
Outputs use `outputs/gameplay_video/full_3min_v2/`; original `full_3min/` remains.


Revised delivery audit: `full_3min_v2/city_invaders_gameplay_3min.mp4`, about
342 MiB, exactly 180 s and 10,800 decoded frames at 1920x1080/60 fps with one audio
track. Encounter telemetry records 5/3/3/1/1 prepared groups and zero spawn events
in all five refilmed shots. Final cut at 46 s was checked at an exact timestamp
and is near-black; the 48 s frame shows the new street encounter. The prior
full video is untouched. Five Python contract/safety tests and the native movement
regression pass; final take parsing/runtime checks found no GDScript errors.

## Encounter refinement (2026-10-28, v3)

The user approved v2 and requested natural circuit collection after kills,
flying above the Usina to reach the far-side robot, and grenade throws closer
to enemies. Only battle, grenade and drone shots are replaced; all twelve shot
durations and the total 180 seconds remain unchanged, with v2 preserved.

- Battle: fight first, then use a world-space pickup approach to circuits that
  the normal robot death handler actually dropped. Freshly created pickups are
  observed after their own grant handler. Carried parts are logged.
- Grenades: guide the view before each throw using the existing 11 m/s speed
  and upward impulse, aiming short of approaching feet to allow for bounce.
  Physics, fuse, damage and EMP rules are unchanged. The last observed distance
  to a living robot before each burst is recorded (one physics tick precision).
- Drone: launch the actually captured drone, climb vertically using ascent/run
  inputs, advance to a point above the northern side of the roof, then hover,
  aim and fire normally at an already present far-side trooper. Position and
  target health samples prove progress and hits; collisions remain enabled.

Headless rehearsal collected four circuits; grenade burst distances were
3.93 m (Bergamota) and 1.41 m (Porongo). Drone altitude reached 58.78 m and
crossed from z=96.76 to z=-19.23; its fire reduced the far-side target's health.
These rehearsals are interaction checks, not performance measurements.

Another agent occupied test port 24691 during the first capture attempt and
the window exited before the take. The recorder now supports `--port`, rejects
24690, and v3 recording uses 24693. Do not stop the other agent's game.
Output: `outputs/gameplay_video/full_3min_v3/` alongside preserved v1/v2.

Final v3 delivery: `full_3min_v3/city_invaders_gameplay_3min.mp4`, 343 MiB,
1920×1080, exactly 180 s / 10,800 frames at 60 fps, one audio track. The final
recorded battle collects four circuits. With moving-target lead, recorded
burst distances are 5.80 m / 3.62 m (inside the 6 m blast / 9 m EMP radii).
The drone crosses above the roof at 58.78 m altitude and damages the far-side
trooper (minimum observed health 8). All three new clips have zero identical
adjacent source frames, audible PCM, and no script/parse errors. Six scene-data
and owner-port tests pass; the new renderer port guard rejects 24690 before
starting anything. Both the prior grenade attempt and all v1/v2 videos remain.
