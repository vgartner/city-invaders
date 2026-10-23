extends CharacterBody3D
const Pigeon := preload("res://scripts/pigeon.gd")
const EnemyScript := preload("res://scripts/enemy.gd")
## First-person player. The owning peer simulates movement; position, yaw,
## health and death are replicated to everyone else. Shots are resolved on
## the server (hitscan) so enemy damage stays authoritative. Weapons: pistol
## (semi-auto) and machine gun (full-auto, picked up on the street).

const Step := preload("res://scripts/step.gd")
const WALK_SPEED := 5.0
const RUN_SPEED := 9.0
const JUMP_VELOCITY := 5.0
const MOUSE_SENSITIVITY := 0.0025
const RESPAWN_SECONDS := 4.0
const MAX_HEALTH := 100
const MAX_ARMOR := 100
const WEAPONS := {
	# empty hands: the round starts unarmed, and death costs the whole
	# inventory - weapons are found on the streets
	"hands": {"label": "Unarmed", "mag": 0, "reserve_max": 0, "interval": 0.5, "damage": 0,
			"auto": false, "spread": 0.0, "reload": 0.0, "start_reserve": 0, "unarmed": true},
	"pistol": {"label": "Pistol", "mag": 12, "reserve_max": 72, "interval": 0.22, "damage": 20,
			"auto": false, "spread": 0.0, "reload": 1.2, "start_reserve": 48},
	# rifle rounds hit at least as hard as the pistol (3 hits per robot); the
	# advantage is the rate of fire, kept honest by spread and limited ammo
	"machinegun": {"label": "Machine gun", "mag": 40, "reserve_max": 240, "interval": 0.085, "damage": 20,
			"auto": true, "spread": 0.012, "reload": 2.0, "start_reserve": 80},
	# .38 revolver: six heavy rounds, slow double action, long reload
	"revolver": {"label": ".38 Revolver", "mag": 6, "reserve_max": 42, "interval": 0.38, "damage": 34,
			"auto": false, "spread": 0.0, "reload": 2.4, "start_reserve": 18},
	# side-by-side 12-gauge: two shells of 9 pellets, deadly up close, wide spread
	"shotgun": {"label": "12-gauge", "mag": 2, "reserve_max": 30, "interval": 0.28, "damage": 11,
			"pellets": 9, "auto": false, "spread": 0.05, "reload": 2.0, "start_reserve": 10},
	# the gaúcho's laço: throw it at a robot (held still a few seconds, a mech
	# only slowed) or at a drone (pulled down and yours); no ammo
	# the barbecue skewer: stab and slash up close (no ammo)
	"espeto": {"label": "Espeto", "mag": 0, "reserve_max": 0, "interval": 0.5, "damage": 45,
			"auto": false, "spread": 0.0, "reload": 0.0, "start_reserve": 0, "melee": true},
	"laco": {"label": "Laço", "mag": 1, "reserve_max": 0, "interval": 1.4, "damage": 0,
			"auto": false, "spread": 0.0, "reload": 0.0, "start_reserve": 0, "lasso": true},
	# the cannon a downed mech drops: heavy shells that burst (BLAST m), few of them
	"canhao": {"label": "Mech cannon", "mag": 3, "reserve_max": 9, "interval": 1.1, "damage": 90,
			"auto": false, "spread": 0.0, "reload": 2.2, "start_reserve": 3, "blast": 4.5},
}
const LASSO_RANGE := 22.0           # drones keep 18 m off (drone.gd STANDOFF)
const LASSO_HOLD_S := 6.0
const AMMO_PICKUP := {"pistol": 24, "machinegun": 60, "revolver": 12, "shotgun": 8}
const VIEW_MODELS := {
	"pistol": "res://assets/common/weapons/pistol/pistol_9mm_viewmodel.glb",
	"machinegun": "res://assets/common/weapons/machinegun/carbine_556_viewmodel.glb",
	"revolver": "res://assets/common/weapons/revolver/revolver_38_viewmodel.glb",
	"shotgun": "res://assets/common/weapons/shotgun/shotgun_12g_viewmodel.glb",
	"laco": "res://assets/rio_grande_do_sul/weapons/laco/laco_fp.glb",
	"espeto": "res://assets/rio_grande_do_sul/weapons/espeto/espeto_churrasco_viewmodel.glb",
	"hands": "res://assets/common/melee/fists/fists_viewmodel.glb",
	"canhao": "res://assets/common/salvage/mech_cannon_viewmodel.gltf",
}
const FISTS := true                   # jab, jab, kick (false: kicks only)
## vertical field of view a view model was framed for (the arsenal pack: 70
## horizontal at 16:9, about 43 vertical); the others suit camera.fov
## per-weapon fit of a view model that came too close / too big (offset, scale)
## (offset, scale, and optionally a sideways squeeze bringing two hands together)
const VM_FIT := {"canhao": [Vector3(0.04, -0.13, -0.12), 0.8],
		"hands": [Vector3(0.0, -0.11, -0.02), 1.0, 0.72]}
const VM_FOV := {"pistol": 43.0, "machinegun": 43.0, "revolver": 43.0, "shotgun": 43.0, "espeto": 43.0, "hands": 43.0, "canhao": 43.0}

@export var health := MAX_HEALTH
@export var dead := false
var display_name := "Player"
var camera: Camera3D
var head: Node3D
var pitch := 0.0
## robot parts carried (traded at repair shops; lost on death)
var parts := {"circuit": 0, "core": 0, "lens": 0, "module": 0}
## robot parts carried: a few in the pockets, many in a mala de garupa
const PARTS_POCKETS := 4
const PARTS_BAG := 30
var has_bag := false
var glasses: Control                 # the information glasses (glasses.gd), once found
var has_glasses := false
## GPS upgrade from a repair shop: the people containers on the map (the
## Coletor's capsule module, decoded, knows where they are)
var gps_containers := false


func parts_cap() -> int:
	return PARTS_BAG if has_bag else PARTS_POCKETS


func parts_total() -> int:
	var n := 0
	for k in parts:
		n += int(parts[k])
	return n
var weapon := "hands"
var owned := []
const EMPTY_MAGS := {"hands": 0, "pistol": 0, "machinegun": 0, "revolver": 0, "shotgun": 0, "laco": 0, "espeto": 0, "canhao": 0}
var _mags := EMPTY_MAGS.duplicate()
var _reserves := EMPTY_MAGS.duplicate()
var ammo: int:
	get: return _mags[weapon]
var reserve: int:
	get: return _reserves[weapon]
var _trigger_held := false
var _view_model: Node3D
var _view_models := {}
var _vm_anims := {}     # weapon -> AnimationPlayer of its view model
var _fire_cd := 0.0
var _reload_left := 0.0
var _muzzle: OmniLight3D
const Hud := preload("res://scripts/hud.gd")
var _hud: Control
var _damage_flash: ColorRect
var _hit_marker: Label
var _body: MeshInstance3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var spawn_point := Vector3.ZERO
var director_phase := "BUILD_UP"
var team_kills := 0
var civ_alive := 0
var objective := ""          # phase goal line, from the server
var goal := 0                # robots to destroy this phase (0 = open-ended)
var goal_extra := 0          # added to the goal by civilians the robots killed
var mechs := 0               # heavy mechs destroyed this phase / needed
var antenna := 0             # the relay antenna: 0 none, 1 hidden, 2 spotted, 3 destroyed
var mech_goal := 0
var civ_lost := 0            # civilians killed by robots this phase
var exit_open := false
var civ_dead := 0
var _spawn_shield := 0.0
var armor := 0                 # the pala: absorbs part of every hit
## the resistance's grenades (definitions bergamota / porongo): how many of
## each, which one Q throws (Z switches)
const GRENADE_MAX := 4
var grenades := {"bergamota": 0, "porongo": 0}
var grenade := "bergamota"
var _grenade_cd := 0.0
var _adrenaline := 0.0         # Fruki: faster running and reloading while > 0
var vehicle: Node3D            # the car / bike this player is driving (local player)
var score := 0
var _score_flash := ""
var _score_flash_t := 0.0
var _chase: Camera3D
var _near_vehicle: Node3D
var _near_cd := 0.0
var _veh_last := Vector3.ZERO
var _veh_kmh := 0.0
var _saved_layers := Vector2i.ZERO
var _steer := 0.0
var _chase_yaw := 0.0          # mouse look around the vehicle while driving
var _chase_pitch := 0.0        # mouse up/down: the camera rises over the vehicle or drops behind it
var design := false          # main's design mode: world frozen, this player flies (noclip)
const DESIGN_SPEED := 8.0
const DESIGN_FAST := 30.0
var _step_cd := 0.0


func _enter_tree() -> void:
	set_multiplayer_authority(int(str(name)))
	add_to_group("players")


func _ready() -> void:
	collision_layer = 4
	collision_mask = 1 | 2 | 8 | 16 | 32     # world, robots, map border, cars, people
	# walk up the 15 cm curbs: the capsule meets the curb edge at ~55 degrees,
	# which the default 45-degree floor limit treats as a wall
	floor_max_angle = deg_to_rad(60)
	floor_snap_length = 0.3
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)

	_body = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(fmod(float(int(str(name))) * 0.37, 1.0), 0.7, 0.9)
	mesh.material = mat
	_body.mesh = mesh
	_body.position.y = 0.9
	add_child(_body)

	var tag := Label3D.new()
	tag.text = display_name
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position.y = 2.1
	tag.font_size = 48
	add_child(tag)

	head = Node3D.new()
	head.position.y = 1.65
	add_child(head)
	camera = Camera3D.new()
	camera.fov = 80
	camera.far = 1500
	head.add_child(camera)
	_muzzle = OmniLight3D.new()
	_muzzle.light_color = Color(1, 0.8, 0.4)
	_muzzle.light_energy = 0.0
	_muzzle.omni_range = 6.0
	_muzzle.position = Vector3(0.25, -0.2, -0.6)
	camera.add_child(_muzzle)
	_view_model = Node3D.new()
	_view_model.position = Vector3(0.2, -0.15, -0.43)     # above the HUD status bar
	camera.add_child(_view_model)

	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	for prop in [".:position", ".:rotation", ".:health", ".:dead"]:
		cfg.add_property(NodePath(prop))
	sync.replication_config = cfg
	add_child(sync)

	var mine := is_multiplayer_authority()
	camera.current = mine
	_body.visible = not mine
	tag.visible = not mine
	set_physics_process(mine)
	set_process_unhandled_input(mine)
	if mine:
		_build_hud()
		_show_weapon()
		# the field tablet, held like a view model (framed for the 43-degree lens)
		_tablet = preload("res://scripts/tablet.gd").new()
		_tablet.player = self
		camera.add_child(_tablet)
		var k: float = tan(deg_to_rad(camera.fov) / 2.0) / tan(deg_to_rad(43.0) / 2.0)
		_tablet.scale = Vector3(k, k, 1.0)
		if ResourceLoader.exists(LEG):
			_leg = (load(LEG) as PackedScene).instantiate()
			camera.add_child(_leg)
			_leg.scale = Vector3(k, k, 1.0)
			_leg.position.y = LEG_LIFT
			_leg.visible = false
			for mi in _leg.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var aps := _leg.find_children("*", "AnimationPlayer", true, false)
			if aps.size() > 0:
				_leg_anim = aps[0]
				_leg_anim.animation_finished.connect(func(_n): _leg.visible = false)


