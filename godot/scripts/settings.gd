extends Node
## Player preferences kept between sessions in user://settings.cfg: key
## bindings (physical keys, so they sit in the same place on any keyboard
## layout), sound on/off, friendly fire and the last name typed in the menu.

const PATH := "user://settings.cfg"
## action -> [label, default physical key]
const ACTIONS := {
	"forward": ["Move forward", KEY_W],
	"back": ["Move back", KEY_S],
	"left": ["Strafe left", KEY_A],
	"right": ["Strafe right", KEY_D],
	"run": ["Run", KEY_SHIFT],
	"jump": ["Jump", KEY_SPACE],
	"reload": ["Reload", KEY_R],
	"weapon_1": ["Pistol", KEY_1],
	"weapon_2": ["Machine gun", KEY_2],
	"weapon_3": [".38 Revolver", KEY_3],
	"weapon_4": ["12-gauge shotgun", KEY_4],
	"weapon_5": ["Laço", KEY_5],
	"weapon_6": ["Espeto", KEY_6],
	"weapon_7": ["Mech cannon", KEY_7],
	"mute": ["Sound on / off", KEY_M],
	"design": ["Design mode (freeze + fly)", KEY_F2],
	"use": ["Enter / leave vehicle", KEY_E],
	"drone": ["Fly / bring back a captured drone", KEY_G],
	"horn": ["Horn (driving)", KEY_B],
	"radio": ["Car radio: on / next station / off", KEY_N],
	"tablet": ["Tablet (GPS, radio, Bah)", KEY_T],
	"glasses": ["Information glasses on / off", KEY_O],
}

signal changed

var keys := {}          # action -> Key
var muted := false
## shots hurt civilians and officers too (the host's choice applies)
var friendly_fire := true
## how sharply vehicles answer A/D: 0.2 (gentle) .. 1.0 (twitchy)
var steering := 0.5
## screen effects: "high" adds bounced light (SSIL, about a quarter of the
## frame on a large screen for a barely visible gain), "low" also drops
## ambient occlusion and anti-aliasing for slower machines
const GRAPHICS := ["low", "medium", "high"]
var graphics := "medium"
## the 3D picture's resolution: "auto" follows the frame rate (lower when the
## card cannot keep up), a percentage holds it there; below 100 % an upscaler
## (MetalFX on a Mac, FSR elsewhere) brings it to the screen - what most games
## do on large screens
const RESOLUTIONS := ["auto", "100", "85", "67", "50"]
var resolution := "auto"
## ambient occlusion (with graphics MEDIUM / HIGH): off for speed on big screens
var ssao := true
## easy / medium / hard (difficulty.gd); the host's applies to the round
var difficulty := "medium"
var player_name := "Player"
## the tablet was opened once: the hint under the crosshair is not shown again
var tablet_used := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in ACTIONS:
		keys[a] = ACTIONS[a][1]
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for a in ACTIONS:
			keys[a] = int(cfg.get_value("keys", a, keys[a]))
		muted = bool(cfg.get_value("audio", "muted", false))
		friendly_fire = bool(cfg.get_value("game", "friendly_fire", true))
		steering = float(cfg.get_value("game", "steering", 0.5))
		graphics = str(cfg.get_value("video", "graphics", "medium"))
		resolution = str(cfg.get_value("video", "resolution", "auto"))
		ssao = bool(cfg.get_value("video", "ssao", true))
		if not resolution in RESOLUTIONS:
			resolution = "auto"
		difficulty = str(cfg.get_value("game", "difficulty", "medium"))
		if not difficulty in ["easy", "medium", "hard"]:
			difficulty = "medium"
		if not graphics in GRAPHICS:
			graphics = "medium"
		player_name = str(cfg.get_value("player", "name", player_name))
		tablet_used = bool(cfg.get_value("help", "tablet_used", false))
	_apply_mute()


func save() -> void:
	var cfg := ConfigFile.new()
	for a in keys:
		cfg.set_value("keys", a, keys[a])
	cfg.set_value("audio", "muted", muted)
	cfg.set_value("game", "friendly_fire", friendly_fire)
	cfg.set_value("game", "steering", steering)
	cfg.set_value("video", "graphics", graphics)
	cfg.set_value("video", "resolution", resolution)
	cfg.set_value("video", "ssao", ssao)
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("player", "name", player_name)
	cfg.set_value("help", "tablet_used", tablet_used)
	cfg.save(PATH)


func key(action: String) -> Key:
	return keys.get(action, ACTIONS[action][1])


## actions held by the DevAgent (automated tests drive the real input path)
var virtual := {}


func pressed(action: String) -> bool:
	if virtual.has(action):
		return true
	# typing in a text box (chat, editor fields): the keys are text, not moves
	var focus := get_viewport().gui_get_focus_owner() if get_viewport() else null
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return false
	return Input.is_physical_key_pressed(key(action))


## A key event for `action` (pressed, not a key repeat).
func is_event(event: InputEvent, action: String) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == key(action)


func bind(action: String, physical_key: Key) -> void:
	# a key does one thing: whatever had it before gets this action's old key
	for a in keys:
		if a != action and keys[a] == physical_key:
			keys[a] = keys[action]
	keys[action] = physical_key
	save()
	changed.emit()


func reset_keys() -> void:
	for a in ACTIONS:
		keys[a] = ACTIONS[a][1]
	save()
	changed.emit()


func toggle_mute() -> void:
	muted = not muted
	_apply_mute()
	save()
	changed.emit()


func toggle_friendly_fire() -> void:
	friendly_fire = not friendly_fire
	save()
	changed.emit()


func cycle_difficulty() -> void:
	var levels := ["easy", "medium", "hard"]
	difficulty = levels[(levels.find(difficulty) + 1) % levels.size()]
	save()
	changed.emit()


func cycle_graphics() -> void:
	graphics = GRAPHICS[(GRAPHICS.find(graphics) + 1) % GRAPHICS.size()]
	save()
	changed.emit()


func cycle_resolution() -> void:
	resolution = RESOLUTIONS[(RESOLUTIONS.find(resolution) + 1) % RESOLUTIONS.size()]
	save()
	changed.emit()


func toggle_ssao() -> void:
	ssao = not ssao
	save()
	changed.emit()


func resolution_label() -> String:
	return "AUTO" if resolution == "auto" else resolution + " %"


func set_steering(v: float) -> void:
	steering = clamp(v, 0.2, 1.0)
	save()


func set_player_name(n: String) -> void:
	n = n.strip_edges()
	if n != "" and n != player_name:
		player_name = n
		save()


func key_label(action: String) -> String:
	if DisplayServer.get_name() == "headless":
		return OS.get_keycode_string(key(action))
	# the label of the key at that position on this keyboard layout
	return OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(key(action)))


func _apply_mute() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), muted)
