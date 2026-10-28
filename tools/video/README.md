# Gameplay video production

Read this guide before recording or revising a City Invaders gameplay video.
These are reusable production rules from the approved three-minute presentation,
not requirements to repeat its exact map, actors or chapter order.

## Movement and pacing

- Make play look like a person controlling the game: continuous movement,
  gradual starts/stops, smooth turns and deliberate aiming. Use ordinary input
  and collision physics, driven by simulation time. Do not move the player by
  repeated teleports or a wall-clock sequence of remote position updates.
- Keep a believable playing speed. Smooth movement must not become slow motion.
  Preserve gameplay bonuses: an adrenaline pickup must visibly increase speed;
  do not reduce scripted input to cancel its effect.
- Move through different places and approach encounters. Avoid a stationary
  shooting gallery with successive robots, mechs and swarms appearing in view.
- Prepare actors, equipment and locations before a take. Let loading and spawn
  effects settle outside the recorded frames, then release normal AI for play.
- Use short fades between separate scenes. Repositioning and staging belong
  outside the visible take; do not show a teleport between locations. Reserve
  free-camera moves for establishing/location shots.

## Show complete, real interactions

- After combat, approach and collect parts dropped by defeated robots. Show
  the item and normal pickup feedback; verify the inventory actually changed.
  Do not substitute a grant command or a pre-placed prop for a natural drop.
- When showcasing a consumable, rescue, vehicle or gadget, include the result,
  not only the button press. Examples: the speed boost, freed civilians,
  successful vehicle entry, or capture and subsequent flight of the same drone.
- Plan drone routes with building and roof clearance. Ascend before advancing
  into an obstacle, cross above it, then aim at the target on the far side.
  Respect normal collision, control range and battery limits. Verify progress,
  line of sight, visible fire and actual hits; repeated shots at a wall do not
  demonstrate combat.
- Aim thrown objects for the enemy's position at impact/detonation. Account for
  launch speed, the upward impulse, gravity, ground height, bounce, fuse and
  target motion. Show the landing/effect near the robots and check the actual
  blast/EMP distance and effect. A recorded throw event alone is insufficient.
- Drive along a tested, clear route, at normal speed, braking for obstacles.
  Keep world collisions. Do not change the game's damage, movement or collision
  rules merely to make a presentation succeed.

## Recording and assembly

Use an isolated working tree and a free test-game port. Port 24690 belongs to
the player's game and must not be used for staging, playback or shutdown.
The default test port is 24691; use another free port if it is occupied. Never
close another agent's or the player's game to clear it.

The current macOS workflow needs Godot on PATH and the system Swift/AVFoundation
runtime. No external media download is needed:

```bash
python3 tools/video/render_presentation.py \
  --port 24693 --output /absolute/output/new_video_revision
```

The current `presentation.json` and renderer implement a **180-second, 60 fps,
1920×1080** edit. For a different requested duration, update the shot plan and
its validation together; these numbers are the current delivery contract, not
an intrinsic limit on future videos.

- Preserve the game's audio. Check audible content, not just the existence of
  an audio track. Keep chapter text brief and avoid obstructing the action/HUD.
- Record bounded shots rather than one huge intermediate. Allow disk space for
  each raw shot and the final file. Offline Movie Maker speed is not gameplay
  FPS and must not be reported as a performance benchmark.
- Trim menus, loading and preparation using the logged take/frame markers.
  Keep exact shot durations and smooth video/audio fades within the edit.
- Preserve prior approved videos. Use a new revision directory. The tool reuses
  clips with an existing audit **without checking source hashes**: copy only
  unchanged shots, and re-record every shot affected by a script/plan change.
- Keep take logs, capture audits, previews and final audit alongside the video.
  Remove only this workflow's temporary raw/video/audio files after verification.
- Finish and deliver the complete requested video. A rehearsal or sample is not
  the final deliverable unless the user explicitly requested one.

## Acceptance checks

Before delivery:

1. Confirm the requested duration, resolution, frame count/rate and audio in the
   final encoded file by decoding it, rather than trusting export metadata alone.
2. Check script/parse errors in the captured runs and retain other warnings.
3. Verify actual interaction outcomes: collected inventory, captures, rescues,
   hits and grenade proximity. Keep the evidence in the take logs.
4. Inspect frames at the revised actions and scene boundaries. Extract exact
   timestamps; nearby keyframes can conceal a bad cut. Look for stuck movement,
   aim errors, visible spawning, frozen frames and audio discontinuities.
5. Preserve normal gameplay outside explicit staging and restore runtime flags
   when stopping a rehearsal. Report the final video's absolute location.

Implementation and commands: [DevAgent video documentation](../../docs/DEVAGENT.md#complete-three-minute-presentation).
Approved edit history and audits: [gameplay video handover](../../docs/handovers/2026-10-27-gameplay-video.md).

## Latest approved recording

The approved v3 was recorded in the **Gasômetro map, Porto Alegre**, around the
Usina do Gasômetro and Guaíba waterfront, using the isolated `gameplay-video`
working tree. Its full video is stored locally at:

```text
~/Documents/Codex/2026-10-14/referenced-chatgpt-conversation-this-is-an/outputs/gameplay_video/full_3min_v3/city_invaders_gameplay_3min.mp4
```

The adjacent `FINAL_QA.json`, `chapters.json` and per-shot folders contain the
validation, chapter plan, clips and take logs. This machine-specific output path
is historical delivery information; future recordings should choose a fresh
output folder rather than overwrite it.