## A GPS route (tablet > GPS > Enter): the way there along the streets and
## pavements (the navigation mesh), drawn on the maps and, through the
## information glasses, on the ground ahead. Arriving ends it.
var route_to := Vector3.INF
var route_name := ""
var route_path := PackedVector3Array()
var _route_cd := 0.0
func set_route(at: Vector3, label: String) -> void:
	route_to = at
	route_name = label.get_slice("  (", 0)
	_route_cd = 0.0
	_toast_text("Rota: " + route_name)


func clear_route() -> void:
	route_to = Vector3.INF
	route_name = ""
	route_path = PackedVector3Array()


func _route_tick(delta: float) -> void:
	if route_to == Vector3.INF:
		return
	var here: Vector3 = vehicle.global_position if vehicle else global_position
	if Vector2(here.x - route_to.x, here.z - route_to.z).length() < 7.0:
		_toast_text("Chegaste: " + route_name)
		clear_route()
		return
	_route_cd -= delta
	if _route_cd > 0.0:
		return
	_route_cd = 0.8
	route_path = NavigationServer3D.map_get_path(get_world_3d().navigation_map, here, route_to, true)


func _toast_text(text: String) -> void:
	_picked("", {"name": text.trim_prefix("+ ")})
	if _toast:
		_toast.text = text


## The name of the place just entered (a shop, the Farroupilha camp), big
## and fading, once as you come in.
var _place_label: Label
var in_shop := false              # inside a shop's pocket (main.enter_shop), below the city
var _place_name := ""
var _place_cd := 0.0
func show_place(text: String) -> void:
	_place_name = text
	if text == "" or _ui == null:
		return
	if _place_label == null:
		_place_label = Label.new()
		_place_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_place_label.position.y = 130
		_place_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_place_label.add_theme_font_size_override("font_size", 44)
		_place_label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.78))
		_place_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_place_label.add_theme_constant_override("outline_size", 10)
		_ui.add_child(_place_label)
	_place_label.text = text
	_place_label.reset_size()
	_place_label.position.x = (get_viewport().get_visible_rect().size.x - _place_label.size.x) / 2.0
	_place_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(_place_label, "modulate:a", 0.0, 0.8)


func _place_tick(delta: float) -> void:
	_place_cd -= delta
	if _place_cd > 0.0:
		return
	_place_cd = 0.5
	var main := get_tree().current_scene
	if not main.has_method("area_name_at") or in_shop:
		return                     # in a shop: its name was shown at the door
	var here: String = main.area_name_at(global_position)
	if here != _place_name:
		show_place(here)


## A line just under the crosshair, where the player is looking (a banner at
## the top went unseen): how to open the tablet, until it has been opened once
## (ever - Settings.tablet_used); and, with robot parts enough to trade or the
## pockets full, where a repair shop is - 10 s a minute until one is used.
var _tablet_opened := false
var _hint: Label
var _shop_used := false
var _shop_hint_t := 50.0
func _hint_tick(delta: float) -> void:
	if _hint == null:
		return
	var text := ""
	var calm := not dead and not design and vehicle == null and not (_tablet and _tablet.visible) and _shop_panel == null
	if calm and not Settings.tablet_used:
		text = "Press %s - the tablet: map (GPS), radio and Bah, your assistant" % Settings.key_label("tablet")
	elif calm and not _shop_used and not _near_shop and (_can_trade() or parts_total() >= parts_cap()):
		_shop_hint_t += delta
		if fmod(_shop_hint_t, 60.0) < 10.0:
			text = "You have robot parts to trade: open the tablet (%s) and find a REPAIR SHOP on the GPS" % Settings.key_label("tablet")
	_hint.text = text
	_hint.visible = text != ""


## Something in the repair shop's list the parts in the pockets would buy.
func _can_trade() -> bool:
	for item in SHOP:
		var ok := true
		for k in item[1]:
			if int(parts.get(k, 0)) < int(item[1][k]):
				ok = false
		if ok:
			return true
	return false


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_damage_flash = ColorRect.new()
	_damage_flash.color = Color(0.8, 0, 0, 0)
	_damage_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_damage_flash)
	glasses = preload("res://scripts/glasses.gd").new()
	glasses.player = self
	layer.add_child(glasses)
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER)
	_toast.anchor_top = 0.62
	_toast.anchor_bottom = 0.62
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 30)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.92, 0.6))
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.modulate.a = 0.0
	layer.add_child(_toast)
	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_CENTER)
	_hint.anchor_top = 0.56
	_hint.anchor_bottom = 0.56
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 24)
	_hint.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_hint.add_theme_constant_override("outline_size", 8)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.visible = false
	layer.add_child(_hint)
	_hit_marker = Label.new()
	_hit_marker.text = "●"
	_hit_marker.add_theme_font_size_override("font_size", 40)
	_hit_marker.add_theme_color_override("font_color", Color(1, 0.15, 0.1))
	_hit_marker.modulate.a = 0.0
	layer.add_child(_hit_marker)
	var cross := Label.new()
	_cross = cross
	_ui = layer
	_gps = preload("res://scripts/gps.gd").new()
	_gps.vehicle = self
	_gps.position = Vector2(20, 70)
	layer.add_child(_gps)
	_gps.load_icons(get_tree().current_scene.get("place_kinds") if get_tree().current_scene.get("place_kinds") else {})
	for small in ["robo", "enxame"]:
		_gps.icons.erase(small)             # the corner map keeps robots as dots
	_gps.set_driving(false)
	cross.text = "+"
	cross.add_theme_font_size_override("font_size", 28)
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.position -= Vector2(8, 18)
	layer.add_child(cross)
	_hud = Hud.new()
	layer.add_child(_hud)


func _process(delta: float) -> void:
	_spawn_shield = max(0.0, _spawn_shield - delta)
	_grenade_cd = max(0.0, _grenade_cd - delta)
	_adrenaline = max(0.0, _adrenaline - delta)
	_score_flash_t -= delta
	_muzzle.light_energy = max(0.0, _muzzle.light_energy - delta * 40.0)
	_body.visible = not is_multiplayer_authority() and not dead
	if _view_model:
		_view_model.visible = not design and vehicle == null and not (_tablet and _tablet.visible)    # no floating arms over the car
	if is_multiplayer_authority():
		_vehicle_view(delta)
		_shop_tick(delta)
		_hint_tick(delta)
		_place_tick(delta)
		_route_tick(delta)
		# the corner map: the car's GPS while driving; on foot only through the
		# information glasses (projected, cyan) - otherwise the tablet has the map
		if _gps:
			var lens: bool = glasses != null and glasses.on and vehicle == null
			_gps.visible = vehicle != null or lens
			_gps.modulate = Color(0.55, 1.0, 1.0, 0.8) if lens else Color.WHITE
	if _hud:
		var keys := {"pistol": Settings.key_label("weapon_1"), "machinegun": Settings.key_label("weapon_2"),
				"revolver": Settings.key_label("weapon_3"), "shotgun": Settings.key_label("weapon_4"),
				"laco": Settings.key_label("weapon_5"), "espeto": Settings.key_label("weapon_6"),
				"canhao": Settings.key_label("weapon_7")}
		var slots := "   ".join(owned.map(func(w): return ("[%s %s]" if w == weapon else "%s %s") % [keys.get(w, ""), WEAPONS[w]["label"]]))
		if grenades.values().any(func(n): return n > 0):
			var gk := Settings.key_label("grenade")
			slots += "   ·   %s %s" % [gk, "  ".join(["bergamota", "porongo"].map(func(g): return ("[%s %d]" if g == grenade else "%s %d") % [
					"Bergamota" if g == "bergamota" else "Porongo", grenades[g]]))]
		if parts.values().any(func(n): return n > 0) or has_bag:
			slots += "   ·   PARTS  circuit %d  core %d  lens %d  module %d  (%d/%d%s)" % [parts["circuit"], parts["core"],
					parts["lens"], parts["module"], parts_total(), parts_cap(), " mala" if has_bag else ""]
		if drones > 0:
			slots += "   ·   drones %d (%s fly)" % [drones, Settings.key_label("drone")]
		if _pip and _pip.has_meta("cam"):
			(_pip.get_meta("cam") as Camera3D).global_transform = camera.global_transform
		_lasso_reticle(delta)
		_hud.refresh({"health": health, "armor": armor, "weapon": WEAPONS[weapon]["label"], "slots": slots,
				"ammo": ammo, "reserve": reserve, "reloading": _reload_left > 0,
				"kills": team_kills, "goal": goal, "goal_extra": goal_extra, "mechs": mechs, "mech_goal": mech_goal, "antenna": antenna,
				"civ_alive": civ_alive, "civ_lost": civ_lost, "threat": director_phase,
				"objective": objective, "exit_open": exit_open, "dead": dead, "design": design,
				"prompt": _vehicle_prompt() if _adrenaline <= 0 or vehicle else "ADRENALINE  %d s" % ceili(_adrenaline),
				"score": score,
				"score_flash": _score_flash if _score_flash_t > 0 else "", "score_up": not _score_flash.begins_with("-"),
				"design_hint": ("DESIGN MODE  ·  %s back to the game  ·  fly %s%s%s%s, Space up, Ctrl down, %s fast  ·  click picks, hold and move to drag, Q/E turn, Shift+click adds  ·  right drag or arrows turn the view  ·  Tab: look with the mouse" % [
					Settings.key_label("design"), Settings.key_label("forward"), Settings.key_label("left"),
					Settings.key_label("back"), Settings.key_label("right"), Settings.key_label("run")])
					+ ("\n" + get_tree().current_scene.design_label if get_tree().current_scene.design_label != "" else "")}, delta)
		_damage_flash.color.a = max(0.0, _damage_flash.color.a - delta * 1.5)
		_hit_marker.modulate.a = max(0.0, _hit_marker.modulate.a - delta * 0.8)


var _tablet: Node3D
var _toast: Label                   # "+ Circuit board": what was just picked up
var _leg: Node3D                     # the kick's leg (bombacha, bota, espora), shown only mid-kick
var _leg_anim: AnimationPlayer
func _tablet_input(event: InputEvent) -> bool:
	if not (event is InputEventKey and event.pressed and not event.echo) or _tablet == null:
		return false
	if Settings.is_event(event, "tablet"):
		if _tablet.visible:
			_tablet.close()
			_show_weapon()
		elif not vehicle and not dead and not design:
			_tablet.open()
			_tablet_opened = true
			if not Settings.tablet_used:
				Settings.tablet_used = true
				Settings.save()
		return true
	return _tablet.visible and _tablet.key(event)


