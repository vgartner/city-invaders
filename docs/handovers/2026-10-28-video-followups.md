# Handover: gameplay video follow-ups

From: Claude Code review of the `gameplay-video` work (2026-10-28) · To:
Codex (or any coding agent) · Owner: Vilson

The gameplay video work was reviewed and **merged into `main`** (rebased:
commits e0af34b..bfcb84b, plus 9df7833 removing machine paths from the
docs). The old `gameplay-video` branch is now behind and superseded:
**start a fresh worktree from the current `main`**, not from that branch.
Read [AGENTS.md](../../AGENTS.md) and [tools/video/README.md](../../tools/video/README.md)
first. Test on your own port (24691 or another free one), never 24690.

None of these blocked the merge; take them in this order, one commit each,
docs in the same commit.

## 1. God mode left on after a stage is cleared

`godot/scripts/video_stage.gd`: `prepare()` turns god mode on
(`_player.set_meta("god", true)`, ~line 104) but `clear()` (~line 172)
restores the director, swarm timer, resolution, audio and window size and
not god mode. Save the previous value in `_saved` and restore it in
`clear()`. Extend `tools/devagent/test_stage.py` (or the native test) to
check it.

## 2. Assembly works only on macOS

`tools/video/render_presentation.py` compiles `tools/video/media.swift`
(`/usr/bin/swiftc`, AVFoundation) and calls `/usr/bin/avconvert`.
Contributors on Linux or Windows cannot render a video. Add an `ffmpeg`
path (encode the Movie Maker AVI/PNG sequence, mux the WAV, trim by the
logged frame markers, the per-shot fades and the final concatenation),
chosen automatically when `swiftc` / `avconvert` are missing or with
`--encoder ffmpeg`. Keep the AVFoundation path as it is. Keep the QA the
same: decoded frame count, duration, resolution and audio checked on the
final file. Document both in `tools/video/README.md`.

## 3. Code style of the new scripts

`video_stage.gd`, `video_actions.gd` and the new DevAgent methods use
compact dictionaries (`{"a":1,"b":2}`) and one-line `if x: y` bodies; the
rest of the project writes `{"a": 1, "b": 2}` and puts bodies on their own
line. Reformat those files to match (no behaviour change), and keep
comments short, saying why, as elsewhere.

## 4. Audio peaks at 0 dBFS

The approved v3 measures mean -17.1 dB, max **0.0 dB** (ffmpeg
`volumedetect`): explosions likely clip. In the assembly, normalise or
limit the final mix (for example a peak limit at -1 dBTP, loudness around
-16 LUFS for web video) and add the measured peak / loudness to the final
QA, failing above -1 dBTP.

## 5. Two framings to improve

From a contact sheet of the v3 (one frame per chapter):

- **`usina_walk`** (chapter 2): the camera looks down at the grass and the
  path for most of the shot - raise the view (pitch around 0-5 deg) so the
  Usina, the street and the pickups are in frame, still showing the Fruki
  and the adrenaline speed-up.
- **`film_vehicle`** (chapter 8, the armoured harvester): a tree covers a
  large part of the frame. Choose a route or camera side with a clear view
  of the harvester and the robots it runs over.

## 6. Re-record with the newer game

Two visible changes landed in `main` after v3 was recorded:

- the **vehicle explosion** (`car.gd` `explode_fx`): a fireball, sparks
  and smoke instead of flat orange discs - worth a moment in the battle or
  harvester chapter (a robot-hit car, or `explode_fx` on a parked car);
- the **tablet home screen** now names the map ("Usina do Gasômetro ·
  Porto Alegre") - the tablet chapter can open on the home screen first.

After items 1-5, record a **v4** into a new output folder (keep v3), run
the full acceptance checks of `tools/video/README.md`, and report the
video's location and the QA. Do not commit videos or large media to the
repository.

## Done means

Items 1-4 committed and pushed to `main` (tests passing, docs updated),
items 5-6 delivered as the v4 video with its QA, and a short report of
what was tested and how.

## Implementation progress

1. God-mode restoration: saved the original player's metadata presence/value
   through a weak reference. Native simulation covers absent/false/true states,
   repeat clearing, smooth movement and restored ordinary input; scene tests pass.
2. Portable encoding: FFmpeg/FFprobe with Pillow captions, selected automatically
   without native macOS tools or explicitly with `--encoder ffmpeg`. Generated
   audiovisual fixtures pass marker trimming, caption encoding, decoded frame /
   duration / dimension / audio checks and a black fade at the chapter boundary.
3. Style: expanded one-line control flow and statement chains, and spaced
   dictionaries/operators in the two video helpers and their DevAgent wrappers.
   Non-whitespace tokens were preserved (semicolon separators become newlines).
   Godot parse/native simulation and the six scene-contract tests remain passing.
4. Audio: full assembly now uses two-pass FFmpeg mastering for either video
   encoder, then measures the encoded AAC. The gate is -1 dBTP maximum and
   -16 LUFS ±1 LU, with AAC headroom and retries from the original mix.
   Movie capture reserves 6 dB on the master bus and restores the prior gain.
   Generated-media round trips, rejection gates and native gain restoration pass.

## v4 framing and current-game recording

The Usina walk keeps pitch between -5 and +20 degrees, showing the facade,
chimney and pickups instead of mostly grass. Fruki and pala still collect through
normal movement, with the real speed bonus unchanged. The harvester now follows
the clear northbound avenue from approximately (44, 300), with a raised chase
orbit. Three troopers are prepared before recording. Their normal death signals
log player-attributed vehicle kills; the acceptance gate requires at least one.
A parked car ahead/right uses the current `explode_fx` at 6.2 s as an explicit
staged effect showcase, not a claimed robot-triggered explosion.

Rendered pilot checks: both pickups collected; the recorded harvester take has
two player-attributed robot kills and the explosion visible without foreground
foliage. Headless route rehearsal has three vehicle kills. The tablet chapter
starts on its home screen, exposing the map label supplied by the updated game.
All v4 chapters are captured from the fresh current-main worktree; v3 source
clips are not copied. Final output and measured QA follow after assembly.

A stricter audio-master regression test found AAC padding extending a generated
2 s fixture to 2.005 s. Mastering now receives the edit's exact duration and
limits the muxed output to it; the test checks the mastered container duration
as well as loudness and decoded video frames. The corrected round trip passes.

The first v4 drone take was correctly rejected: its trooper walked inside the
Usina and remained protected by the roof (health stayed 100). The target is now
prepared farther north in the open plaza, with normal AI still enabled. The
replacement rendered take passes, reducing health from 100 to 31 during the
attack. QA now requires a health reduction within the attack window, with a
regression test rejecting damage that only occurred before that window.
The rejected take/logs are retained separately in the local output folder.
