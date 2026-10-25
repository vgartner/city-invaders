extends Node
const HUD = preload("res://scripts/hud.gd")
var notifications := 0

func _ready() -> void:
	var hud := HUD.new()
	add_child(hud)
	var state := {"health": 100, "armor": 0, "weapon": "pistol", "slots": "pistol",
		"ammo": 10, "reserve": 20, "reloading": false, "kills": 0, "goal": 30,
		"civ_alive": 10, "civ_lost": 0, "goal_extra": 0, "threat": "BUILD_UP",
		"objective": "test", "exit_open": false, "dead": false, "design_hint": "design"}
	hud.refresh(state, 0.0)
	hud._health.theme_changed.connect(func(): notifications += 1)
	hud._banner.theme_changed.connect(func(): notifications += 1)
	for i in 100:
		hud.refresh(state, 0.016)
	assert(notifications == 0, "Identical HUD state must not reapply themes")
	state.health = 50
	hud.refresh(state, 0.0)
	assert(hud._health.get_theme_color("font_color") == HUD.AMBER)
	state.health = 20
	state.ammo = 0
	state.armor = 10
	state.threat = "RELAX"
	hud.refresh(state, 0.0)
	assert(hud._health.get_theme_color("font_color") == HUD.RED)
	assert(hud._ammo.get_theme_color("font_color") == HUD.RED)
	assert(hud._armor.get_theme_color("font_color") == HUD.ARMOR_COLOUR)
	assert(hud._threat.get_theme_color("font_color") == HUD.GREEN)
	state.exit_open = true
	hud.refresh(state, 0.1)
	var first: Color = hud._banner.get_theme_color("font_color")
	hud.refresh(state, 0.1)
	assert(hud._banner.get_theme_color("font_color") != first, "Exit pulse must animate")
	state.design = true
	hud.refresh(state, 0.0)
	assert(hud._banner.get_theme_font_size("font_size") == 20)
	assert(hud._banner.get_theme_color("font_color") == HUD.AMBER)
	state.design = false
	hud.refresh(state, 0.0)
	assert(hud._banner.get_theme_font_size("font_size") == 30)
	print("HUD stable-state, alert transitions and exit pulse tests passed")
	get_tree().quit()