## Bah's "ask anything": a line to type in over the tablet; the answer comes
## from the AI on the VGData server (Online.chat) and shows on the tablet.
var _ask: LineEdit
func ask_bah() -> void:
	if _ask:
		return
	_ask = LineEdit.new()
	_ask.placeholder_text = "Pergunte à Bah e aperte Enter (Esc cancela)"
	_ask.max_length = 500
	_ask.add_theme_font_size_override("font_size", 24)
	_ask.custom_minimum_size = Vector2(760, 52)
	# centred near the bottom by its anchors alone (a position on top of the
	# anchors put it off the screen)
	_ask.anchor_left = 0.5
	_ask.anchor_right = 0.5
	_ask.anchor_top = 1.0
	_ask.anchor_bottom = 1.0
	_ask.offset_left = -380
	_ask.offset_right = 380
	_ask.offset_top = -170
	_ask.offset_bottom = -118
	_ask.modulate.a = 0.0                  # the tablet shows the text in its own question field
	_ui.add_child(_ask)
	_ask.grab_focus()
	_ask.text_submitted.connect(func(t: String):
		_close_ask()
		t = t.strip_edges()
		if t == "":
			return
		_tablet.chat_q = t
		_tablet.chat_wait = true
		_tablet.set("_answer", -2)
		Online.chat(t, _bah_context(), func(reply: String, _ok: bool):
			if is_instance_valid(_tablet):
				_tablet.chat_wait = false
				_tablet.chat_reply = reply))
	_ask.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			_close_ask()
			get_viewport().set_input_as_handled())


func _close_ask() -> void:
	if _ask:
		_ask.queue_free()
		_ask = null


## What Bah knows about the moment (so "what now?" gets a useful answer).
func _bah_context() -> Dictionary:
	var main := get_tree().current_scene
	return {"map": main.get("map_id"), "health": health, "armor": armor, "weapon": weapon, "parts": parts,
			"has_glasses": has_glasses, "gps_containers": gps_containers, "objective": objective,
			"difficulty": Difficulty.level}


func radio_stop() -> void:
	if _radio:
		_radio.stop()
	_radio_station = -1
	if is_instance_valid(vehicle):
		vehicle.radio_on = false


func _unhandled_input(event: InputEvent) -> void:
	if _tablet_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and Settings.is_event(event, "glasses") \
			and has_glasses and glasses and not design:
		glasses.toggle()
		get_viewport().set_input_as_handled()
		return
	if design and _design_mouse(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _drone:
		_drone.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)       # steer the drone's camera
		_drone_cam.rotation.x = clamp(_drone_cam.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.4, 0.6)
	elif event is InputEventKey and event.pressed and not event.echo and Settings.is_event(event, "drone"):
		_toggle_drone()
	elif event is InputEventKey and event.pressed and Settings.is_event(event, "horn") and vehicle:
		vehicle.request_honk.rpc_id(1)
	elif event is InputEventKey and event.pressed and not event.echo and Settings.is_event(event, "radio") and vehicle:
		_radio_next()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and vehicle:
		_chase_yaw -= event.relative.x * MOUSE_SENSITIVITY      # look around the vehicle
		_chase_pitch = clamp(_chase_pitch + event.relative.y * MOUSE_SENSITIVITY,
				-0.5 if vehicle and vehicle.kind == "harvester" else -0.35, 0.9)      # the harvester aims up at drones
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		pitch = clamp(pitch - event.relative.y * MOUSE_SENSITIVITY, -1.5, 1.5)
		head.rotation.x = pitch
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_TAB and design:
		# design mode: free the cursor for the editor panel, or go back to flying
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed:
		# keys from Settings (configurable); Esc (pause) and the mute key are
		# handled by main: they must work while paused
		if Settings.is_event(event, "reload"):
			_start_reload()
		elif Settings.is_event(event, "weapon_1"):
			_switch("pistol")
		elif Settings.is_event(event, "weapon_2"):
			_switch("machinegun")
		elif Settings.is_event(event, "use"):
			if _shop_panel:
				_close_shop()
			elif _near_shop and not vehicle:
				_open_shop()
			elif not vehicle and _people_container():
				get_tree().current_scene.open_container.rpc_id(1, _people_container().get_path())
			elif not vehicle and _shop_door():
				get_tree().current_scene.enter_shop(_shop_door(), self)
			elif not vehicle and _site_door():
				_site_door().interact()
			else:
				_use_vehicle()
		elif Settings.is_event(event, "weapon_3"):
			_switch("revolver")
		elif Settings.is_event(event, "weapon_4"):
			_switch("shotgun")
		elif Settings.is_event(event, "weapon_5"):
			_switch("laco")
		elif Settings.is_event(event, "weapon_6"):
			_switch("espeto")
		elif Settings.is_event(event, "weapon_7"):
			_switch("canhao")
		elif Settings.is_event(event, "grenade"):
			_throw_grenade()
		elif Settings.is_event(event, "grenade_switch"):
			grenade = "porongo" if grenade == "bergamota" else "bergamota"
			_toast_text("%s  (%d)" % [Entities.get_def(grenade).get("name", grenade), grenades[grenade]])
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var i := owned.find(weapon)
		var step := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
		if not owned.is_empty():
			_switch(owned[(i + step + owned.size()) % owned.size()])
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not get_tree().current_scene.paused and not design:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if design:
		_fly(delta)
		return
	if vehicle:
		_drive_tick()
		return
	_fire_cd -= delta
	if _reload_left > 0:
		_reload_left -= delta * (2.0 if _adrenaline > 0 else 1.0)
		if _reload_left <= 0:
			var take: int = min(WEAPONS[weapon]["mag"] - _mags[weapon], _reserves[weapon])
			_mags[weapon] += take
			_reserves[weapon] -= take
	if dead or get_tree().current_scene.paused:
		velocity = Vector3(0, velocity.y - gravity * delta if not is_on_floor() else 0.0, 0)
		move_and_slide()
		return
	var pressed := (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) \
			or Settings.virtual.has("fire")             # the DevAgent's trigger (automated play tests)
	if _drone:
		if pressed:
			_drone_fire()           # with the drone up, the click fires its gun
	elif pressed and (WEAPONS[weapon]["auto"] or not _trigger_held):
		_try_fire()
	_trigger_held = pressed
	if _drone:
		_fly_drone(delta)
		velocity = Vector3(0, velocity.y - gravity * delta if not is_on_floor() else 0.0, 0)
		move_and_slide()                  # the body stands where it was left
		return
	if passenger:
		if not is_instance_valid(passenger) or passenger.get("_wrecked"):
			_get_off()
		else:
			global_position = passenger.to_global(_seat)      # riding along
			velocity = Vector3.ZERO
			return

	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Settings.pressed("jump"):
		velocity.y = JUMP_VELOCITY
	var input := Vector2(
		float(Settings.pressed("right")) - float(Settings.pressed("left")),
		float(Settings.pressed("back")) - float(Settings.pressed("forward")))
	var dir := (transform.basis * Vector3(input.x, 0, input.y)).normalized()
	var speed := (RUN_SPEED if Settings.pressed("run") else WALK_SPEED) * (Tune.adrenaline_speed if _adrenaline > 0 else 1.0)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	Step.try_step(self, Vector3(velocity.x, 0, velocity.z) * get_physics_process_delta_time() * 3.0)
	move_and_slide()
	# footsteps
	if is_on_floor() and dir.length() > 0.1:
		_step_cd -= delta
		if _step_cd <= 0:
			_step_cd = 0.3 if speed > WALK_SPEED else 0.45
			Sfx.play("step", -14.0)
	if position.y < -20 and not in_shop:
		position = spawn_point


# ---- vehicles (E): take any car, bus, motorbike or bicycle ---------------------

func _use_vehicle() -> void:
	if dead or design:
		return
	if passenger:
		_get_off()
	elif vehicle:
		request_exit.rpc_id(1)
	elif _near_vehicle and _near_vehicle.kind == "bus" and _near_vehicle.to_local(global_position).z > 0.0:
		_board(_near_vehicle)                    # a rear door: ride along as a passenger
	elif _near_vehicle:
		request_vehicle.rpc_id(1, str(_near_vehicle.name))


## Passenger on a bus: no one's driving you anywhere but the bus's route; you
## can look round and shoot out of the windows. E gets off by the rear door.
var passenger: Node3D
var _seat := Vector3.ZERO
func _board(bus: Node3D) -> void:
	passenger = bus
	_saved_layers = Vector2i(collision_layer, collision_mask)
	collision_layer = 0
	collision_mask = 0
	var box: AABB = AABB(bus._box_centre - bus._box.size / 2, bus._box.size)
	_seat = Vector3(box.size.x * 0.22, box.position.y + 0.95, box.size.z * 0.22)   # a seat in the back half
	Sfx.play("reload", -4.0)              # the door


func _get_off() -> void:
	var bus := passenger
	passenger = null
	collision_layer = _saved_layers.x
	collision_mask = _saved_layers.y
	if not is_instance_valid(bus):
		return
	# out of the rear door (the kerb side, +X) onto the walkable street
	var at: Vector3 = bus.to_global(Vector3(bus._box.size.x / 2 + 0.9, 0, bus._box.size.z * 0.25))
	global_position = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, at) + Vector3(0, 0.1, 0)
	velocity = Vector3.ZERO
	Sfx.play("reload", -4.0)              # the door


func _find_vehicle() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for v in get_tree().current_scene.traffic_root.get_children():
		if v.driver_peer != 0 or v.get("_wrecked"):
			continue
		var d: float = (v as Node3D).global_position.distance_to(global_position)
		# within 2.5 m of its sides, whatever its size (bike or harvester)
		var reach: float = 2.5 + (max(v._box.size.x, v._box.size.z) / 2.0 if v._box else 1.0)
		if d < reach and d < bd:
			bd = d
			best = v
	return best


@rpc("any_peer", "call_local", "reliable")
func request_vehicle(car_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or (sender if sender != 0 else 1) != get_multiplayer_authority():
		return
	var car: Node = get_tree().current_scene.traffic_root.get_node_or_null(car_name)
	if car == null or car.driver_peer != 0 or car.global_position.distance_to(global_position) > 10.0:
		return
	car.take(get_multiplayer_authority(), self)
	entered_vehicle.rpc_id(get_multiplayer_authority(), car_name)


@rpc("any_peer", "call_local", "reliable")
func request_exit() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or (sender if sender != 0 else 1) != get_multiplayer_authority():
		return
	for car in get_tree().current_scene.traffic_root.get_children():
		if car.driver_peer == get_multiplayer_authority():
			car.release()
			# out on the driver's (left) side, on the walkable street
			var side: Vector3 = car.global_transform.basis.x * -(car._box.size.x / 2 + 0.9)
			var at := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, car.global_position + side)
			left_vehicle.rpc_id(get_multiplayer_authority(), at + Vector3(0, 0.1, 0))
			return


