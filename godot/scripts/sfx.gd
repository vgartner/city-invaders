extends Node
## Sound effects (Kenney CC0 packs in res://assets/audio; gunshots synthesised
## by tools/assets/gen_gunshots.py). Each cue has a few
## variants picked at random with a slight pitch jitter. play() is 2D (the
## local player's own sounds); play_at() is positional 3D.

const DIR := "res://assets/audio/"
const CUES := {
	"pistol": ["gun_pistol_000.wav", "gun_pistol_001.wav", "gun_pistol_002.wav"],
	"machinegun": ["gun_rifle_000.wav", "gun_rifle_001.wav", "gun_rifle_002.wav"],
	"revolver": ["gun_revolver_000.wav", "gun_revolver_001.wav", "gun_revolver_002.wav"],
	"shotgun": ["gun_shotgun_000.wav", "gun_shotgun_001.wav", "gun_shotgun_002.wav"],
	"robot_fire": ["robot_phaser_000.wav", "robot_phaser_001.wav", "robot_phaser_002.wav"],
	"robot_hit": ["impactMetal_000", "impactMetal_001", "impactMetal_002"],
	"robot_death": ["explosionCrunch_000", "explosionCrunch_001", "explosionCrunch_002"],
	"robot_step": ["impactPlate_heavy_000", "impactPlate_heavy_001", "impactPlate_heavy_002"],
	"prop_break": ["impactMetal_heavy_000", "impactMetal_heavy_001", "impactMetal_heavy_002"],
	"glass": ["impactGlass_medium_000", "impactGlass_medium_001"],
	"step": ["footstep_concrete_000", "footstep_concrete_001", "footstep_concrete_002",
			"footstep_concrete_003", "footstep_concrete_004"],
	"pickup": ["forceField_000"],
	"horn_car": ["horn_car_000.wav", "horn_car_001.wav"],
	"horn_bus": ["horn_bus_000.wav"],
	"horn_moto": ["horn_moto_000.wav"],
	"bell_bike": ["bell_bike_000.wav"],
	"reload": ["doorOpen_000"],
	"quero_quero": ["quero_quero_000.wav", "quero_quero_001.wav"],     # tools/assets/gen_bird_calls.py
}
var _streams := {}


func _stream(cue: String) -> AudioStream:
	var name: String = CUES[cue][randi() % CUES[cue].size()]
	if not _streams.has(name):
		_streams[name] = load(DIR + name + ("" if "." in name else ".ogg"))
	return _streams[name]


func play(cue: String, volume_db := 0.0) -> void:
	if not CUES.has(cue):
		return
	var p := AudioStreamPlayer.new()
	p.stream = _stream(cue)
	p.volume_db = volume_db
	p.pitch_scale = randf_range(0.93, 1.07)
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


## 3D sounds playing at once, and the last of each cue (where, when): a fire
## fight asked for dozens a second, each a new node - past MAX_3D, or the same
## cue again within REPEAT_S a few metres away, a sound is left out (it would
## not be heard over the others anyway).
const MAX_3D := 24
const REPEAT_S := 0.05
var _playing_3d := 0
var _last_cue := {}


func play_at(cue: String, pos: Vector3, volume_db := 0.0, range_m := 90.0) -> void:
	if not CUES.has(cue) or get_tree().current_scene == null:
		return
	if _playing_3d >= MAX_3D:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var last: Array = _last_cue.get(cue, [Vector3.INF, -1.0])
	if now - float(last[1]) < REPEAT_S and (last[0] as Vector3).distance_to(pos) < 4.0:
		return
	_last_cue[cue] = [pos, now]
	_playing_3d += 1
	var p := AudioStreamPlayer3D.new()
	p.tree_exited.connect(func(): _playing_3d -= 1)
	p.stream = _stream(cue)
	p.volume_db = volume_db
	p.pitch_scale = randf_range(0.93, 1.07)
	p.unit_size = 8.0
	p.max_distance = range_m
	get_tree().current_scene.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()