## Server -> this player: burnt to death in an exploding vehicle.
@rpc("authority", "call_local", "reliable")
func burned() -> void:
	if vehicle:
		var at: Vector3 = vehicle.global_position + vehicle.global_transform.basis.x * -3.0
		left_vehicle(at)
	if dead:
		return
	health = 0
	dead = true
	report_hurt.rpc_id(1, 100)
	await get_tree().create_timer(RESPAWN_SECONDS).timeout
	_respawn(_safe_spawn())


## Server -> this player: the score changed (shown in the HUD with a flash).
@rpc("authority", "call_local", "reliable")
func set_score(total: int, delta: int, reason: String) -> void:
	score = total
	_score_flash = ("%+d  %s" % [delta, reason])
	_score_flash_t = 2.5


@rpc("authority", "call_local", "reliable")
func entered_vehicle(car_name: String) -> void:
	vehicle = get_tree().current_scene.traffic_root.get_node_or_null(car_name)
	if vehicle == null:
		return
	_saved_layers = Vector2i(collision_layer, collision_mask)
	_chase_yaw = 0.0
	_chase_pitch = 0.0
	collision_layer = 0
	collision_mask = 0
	_veh_last = vehicle.global_position
	if _chase == null:
		_chase = Camera3D.new()
		_chase.top_level = true
		_chase.fov = camera.fov
		add_child(_chase)
	_chase.global_position = vehicle.global_transform * Vector3(0, 3, 8)
	_chase.current = true
	Sfx.play("reload", -6.0)
	if is_instance_valid(_gps):
		_gps.vehicle = vehicle            # the GPS follows the vehicle while driving
		_gps.set_driving(true)
	if is_multiplayer_authority() and vehicle.kind in RADIO_KINDS:
		if vehicle.kind == "harvester" and not _radio_switched_off:
			_radio_tune(Music.stations().find("colheitadeira"))     # the harvester plays its own song
		elif _radio_station >= 0:
			_radio_tune(_radio_station)


var _gps: Control
@rpc("authority", "call_local", "reliable")
func left_vehicle(at: Vector3) -> void:
	if is_instance_valid(_gps):
		_gps.vehicle = self
		_gps.set_driving(false)
	if is_instance_valid(vehicle):
		vehicle.radio_on = false
	vehicle = null
	if _radio:
		_radio.stop()
	global_position = at
	velocity = Vector3.ZERO
	collision_layer = _saved_layers.x
	collision_mask = _saved_layers.y
	camera.current = true


## Local player at the wheel: controls to the server, ride along.
func _drive_tick() -> void:
	if not is_instance_valid(vehicle):
		left_vehicle(global_position)
		return
	var t := float(Settings.pressed("forward")) - float(Settings.pressed("back"))
	var want := float(Settings.pressed("right")) - float(Settings.pressed("left"))
	# keys are all-or-nothing: ease the wheel in and back (faster to centre),
	# scaled by the steering sensitivity setting
	# sensitivity sets how fast the wheel turns, not how far: full lock is always there
	var rate := (1.0 + 6.0 * Settings.steering) * (1.0 if abs(want) > abs(_steer) else 2.0) * get_physics_process_delta_time()
	_steer = move_toward(_steer, want, rate)
	vehicle.drive_input.rpc_id(1, t, _steer, float(Settings.pressed("jump")))
	# the harvester's grain gun: aim with the camera, left button
	_fire_cd -= get_physics_process_delta_time()
	if vehicle.kind == "harvester":
		# the corn cannon shoots where the crosshair (screen centre) points; a
		# marker shows where the cob lands
		var aim := _harvester_aim()
		_aim_marker(aim)
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
				and _fire_cd <= 0:
			_fire_cd = 0.22
			var tip := vehicle.find_child("muzzle_auger", true, false) as Node3D
			var from: Vector3 = tip.global_position if tip else vehicle.global_position + Vector3(0, 4.5, 0)
			vehicle.grain_fire.rpc_id(1, (aim - from).normalized())
	elif _marker:
		_marker.visible = false
	global_position = vehicle.global_position + Vector3(0, 0.6, 0)
	velocity = Vector3.ZERO


var _marker: MeshInstance3D


## Where the screen centre points from the chase camera (the vehicle itself ignored).
func _harvester_aim() -> Vector3:
	var from := _chase.global_position
	var dir := -_chase.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 120.0, 1 | 2 | 16 | 32)
	var ex := [vehicle.get_rid()]
	for b in vehicle.find_children("*", "CollisionObject3D", true, false):
		ex.append((b as CollisionObject3D).get_rid())
	q.exclude = ex
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if hit else from + dir * 120.0


## A ring on whatever the aim falls on.
func _aim_marker(at: Vector3) -> void:
	if _marker == null:
		_marker = MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.45
		ring.outer_radius = 0.6
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.85, 0.1)
		m.no_depth_test = true
		ring.material = m
		_marker.mesh = ring
		_marker.top_level = true
		add_child(_marker)
	_marker.visible = true
	_marker.global_position = at + Vector3(0, 0.05, 0)


## Chase camera behind the vehicle; prompt and speed for the HUD.
func _vehicle_view(delta: float) -> void:
	if vehicle:
		var big: bool = vehicle.kind in ["bus", "truck", "lorry", "harvester"]
		_chase_yaw = lerp_angle(_chase_yaw, 0.0, min(1.0, delta * 0.4)) if vehicle.kind != "harvester" else _chase_yaw
		# follow where the vehicle is drawn (interpolated between physics steps)
		var vt: Transform3D = vehicle.get_global_transform_interpolated()
		var yaw := Basis(Vector3.UP, vt.basis.get_euler().y + _chase_yaw)
		# orbit at the base distance; the mouse tilts it up over the roof or down behind
		var base := Vector2(12.0 if big else 6.5, 4.5 if big else 2.6)
		var elev: float = clamp(atan2(base.y, base.x) + _chase_pitch, 0.05, 1.35)
		var pivot: Vector3 = vt.origin + Vector3(0, 1.2, 0)
		if vehicle.kind == "harvester":
			# the grain gun aims through the screen centre: the camera looks past
			# the cab, over its left shoulder by the auger, not at the machine's
			# middle (the crosshair sat on the harvester and every cob landed
			# just in front of it); the mouse raises the aim above the horizon too
			pivot = vt.origin + Vector3(0, 5.5, 0) + yaw * Vector3(-1.6, 0, 0)
			base = Vector2(11.0, 2.0)
			elev = clamp(atan2(base.y, base.x) + _chase_pitch, -0.3, 1.2)
		var want: Vector3 = pivot + yaw * Vector3(0, sin(elev), cos(elev)) * base.length() \
				if vehicle.kind == "harvester" else vt.origin + yaw * Vector3(0, sin(elev), cos(elev)) * base.length()
		_chase.global_position = _chase.global_position.lerp(want, min(1.0, delta * 5.0))
		_chase.look_at(pivot, Vector3.UP)
		var moved: Vector3 = vehicle.global_position - _veh_last
		_veh_last = vehicle.global_position
		_veh_kmh = lerp(_veh_kmh, moved.length() / max(delta, 1e-4) * 3.6, 0.1)
		return
	_near_cd -= delta
	if _near_cd <= 0:
		_near_cd = 0.25
		_near_vehicle = _find_vehicle() if not dead else null


## Repair shops (assistência técnica): robot parts for gadgets.
const SHOP := [
	["Tower detector - the nearest relay antenna shows on the GPS", {"circuit": 4, "lens": 1}, "detector"],
	["Drone battery +60 s (refills the glasses too)", {"circuit": 3, "core": 1}, "battery"],
	["Information glasses", {"lens": 2, "circuit": 2}, "glasses"],
	["GPS upgrade: people containers (decodes a Coletor's module)", {"module": 1, "circuit": 2}, "gps_containers"],
	["Build a drone", {"module": 1, "circuit": 3}, "drone"],
	["Reinforced pala (armour)", {"circuit": 3}, "pala"],
	["Ammunition", {"circuit": 2}, "ammo"],
	["Porongo EMP grenade (built round a URB core)", {"core": 1, "circuit": 1}, "porongo"],
]
var _near_shop := false
var _shop_cd := 0.0
var _shop_panel: PanelContainer
var _battery_bonus := 0.0


func _shop_tick(delta: float) -> void:
	_shop_cd -= delta
	if _shop_cd > 0:
		return
	_shop_cd = 0.3
	var props = get_tree().current_scene.get("props")
	_near_shop = false
	if props and not dead:
		for at in props.shops:
			if (at as Vector3).distance_to(global_position) < 3.2:
				_near_shop = true
	if _shop_panel and not _near_shop:
		_close_shop()


func _open_shop() -> void:
	_shop_used = true
	_shop_panel = PanelContainer.new()
	_shop_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_shop_panel.add_child(box)
	var title := Label.new()
	title.text = "ASSISTÊNCIA TÉCNICA  ·  you carry: circuit %d  core %d  lens %d  module %d" % [
			parts["circuit"], parts["core"], parts["lens"], parts["module"]]
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	for offer in SHOP:
		if offer[2] == "gps_containers" and gps_containers:
			continue                      # installed already
		var cost: Dictionary = offer[1]
		var b := Button.new()
		b.text = "%s   (%s)" % [offer[0], ", ".join(cost.keys().map(func(k): return "%d %s" % [cost[k], k]))]
		b.add_theme_font_size_override("font_size", 20)
		b.disabled = cost.keys().any(func(k): return parts.get(k, 0) < cost[k])
		b.pressed.connect(_buy.bind(offer))
		box.add_child(b)
	var close := Button.new()
	close.text = "Close (%s)" % Settings.key_label("use")
	close.pressed.connect(_close_shop)
	box.add_child(close)
	_ui.add_child(_shop_panel)
	_shop_panel.position -= _shop_panel.get_combined_minimum_size() / 2
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_shop() -> void:
	if _shop_panel:
		_shop_panel.queue_free()
	_shop_panel = null
	if not get_tree().current_scene.get("driven"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _buy(offer: Array) -> void:
	var cost: Dictionary = offer[1]
	for k in cost:
		if parts.get(k, 0) < cost[k]:
			return
	for k in cost:
		parts[k] -= cost[k]
	match offer[2]:
		"detector":
			get_tree().current_scene.detect_antenna.rpc_id(1, global_position)
		"battery":
			_battery_bonus += 60.0
			if glasses:
				glasses.recharge()
		"drone":
			drones += 1
		"glasses":
			has_glasses = true
			if glasses:
				glasses.recharge()
		"gps_containers":
			gps_containers = true
			_picked("gps_containers", {"name": "GPS: people containers"})
		"pala":
			armor = MAX_ARMOR
		"ammo":
			for w in owned:
				_reserves[w] = min(WEAPONS[w]["reserve_max"], _reserves[w] + AMMO_PICKUP.get(w, 24))
		"porongo":
			grenades["porongo"] = mini(GRENADE_MAX, grenades["porongo"] + 1)
	Sfx.play("pickup", -4.0)
	_close_shop()
	_open_shop()                      # refreshed counts


## Car radio (this player only): N turns it on, steps through the stations
## (one per music folder, see music.gd) and turns it off.
const Music := preload("res://scripts/music.gd")
const Difficulty := preload("res://scripts/difficulty.gd")
const Entities := preload("res://scripts/entities.gd")
const RADIO_KINDS := ["car", "bus", "lorry", "truck", "harvester"]
var _radio: AudioStreamPlayer
var _radio_station := -1          # index into Music.stations(); -1: off
var _radio_switched_off := false  # turned off by hand: the harvester stays quiet too


func _radio_next() -> void:
	var st := Music.stations()
	if st.is_empty():
		return
	var playing := _radio != null and _radio.playing
	var next: int = (_radio_station + 1) if playing else maxi(0, _radio_station)
	if playing and next >= st.size():
		_radio.stop()
		if is_instance_valid(vehicle):
			vehicle.radio_on = false
		_radio_station = -1
		_radio_switched_off = true
		Sfx.play("pickup", -14.0)
		return
	_radio_switched_off = false
	_radio_tune(next)


func _radio_tune(i: int) -> void:
	var st := Music.stations()
	if i < 0 or i >= st.size():
		return
	if _radio == null:
		_radio = AudioStreamPlayer.new()
		_radio.volume_db = 0.0
		add_child(_radio)
	_radio_station = i
	Music.playlist(_radio, st[i])
	if is_instance_valid(vehicle):
		vehicle.radio_on = true


## The people container within reach (E lets everyone out), or null.
func _people_container() -> Node3D:
	var main := get_tree().current_scene
	return main.container_near(global_position) if main.has_method("container_near") else null


## The landmark whose entrance the player stands at (E opens it), or null.
func _site_door() -> Node3D:
	var main := get_tree().current_scene
	return main.site_near(global_position) if main.has_method("site_near") else null


## The closed shop whose door the player stands at (E walks in), or null.
func _shop_door() -> Node3D:
	var main := get_tree().current_scene
	return main.shop_near(global_position) if main.has_method("shop_near") else null


func _vehicle_prompt() -> String:
	var key := Settings.key_label("use")
	if _near_shop and not vehicle:
		return "%s  REPAIR SHOP: trade robot parts for gadgets" % key
	if not vehicle and _people_container():
		return "%s  OPEN THE CONTAINER: free %d people" % [key, _people_container().people.size()]
	if not vehicle and _site_door():
		var st: Node3D = _site_door()
		if st.entry_ready:
			return "%s  CLOSE %s" % [key, String(st.title).to_upper()]
		if st.entry_requested:
			return "OPENING %s..." % String(st.title).to_upper()
		return "%s  ENTER %s" % [key, String(st.title).to_upper()]
	if not vehicle and _shop_door():
		var l: Dictionary = _shop_door().get_meta("landmark", {})
		return "%s  enter %s" % [key, String(l.get("caption", l.get("label", "the shop")))]
	if vehicle:
		var hp := ""
		if vehicle.HP.has(vehicle.kind):
			var left: int = vehicle._hp if vehicle._hp > 0 else vehicle.HP[vehicle.kind]
			hp = "   ·   vehicle %d%%" % roundi(100.0 * left / vehicle.HP[vehicle.kind])
		var radio := ""
		if vehicle.kind in RADIO_KINDS:
			radio = "   ·   %s radio" % Settings.key_label("radio")
			if _radio and _radio.playing:
				radio = "   ·   %s  %s - %s" % [Settings.key_label("radio"), Music.label(_radio.get_meta("station", "")),
						Music.title(_radio.stream.resource_path)]
		return "%d km/h%s   ·   %s get out   ·   %s horn%s" % [roundi(_veh_kmh), hp, key, Settings.key_label("horn"), radio]
	if _drone:
		return "DRONE  ·  battery %d s  ·  WASD, Space / Ctrl up and down, mouse to look  ·  %s back to your body" \
				% [ceili(_drone_battery), Settings.key_label("drone")]
	if passenger:
		return "%s  get off the bus" % key
	if _near_vehicle and _near_vehicle.kind == "bus" and _near_vehicle.to_local(global_position).z > 0.0:
		return "%s  get on the bus (passenger)   ·   front door: drive it" % key
	if _near_vehicle:
		var what: String = {"car": "drive", "bus": "drive the bus", "motoboy": "ride", "cyclist": "ride",
				"horse": "ride the horse", "harvester": "drive the ARMOURED HARVESTER (click: grain gun)"}.get(_near_vehicle.kind, "drive")
		return "%s  %s" % [key, what]
	return ""


## Design mode: free flight where the camera looks, through walls.
## Space up, Ctrl down, run key fast.
## The mouse is free for the editor: a click picks (or places) what is under
## the cursor, Shift+click adds to the selection; right drag or the arrow
## keys turn the view, the wheel flies forward and back.
func _fly(delta: float) -> void:
	# dragging at the crosshair: the object follows where the view points
	var main := get_tree().current_scene
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not main.get("_drag").is_empty():
		main.design_drag_move(camera.global_position, -camera.global_transform.basis.z)
	if get_viewport().gui_get_focus_owner() is LineEdit:
		velocity = Vector3.ZERO           # typing in the editor (a name, the search box)
		return
	var turn := Vector2(
		float(Input.is_physical_key_pressed(KEY_LEFT)) - float(Input.is_physical_key_pressed(KEY_RIGHT)),
		float(Input.is_physical_key_pressed(KEY_UP)) - float(Input.is_physical_key_pressed(KEY_DOWN)))
	if turn != Vector2.ZERO:
		rotate_y(turn.x * DESIGN_TURN * delta)
		pitch = clamp(pitch + turn.y * DESIGN_TURN * delta, -1.5, 1.5)
		head.rotation.x = pitch
	var input := Vector3(
		float(Settings.pressed("right")) - float(Settings.pressed("left")),
		float(Settings.pressed("jump")) - float(Input.is_physical_key_pressed(KEY_CTRL)),
		float(Settings.pressed("back")) - float(Settings.pressed("forward")))
	var basis := camera.global_transform.basis
	var move := basis.x * input.x + basis.z * input.z + Vector3.UP * input.y
	if move.length() > 0.01:
		global_position += move.normalized() * (DESIGN_FAST if Settings.pressed("run") else DESIGN_SPEED) * delta
	velocity = Vector3.ZERO


const DESIGN_TURN := 1.6            # rad/s with the arrow keys


## Design mode mouse: pick under the cursor, right drag looks, wheel flies.
func _design_mouse(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			var at := get_viewport().get_mouse_position()
			var from := camera.project_ray_origin(at)
			var dir := camera.project_ray_normal(at)
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				from = camera.global_position
				dir = -camera.global_transform.basis.z
			var main := get_tree().current_scene
			# a press on the selected object starts dragging it; elsewhere it picks
			if not mb.shift_pressed and main.design_drag_start(from, dir):
				return true
			main.design_select(from, dir, mb.shift_pressed)
			return true
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := (6.0 if mb.shift_pressed else 2.0) * (1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
			global_position += -camera.global_transform.basis.z * step
			return true
		return true                        # right button: only for looking
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_tree().current_scene.design_drag_end()
		return false
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not get_tree().current_scene.get("_drag").is_empty():
		var mp: Vector2 = get_viewport().get_mouse_position()
		get_tree().current_scene.design_drag_move(camera.project_ray_origin(mp), camera.project_ray_normal(mp))
		return true
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		pitch = clamp(pitch - event.relative.y * MOUSE_SENSITIVITY, -1.5, 1.5)
		head.rotation.x = pitch
		return true
	return false


func _try_fire() -> void:
	if _fire_cd > 0 or _reload_left > 0 or (_tablet and _tablet.visible):
		return
	if WEAPONS[weapon].get("unarmed", false):
		_melee()
		return
	if WEAPONS[weapon].get("melee", false):
		# the skewer: stab, slash, stab...
		_combo = (_combo + 1) % 2
		_fire_cd = MELEE["espeto"][2]
		_vm_play("stab" if _combo == 0 else "slash", true)
		Sfx.play("step", -4.0)
		server_shoot.rpc_id(1, camera.global_position, -camera.global_transform.basis.z, "espeto")
		return
	if _mags[weapon] <= 0:
		_start_reload()
		return
	var w: Dictionary = WEAPONS[weapon]
	if w.get("lasso", false):
		_throw_lasso()
		return
	_mags[weapon] -= 1
	_fire_cd = w["interval"]
	_muzzle.light_energy = 6.0
	Sfx.play(weapon, -4.0)
	gunshot_fx.rpc(weapon)
	if _vm_anims.has(weapon):
		_vm_play("fire", true)
	else:
		# small recoil kick on the placeholder
		_view_model.position.z = -0.38
		create_tween().tween_property(_view_model, "position:z", -0.43, w["interval"] * 0.9)
	var origin := camera.global_position
	var b := camera.global_transform.basis
	var spread: float = w["spread"]
	for pellet in w.get("pellets", 1):
		var dir := -b.z + b.x * randf_range(-1, 1) * spread + b.y * randf_range(-1, 1) * spread
		_shoot_ray(origin, dir.normalized())


## Empty hands: punch, punch, kick - a few metres of reach, enough to get
## away from a robot or finish one off; the third blow is a kick, harder.
const MELEE := {"punch": [14, 2.2, 0.45], "kick": [24, 2.6, 0.8], "espeto": [45, 2.8, 0.5]}    # damage, reach m, recovery s
var _combo := 0


## The kick's leg (rio_grande_do_sul/melee/chute_campeiro): clip and the
## moment the boot lands (ATTACK_EVENTS.json there).
const LEG := "res://assets/rio_grande_do_sul/melee/chute_campeiro/chute_campeiro_viewmodel.glb"
## (The package's stomp stays below the frame at this lens, so it is not used.)
const KICKS := {"kick_front": 0.22, "kick_side": 0.30}
const PUNCHES := {"jab_right": 0.15, "jab_left": 0.15, "hook_right": 0.25}
const KICK_SPEED := 0.75             # a little slower than authored: on screen long enough to read
const LEG_LIFT := 0.14               # raised above the HUD bar along the bottom


func _melee() -> void:
	# empty hands: kicks only until a good fists model arrives (FISTS on: jab, jab, kick)
	var kind := "kick"
	if FISTS:
		_combo = (_combo + 1) % 3
		kind = "kick" if _combo == 0 else "punch"
	_fire_cd = MELEE[kind][2]
	if kind == "kick" and _leg_anim:
		# a front kick, now and then one from the side
		var clip := "kick_side" if randf() < 0.3 else "kick_front"
		if _leg_anim.has_animation(clip):
			_leg.visible = true
			_leg_anim.stop()
			_leg_anim.play(clip, 0.0, KICK_SPEED)
			await get_tree().create_timer(KICKS[clip] / KICK_SPEED).timeout
			Sfx.play("step", -2.0)
			var lb := camera.global_transform.basis
			server_shoot.rpc_id(1, camera.global_position, -lb.z, kind)
			return
	if kind == "punch" and _vm_anims.has("hands"):
		# the fists: right jab, left jab (now and then a right hook), the blow
		# counted when the knuckles land (tools/blender/fists_viewmodel.py)
		var clip := "hook_right"           # the jabs looked weak: only the hook stays
		_vm_play(clip, true)
		await get_tree().create_timer(PUNCHES[clip]).timeout
		Sfx.play("step", -2.0)
		var pb := camera.global_transform.basis
		server_shoot.rpc_id(1, camera.global_position, -pb.z, kind)
		return
	Sfx.play("step", -2.0)
	# a jab of the camera towards the blow
	var tw := create_tween()
	tw.tween_property(camera, "position:z", -0.12 if kind == "punch" else -0.05, 0.06)
	tw.tween_property(camera, "position:z", 0.0, 0.18)
	if kind == "kick":
		var tw2 := create_tween()
		tw2.tween_property(camera, "rotation:x", -0.08, 0.1)
		tw2.tween_property(camera, "rotation:x", 0.0, 0.25)
	var b := camera.global_transform.basis
	server_shoot.rpc_id(1, camera.global_position, -b.z, kind)


## With the laço in hand: the crosshair turns into a yellow ring when a robot
## or drone is within reach on the line, and the loop spins overhead.
func _lasso_reticle(delta: float) -> void:
	if _cross == null:
		return
	if weapon != "laco" or vehicle or passenger or design:
		_cross.text = "+"
		_cross.add_theme_color_override("font_color", Color.WHITE)
		return
	_lasso_cd -= delta
	if _lasso_cd <= 0:
		_lasso_cd = 0.1
		_lasso_aim = _lasso_target()
		var ap: AnimationPlayer = _vm_anims.get("laco")
		if ap and _fire_cd <= 0 and ap.current_animation != ("swing" if _lasso_aim else "idle"):
			ap.play("swing" if _lasso_aim else "idle", 0.2)
	_cross.text = "◎" if _lasso_aim else "+"
	_cross.add_theme_color_override("font_color", Color(1.0, 0.85, 0.15) if _lasso_aim else Color.WHITE)


## The laço goes out along the crosshair; the first robot or drone close to
## the line within LASSO_RANGE is caught (the server decides).
func _throw_lasso() -> void:
	_fire_cd = WEAPONS["laco"]["interval"]
	_vm_play("throw", true)
	Sfx.play("reload", -8.0)
	var t := _lasso_target()
	if t:
		lasso_throw.rpc_id(1, t.get_path())
	_lasso_line(t.global_position + Vector3(0, 1.2, 0) if t else camera.global_position - camera.global_transform.basis.z * LASSO_RANGE)


## The robot or drone the laço would catch now (nearest to the crosshair line).
func _lasso_target() -> Node3D:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var best: Node3D = null
	var bd := 1.6                         # how far off the line still counts (metres)
	for e in get_tree().get_nodes_in_group("robots"):
		if not e.is_alive():
			continue
		var c: Vector3 = e.global_position + Vector3(0, 0.0 if e.get("variant") == "drone" else 1.2, 0)
		var along := (c - from).dot(dir)
		if along < 1.0 or along > LASSO_RANGE:
			continue
		var off := (c - (from + dir * along)).length()
		if off < bd:
			var q := PhysicsRayQueryParameters3D.create(from, c, 1)
			if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
				bd = off
				best = e
	return best


@rpc("any_peer", "call_local", "reliable")
func lasso_throw(target_path: NodePath) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or (sender if sender != 0 else 1) != get_multiplayer_authority():
		return
	var t := get_node_or_null(target_path)
	if t == null or not t.is_alive() or t.global_position.distance_to(global_position) > LASSO_RANGE + 3.0:
		return
	if t.get("variant") == "drone":
		t.lassoed(self)
	elif t.has_method("lassoed"):
		t.lassoed(LASSO_HOLD_S)


## Server -> this player: a drone pulled down with the laço is yours.
var drones := 0
var _cross: Label
var _lasso_cd := 0.0
var _lasso_aim: Node3D
@rpc("authority", "call_local", "reliable")
func got_drone() -> void:
	drones += 1
	Sfx.play("pickup", -4.0)


## Flying a captured drone: G sends it up from where you stand and you see
## through its camera (your body stays put, shown in a corner window); G
## again, a dead battery or your body taking hits brings you back. The drone
## goes back into your kit unless it was lost.
const DRONE_BATTERY_S := 90.0
const DRONE_SPEED := 9.0
## metres above the ground under it: above the tallest towers (the relay
## antenna can sit on a 65 m roof)
const DRONE_CEILING := 120.0
## the drone's light gun: no ammo, it fires while the battery lasts
const DRONE_DAMAGE := 5
const DRONE_INTERVAL := 0.15
const DRONE_RANGE := 160.0             # control link: no further from your body
var _drone: Node3D
var _drone_cam: Camera3D
var _drone_battery := 0.0
var _spot_cd := 0.0
var _pip: SubViewportContainer
var _ui: CanvasLayer


func _toggle_drone() -> void:
	if _drone:
		_land_drone()
		return
	if drones <= 0 or vehicle or passenger or dead or design:
		return
	_drone = Node3D.new()
	_drone.top_level = true
	var model := load("res://assets/common/enemies/drone/drone.glb") as PackedScene
	if model:
		_drone.add_child(model.instantiate())
	add_child(_drone)
	_drone.global_position = global_position + Vector3(0, 2.5, 0)
	_drone.rotation.y = rotation.y
	_drone_cam = Camera3D.new()
	_drone_cam.fov = 75.0
	_drone_cam.position = Vector3(0, -0.25, -0.35)
	_drone_cam.rotation.x = -0.35
	_drone.add_child(_drone_cam)
	_drone_cam.current = true
	_drone_battery = DRONE_BATTERY_S + _battery_bonus
	_show_pip(true)
	if _view_model:
		_view_model.visible = false
	Sfx.play("pickup", -6.0)


func _land_drone() -> void:
	if _drone:
		_drone.queue_free()
	_drone = null
	camera.current = true
	_show_pip(false)
	if _view_model:
		_view_model.visible = true


func _fly_drone(delta: float) -> void:
	_drone_battery -= delta
	# looking for the robots' relay antenna from the air
	_spot_cd -= delta
	if _spot_cd <= 0:
		_spot_cd = 0.3
		for a in get_tree().get_nodes_in_group("relay"):
			if a.spotted or not a.is_alive() or a.global_position.distance_to(_drone.global_position) > 55.0:
				continue
			var q := PhysicsRayQueryParameters3D.create(_drone.global_position, a.global_position + Vector3(0, 5, 0), 1 | 64)
			q.exclude = [a.get_rid()]
			if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
				a.mark_spotted.rpc()
	var input := Vector3(
		float(Settings.pressed("right")) - float(Settings.pressed("left")),
		float(Settings.pressed("jump")) - float(Input.is_physical_key_pressed(KEY_CTRL)),
		float(Settings.pressed("back")) - float(Settings.pressed("forward")))
	var b := _drone.global_transform.basis
	var move := (b.x * input.x + b.z * input.z).normalized() * Vector3(1, 0, 1) + Vector3.UP * input.y
	var next := _drone.global_position + move * DRONE_SPEED * (2.0 if Settings.pressed("run") else 1.0) * delta
	# stay in the air above the ground, within the link range and the map
	var q := PhysicsRayQueryParameters3D.create(next + Vector3(0, 1, 0), next - Vector3(0, 60, 0), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		next.y = max(next.y, hit.position.y + 1.0)
	next.y = min(next.y, (hit.position.y if hit else global_position.y) + DRONE_CEILING)
	# buildings and roofs are solid to it
	var wall := PhysicsRayQueryParameters3D.create(_drone.global_position, next + (next - _drone.global_position).normalized() * 0.6, 1 | 64)
	var blocked := not get_world_3d().direct_space_state.intersect_ray(wall).is_empty()
	if not blocked and next.distance_to(global_position) < DRONE_RANGE and get_tree().current_scene.in_bounds(next, 5.0):
		_drone.global_position = next
	if _drone_battery <= 0:
		_land_drone()


func _drone_fire() -> void:
	if _fire_cd > 0 or _drone_cam == null:
		return
	_fire_cd = DRONE_INTERVAL
	Sfx.play("machinegun", -12.0)
	var b := _drone_cam.global_transform.basis
	var dir := -b.z + b.x * randf_range(-1, 1) * 0.01 + b.y * randf_range(-1, 1) * 0.01
	_shoot_ray(_drone_cam.global_position, dir.normalized(), "drone")


## A small window in the corner with what your body sees while you fly.
func _show_pip(on: bool) -> void:
	if not on:
		if _pip:
			_pip.queue_free()
		_pip = null
		return
	_pip = SubViewportContainer.new()
	_pip.stretch = true
	_pip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_pip.offset_left = -360
	_pip.offset_right = -20
	_pip.offset_top = 70
	_pip.offset_bottom = 262
	var vp := SubViewport.new()
	vp.world_3d = get_world_3d()
	vp.size = Vector2i(320, 180)
	_pip.add_child(vp)
	var cam := Camera3D.new()
	cam.fov = camera.fov
	vp.add_child(cam)
	cam.set_meta("follow", true)
	if _ui:
		_ui.add_child(_pip)
	else:
		get_tree().current_scene.add_child(_pip)
	_pip.set_meta("cam", cam)


## The rope flying out to where it caught (or fell short).
func _lasso_line(to: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.55, 0.38, 0.2)
	var from := camera.global_position + camera.global_transform.basis * Vector3(0.25, -0.2, -0.4)
	im.surface_begin(Mesh.PRIMITIVE_LINES, m)
	for k in 12:                          # a slight sag along the rope
		for j in [k, k + 1]:
			var f := float(j) / 12.0
			im.surface_add_vertex(from.lerp(to, f) - Vector3(0, sin(f * PI) * 0.6, 0))
	im.surface_end()
	mi.mesh = im
	mi.top_level = true
	get_tree().current_scene.add_child(mi)
	get_tree().create_timer(0.7).timeout.connect(mi.queue_free)


## One bullet / pellet: the server applies it, this peer shows where it lands.
func _shoot_ray(origin: Vector3, dir: Vector3, w := "") -> void:
	server_shoot.rpc_id(1, origin, dir.normalized(), w if w != "" else weapon)
	# local impact effect where the bullet lands
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * 150.0, shot_mask())
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		_impact(hit.position, hit.normal, hit.collider.has_method("apply_damage"))
	# a quero-quero in the way: birds are local to every peer, so this shot is
	# the one that hits it (up to whatever else the bullet would hit first)
	var wn := w if w != "" else weapon
	var reach: float = MELEE[wn][1] if MELEE.has(wn) else 150.0
	var bq := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * reach, Pigeon.LAYER)
	var bird := get_world_3d().direct_space_state.intersect_ray(bq)
	if bird and bird.collider.has_meta("bird") and (not hit or origin.distance_to(bird.position) < origin.distance_to(hit.position)):
		var dmg: int = MELEE[wn][0] if MELEE.has(wn) else (DRONE_DAMAGE if wn == "drone" else WEAPONS.get(wn, WEAPONS["pistol"])["damage"])
		bird.collider.get_meta("bird").apply_damage(dmg, self)
	# through a tree crown, or into a trunk: leaves come down
	var fq := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * 150.0, 128)
	fq.collide_with_areas = true
	fq.collide_with_bodies = false
	var leaf := get_world_3d().direct_space_state.intersect_ray(fq)
	if leaf and (not hit or origin.distance_to(leaf.position) < origin.distance_to(hit.position)):
		shake_leaves.rpc(leaf.position - dir.normalized() * 0.3)   # on the near face
	elif hit and hit.collider.has_meta("tree_crown"):
		shake_leaves.rpc(hit.collider.get_meta("tree_crown"))


func _start_reload() -> void:
	if WEAPONS[weapon].get("unarmed", false):
		return
	if _reload_left <= 0 and _mags[weapon] < WEAPONS[weapon]["mag"] and _reserves[weapon] > 0:
		_reload_left = WEAPONS[weapon]["reload"]
		_vm_play("reload", false, WEAPONS[weapon]["reload"])
		Sfx.play("reload", -8.0)


## Play a view-model clip; `fit_seconds` stretches it to the gameplay duration.
func _vm_play(clip: String, restart := false, fit_seconds := 0.0) -> void:
	var ap: AnimationPlayer = _vm_anims.get(weapon)
	if ap == null or not ap.has_animation(clip):
		return
	var speed := 1.0
	if fit_seconds > 0:
		speed = ap.get_animation(clip).length / fit_seconds
	if restart:
		ap.stop()
	ap.play(clip, 0.0, speed)          # no cross-fade: the clips scale magazines to zero


func _switch(w: String) -> void:
	if w == weapon or not w in owned:
		return
	weapon = w
	_reload_left = 0.0
	_fire_cd = 0.25
	_show_weapon()


func _show_weapon() -> void:
	if _view_model == null:
		return
	for c in _view_model.get_children():
		c.visible = false
	if WEAPONS[weapon].get("unarmed", false) and (not VIEW_MODELS.has(weapon) or not FISTS):
		return                              # nothing in the hands yet
	if not _view_models.has(weapon):
		var node: Node3D
		if ResourceLoader.exists(VIEW_MODELS[weapon]):
			node = (load(VIEW_MODELS[weapon]) as PackedScene).instantiate()
			# view models are authored with the camera at their origin
			node.position = -_view_model.position
			# framed for a narrower lens: stretching x/y about the eye (not z)
			# shows them as that lens would, while the world keeps camera.fov
			if VM_FOV.has(weapon):
				var k: float = tan(deg_to_rad(camera.fov) / 2.0) / tan(deg_to_rad(VM_FOV[weapon]) / 2.0)
				node.scale = Vector3(k, k, 1.0)
			if VM_FIT.has(weapon):
				node.position += VM_FIT[weapon][0]
				node.scale *= float(VM_FIT[weapon][1])
				if VM_FIT[weapon].size() > 2:
					node.scale.x *= float(VM_FIT[weapon][2])
					# a slight tilt of each half towards the middle reads as fists in a V
					node.rotation.x = deg_to_rad(-6.0)
			for mi in node.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var players := node.find_children("*", "AnimationPlayer", true, false)
			if players.size() > 0:
				var ap: AnimationPlayer = players[0]
				for loop_clip in ["idle", "swing", "idle_fists"]:
					if ap.has_animation(loop_clip):
						ap.get_animation(loop_clip).loop_mode = Animation.LOOP_LINEAR
				# after a clip: back to the resting one (the fists keep their guard)
				var rest := "idle" if ap.has_animation("idle") else "idle_fists"
				ap.animation_finished.connect(func(_n): if ap.has_animation(rest): ap.play(rest, 0.0))
				_vm_anims[weapon] = ap
		else:
			# placeholder gun until the generated model arrives
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.07, 0.11, 0.32) if weapon == "pistol" else Vector3(0.09, 0.14, 0.62)
			mi.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.12, 0.12, 0.13)
			mat.metallic = 0.7
			mat.roughness = 0.35
			mi.material_override = mat
			mi.position.z = -0.1 if weapon == "pistol" else -0.2
			node = mi
		_view_model.add_child(node)
		_view_models[weapon] = node
	_view_models[weapon].visible = true
	_vm_play("raise" if weapon == "hands" else "draw")


## What a player's bullet can hit: the world and robots, and with friendly
## fire on also pedestrians and officers.
static func shot_mask() -> int:
	return 1 | 2 | 16 | (32 if Settings.friendly_fire else 0)


@rpc("any_peer", "call_local", "reliable")
func server_shoot(origin: Vector3, dir: Vector3, w: String = "pistol") -> void:
	if not multiplayer.is_server():
		return
	var melee := MELEE.has(w)
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * (MELEE[w][1] if melee else 150.0), shot_mask())
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var dmg: int = MELEE[w][0] if melee else (DRONE_DAMAGE if w == "drone" else WEAPONS.get(w, WEAPONS["pistol"])["damage"])
	if melee:
		if hit and hit.collider.has_method("apply_damage"):
			hit.collider.apply_damage(dmg, self)
			Sfx.play_at("robot_hit", hit.position, -2.0)
		return                              # a blow makes no noise for the robots to hear
	if WEAPONS.get(w, {}).has("blast"):
		# the mech cannon's missile flies there (seen by everyone) and bursts
		# where it lands: robots around take it too
		var at: Vector3 = hit.position if hit else origin + dir * 150.0
		var r: float = WEAPONS[w]["blast"]
		var wall: bool = not hit.is_empty() and hit.collider is StaticBody3D and absf((hit.normal as Vector3).y) < 0.5
		var main := get_tree().current_scene
		var muzzle: Vector3 = origin + dir * 1.2 + Vector3(0, -0.3, 0)
		var flight: float = maxf(muzzle.distance_to(at) / EnemyScript.CANNON_SPEED, 0.1)
		main.missile_fx.rpc(muzzle, at, flight)
		get_tree().create_timer(flight).timeout.connect(main.player_cannon_land.bind(
				origin, at, hit.normal if hit else Vector3.UP, wall, r, dmg, get_multiplayer_authority()))
		return
	if hit and hit.collider.has_method("hit_scale"):
		dmg = maxi(1, int(round(dmg * hit.collider.hit_scale(hit.position, origin))))     # weak points
	if hit and hit.collider.has_method("apply_damage"):
		hit.collider.apply_damage(dmg, self)
	elif hit and hit.collider.has_meta("prop_index"):
		get_tree().current_scene.props.damage_prop(hit.collider.get_meta("prop_index"), dmg)
	# gunshots are heard: nearby patrolling robots come to look where it came from
	for e in get_tree().current_scene.enemies_root.get_children():
		e.heard(origin)
	for c in get_tree().get_nodes_in_group("civilians"):
		c.heard(origin)


func _impact(at: Vector3, normal: Vector3, metal: bool) -> void:
	var parts := CPUParticles3D.new()
	parts.one_shot = true
	parts.amount = 14
	parts.explosiveness = 1.0
	parts.lifetime = 0.45
	parts.direction = normal
	parts.spread = 35.0
	parts.initial_velocity_min = 1.5
	parts.initial_velocity_max = 4.0
	parts.gravity = Vector3(0, -6, 0)
	var m := SphereMesh.new()
	m.radius = 0.025
	m.height = 0.05
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0.75, 0.3) if metal else Color(0.65, 0.62, 0.58)
	m.material = mat
	parts.mesh = m
	get_tree().current_scene.add_child(parts)
	parts.global_position = at + normal * 0.05
	parts.emitting = true
	get_tree().create_timer(1.0).timeout.connect(parts.queue_free)


## Every peer: leaves falling where this player's shot went through a tree.
@rpc("any_peer", "call_local", "unreliable")
func shake_leaves(at: Vector3) -> void:
	var main := get_tree().current_scene
	if main.get("props"):
		main.props.leaves(at)


## Other peers hear this player's shots at its position.
@rpc("any_peer", "call_remote", "unreliable")
func gunshot_fx(w: String) -> void:
	Sfx.play_at(w, global_position + Vector3(0, 1.5, 0), -2.0)
	get_tree().call_group("pigeons", "scare", global_position)


## Server-side check used by pickups and director drops.
## A pickup you walked over but could not take: say why (once in a while).
var _refused_t := 0.0
@rpc("any_peer", "call_local", "reliable")
func refused(kind: String) -> void:
	if not is_multiplayer_authority() or Time.get_ticks_msec() / 1000.0 - _refused_t < 4.0:
		return
	_refused_t = Time.get_ticks_msec() / 1000.0
	if kind in ["circuit", "core", "lens", "module"]:
		_toast_text("POCKETS FULL (%d/%d): trade parts at a repair shop%s" % [parts_total(), parts_cap(),
				"" if has_bag else ", or find a mala de garupa to carry 30"])


func can_take(kind: String) -> bool:
	match Entities.get_def(kind).get("category", ""):
		"healing":
			return health < MAX_HEALTH
		"armour":
			return armor < MAX_ARMOR
		"booster":
			return _adrenaline <= 0
	match kind:
		"medkit", "churrasco", "chimarrao", "remedio":
			return health < MAX_HEALTH
		"fruki":
			return _adrenaline <= 0
		"pala":
			return armor < MAX_ARMOR
		"circuit", "core", "lens", "module":
			return parts_total() < parts_cap()       # pockets full: a mala de garupa holds more
		"mala_garupa":
			return not has_bag
		"oculos":
			return not has_glasses
		"bateria":
			return true
		"ammo":
			for w in owned:
				if _reserves[w] < WEAPONS[w]["reserve_max"]:
					return true
			return false
		"pistol", "machinegun", "revolver", "shotgun", "espeto", "canhao":
			return not kind in owned or _reserves[kind] < WEAPONS[kind]["reserve_max"]
		"laco":
			return not "laco" in owned
		"bergamota", "porongo":
			return grenades[kind] < GRENADE_MAX
	return false


## Q: the grenade picked (Z) goes out along the view, in an arc; the server
## throws it on every peer (main.throw_grenade).
func _throw_grenade() -> void:
	if dead or design or vehicle or (_tablet and _tablet.visible) or _grenade_cd > 0.0:
		return
	if grenades[grenade] <= 0:
		var other := "porongo" if grenade == "bergamota" else "bergamota"
		if grenades[other] > 0:
			grenade = other
		else:
			_toast_text("No grenades - Bergamotas and Porongos lie about the city")
			return
	grenades[grenade] -= 1
	_grenade_cd = 0.8
	var fwd := -camera.global_transform.basis.z
	var origin := camera.global_position + fwd * 0.6 + camera.global_transform.basis.x * 0.25 - Vector3(0, 0.15, 0)
	get_tree().current_scene.throw_grenade.rpc_id(1, grenade, origin, fwd)
	Sfx.play("reload", -10.0)


## Item granted by the server (pickup touched or director drop).
@rpc("any_peer", "call_local", "reliable")
func give(kind: String) -> void:
	if not multiplayer.get_remote_sender_id() in [0, 1] or not is_multiplayer_authority():
		return
	# healing, armour and boosters act by their definition's effect
	var d: Dictionary = Entities.get_def(kind)
	_picked.call_deferred(kind, d)
	if d.get("category", "") in ["healing", "armour", "booster"]:
		var fx: Dictionary = d.get("effect", {})
		health = min(MAX_HEALTH, health + int(fx.get("heal", 0)))
		if fx.has("armor"):
			armor = min(MAX_ARMOR, armor + int(fx["armor"]))
		if fx.has("adrenaline"):
			_adrenaline = float(fx["adrenaline"])
		Sfx.play("pickup", -6.0)
		if _damage_flash:
			_damage_flash.color = Color(0.2, 0.9, 0.3, 0.25)
		return
	match kind:
		"medkit", "churrasco":
			health = min(MAX_HEALTH, health + 35)
		"chimarrao":
			health = min(MAX_HEALTH, health + 20)    # a mate restores a bit less
		"remedio":
			health = min(MAX_HEALTH, health + 50)    # from the pharmacy counter
		"fruki":
			health = min(MAX_HEALTH, health + 25)    # guaraná: the adrenaline shot
			_adrenaline = Tune.adrenaline_s
		"pala":
			armor = MAX_ARMOR
		"circuit", "core", "lens", "module":
			parts[kind] = parts.get(kind, 0) + 1
		"mala_garupa":
			has_bag = true
		"oculos":
			has_glasses = true
			if glasses:
				glasses.recharge()
		"bateria":
			_battery_bonus += 60.0               # the drone flies longer...
			if glasses:
				glasses.recharge()              # ...and the glasses are full again
		"ammo":
			for w in owned:
				var amount: int = AMMO_PICKUP.get(w, 24)
				_reserves[w] = min(WEAPONS[w]["reserve_max"], _reserves[w] + amount)
		"bergamota", "porongo":
			grenades[kind] = mini(GRENADE_MAX, grenades[kind] + 2)
			if grenades[grenade] == 0:
				grenade = kind
		"laco":
			if not "laco" in owned:
				owned.append("laco")
				_mags["laco"] = 1
				_reserves["laco"] = 0
			_switch("laco")
		"pistol", "machinegun", "revolver", "shotgun", "espeto", "canhao":
			if not kind in owned:
				owned.append(kind)
				_mags[kind] = WEAPONS[kind]["mag"]
				_switch(kind)
			_reserves[kind] = min(WEAPONS[kind]["reserve_max"], _reserves[kind] + WEAPONS[kind]["start_reserve"] * 2)
	Sfx.play("pickup", -6.0)
	if _damage_flash:
		_damage_flash.color = Color(0.2, 0.9, 0.3, 0.25)


## What was picked up, for a moment under the crosshair (parts with the count held).
func _picked(kind: String, d: Dictionary) -> void:
	if _toast == null:
		return
	var text := "+ " + String(d.get("name", kind.capitalize()))
	if parts.has(kind):
		text += "   (%d)" % parts[kind]
	# what it does, so it is clear from the first one picked up
	var fx: Dictionary = d.get("effect", {}) if d.get("category", "") in ["healing", "armour", "booster"] else {}
	var says := []
	if int(fx.get("heal", 0)) > 0:
		says.append("Health +%d" % int(fx["heal"]))
	if int(fx.get("armor", 0)) > 0:
		says.append("Armor +%d" % int(fx["armor"]))
	if float(fx.get("adrenaline", 0.0)) > 0.0:
		says.append("Adrenaline %d s (faster)" % int(fx["adrenaline"]))
	if not says.is_empty():
		text += "   ·   " + "   ".join(says)
	_toast.text = text
	_toast.modulate.a = 1.0
	if _toast.has_meta("tw"):
		var old: Tween = _toast.get_meta("tw")
		if old and old.is_valid():
			old.kill()
	var tw := create_tween()
	tw.tween_interval(1.6 if says.is_empty() else 3.0)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.6)
	_toast.set_meta("tw", tw)


@rpc("any_peer", "call_local", "reliable")
func hurt(amount: int, from: Vector3) -> void:
	if not is_multiplayer_authority() or dead or get_meta("god", false) or _spawn_shield > 0:
		return
	if _drone:
		_land_drone()                    # your body is under fire: back to it
	if vehicle and vehicle.HP.has(vehicle.kind):
		# at the wheel of a motor vehicle: the vehicle takes the hit
		vehicle.vehicle_hit.rpc_id(1, amount)
		return
	if armor > 0:
		# the pala takes half the hit until it is worn through
		var absorbed: int = min(armor, int(ceil(amount * Tune.pala_absorb)))
		armor -= absorbed
		amount -= absorbed
	health -= amount
	if _damage_flash:
		_damage_flash.color = Color(0.8, 0, 0, 0.45)
		# red dot around the crosshair pointing at the shooter
		var local := global_transform.basis.inverse() * (from - global_position)
		var ang := atan2(local.x, -local.z)
		var centre := get_viewport().get_visible_rect().size / 2
		_hit_marker.position = centre + Vector2(sin(ang), -cos(ang)) * 140 - Vector2(14, 28)
		_hit_marker.modulate.a = 1.0
	report_hurt.rpc_id(1, amount)
	if health <= 0:
		health = 0
		dead = true
		if vehicle:
			request_exit.rpc_id(1)
		await get_tree().create_timer(Difficulty.get_value("respawn_s")).timeout
		_respawn(_safe_spawn())


func _respawn(at: Vector3) -> void:
	position = at
	velocity = Vector3.ZERO
	health = MAX_HEALTH
	if dead and Difficulty.get_value("death_penalty") > 0:
		get_tree().current_scene.death_penalty.rpc_id(1)
	# back with empty hands: weapons, ammo, laço, pala, drones and parts are gone
	parts = {"circuit": 0, "core": 0, "lens": 0, "module": 0}
	has_bag = false
	has_glasses = false
	if glasses and glasses.on:
		glasses.toggle()
	armor = 0
	drones = 0
	owned = []
	weapon = "hands"
	_mags = EMPTY_MAGS.duplicate()
	_reserves = EMPTY_MAGS.duplicate()
	_reload_left = 0.0
	_show_weapon()
	_spawn_shield = 2.0
	dead = false


## Respawn point while the round goes on: a reachable street point far from
## living robots and out of their sight, preferably near a living teammate.
func _safe_spawn() -> Vector3:
	var main := get_tree().current_scene
	var map := get_world_3d().navigation_map
	var robots := []
	for e in main.enemies_root.get_children():
		if e.is_alive():
			robots.append(e.global_position)
	if robots.is_empty():
		return spawn_point
	var mates := []
	for pl in get_tree().get_nodes_in_group("players"):
		if pl != self and not pl.dead:
			mates.append(pl.global_position)
	var space := get_world_3d().direct_space_state
	var best := spawn_point
	var best_score := -INF
	for attempt in 60:
		var c := NavigationServer3D.map_get_random_point(map, 1, true)
		if not get_tree().current_scene.in_bounds(c, 10.0):
			continue
		var path := NavigationServer3D.map_get_path(map, spawn_point, c, true)
		if path.is_empty() or path[path.size() - 1].distance_to(c) > 1.0:
			continue          # not on the street network the round started on
		var nearest := INF
		var seen := false
		for r in robots:
			var d: float = c.distance_to(r)
			nearest = min(nearest, d)
			if d < 50.0 and not seen:
				var q := PhysicsRayQueryParameters3D.create(c + Vector3(0, 1.6, 0), r + Vector3(0, 1.5, 0), 1)
				seen = space.intersect_ray(q).is_empty()
		var score: float = min(nearest, 80.0) - (60.0 if seen else 0.0)
		for m in mates:
			if c.distance_to(m) < 25.0:
				score += 15.0
				break
		if score > best_score:
			best_score = score
			best = c
	return best + Vector3(0, 0.3, 0)


## Next phase: the new city is loaded, walk in at its start (keeps health,
## weapons and ammo).
@rpc("any_peer", "call_local", "reliable")
func arrive(at: Vector3) -> void:
	if not multiplayer.get_remote_sender_id() in [0, 1] or not is_multiplayer_authority():
		return
	spawn_point = at
	position = at + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	velocity = Vector3.ZERO
	_spawn_shield = 3.0


## Full round reset, sent by the server to every player.
@rpc("any_peer", "call_local", "reliable")
func reset_round() -> void:
	if not multiplayer.get_remote_sender_id() in [0, 1] or not is_multiplayer_authority():
		return
	_respawn(spawn_point + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2)))
	team_kills = 0


@rpc("any_peer", "call_local", "reliable")
func report_hurt(amount: int) -> void:
	if multiplayer.is_server():
		get_tree().call_group("director", "on_player_hurt", get_multiplayer_authority(), amount)


## Called by the server for every player when director state changes.
@rpc("any_peer", "call_local", "reliable")
func set_status(phase: String, kills: int, alive := 0, dead := 0, banner := "",
		goal_total := 0, extra := 0, lost := 0, exit := false, mech_kills := 0, mech_total := 0, relay := 0) -> void:
	objective = banner
	antenna = relay
	mechs = mech_kills
	mech_goal = mech_total
	goal = goal_total
	goal_extra = extra
	civ_lost = lost
	exit_open = exit
	civ_alive = alive
	civ_dead = dead
	if phase == "RELAX" and director_phase != "RELAX":
		for w in owned:      # breather: restock ammo
			_reserves[w] = max(_reserves[w], WEAPONS[w]["start_reserve"])
	director_phase = phase
	team_kills = kills
