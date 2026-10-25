extends Node3D
## City Invaders: loads the OSM/Mapillary city with street furniture,
## sky and sun, bakes a navigation mesh, and runs a co-op shooter round:
## players host or join (ENet), the server-side AI Director sends robot
## waves through the real streets.

const PORT := 24680
## Cities built by tools/map/osm2gltf.py into res://city/<id>.glb (+ _horizon,
## _collision, .spawn/.props/.roads.json). Only the ones present are offered.
## id, menu label, next phase (reached through an exit once `goal` robots are
## destroyed; "" = last phase: reaching the goal liberates the city), goal.
## Every 2 civilians the robots kill add 1 robot to the goal. An optional 5th
## column says on which side the exit opens ("east" by default, "north"):
## the next map starts on the street where this one ends.
const MAPS := [
	["gasometro", "Phase 1 · Usina do Gasômetro", "centro", 25],
	["centro", "Phase 2 · Centro Histórico", "mercado", 30, "north"],
	["mercado", "Phase 3 · Mercado Público", "", 30],
	["poa", "Centro (whole, free play)", "", 0],
]
const VISUAL_ONLY := ["sidewalk", "curb"]   # their collision comes from <city>_collision.glb
## road paint sits 1.2 cm above the asphalt: as collision every stripe edge is
## a tiny step and the camera bobs across zebra crossings
const NO_COLLISION := ["paint_white", "paint_yellow", "water"]   # water: the quay parapet stops people
## roofs collide on their own layer: kept out of the street navmesh (with
## terrain the bake height range would otherwise make low roofs into
## unreachable islands robots try to walk to), still seen by the dropship
const ROOFS := ["concrete_roof", "tile_roof"]
const ROOF_LAYER := 64
const MENU_BG := "res://assets/ui/menu_bg.png"
const Player := preload("res://scripts/player.gd")
const Enemy := preload("res://scripts/enemy.gd")
const Props := preload("res://scripts/props.gd")
const Director := preload("res://scripts/director.gd")
const Pickup := preload("res://scripts/pickup.gd")
const Civilian := preload("res://scripts/civilian.gd")
const Car := preload("res://scripts/car.gd")
const Dropship := preload("res://scripts/dropship.gd")
const ControlsMenu := preload("res://scripts/controls_menu.gd")
const Wreck := preload("res://scripts/wreck.gd")
const MapEditor := preload("res://scripts/map_editor.gd")
const EditorTools := preload("res://scripts/editor_tools.gd")
const LandmarkSite := preload("res://scripts/landmark_site.gd")
const Studio := preload("res://scripts/studio.gd")
const Inspector := preload("res://scripts/inspector.gd")
const Edits := preload("res://scripts/edits.gd")
const Photos := preload("res://scripts/photos.gd")
const EditorMenu := preload("res://scripts/editor_menu.gd")
const Pigeon := preload("res://scripts/pigeon.gd")
const Drone := preload("res://scripts/drone.gd")
const FLOCKS := 7
const CIVILIANS := 26         # for a 300 m city; scaled by density()
const TRAFFIC := 16
## pickups per map, by role (the collection's roles.json picks the object:
## churrasco, chimarrão, Fruki... in Rio Grande do Sul) or by id
const PICKUP_COUNTS := {"pistol": 8, "espeto": 4, "healing_big": 7, "healing_small": 9, "armour": 3, "booster": 5,
		"ammo": 12, "machinegun": 4, "revolver": 3, "shotgun": 3, "laco": 2, "mala_garupa": 2, "oculos": 1, "bateria": 2,
		"bergamota": 4, "porongo": 3}
## the collection whose roles a map uses (all bundled maps are Porto Alegre)
var collection := "rio_grande_do_sul"
const Entities := preload("res://scripts/entities.gd")

var spawn_point := Vector3(0, 1, 0)
var map_id := ""             # loaded city, "" until one is chosen (or the host tells us)
var driven := false          # started by the DevAgent: leave the mouse free
var nav_ready := false       # street navmesh baked (pickups, robots, pedestrians need it)
var map_select: OptionButton
var phase_select: OptionButton
var players_root: Node3D
var enemies_root: Node3D
var pickups_root: Node3D
var civilians_root: Node3D
var traffic_root: Node3D
var civ_spawner: MultiplayerSpawner
var car_spawner: MultiplayerSpawner
var ships_root: Node3D
var ship_spawner: MultiplayerSpawner
var _ship_seq := 0
var map_half := 150.0        # half size of a square city (older <city>.spawn.json)
var bounds := Rect2(-150, -150, 300, 300)   # playable area in x/z (from <city>.spawn.json)
var crowd: Array = []        # promenade points (Vector3): more pedestrians there
var elev := Vector2(0, 0)    # ground height range of the city (terrain)
var _map_nodes: Array = []   # everything _load_city built (freed on a phase change)
var _exit: Node3D            # server: the beacon to the next phase, once open
var _phase_kills := 0
var _phase_mechs := 0        # heavy mechs destroyed this phase (by anyone)
## (robot and mech goals per phase: difficulty.gd)
var _phase_civ_lost := 0     # civilians killed by robots this phase (raises the goal)
var _victory := false
var _changing := false
var _controls: Control
var _sound_buttons: Array = []
var _ff_buttons: Array = []
## score per player (peer id -> points), server-side; players see theirs
const POINTS := {"trooper": 100, "drone": 150, "mech": 500, "collector": 300, "swarm": 40, "civilian": -100, "civilian_robot": -20, "phase": 1000}
var scores := {}
var landmark_pickups: Array = []     # [kind, position] from landmark models (fixed spots)
var city_top := 0.0          # highest roof of the loaded city (dropship cruise altitude)
var road_graph := {}
var civ_killed := 0
var _civ_seq := 0
var _car_seq := 0
var _civ_cd := 0.0
var _round_live := false
var props: Node3D
var pickup_spawner: MultiplayerSpawner
var _pickup_seq := 0
var spawner: MultiplayerSpawner
var enemy_spawner: MultiplayerSpawner
var nav_region: NavigationRegion3D
var director: Node
var menu: Control
var address_edit: LineEdit
var name_edit: LineEdit
var status_label: Label
var paused := false
## design mode (solo): the world freezes, the player flies through it without
## colliding - to look at buildings and characters up close, or point them out
var design := false
var _design_from: Transform3D
var _design_pitch := 0.0
var pause_menu: Control
var restart_button: Button
var _enemy_seq := 0
var _status_cd := 0.0
var _res_cd := 2.0
var _loading: Control
var _load_title: Label
var _load_bar: ProgressBar
var _load_step: Label


func _ready() -> void:
	# main keeps listening for Esc while paused; its world children still pause
	process_mode = Node.PROCESS_MODE_ALWAYS
	# physics interpolation is on in the project but only vehicles use it
	# (car.gd): they move at the physics rate, the screen draws faster
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# a slow frame runs at most 3 physics steps: the game slows down a little
	# instead of spiralling (each catch-up step made the next frame slower)
	Engine.max_physics_steps_per_frame = 3
	_setup_environment()
	players_root = _root("Players")
	enemies_root = _root("Enemies")
	spawner = _spawner("PlayerSpawner", players_root, _spawn_player)
	enemy_spawner = _spawner("EnemySpawner", enemies_root, _spawn_enemy_node)
	pickups_root = _root("Pickups")
	pickup_spawner = _spawner("PickupSpawner", pickups_root, _spawn_pickup_node)
	civilians_root = _root("Civilians")
	civ_spawner = _spawner("CivilianSpawner", civilians_root, _spawn_civilian_node)
	traffic_root = _root("Traffic")
	car_spawner = _spawner("CarSpawner", traffic_root, _spawn_car_node)
	ships_root = _root("Ships")
	ship_spawner = _spawner("ShipSpawner", ships_root, _spawn_ship_node)
	director = Director.new()
	director.name = "Director"
	director.add_to_group("director")
	director.enemies_root = enemies_root
	director.spawn_enemy = func(pos): enemy_spawner.spawn({"id": _next_enemy_id(), "pos": pos})
	director.drop_item = func(kind, pos): _spawn_pickup(kind, pos, false)
	director.call_ship = call_dropship
	director.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(director)
	_build_menu()
	_build_pause_menu()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): status_label.text = "Connected")
	multiplayer.connection_failed.connect(func():
		status_label.text = "Connection failed"
		if _loading:
			_hide_loading()
		menu.visible = true)
	_maybe_screenshot()
	if _pending_edit != "":
		# the editor's File > Open phase: straight into that phase's design mode
		var id := _pending_edit
		_pending_edit = ""
		_studio_edit.call_deferred(id)


## Retina screens render ~16 Mpx per frame: scale the 3D render (FSR
## upscaled, HUD stays sharp) between 50% and 100% to hold about 60 fps.
var dynamic_resolution := true    # off for measurements (DevAgent perf runs)
func _dynamic_resolution(delta: float) -> void:
	_res_cd -= delta
	if _res_cd > 0 or not dynamic_resolution:
		return
	_res_cd = 1.0
	var vp := get_viewport()
	var fps := Engine.get_frames_per_second()
	var scale := vp.scaling_3d_scale
	if _res_trial_fps > 0.0:
		# a step down two seconds ago: kept only if it bought frames; if not,
		# the card was not the bottleneck (physics, scripts) - back up, and
		# no more tries for a while
		_res_trial_t -= 1.0
		if _res_trial_t > 0.0:
			return
		if fps < _res_trial_fps * 1.06:
			_set_render_scale(minf(1.0, scale + RES_STEP))
			_res_hold = 20.0
		_res_trial_fps = 0.0
		return
	_res_hold = maxf(0.0, _res_hold - 1.0)
	if fps < 54 and scale > RES_MIN + 0.01 and _res_hold <= 0.0:
		_res_trial_fps = fps
		_res_trial_t = 2.0
		_set_render_scale(maxf(RES_MIN, scale - RES_STEP))
	elif scale < _res_max - 0.01 and fps > 80:
		_set_render_scale(minf(_res_max, scale + RES_STEP))


const RES_MIN := 0.5
const RES_STEP := 0.08
const RES_PIXELS := 6.0e6          # what AUTO aims to draw at most: ~1440p of pixels
var _res_trial_fps := 0.0
var _res_trial_t := 0.0
var _res_hold := 0.0
var _res_max := 1.0


## AUTO's start: big screens (4K, ultrawide, Retina) are drawn at the scale
## that keeps about RES_PIXELS, a 1080p one at full size; it adapts from there.
func _auto_resolution_start() -> void:
	var px: Vector2 = Vector2(get_viewport().get_visible_rect().size) * get_window().content_scale_factor
	if get_window():
		px = Vector2(get_window().size)              # the window's real pixels
	var pixels := float(px.x) * float(px.y)
	_res_max = clampf(sqrt(RES_PIXELS / maxf(pixels, 1.0)), RES_MIN, 1.0)
	_set_render_scale(_res_max)


## The 3D picture at `scale` of the screen; below full size an upscaler
## brings it to the screen: MetalFX on a Mac (done by Apple's hardware), FSR 1
## elsewhere. FSR 2 was measured too: it runs at the screen's own resolution
## and on a large screen cost more than it saved (85 % slower than 100 %).
func _set_render_scale(scale: float) -> void:
	var vp := get_viewport()
	var up := Viewport.SCALING_3D_MODE_METALFX_SPATIAL if OS.get_name() == "macOS" else Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_mode = up if scale < 0.99 else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = scale


func _root(n: String) -> Node3D:
	var r := Node3D.new()
	r.name = n
	r.process_mode = Node.PROCESS_MODE_PAUSABLE    # main runs always (Esc), the world pauses
	add_child(r)
	return r


func _spawner(n: String, root: Node, fn: Callable) -> MultiplayerSpawner:
	var s := MultiplayerSpawner.new()
	s.name = n
	add_child(s)
	s.spawn_path = s.get_path_to(root)
	s.spawn_function = fn
	return s


func _process(delta: float) -> void:
	_dynamic_resolution(delta)
	_performance_guard(delta)
	if get_tree().paused:
		return                 # no spawning in a paused world (design mode, Esc): they would hang in the air
	_bubble(delta)

	_update_screens()
	# broadcast director state to every player's HUD
	if not multiplayer.is_server():
		return
	_status_cd -= delta
	if _status_cd > 0:
		return
	_status_cd = 0.5
	var phase: String = Director.Phase.keys()[director.phase]
	var alive := 0
	var people := 0
	for c in civilians_root.get_children():
		if c.is_alive():
			alive += 1
			if not c.dog:
				people += 1
	var banner := _objective_text()
	var goal := _goal()
	for p in players_root.get_children():
		p.set_status.rpc(phase, director.kills - _phase_kills, people, civ_killed, banner,
				goal, max(0, goal - _map_spec(map_id)[3]) if goal > 0 else 0, _phase_civ_lost, _exit != null,
				min(_phase_mechs, _mech_goal()), _mech_goal(), antenna_state())
	_check_phase_goal()
	_check_phase_failed()
	# keep the streets populated: new pedestrians appear out of sight
	if _round_live:
		_civ_cd -= 0.5
		if _civ_cd <= 0 and alive < civilians_wanted():
			_civ_cd = 4.0
			_spawn_civilians(min(3, civilians_wanted() - alive))


## Test hook: `godot --path godot -- --shot=/tmp/x.png [--yaw=deg] [--wait=s]`
## starts solo, saves one frame and quits.
func _maybe_screenshot() -> void:
	var shot := ""
	var yaw := 0.0
	var wait := 4.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.substr(7)
		elif arg.begins_with("--yaw="):
			yaw = float(arg.substr(6))
		elif arg.begins_with("--wait="):
			wait = float(arg.substr(7))
		elif arg.begins_with("--pos="):
			var c := arg.substr(6).split(",")
			spawn_point = Vector3(float(c[0]), float(c[1]), float(c[2]))
	if shot == "":
		return
	await enter_map(_selected_map())
	menu.visible = false
	var p := _spawn_player({"id": 1, "name": "shot"})
	players_root.add_child(p)
	p.rotation_degrees.y = yaw
	await get_tree().create_timer(wait).timeout
	get_viewport().get_texture().get_image().save_png(shot)
	print("cam ", p.camera.global_position, " current ", p.camera.current, " enemies alive: ", enemies_root.get_child_count(), " director: ",
			Director.Phase.keys()[director.phase])
	get_tree().quit()


func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.45, 0.85)
	sky_mat.sky_horizon_color = Color(0.66, 0.78, 0.92)
	sky_mat.ground_bottom_color = Color(0.25, 0.25, 0.25)
	sky_mat.ground_horizon_color = Color(0.6, 0.62, 0.65)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.35
	env.ambient_light_color = Color(0.62, 0.62, 0.64)
	env.ambient_light_energy = 0.9
	# AgX keeps bright facades and the sky from clipping to flat white
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.05
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.05
	env.glow_enabled = true            # emissive eyes, rifles, lamps and tracers bloom a little
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.ssao_enabled = true
	env.ssao_intensity = 1.6
	env.ssao_radius = 1.2
	env.ssil_enabled = true            # sunlit walls bounce colour onto the street and their neighbours
	env.ssil_intensity = 0.9           # (graphics "high" only: see apply_graphics)
	env.fog_enabled = true
	env.fog_density = 0.0016          # distant towers fade into haze
	env.fog_light_color = Color(0.78, 0.84, 0.92)
	env.fog_sky_affect = 0.2
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	apply_graphics()
	if not Settings.changed.is_connected(apply_graphics):
		Settings.changed.connect(apply_graphics)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Porto Alegre, early afternoon: sun high in the north (southern hemisphere)
	sun.rotation_degrees = Vector3(-58, 160, 0)
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	sun.light_angular_distance = 0.6   # the sun's disc: shadows soften away from their caster
	sun.shadow_blur = 1.5
	add_child(sun)
	apply_graphics()



## The city (and its navmesh bake) only starts when a map is chosen, so
## anything placed on the navmesh at round start has to wait for the bake:
## before that the navigation map exists but is empty.
func wait_for_navmesh() -> void:
	while not nav_ready:
		await get_tree().process_frame
	# the baked mesh reaches the navigation map asynchronously (a big city
	# takes a few syncs): wait until it really answers path queries
	var map := get_world_3d().navigation_map
	for attempt in 600:
		await get_tree().physics_frame
		var p := NavigationServer3D.map_get_random_point(map, 1, true)
		if p != Vector3.ZERO and NavigationServer3D.map_get_path(map, spawn_point, p, true).size() > 1:
			return


## The built-in phases plus maps imported with tools/map/new_city.py (listed in
## godot/city/maps.json as [id, label, next, goal, exit side]).
static func all_maps() -> Array:
	var out: Array = MAPS.duplicate()
	if FileAccess.file_exists("res://city/maps.json"):
		var extra = JSON.parse_string(FileAccess.get_file_as_string("res://city/maps.json"))
		if extra is Array:
			for m in extra:
				if not out.any(func(o): return o[0] == m[0]):
					out.append(m)
	return out


func _map_spec(id: String) -> Array:
	for m in all_maps():
		if m[0] == id:
			return m
	return [id, id, "", 0]


func _exit_side() -> String:
	var m := _map_spec(map_id)
	return m[4] if m.size() > 4 else "east"


## Robots to destroy this phase: the base goal plus one for every two
## civilians the robots have killed.
func _goal() -> int:
	var m := _map_spec(map_id)
	if m[3] <= 0:
		return 0
	var goals: Dictionary = Difficulty.get_value("goals")
	var base: int = goals[map_id] if goals.has(map_id) else int(round(m[3] * Difficulty.get_value("goal_scale")))
	return base + _phase_civ_lost / 2


## Heavy mechs to destroy this phase (none on free-play maps).
func _mech_goal() -> int:
	return 0 if _map_spec(map_id)[3] <= 0 else Difficulty.get_value("mechs").get(map_id, Difficulty.get_value("mech_default"))


func _objective_text() -> String:
	var m := _map_spec(map_id)
	if m[3] <= 0:
		return m[1]
	if _victory:
		return "%s LIBERATED! - Esc for the menu" % m[1].get_slice(" · ", 1).to_upper()
	if _announce_t > 0.0 and _announce_text != "":
		return _announce_text
	if _phase_failed:
		return "TOO MANY PEOPLE LOST - the robots hold %s. Starting over..." % m[1]
	if _exit:
		return "EXIT OPEN - follow the green beacon to %s" % _map_spec(m[2])[1]
	return "%s [%s] - destroy %d robots, %d mechs and their relay antenna, protect the people" % [m[1], Difficulty.label(), _goal(), _mech_goal()]


## Server: once the phase goal is reached, open an exit on the map border
## (the street end farthest towards the next city, east by default).
## Server: points to one player (peer) or to everybody (peer 0).
## Server: a player died (medium / hard cost points).
@rpc("any_peer", "call_local", "reliable")
func death_penalty() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	award(peer if peer != 0 else 1, -int(Difficulty.get_value("death_penalty")), "died")


func award(peer: int, points: int, reason: String) -> void:
	if not multiplayer.is_server():
		return
	for p in players_root.get_children():
		var id := p.get_multiplayer_authority()
		if peer == 0 or id == peer:
			scores[id] = scores.get(id, 0) + points
			p.set_score.rpc_id(id, scores[id], points, reason)


## Server: what a downed robot leaves on the street (picked up within 40 s).
const DROPS := {"trooper": ["circuit"], "mech": ["core", "circuit", "circuit"], "drone": ["lens"],
		"collector": ["module", "circuit"]}
func _drop_parts(e) -> void:
	# after the robot has come apart (enemy.gd: a trooper bursts 0.35 s after it
	# falls, a mech once it has toppled), not the moment it dies
	var kind: String = e.get("variant") if e.get("variant") else "trooper"
	get_tree().create_timer(1.7 if kind == "mech" else 0.45).timeout.connect(
			_drop_parts_at.bind(kind, (e as Node3D).global_position))


func _drop_parts_at(kind: String, where: Vector3) -> void:
	var list: Array = DROPS.get(kind, []).duplicate()
	if kind == "trooper" and randf() < 0.5:
		list.append("circuit")
	var map := get_world_3d().navigation_map
	for k in list:
		var at := NavigationServer3D.map_get_closest_point(map, where
				+ Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5)))
		var pk := _spawn_pickup(k, at, false)
		if pk:
			# bound to the pickup itself: taken before then, the timer just lets go
			# (a lambda holding it reported "Lambda capture was freed")
			get_tree().create_timer(40.0).timeout.connect(pk.queue_free)


func _on_robot_killed(e) -> void:
	_drop_parts(e)
	if e.get("variant") == "mech":
		# a downed mech leaves its arm cannon: a heavy weapon for whoever gets
		# there - once it has toppled and come apart
		get_tree().create_timer(1.7).timeout.connect(_drop_cannon_at.bind((e as Node3D).global_position))
	if e.get("variant") == "mech":
		_phase_mechs += 1
	if e.get("commander") and e.killed_by_player:
		award(e.killer_peer, 1500, "robot commander destroyed")
	if e.killed_by_player:
		var kind: String = e.get("variant") if e.get("variant") else "trooper"
		award(e.killer_peer, POINTS.get(kind, 100), {"mech": "mech destroyed", "drone": "drone shot down",
				"collector": "Coletor destroyed"}.get(kind, "robot destroyed"))


## Hard: losing this share of the people the phase began with loses it -
## the round starts over.
var _phase_civ_start := 0
var _phase_failed := false
func _check_phase_failed() -> void:
	var share: float = Difficulty.get_value("civ_fail")
	if share <= 0.0 or _phase_failed or _victory or _phase_civ_start <= 0 or not multiplayer.is_server():
		return
	if _phase_civ_lost >= ceili(share * _phase_civ_start):
		_phase_failed = true
		director.set_process(false)
		Sfx.play("robot_death", 0.0)
		await get_tree().create_timer(7.0).timeout
		_phase_failed = false
		_restart_round()


func _check_phase_goal() -> void:
	var m := _map_spec(map_id)
	if _exit or _changing or _victory or m[3] <= 0 or director.kills - _phase_kills < _goal() \
			or _phase_mechs < _mech_goal() or antenna_state() % 10 in [1, 2]:
		return
	if m[2] == "":
		_victory = true            # last phase: the city is liberated
		director.set_process(false)
		Sfx.play("pickup", 0.0)
		award(0, POINTS["phase"], "city liberated")
		return
	var best := Vector3.INF
	for e in road_graph.get("entries", []):
		var edge: Dictionary = road_graph["edges"][e[0]]
		var n: Array = road_graph["nodes"][int(edge["a"]) if e[1] else int(edge["b"])]
		var p := Vector3(n[0], 0, n[1])
		var north := _exit_side() == "north"
		if best == Vector3.INF or (p.z < best.z if north else p.x > best.x):
			best = p
	if best == Vector3.INF:
		best = Vector3(bounds.end.x - 15, 0, bounds.get_center().y)
	var map := get_world_3d().navigation_map
	var inward := Vector3(0, 0, 8.0) if _exit_side() == "north" else Vector3(-sign(best.x) * 8.0, 0, 0)
	best = NavigationServer3D.map_get_closest_point(map, best + inward)
	open_exit.rpc(best)


## Every peer: the green beacon; the server watches who walks into it.
@rpc("authority", "call_local", "reliable")
func open_exit(at: Vector3) -> void:
	_exit = Node3D.new()
	_exit.position = at
	_exit.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_exit)
	_map_nodes.append(_exit)
	var col := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.6
	cyl.bottom_radius = 2.2
	cyl.height = 60.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.3, 1.0, 0.45, 0.28)
	cyl.material = mat
	col.mesh = cyl
	col.position.y = 30.0
	col.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_exit.add_child(col)
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 1.0, 0.45)
	light.light_energy = 4.0
	light.omni_range = 12.0
	light.position.y = 2.0
	_exit.add_child(light)
	Sfx.play("pickup", 0.0)
	if multiplayer.is_server():
		var area := Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4          # players
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.5
		cs.shape = sph
		cs.position.y = 1.0
		area.add_child(cs)
		_exit.add_child(area)
		area.body_entered.connect(func(b):
			if b.is_in_group("players") and not b.dead:
				_go_next_phase())


@rpc("authority", "call_local", "reliable")
func close_exit() -> void:
	if is_instance_valid(_exit):
		_map_nodes.erase(_exit)
		_exit.queue_free()
	_exit = null


func _go_next_phase() -> void:
	if _changing:
		return
	_changing = true
	change_phase.rpc(_map_spec(map_id)[2])


## Every peer: drop the current city and load the next one; the server then
## repopulates it and walks every player in at its start.
@rpc("authority", "call_local", "reliable")
func change_phase(next_id: String) -> void:
	# phase maps overlap at their border: arrive where the exit was
	_arrive_at = _exit.global_position if is_instance_valid(_exit) else Vector3.INF
	_changing = true
	_round_live = false
	if multiplayer.is_server():
		for root in [enemies_root, civilians_root, traffic_root, pickups_root, ships_root]:
			for c in root.get_children():
				c.queue_free()
	for n in _map_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_map_nodes.clear()
	_exit = null
	map_id = ""
	nav_ready = false
	road_graph = {}
	crowd = []
	city_top = 0.0
	await get_tree().process_frame
	await enter_map(next_id)
	if multiplayer.is_server():
		director.reset()
		director.set_process(true)
		_phase_kills = director.kills
		_phase_mechs = 0
		_phase_civ_lost = 0
		_phase_civ_start = civilians_wanted()
		_victory = false
		spawn_point = _random_start()
		for pl in players_root.get_children():
			pl.arrive.rpc_id(pl.get_multiplayer_authority(), spawn_point)
		await get_tree().physics_frame
		_place_pickups()
		director.populate()
		_spawn_drones()
		_start_world()
	await _finish_loading()
	_changing = false


## Server: a different start every round - a random reachable street point
## (well inside the map; on a phase with an exit, away from the exit side).
var _arrive_at := Vector3.INF
func _random_start() -> Vector3:
	var map := get_world_3d().navigation_map
	if _arrive_at != Vector3.INF and in_bounds(_arrive_at, 5.0):
		var at := NavigationServer3D.map_get_closest_point(map, _arrive_at)
		_arrive_at = Vector3.INF
		return at + Vector3(0, 1.0, 0)
	_arrive_at = Vector3.INF
	var has_exit: bool = _map_spec(map_id)[2] != ""
	for attempt in 80:
		var p := NavigationServer3D.map_get_random_point(map, 1, true)
		if not in_bounds(p, 25.0):
			continue
		if has_exit and _exit_side() == "east" and p.x > bounds.position.x + bounds.size.x * 0.55:
			continue                      # away from the exit side
		if has_exit and _exit_side() == "north" and p.z < bounds.position.y + bounds.size.y * 0.45:
			continue
		var path := NavigationServer3D.map_get_path(map, spawn_point, p, true)
		if path.size() > 1 and path[path.size() - 1].distance_to(p) < 1.0:
			return p + Vector3(0, 1.0, 0)
	return spawn_point


## Area relative to the 300 m city the population numbers were tuned for
## (bigger maps get more pedestrians, cars and pickups, up to 2.5x).
func density() -> float:
	return clamp(bounds.get_area() / (300.0 * 300.0), 1.0, 1.9)   # big maps: a crowd as dense as a 520 x 520 m one


## Inside the playable rectangle, `margin` metres from its edges.
func in_bounds(p: Vector3, margin := 0.0) -> bool:
	return p.x > bounds.position.x + margin and p.x < bounds.end.x - margin \
			and p.z > bounds.position.y + margin and p.z < bounds.end.y - margin


## Distance from the origin to the farthest map corner (dropship entry/exit).
func map_reach() -> float:
	var r := 0.0
	for c in [bounds.position, bounds.end, Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
		r = max(r, (c as Vector2).length())
	return r


func civilians_wanted() -> int:
	return int(round(CIVILIANS * density() * 1.4 * ambient_scale))


## Performance guard (server): when the frame stays slow even at the lowest
## render scale, fewer passers-by are kept (down to 60%); with room to spare
## the full crowd comes back. Robots and goals never change with it.
var ambient_scale := 1.0
var _guard_cd := 3.0
func _performance_guard(delta: float) -> void:
	_guard_cd -= delta
	if _guard_cd > 0 or not multiplayer.is_server():
		return
	_guard_cd = 3.0
	var fps := Engine.get_frames_per_second()
	var res := get_viewport().scaling_3d_scale
	if fps < 48 and (res <= 0.55 or not dynamic_resolution):
		ambient_scale = max(0.6, ambient_scale - 0.1)
	elif fps > 68 and ambient_scale < 1.0:
		ambient_scale = min(1.0, ambient_scale + 0.05)
	# above the target: the farthest walker nobody is near leaves the streets
	var extra := civilians_root.get_child_count() - civilians_wanted()
	if ambient_scale < 1.0 and extra > 3:
		var far: Node3D = null
		var far_d := 140.0
		for c in civilians_root.get_children():
			if c.get("police") or c.get("vendor"):
				continue
			var d := INF
			for pl in players_root.get_children():
				d = min(d, (pl as Node3D).global_position.distance_to(c.global_position))
			if d > far_d:
				far_d = d
				far = c
		if far:
			far.queue_free()


func _city(suffix: String) -> String:
	return "res://city/%s%s" % [map_id, suffix]


static func available_maps() -> Array:
	return all_maps().filter(func(m): return ResourceLoader.exists("res://city/%s.glb" % m[0]))


## Load a city once per session: from the menu (solo/host) or on a client when
## the host says which one it runs.
## Load a city behind a loading screen: the big glTF scenes stream in on a
## worker thread (progress bar), then the city is assembled and the street
## navmesh baked; the round only starts once everything is in place.
func enter_map(id: String) -> void:
	if map_id != "":
		while not nav_ready:          # already loading (e.g. host_map arrived twice)
			await get_tree().process_frame
		return
	map_id = id
	var label := id
	for m in all_maps():
		if m[0] == id:
			label = m[1]
	_show_loading("Loading " + label)
	await get_tree().process_frame     # let the loading screen paint first
	await get_tree().process_frame
	var paths := [_city(".glb"), _city("_collision.glb"), _city("_horizon.glb")].filter(
			func(p): return ResourceLoader.exists(p))
	for p in paths:
		ResourceLoader.load_threaded_request(p)
	while true:
		var done := 0.0
		var pending := false
		for p in paths:
			var prog := []
			var st := ResourceLoader.load_threaded_get_status(p, prog)
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				pending = true
				done += prog[0] if prog.size() > 0 else 0.0
			else:
				done += 1.0
		_set_loading(0.65 * done / max(1, paths.size()), "Loading buildings and streets...")
		if not pending:
			break
		await get_tree().process_frame
	for p in paths:
		ResourceLoader.load_threaded_get(p)    # now cached: _load_city's load() is instant
	_set_loading(0.7, "Building the city...")
	await get_tree().process_frame
	_load_city()
	_load_roads()
	_set_loading(0.8, "Mapping the streets for robots and people...")
	_warm_people_request()              # read from disk on threads while the navmesh bakes
	var t := 0.0
	while not nav_ready:
		t += get_process_delta_time()
		_set_loading(0.8 + 0.18 * (1.0 - exp(-t / 4.0)), "Mapping the streets for robots and people...")
		await get_tree().process_frame
	await wait_for_navmesh()
	_set_loading(0.96, "Assembling the robots...")
	await get_tree().process_frame
	_warm_models()                     # ships and every robot kind loaded (and kept) now
	for k in Enemy.VARIANTS:
		Wreck.prepare(Enemy.VARIANTS[k]["model"])     # split into plates now, not at the first kill
	_set_loading(0.97, "Filling the streets...")


## End of loading: wait until the round is populated (server) or the host's
## pedestrians/robots have arrived (client), then render the city all around
## the player behind the loading screen so meshes, textures and shaders are
## on the GPU before the first visible frame - otherwise the game stalls
## right after the loading screen while everything pops in.
## Models that appear in the middle of a round (ships, every robot) are
## loaded with the map: the first one read from disk mid-fight was a
## 100-150 ms freeze. Kept referenced so they stay in memory.
var _warm: Dictionary = {}
func _warm_models() -> void:
	var paths: Array = [Dropship.MODEL]
	for k in Dropship.MODELS:
		paths.append(Dropship.MODELS[k])
	for k in Enemy.VARIANTS:
		paths.append(Enemy.VARIANTS[k]["model"])
	for p in paths:
		if ResourceLoader.exists(p) and not _warm.has(p):
			_warm[p] = load(p)
	for p in _warm_people:
		var r: Resource = ResourceLoader.load_threaded_get(p)
		if r:
			_warm[p] = r
	_warm_people = []


## Every pedestrian, officer, vendor and dog model (and the football shirts
## without crests, the shared gait's donors), requested on threads: a group
## of people coming in mid-round read up to five models from disk in one
## frame - 100-340 ms freezes. Also warm view models and the swarm: native
## profiling measured 240-276 ms in a first weapon switch and 103 ms in the
## first swarm's _ready. Keep the PackedScenes alive in _warm, keyed by path,
## so later load() calls reuse resources. No model simplification is involved.
## Picked up (and kept) by _warm_models.
var _warm_people: PackedStringArray = []
func _warm_people_request() -> void:
	var want: PackedStringArray = []
	for m in Civilian.MODELS:
		want.append(m)
		var plain: String = m.get_basename() + "_sem_escudo_basecolor.png"
		if ResourceLoader.exists(plain):
			want.append(plain)
	for k in Civilian.PEOPLE_GAIT:
		want.append(Civilian.PEOPLE_GAIT[k])
	for path in Player.VIEW_MODELS.values():
		want.append(path)
	# Drones can all die: retaining their scene avoids a synchronous reload
	# when the next reinforcement arrives (180-196 ms in native probes).
	want.append(Drone.MODEL)
	want.append(preload("res://scripts/swarm.gd").MODEL)
	want.append(PeopleContainer.MODEL)
	for p in want:
		if not p in _warm_people and ResourceLoader.exists(p) \
				and ResourceLoader.load_threaded_request(p, "", true) == OK:
			_warm_people.append(p)
var texture_sharing_stats: Dictionary = {}
func _finish_loading() -> void:
	var t := 0.0
	while t < 8.0 and ((multiplayer.is_server() and not _round_live)
			or (not multiplayer.is_server() and civilians_root.get_child_count() == 0)):
		t += get_process_delta_time()
		await get_tree().process_frame
	_set_loading(0.985, "Sharing identical textures...")
	await get_tree().process_frame
	var sharing := preload("res://scripts/texture_sharing.gd").new()
	var share_start := Time.get_ticks_usec()
	var texture_before := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	for scene in _warm.values():
		sharing.resource(scene)
	sharing.tree(self)
	print("Texture sharing: %d checked, %d duplicates (%.1f MiB imported files), %.2f s" % [
			sharing.checked, sharing.shared, sharing.shared_bytes / 1048576.0,
			(Time.get_ticks_usec() - share_start) / 1000000.0])
	texture_sharing_stats = {"checked": sharing.checked, "shared": sharing.shared,
			"seconds": (Time.get_ticks_usec() - share_start) / 1000000.0,
			"texture_before_mb": texture_before / 1048576.0}
	await get_tree().process_frame
	await get_tree().process_frame
	texture_sharing_stats["texture_after_mb"] = RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0
	_set_loading(0.99, "Getting ready...")
	var pl: Node3D = null
	for p in players_root.get_children():
		if p.is_multiplayer_authority():
			pl = p
	if pl:
		await pl.prewarm_view_models()
		await pl.prewarm_impact_fx()
		await _prewarm_container(pl.camera)
		var yaw := pl.rotation.y
		for k in 8:
			pl.rotation.y = yaw + k * TAU / 8.0
			await get_tree().process_frame
			await get_tree().process_frame
		pl.rotation.y = yaw
	await get_tree().process_frame
	_set_loading(1.0, "Ready")
	_hide_loading()
	if not driven:   # leave the mouse free while the DevAgent drives the game
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Warm only the imported geometry: no container physics, captives, groups or
## replication side effects. First delivery otherwise loaded/rendered it mid-round.
func _prewarm_container(cam: Camera3D) -> void:
	if DisplayServer.get_name() == "headless" or not _warm.has(PeopleContainer.MODEL):
		return
	var model: Node3D = (_warm[PeopleContainer.MODEL] as PackedScene).instantiate()
	add_child(model)
	model.global_position = cam.global_position - cam.global_basis.z * 6.0 - Vector3(0, 1.6, 0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	model.queue_free()


@rpc("authority", "call_remote", "reliable")
func host_map(id: String) -> void:
	await enter_map(id)
	await _finish_loading()


func _show_loading(title: String) -> void:
	if _loading == null:
		var layer := CanvasLayer.new()
		layer.layer = 30
		add_child(layer)
		_loading = Control.new()
		_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.add_child(_loading)
		var bg := ColorRect.new()
		bg.color = Color(0.03, 0.04, 0.06)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_loading.add_child(bg)
		if ResourceLoader.exists(MENU_BG):
			var art := TextureRect.new()
			art.texture = load(MENU_BG)
			art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			art.set_anchors_preset(Control.PRESET_FULL_RECT)
			art.modulate = Color(0.45, 0.45, 0.5)
			_loading.add_child(art)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		_loading.add_child(center)
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(720, 0)
		box.add_theme_constant_override("separation", 18)
		center.add_child(box)
		_load_title = Label.new()
		_load_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_load_title.add_theme_font_size_override("font_size", 48)
		_load_title.add_theme_color_override("font_color", Color(1.0, 0.32, 0.22))
		_load_title.add_theme_color_override("font_outline_color", Color.BLACK)
		_load_title.add_theme_constant_override("outline_size", 8)
		box.add_child(_load_title)
		_load_bar = ProgressBar.new()
		_load_bar.custom_minimum_size = Vector2(0, 26)
		_load_bar.show_percentage = false
		_load_bar.max_value = 1.0
		var track := StyleBoxFlat.new()
		track.bg_color = Color(0.08, 0.09, 0.12, 0.9)
		track.border_color = Color(0.85, 0.2, 0.15, 0.9)
		track.set_border_width_all(2)
		track.set_corner_radius_all(6)
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.9, 0.25, 0.16)
		fill.set_corner_radius_all(6)
		_load_bar.add_theme_stylebox_override("background", track)
		_load_bar.add_theme_stylebox_override("fill", fill)
		box.add_child(_load_bar)
		_load_step = Label.new()
		_load_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_load_step.add_theme_font_size_override("font_size", 24)
		_load_step.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9))
		box.add_child(_load_step)
	_load_title.text = title
	_load_bar.value = 0.0
	_load_step.text = ""
	_loading.visible = true
	_loading_music()


func _set_loading(frac: float, step: String) -> void:
	_load_bar.value = frac
	_load_step.text = step


func _hide_loading() -> void:
	_loading.visible = false
	if _load_music and _load_music.playing:
		var tw := create_tween()
		tw.tween_property(_load_music, "volume_db", -40.0, 2.0)
		tw.tween_callback(_load_music.stop)


## Loading-screen music: the "loading" station, or the gaita until there is one.
var _load_music: AudioStreamPlayer
func _loading_music() -> void:
	if _load_music == null:
		_load_music = AudioStreamPlayer.new()
		_load_music.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_load_music)
	if _load_music.playing:
		return
	_stop_menu_music()
	_load_music.volume_db = -8.0
	Music.playlist(_load_music, loading_station(map_id))


## The loading music of a map's city: "loading_<first map of the city>",
## then "loading_<city name>" (loading_porto_alegre for every Porto Alegre
## map), then the common "loading" station, then the gaita.
func loading_station(id: String) -> String:
	if id != "":
		var name := ""
		for c in available_cities():
			for p in c[1]:
				if p[0] == id:
					name = String(c[0]).get_slice(" (", 0)
		var slug := name.to_lower().strip_edges().replace(" ", "_")
		for k in ["ã", "á", "â", "à"]:
			slug = slug.replace(k, "a")
		for pair in [["é", "e"], ["ê", "e"], ["í", "i"], ["ó", "o"], ["ô", "o"], ["õ", "o"], ["ú", "u"], ["ç", "c"]]:
			slug = slug.replace(pair[0], pair[1])
		for st in ["loading_" + city_of(id), "loading_" + slug]:
			if not Music.tracks(st).is_empty():
				return st
	return "loading" if not Music.tracks("loading").is_empty() else "gaita"


## The title music gives way (to a city's opening film, to a loading screen).
func _stop_menu_music() -> void:
	if _menu_music and _menu_music.playing:
		var tw := create_tween()
		tw.tween_property(_menu_music, "volume_db", -40.0, 1.0)
		tw.tween_callback(_menu_music.stop)


func _selected_map() -> String:
	var cities := available_cities()
	if cities.is_empty():
		return available_maps()[0][0]
	var c: Array = cities[clampi(map_select.selected, 0, cities.size() - 1)] if map_select else cities[0]
	var phases: Array = c[1]
	var k := phase_select.selected if phase_select and phase_select.selected >= 0 else 0
	return phases[clampi(k, 0, phases.size() - 1)][0]


## Cities for the menu: every chain of phases (a map nobody leads to, then
## its "next" maps) is one city: [name, [map spec, ...]].
const CITY_NAMES := {"gasometro": "Porto Alegre", "poa": "Porto Alegre (whole Centro, free play)"}
static func available_cities() -> Array:
	var maps := available_maps()
	var by_id := {}
	for m in maps:
		by_id[m[0]] = m
	var led_to := {}
	for m in maps:
		if m[2] != "":
			led_to[m[2]] = true
	var out := []
	for m in maps:
		if led_to.has(m[0]):
			continue
		var chain := [m]
		while chain[-1][2] != "" and by_id.has(chain[-1][2]) and chain.size() < 12:
			chain.append(by_id[chain[-1][2]])
		var name: String = CITY_NAMES.get(m[0], String(m[1]).get_slice(" · ", 0))
		out.append([name, chain])
	return out


func _fill_phases() -> void:
	phase_select.clear()
	var cities := available_cities()
	if cities.is_empty():
		return
	for p in cities[clampi(map_select.selected, 0, cities.size() - 1)][1]:
		var label: String = p[1]
		phase_select.add_item(label.get_slice(" · ", 1) if label.contains(" · ") else label)
	phase_select.disabled = phase_select.item_count < 2


func _load_city() -> void:
	nav_region = NavigationRegion3D.new()
	nav_region.name = "Navigation"
	nav_region.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(nav_region)
	_map_nodes.append(nav_region)
	var packed: PackedScene = load(_city(".glb"))
	var city := packed.instantiate()
	city.name = "City"
	nav_region.add_child(city)
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		var top := (mi as MeshInstance3D).get_aabb().end.y
		city_top = max(city_top, top)
	var custom_collision := ResourceLoader.exists(_city("_collision.glb"))
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		var kind := city_mesh_kind(mi)
		if custom_collision and kind in VISUAL_ONLY:
			continue
		if kind in NO_COLLISION:
			continue
		(mi as MeshInstance3D).create_trimesh_collision()
		if kind in ROOFS:
			for body in mi.find_children("*", "StaticBody3D", false, false):
				(body as StaticBody3D).collision_layer = ROOF_LAYER
	if custom_collision:
		# sidewalks with curb ramps: collision only (also baked into the navmesh)
		var col: Node3D = (load(_city("_collision.glb")) as PackedScene).instantiate()
		col.name = "SidewalkCollision"
		nav_region.add_child(col)
		for mi in col.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).create_trimesh_collision()
			(mi as MeshInstance3D).visible = false
	_water(city)
	_matte_grass(city)
	_kit_facades(city)
	_occluders()
	# double-sided collision: rays started inside a volume must still hit it
	for cs in city.find_children("*", "CollisionShape3D", true, false):
		if cs.shape is ConcavePolygonShape3D:
			cs.shape.backface_collision = true
	if ResourceLoader.exists(_city("_horizon.glb")):
		var horizon: Node3D = (load(_city("_horizon.glb")) as PackedScene).instantiate()
		horizon.name = "Horizon"
		_map_nodes.append(horizon)
		_water(horizon)
		_matte_grass(horizon)
		add_child(horizon)            # visual only: no collision, not in the navmesh
	if FileAccess.file_exists(_city(".spawn.json")):
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_city(".spawn.json")))
		var s: Array = data["spawn"]
		spawn_point = Vector3(s[0], s[1], s[2])
		map_half = data.get("half", map_half)
		bounds = Rect2(-map_half, -map_half, map_half * 2, map_half * 2)
		crowd = []
		for c in data.get("crowd", []):
			crowd.append(Vector3(c[0], c[2] if c.size() > 2 else 0.0, c[1]))
		var ev: Array = data.get("elev", [0.0, 0.0])
		elev = Vector2(ev[0], ev[1])
		if data.has("bounds"):
			var b: Array = data["bounds"]       # [min_x, max_x, min_z, max_z]
			bounds = Rect2(b[0], b[2], b[1] - b[0], b[3] - b[2])
	_edge_walls()
	props = Props.new()
	props.name = "Props"
	nav_region.add_child(props)      # poles and trunks must be navmesh obstacles
	props.build(_city(".props.json"))
	_landmarks()
	_ambience()
	_pigeons()
	_quero_queros.call_deferred()
	_place_antenna.call_deferred()
	_place_containers.call_deferred()

	# street-level navigation mesh for the robots (roofs are unreachable islands)
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 1
	nm.agent_radius = 0.5
	nm.agent_height = 2.0
	nm.agent_max_climb = 0.25
	# 0.4 m cells, edges simplified to 2 cells: about half the polygons of 0.25 m
	# (Centro 24,000 -> 12,900) and every path search that much cheaper - the
	# people's walking goals were the biggest script cost in a play-through
	nm.cell_size = 0.4
	nm.cell_height = 0.25
	nm.edge_max_error = 2.0
	nm.filter_baking_aabb = AABB(Vector3(bounds.position.x - 10, elev.x - 2, bounds.position.y - 10),
			Vector3(bounds.size.x + 20, elev.y - elev.x + 6, bounds.size.y + 20))
	nav_region.navigation_mesh = nm
	nav_region.bake_finished.connect(func():
		print("navmesh baked")
		nav_ready = true)
	nav_region.bake_navigation_mesh(true)


# ---- networking -----------------------------------------------------------

func _host() -> void:
	if _game_started:
		return                 # a second start (menu click + DevAgent) would populate the city twice
	_game_started = true
	set_difficulty(Settings.difficulty)
	Settings.set_player_name(name_edit.text)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		status_label.text = "Cannot host on port %d (error %d)" % [PORT, err]
		return
	multiplayer.multiplayer_peer = peer
	status_label.text = "Hosting on port %d" % PORT
	_start_game()
	await play_intro(_selected_map())
	await enter_map(_selected_map())
	spawn_point = _random_start()
	_place_pickups()
	director.populate()
	_spawn_drones()
	_start_world()
	spawner.spawn({"id": 1, "name": name_edit.text})
	await _finish_loading()


func _join() -> void:
	Settings.set_player_name(name_edit.text)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address_edit.text.strip_edges(), PORT)
	if err != OK:
		status_label.text = "Cannot connect (error %d)" % err
		return
	multiplayer.multiplayer_peer = peer
	status_label.text = "Connecting to %s..." % address_edit.text
	_start_game()
	_show_loading("Connecting to %s" % address_edit.text)
	_set_loading(0.0, "Waiting for the host...")


func _solo(id := "") -> void:
	if _game_started:
		return                 # a second start (menu click + DevAgent) would populate the city twice
	_game_started = true
	set_difficulty(Settings.difficulty)
	Settings.set_player_name(name_edit.text)
	_start_game()
	if id == "":
		await play_intro(_selected_map())
	await enter_map(id if id != "" else _selected_map())
	spawn_point = _random_start()
	players_root.add_child(_spawn_player({"id": 1, "name": name_edit.text}))
	_place_pickups()
	director.populate()
	_spawn_drones()
	_start_world()
	await _finish_loading()


var _game_started := false
func _start_game() -> void:
	menu.visible = false       # the mouse is captured once the city has loaded


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		set_difficulty.rpc_id(id, Difficulty.level)
		host_map.rpc_id(id, map_id)
		spawner.spawn({"id": id, "name": "Player %d" % id})


func _on_peer_disconnected(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()


func _spawn_player(data: Variant) -> Node:
	var p: CharacterBody3D = Player.new()
	p.name = str(data["id"])
	p.display_name = data.get("name", p.name)
	p.spawn_point = spawn_point
	p.position = spawn_point + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	return p


## Server: scatter medkits, ammo boxes and machine guns over reachable
## street points (respawning pickups).
func _place_pickups() -> void:
	if not multiplayer.is_server() or pickups_root.get_child_count() > 0:
		return
	await wait_for_navmesh()
	for lp in landmark_pickups:
		_spawn_pickup(lp[0], lp[1] - Vector3(0, 0.0, 0), true, true)
	var map := get_world_3d().navigation_map
	var placed := []
	for key in PICKUP_COUNTS:
		var kind: String = role(key) if Entities.get_def(key).is_empty() else key
		if kind == "":
			continue
		var n := 0
		var tries := 0
		while n < int(round(PICKUP_COUNTS[key] * density() * Difficulty.get_value("pickups"))) and tries < 400:
			tries += 1
			var pos := NavigationServer3D.map_get_random_point(map, 1, true)
			if not in_bounds(pos, 10.0) or pos.distance_to(spawn_point) < 8:
				continue
			var path := NavigationServer3D.map_get_path(map, spawn_point, pos, true)
			if path.is_empty() or path[path.size() - 1].distance_to(pos) > 1.0:
				continue
			if placed.any(func(q): return q.distance_to(pos) < 15.0):
				continue
			placed.append(pos)
			_spawn_pickup(kind, pos, true)
			n += 1
	# what a place sells waits at its door (a pharmacy's medicine, a market's
	# mate...): place_kinds.json "pickup", a role or an item id
	for pl in places:
		var want: String = place_kinds.get(pl["kind"], {}).get("pickup", "")
		if want == "":
			continue
		var item: String = want if not Entities.get_def(want).is_empty() else role(want)
		if item == "":
			continue
		var at := NavigationServer3D.map_get_closest_point(map, Vector3(pl["door"][0], 0, pl["door"][1]))
		if at.distance_to(Vector3(pl["door"][0], at.y, pl["door"][1])) < 4.0:
			# on whatever floor is there now (a shop's front pad sits above the street)
			var top := get_world_3d().direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(at + Vector3(0, 1.2, 0), at - Vector3(0, 2.0, 0), 1))
			if top:
				at.y = top.position.y
			_spawn_pickup(item, at, true, true)
	# items put down by hand in the map editor (by type in its palette)
	for p in user_edits().get("_pickups", []):
		var at := NavigationServer3D.map_get_closest_point(map, Vector3(p["x"], p.get("y", 0.0), p["z"]))
		if p.has("y"):
			at = Vector3(p["x"], p["y"], p["z"])
		_spawn_pickup(p["id"], at, true, true)
	# the round starts unarmed: a couple of pistols a short walk from the start
	for k in 2:
		var near := NavigationServer3D.map_get_closest_point(map,
				spawn_point + Vector3.FORWARD.rotated(Vector3.UP, k * PI + randf()) * randf_range(7.0, 14.0))
		_spawn_pickup("pistol", near, true)


## The map's user edits (edits.gd): read live, so what the map editor saves
## (items, roles, bus lines) counts the next round.
func user_edits() -> Dictionary:
	return Edits.read(map_id)


## What OSM says the map's spots are (<city>.places.json, written at import
## from assets/place_kinds.json): pharmacies, markets, fuel stations... The
## tablet's GPS shows them, items wait at their doors, pharmacies and
## hospitals get a green cross on the facade.
var places: Array = []
var place_kinds: Dictionary = {}
var _signs: Array = []
func _load_places() -> void:
	places = []
	if FileAccess.file_exists("res://assets/place_kinds.json"):
		place_kinds = JSON.parse_string(FileAccess.get_file_as_string("res://assets/place_kinds.json"))
	if FileAccess.file_exists(_city(".places.json")):
		places = JSON.parse_string(FileAccess.get_file_as_string(_city(".places.json")))
	var off: Array = user_edits().get("_place_kinds_off", [])
	places = places.filter(func(pl): return not pl["kind"] in off)
	# the city's collection (the Studio's import window), else Rio Grande do Sul's
	collection = String(user_edits().get("_collection", "rio_grande_do_sul"))
	for n in _signs:
		if is_instance_valid(n):
			n.queue_free()
	_signs = []
	await get_tree().physics_frame
	await get_tree().physics_frame
	for pl in places:
		if place_kinds.get(pl["kind"], {}).get("sign", "") == "cross" and not pl.get("model"):
			_cross_sign(pl)


## The place an OSM building is ({} if none) - for the editor's building panel.
func place_of(building_id: String) -> Dictionary:
	for pl in places:
		if pl.get("building", "") == building_id:
			return pl
	return {}


var _floor_mats := {}
const _LEISURE_FLOORS := {"pitch_surface": "turf", "apron_ground_pad": "concrete",
		"rubber_ground_pad": "rubber", "sand_ground_pad": "sand"}
func _leisure_floor(mesh_name: String) -> StandardMaterial3D:
	var kind: String = _LEISURE_FLOORS[mesh_name]
	if _floor_mats.has(kind):
		return _floor_mats[kind]
	var m := StandardMaterial3D.new()
	match kind:
		"turf":
			m.albedo_texture = load("res://assets/materials/Grass004/color.jpg")
			m.albedo_color = Color(0.55, 0.95, 0.45)            # synthetic: greener and even
			m.roughness = 0.85
			m.uv1_triplanar = true
			m.uv1_scale = Vector3.ONE * 0.5
		"concrete":
			m.albedo_texture = load("res://assets/materials/Concrete034/color.jpg")
			m.roughness = 0.9
			m.uv1_triplanar = true
			m.uv1_scale = Vector3.ONE * 0.3
		"rubber":
			m.albedo_color = Color(0.62, 0.24, 0.18)            # the red safety rubber floor
			m.roughness = 0.95
		"sand":
			m.albedo_color = Color(0.86, 0.77, 0.58)
			m.roughness = 1.0
	_floor_mats[kind] = m
	return m


func _storefront_floor(ceramic: bool) -> StandardMaterial3D:
	if _floor_mats.has(ceramic):
		return _floor_mats[ceramic]
	var m := StandardMaterial3D.new()
	if ceramic:
		m.albedo_color = Color(0.86, 0.85, 0.82)
		m.roughness = 0.35
	else:
		m.albedo_texture = load("res://assets/materials/Concrete034/color.jpg")
		m.normal_enabled = true
		m.normal_texture = load("res://assets/materials/Concrete034/normalgl.jpg")
		m.roughness = 0.9
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE * 0.25
	_floor_mats[ceramic] = m
	return m


## The resistance's grenades (grenade.gd; definitions bergamota / porongo).
## Server: a player threw one - every peer throws its copy from the same start.
const Grenade := preload("res://scripts/grenade.gd")
@rpc("any_peer", "call_local", "reliable")
func throw_grenade(kind: String, origin: Vector3, dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	grenade_thrown.rpc(kind, origin, dir.normalized() * 11.0 + Vector3(0, 2.5, 0), peer if peer != 0 else 1)


@rpc("authority", "call_local", "reliable")
func grenade_thrown(kind: String, origin: Vector3, vel: Vector3, peer: int) -> void:
	var g := Grenade.new()
	g.kind = kind
	g.thrower_peer = peer
	add_child(g)
	g.global_position = origin
	g.linear_velocity = vel


## Server: a grenade's fuse ran out. Bergamota de Aço: a blast (effect
## blast_m) that hurts robots by how near they are, brings drones and swarm
## drones down, and people (friendly fire) and players too. Porongo: an EMP
## (effect emp_m) - robots stand dead still and do not shoot for stun_s (a
## mech half that), drones and swarm drones drop.
func grenade_burst(kind: String, at: Vector3, peer: int) -> void:
	if not multiplayer.is_server():
		return
	var d: Dictionary = Entities.get_def(kind).get("effect", {})
	var by: Node3D = players_root.get_node_or_null(str(peer))
	if kind == "porongo":
		var r := float(d.get("emp_m", 9.0))
		for e in enemies_root.get_children():
			if e.get("variant") == "swarm":
				for i in e.positions.size():
					if (e.alive_mask >> i) & 1 == 1 and e.positions[i].distance_to(at) < r:
						e.hit_unit(i, 9999, by)
				continue
			if not e.has_method("is_alive") or not e.is_alive() or (e as Node3D).global_position.distance_to(at) > r:
				continue
			if e.get("variant") == "drone":
				e.apply_damage(9999, by)
			elif e.has_method("emp"):
				e.emp(float(d.get("stun_s", 6.0)) * (0.5 if e.get("variant") == "mech" else 1.0))
		emp_fx.rpc(at, r)
		return
	var r := float(d.get("blast_m", 6.0))
	for e in enemies_root.get_children():
		if e.get("variant") == "swarm":
			for i in e.positions.size():
				if (e.alive_mask >> i) & 1 == 1 and e.positions[i].distance_to(at) < r:
					e.hit_unit(i, 9999, by)
			continue
		if not e.has_method("is_alive") or not e.is_alive():
			continue
		var dist := (e as Node3D).global_position.distance_to(at)
		if dist < r:
			e.apply_damage(9999 if e.get("variant") == "drone" else int(40.0 + 160.0 * (1.0 - dist / r)), by)
		if e.has_method("heard"):
			e.heard(at)
	if Settings.friendly_fire:
		for c in civilians_root.get_children():
			var dist := (c as Node3D).global_position.distance_to(at)
			if dist < r * 0.8 and c.has_method("apply_damage"):
				c.apply_damage(int(120.0 * (1.0 - dist / r)), by)
	for pl in players_root.get_children():
		var dist := (pl as Node3D).global_position.distance_to(at)
		if dist < r:
			pl.hurt.rpc_id(pl.get_multiplayer_authority(), int(60.0 * (1.0 - dist / r)), at)
	for c in get_tree().get_nodes_in_group("civilians"):
		c.heard(at)
	blast_fx.rpc(at, at, Vector3.UP, false)


## Every peer: the Porongo's pulse - a blue flash and a ring of light
## spreading over the ground.
@rpc("authority", "call_local", "reliable")
func emp_fx(at: Vector3, r: float) -> void:
	Sfx.play_at("robot_hit", at, 6.0, 90.0)
	Sfx.play_at("robot_fire", at, 2.0, 90.0)
	var flash := Enemy.fx_light(Color(0.35, 0.75, 1.0), 12.0, r * 1.6)
	if flash:
		add_child(flash)
		flash.global_position = at + Vector3(0, 1.0, 0)
		var tw := flash.create_tween()
		tw.tween_property(flash, "light_energy", 0.0, 0.7)
		tw.tween_callback(flash.queue_free)
	var shell := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.45)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.material = mat
	shell.mesh = sm
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shell)
	shell.global_position = at
	shell.scale = Vector3.ONE * 0.3
	var st := shell.create_tween().set_parallel()
	st.tween_property(shell, "scale", Vector3.ONE * r, 0.45).set_ease(Tween.EASE_OUT)
	st.tween_property(mat, "albedo_color:a", 0.0, 0.6)
	st.chain().tween_callback(shell.queue_free)


func _drop_cannon_at(where: Vector3) -> void:
	var at := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, where + Vector3(2.0, 0, 0))
	var pk := _spawn_pickup("canhao", at, false)
	if pk:
		get_tree().create_timer(90.0).timeout.connect(pk.queue_free)


## Every peer: a missile flying from `from` to `at` (the mech's cannon and the
## player's, once picked up - enemy.gd Missile).
@rpc("authority", "call_local", "reliable")
func missile_fx(from: Vector3, at: Vector3, flight: float) -> void:
	Sfx.play_at("robot_fire", from, 4.0, 120.0)
	var m := Enemy.Missile.new()
	add_child(m)
	m.fly(from, at, flight, Enemy.fx_light(Color(1.0, 0.6, 0.25), 3.0, 5.0))


## Server: the player's mech cannon round arriving - a blast that hurts the
## robots round it (player.gd server_shoot), then the burst on every peer.
func player_cannon_land(origin: Vector3, at: Vector3, normal: Vector3, wall: bool, r: float, dmg: int, peer: int) -> void:
	var by := players_root.get_node_or_null(str(peer))
	for e in enemies_root.get_children():
		if e.get("variant") == "swarm":
			e.damage_in_radius(at, r, dmg, by)
			continue
		if e is Node3D and (e as Node3D).global_position.distance_to(at) < r + 1.0 and e.has_method("apply_damage"):
			e.apply_damage(dmg, by)
	blast_fx.rpc(origin, at, normal, wall)
	for e in enemies_root.get_children():
		e.heard(origin)


## Server: a mech's missile arriving (enemy.gd _cannon): people near it hurt
## or killed, then the burst on every peer.
func cannon_land(from: Vector3, at: Vector3, normal: Vector3, wall: bool, radius: float) -> void:
	if not multiplayer.is_server():
		return
	for pl in get_tree().get_nodes_in_group("players"):
		if (pl as Node3D).global_position.distance_to(at) < radius:
			pl.hurt.rpc_id(pl.get_multiplayer_authority(), 35, at)
	for c in get_tree().get_nodes_in_group("civilians"):
		if (c as Node3D).global_position.distance_to(at) < radius and c.has_method("apply_damage"):
			c.apply_damage(200, null)
	blast_fx.rpc(from, at, normal, wall)


## Every peer: a heavy shell bursting (the player's mech cannon): dust,
## sparks, a crater and rubble on a wall, shops nearby wrecked.
@rpc("any_peer", "call_local", "reliable")
func blast_fx(from: Vector3, at: Vector3, normal: Vector3, wall: bool) -> void:
	if multiplayer.get_remote_sender_id() not in [0, 1]:
		return
	Sfx.play_at("robot_death", at, 6.0, 120.0)
	if props:
		props._sparks(at)
	var flash := Enemy.fx_light(Color(1.0, 0.6, 0.25), 14.0, 12.0)      # the burst lights the street a moment
	if flash:
		add_child(flash)
		flash.global_position = at + Vector3(0, 1.0, 0)
		var ft := flash.create_tween()
		ft.tween_property(flash, "light_energy", 0.0, 0.35)
		ft.tween_callback(flash.queue_free)
	for b in get_tree().get_nodes_in_group("pigeons"):
		if b.quero and (b as Node3D).global_position.distance_to(at) < 6.0:
			b.apply_damage(999)                # the blast: every peer, its own birds
	const Rubble := preload("res://scripts/rubble.gd")
	var dust := CPUParticles3D.new()
	dust.one_shot = true
	dust.explosiveness = 0.85
	dust.amount = 30
	dust.lifetime = 2.5
	dust.spread = 180.0
	dust.initial_velocity_min = 1.0
	dust.initial_velocity_max = 4.0
	dust.gravity = Vector3(0, 0.6, 0)
	var m := SphereMesh.new()
	m.radius = 0.6
	m.height = 1.2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.55, 0.5, 0.45, 0.45)
	m.material = mat
	dust.mesh = m
	add_child(dust)
	dust.global_position = at
	dust.emitting = true
	get_tree().create_timer(3.5).timeout.connect(dust.queue_free)
	if wall:
		Rubble.crater(self, at, normal)
		Rubble.pile(self, at, normal)
	wreck_shops(at)


## Storefronts collide as one shape of their walls, floors, counters and
## shelves - not one body per lamp, hose and can (60 shops took physics from
## 11 to 33 ms a frame).
const SHOP_SKIP := ["glass", "fixture", "luminous", "lamp", "hose", "pipe", "light", "sign", "caption",
		"ceiling", "frame", "handle", "skirting", "product", "bottle", "can_", "box_small", "_detail"]
func _storefront_solid(n: String) -> bool:
	var low := n.to_lower()
	for k in SHOP_SKIP:
		if low.contains(k):
			return false
	return true


func _mesh_box(mi: MeshInstance3D, m: Node3D) -> void:
	if mi.mesh == null:
		return
	var b: AABB = (m.global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
	if b.size.y < 0.4:
		return                                 # small things on the floor: walk over them
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = b.size
	cs.shape = shape
	cs.position = b.get_center()
	body.add_child(cs)
	m.add_child(body)


func _merge_collision(m: Node3D, meshes: Array) -> void:
	if meshes.is_empty() or not is_instance_valid(m):
		return
	var faces := PackedVector3Array()
	var to_m := m.global_transform.affine_inverse()
	for mi in meshes:
		if not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var xf: Transform3D = to_m * (mi as MeshInstance3D).global_transform
		for v in (mi as MeshInstance3D).mesh.get_faces():
			faces.append(xf * v)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	m.add_child(body)


## Storefronts far away: the light outside-only version (storefronts/lod1)
## takes over beyond LOD_M, the full one (with its shop inside) up close.
const LOD_M := 70.0
func _storefront_lod(m: Node3D, l: Dictionary) -> void:
	var model: String = l.get("model", "")
	if not is_instance_valid(m) or not model.contains("/storefronts/") or model.contains("/damaged/") \
			or model.contains("/lod1/") or l.has("full"):
		return
	var lod := model.get_base_dir().path_join("lod1/" + model.get_file().get_basename() + "_lod1.gltf")
	if not ResourceLoader.exists(lod):
		return
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = LOD_M
	var far: Node3D = (load(lod) as PackedScene).instantiate()
	m.add_child(far)
	for mi in far.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_begin = LOD_M


func _lod_path(model: String) -> String:
	return model.get_base_dir().path_join("lod1/" + model.get_file().get_basename() + "_lod1.gltf")


## Shops (not the fuel station, not a wrecked one, not the one open now).
func _closed_shop(l: Dictionary) -> bool:
	var model: String = l.get("model", "")
	return model.contains("/storefronts/") and not model.contains("/damaged/") and not model.contains("/lod1/") \
			and not model.contains("posto") and not l.get("open", false)


## A shop's door in world space (its model's front, -Z, at depth/2), or INF.
func shop_door(n: Node3D) -> Vector3:
	var l: Dictionary = n.get_meta("landmark", {})
	if not l.has("full"):
		return Vector3.INF
	return n.global_transform * Vector3(0, 0, -_shop_depth(l) / 2.0 - 0.6)


func _shop_depth(l: Dictionary) -> float:
	return 8.0 if String(l.get("full", l.get("model", ""))).contains("_modulo_") else 12.0


## The shop (a whole one or a module on a taller building's ground floor)
## whose door is within reach of `at`, null if none.
func shop_near(at: Vector3) -> Node3D:
	for lm in _landmark_nodes:
		if not is_instance_valid(lm) or lm.has_meta("pocket"):
			continue
		var l: Dictionary = lm.get_meta("landmark", {})
		if l.has("full") and shop_door(lm).distance_to(at) < 2.6:
			return lm
	return null


## E at a shop's door takes you inside: its full model (walls, furniture,
## counter) is built in a pocket under the city - glass made opaque, lit
## inside - and you stand behind its door. Walking out through the door
## brings you back to the street in front of it. Works the same for a
## module on a big building's ground floor (the building is solid there).
## Every peer builds its own pocket for its own player.
const POCKET_DEPTH := 150.0
var _pockets := {}                # shop landmark node -> its pocket (this peer)
func enter_shop(lm: Node3D, who: Node3D) -> void:
	if not is_instance_valid(lm) or who == null:
		return
	var pocket: Node3D = _pockets.get(lm)
	if not is_instance_valid(pocket):
		var l: Dictionary = lm.get_meta("landmark", {}).duplicate()
		l["model"] = l["full"]
		l.erase("full")
		l.erase("solid")
		l["open"] = true
		var p: Array = l.get("pos", [lm.global_position.x, lm.global_position.y, lm.global_position.z])
		l["pos"] = [p[0], p[1] - POCKET_DEPTH, p[2]]
		_landmark(l)
		pocket = _landmark_nodes[-1]
		pocket.set_meta("pocket", lm)
		_pockets[lm] = pocket
		_furnish_pocket(pocket, l)
		# its collision is merged a frame later: stand in once it is there
		await get_tree().physics_frame
		await get_tree().physics_frame
		await get_tree().physics_frame
	var inside: Vector3 = pocket.global_transform * Vector3(0, 0.15, -_shop_depth(pocket.get_meta("landmark")) / 2.0 + 2.6)
	who.global_position = inside
	who.velocity = Vector3.ZERO
	who.rotation.y = pocket.global_rotation.y + PI          # looking in, away from the door
	who.reset_physics_interpolation()
	who.set("in_shop", true)
	var name_of: String = String(lm.get_meta("landmark", {}).get("caption", ""))
	if who.has_method("show_place"):
		who.show_place(name_of if name_of != "" else "Shop")


## Opaque glass, a light, and the way out at the door.
func _furnish_pocket(pocket: Node3D, l: Dictionary) -> void:
	var frosted := StandardMaterial3D.new()
	frosted.albedo_color = Color(0.62, 0.7, 0.72)
	frosted.roughness = 0.25
	frosted.metallic = 0.3
	frosted.emission_enabled = true
	frosted.emission = Color(0.55, 0.62, 0.6)        # daylight behind it
	frosted.emission_energy_multiplier = 0.6
	for mi in pocket.find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name).to_lower()
		if n.contains("glass") or n.contains("vidro") or n.contains("window"):
			(mi as MeshInstance3D).material_override = frosted
	var depth := _shop_depth(l)
	if l.get("place", "") == "repair_shop":
		# an assistência técnica: its counter inside is where you trade parts
		var counter := pocket.find_child("pickup_counter", true, false) as Node3D
		var at: Vector3 = counter.global_position if counter else pocket.global_transform * Vector3(0, 0, 1.5)
		props.shops.append(at)
		pocket.tree_exiting.connect(func(): props.shops.erase(at))
	# its ground pads are visual only (in town the street is the floor): a floor
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var fcs := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(16.0, 0.4, depth + 3.0)
	fcs.shape = slab
	fcs.position = Vector3(0, -0.2, 0)
	floor_body.add_child(fcs)
	pocket.add_child(floor_body)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.96, 0.88)
	light.light_energy = 2.2
	light.omni_range = depth + 4.0
	light.position = Vector3(0, 2.6, 0)
	pocket.add_child(light)
	var out := Area3D.new()
	out.collision_layer = 0
	out.collision_mask = 4                 # players
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 2.5, 1.2)
	cs.shape = box
	out.add_child(cs)
	out.position = Vector3(0, 1.2, -depth / 2.0 - 0.2)
	pocket.add_child(out)
	out.body_entered.connect(func(body): _leave_shop(pocket, body))


## Through the door: back on the street in front of the shop, facing out.
func _leave_shop(pocket: Node3D, who: Node3D) -> void:
	if not who.is_in_group("players") or not who.is_multiplayer_authority():
		return
	var lm: Node3D = pocket.get_meta("pocket")
	if not is_instance_valid(lm):
		return
	var door := shop_door(lm)
	who.set_deferred("global_position", door + Vector3(0, 0.3, 0) - lm.global_transform.basis.z * 0.8)
	who.set_deferred("rotation:y", lm.global_rotation.y)
	who.set("in_shop", false)
	if who.has_method("show_place"):
		who.show_place("")
	# nobody else of ours inside: the pocket goes
	_free_pocket_later.call_deferred(pocket, lm)


func _free_pocket_later(pocket: Node3D, lm: Node3D) -> void:
	await get_tree().create_timer(1.0).timeout
	for pl in players_root.get_children():
		if is_instance_valid(pocket) and (pl as Node3D).global_position.distance_to(pocket.global_position) < 15.0:
			return
	_pockets.erase(lm)
	_landmark_nodes.erase(pocket)
	if is_instance_valid(pocket):
		pocket.queue_free()


## Where the repair shops are, for the GPS: the real shops (a storefront)
## and the counters standing on their own.
func repair_shops() -> Array:
	var out := []
	for lm in _landmark_nodes:
		if is_instance_valid(lm) and not lm.has_meta("pocket") \
				and String(lm.get_meta("landmark", {}).get("place", "")) == "repair_shop":
			out.append((lm as Node3D).global_position)
	for at in props.shops:
		if (at as Vector3).y > -50.0:
			out.append(at)
	return out


## Where the GPS can route a player at `from`: [[label, position], ...] -
## the exit, the nearest of each kind of shop, the camp, the pitches and
## playgrounds, containers (with the GPS upgrade) and spotted antennas.
func route_destinations(from: Vector3, with_containers := false) -> Array:
	var out := []
	var nearest := func(label: String, spots: Array):
		var best := Vector3.INF
		for p in spots:
			if (p as Vector3).distance_to(from) < best.distance_to(from):
				best = p
		if best != Vector3.INF:
			out.append(["%s  (%d m)" % [label, int(best.distance_to(from))], best])
	if _exit and is_instance_valid(_exit):
		out.append(["Saída da fase  (%d m)" % int(_exit.global_position.distance_to(from)), _exit.global_position])
	nearest.call("Assistência técnica", repair_shops())
	var kinds := {}
	for pl in places:
		var label: String = place_kinds.get(pl["kind"], {}).get("label", "")
		if label == "" or pl["kind"] == "repair_shop":
			continue
		if not kinds.has(label):
			kinds[label] = []
		var y := _ground_y(Vector3(pl["door"][0], from.y + 30.0, pl["door"][1]))
		kinds[label].append(Vector3(pl["door"][0], y, pl["door"][1]))
	for label in kinds:
		nearest.call(label, kinds[label])
	var camp := []
	var pitches := []
	var parks := []
	var skate := []
	for lm in _landmark_nodes:
		if not is_instance_valid(lm) or lm.has_meta("pocket"):
			continue
		var l: Dictionary = lm.get_meta("landmark", {})
		if String(l.get("model", "")).contains("farroupilha/palco"):
			camp.append((lm as Node3D).global_position)
		match String(l.get("leisure", "")):
			"pitch": pitches.append((lm as Node3D).global_position)
			"playground": parks.append((lm as Node3D).global_position)
			"skatepark": skate.append((lm as Node3D).global_position)
	nearest.call("Acampamento Farroupilha", camp)
	nearest.call("Campo de futebol", pitches)
	nearest.call("Parquinho", parks)
	nearest.call("Pista de skate", skate)
	if with_containers:
		nearest.call("Container de pessoas", _containers.filter(func(c): return is_instance_valid(c) and not c.lifting).map(
				func(c): return c.global_position))
	nearest.call("Torre avistada", get_tree().get_nodes_in_group("relay").filter(
			func(a): return a.spotted and a.is_alive()).map(func(a): return a.global_position))
	out.sort_custom(func(a, b): return (a[1] as Vector3).distance_to(from) < (b[1] as Vector3).distance_to(from))
	return out


## The named place a player stands in (shown on screen as they enter): the
## Farroupilha camp around its stage, '' elsewhere.
func area_name_at(at: Vector3) -> String:
	for lm in _landmark_nodes:
		if is_instance_valid(lm) and not lm.has_meta("pocket") \
				and String(lm.get_meta("landmark", {}).get("model", "")).contains("farroupilha/palco") \
				and Vector2(lm.global_position.x - at.x, lm.global_position.z - at.z).length() < 26.0:
			return "Acampamento Farroupilha"
	return ""


## A shell or a mech's cannon bursting by a storefront: it becomes its
## damaged variant (storefronts/damaged/*_danificada), on every peer.
func wreck_shops(at: Vector3, r := 5.0) -> void:
	for lm in _landmark_nodes.duplicate():
		if not is_instance_valid(lm):
			continue
		var l: Dictionary = lm.get_meta("landmark", {})
		var model: String = l.get("full", l.get("model", ""))
		if not model.contains("/storefronts/") or model.contains("/damaged/") or model.contains("_modulo_"):
			continue
		var box := AABB()
		var first := true
		for mi in (lm as Node3D).find_children("*", "MeshInstance3D", true, false):
			var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
		if first or not box.grow(r).has_point(at):
			continue
		var wrecked := model.get_base_dir().path_join("damaged/" + model.get_file().get_basename() + "_danificada.gltf")
		if not ResourceLoader.exists(wrecked):
			continue
		var nl := l.duplicate()
		nl.erase("full")
		nl.erase("solid")
		nl["model"] = wrecked
		_landmark_nodes.erase(lm)
		lm.queue_free()
		_landmark(nl)


## The green cross at a model's sign_cross marker (facing its -Z, the street).
func _cross_at(marker: Node3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.75, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(0.15, 1.0, 0.4)
	mat.emission_energy_multiplier = 2.2
	for size in [Vector3(0.8, 0.25, 0.1), Vector3(0.25, 0.8, 0.1)]:
		var mi := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = size
		mi.mesh = b
		mi.material_override = mat
		mi.position = Vector3(0, 0, -0.06)
		marker.add_child(mi)


## A glowing green pharmacy cross on the facade above the door.
func _cross_sign(pl: Dictionary) -> void:
	var door := Vector3(pl["door"][0], 0, pl["door"][1])
	var at := Vector3(pl["at"][0], 0, pl["at"][1])
	var space := get_world_3d().direct_space_state
	var g := space.intersect_ray(PhysicsRayQueryParameters3D.create(door + Vector3(0, 60, 0), door - Vector3(0, 40, 0), 1))
	var y: float = (g.position.y if g else 0.0) + 3.4
	var dir := (at - door)
	dir.y = 0
	if dir.length() < 0.1:
		return
	dir = dir.normalized()
	var from := Vector3(door.x, y, door.z) - dir * 0.5
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * 25.0, 1))
	if hit.is_empty():
		return
	var root := Node3D.new()
	add_child(root)
	_signs.append(root)
	var n: Vector3 = hit.normal
	n.y = 0
	n = n.normalized() if n.length() > 0.1 else -dir
	root.global_position = hit.position + n * 0.12
	root.look_at(root.global_position + n, Vector3.UP)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.75, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(0.15, 1.0, 0.4)
	mat.emission_energy_multiplier = 2.2
	for size in [Vector3(0.9, 0.28, 0.1), Vector3(0.28, 0.9, 0.1)]:
		var mi := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = size
		mi.mesh = b
		mi.material_override = mat
		mi.visibility_range_end = 180.0
		root.add_child(mi)


## After the map is in: the wall photos (always applied by the game), and in
## the released game - no map pipeline to bake them - the placed models and
## the removed objects of the map's user edits.
func _apply_edits() -> void:
	await get_tree().physics_frame
	Photos.apply_all(self, map_id)
	if not Edits.runtime():
		return
	var user := user_edits()
	var space := get_world_3d().direct_space_state
	for p in user.get("_props", []):
		if not p.has("model") or not (FileAccess.file_exists(p["model"]) if String(p["model"]).ends_with(".json") \
				else ResourceLoader.exists(p["model"])):
			continue
		var y: float = p.get("y", 0.0)
		if not p.has("y"):
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p["x"], 400, p["z"]), Vector3(p["x"], -100, p["z"]), 1))
			y = (hit.position.y if hit else 0.0) + float(p.get("y_offset", 0.0))
		var l := {"id": "prop", "model": p["model"], "pos": [p["x"], y, p["z"]], "yaw": deg_to_rad(float(p.get("yaw", 0.0))),
				"solid": p.get("solid", "box")}
		if p.has("label"):
			l["label"] = p["label"]
		for k in ["leisure", "scale", "parts"]:
			if p.has(k):
				l[k] = p[k]
		_landmark(l)
	for at in user.get("_remove", []):
		props.remove_near(Vector2(at[0], at[1]))
		for lm in _landmark_nodes:
			if is_instance_valid(lm) and Vector2(lm.global_position.x, lm.global_position.z).distance_to(Vector2(at[0], at[1])) < 1.0:
				lm.visible = false
				for b in lm.find_children("*", "CollisionObject3D", true, false):
					(b as CollisionObject3D).collision_layer = 0


## The item playing `role_name` on this map: the map editor's choice for the
## map ("_roles"), else the collection's roles.json, else common's.
func role(role_name: String) -> String:
	var r: String = user_edits().get("_roles", {}).get(role_name, "")
	return r if r != "" else Entities.role(collection, role_name)


func _spawn_pickup(kind: String, pos: Vector3, respawns: bool, fixed := false) -> Node:
	_pickup_seq += 1
	# on the ground itself: a navmesh point (the coarse 0.4 m navmesh lies up
	# to ~0.4 m above the grass), the editor's spot or a robot's drop left
	# a pala standing in the air
	var hit := get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.0, 0), pos - Vector3(0, 30.0, 0), 1))
	if hit:
		pos.y = hit.position.y
	return pickup_spawner.spawn({"id": _pickup_seq, "kind": kind, "pos": pos, "respawns": respawns, "fixed": fixed})


func _spawn_pickup_node(data: Variant) -> Node:
	var p: Area3D = Pickup.new()
	p.name = "P%d" % data["id"]
	p.kind = data["kind"]
	p.respawns = data["respawns"]
	p.fixed = data.get("fixed", false)
	p.position = data["pos"]
	return p


func _next_enemy_id() -> int:
	_enemy_seq += 1
	return _enemy_seq


func _spawn_enemy_node(data: Variant) -> Node:
	if data.get("variant", "") == "swarm":
		var sw: Node3D = preload("res://scripts/swarm.gd").new()
		sw.name = "E%d" % data["id"]
		sw.position = data["pos"]
		sw.count = data.get("n", 8)
		if multiplayer.is_server():
			sw.died.connect(director.on_enemy_killed) # one completed group, points already paid per unit
		return sw
	if data.get("variant", "") == "drone":
		var dr: CharacterBody3D = Drone.new()
		dr.name = "E%d" % data["id"]
		dr.position = data["pos"]
		if multiplayer.is_server():
			dr.died.connect(director.on_enemy_killed)
			dr.died.connect(_on_robot_killed)
		return dr
	var e: CharacterBody3D = Enemy.new()
	e.name = "E%d" % data["id"]
	e.position = data["pos"]
	e.dropping = data.get("drop", false)
	e.variant = data.get("variant", "trooper")
	e.commander = data.get("commander", false)
	e.post = data.get("post", Vector3.INF)
	if multiplayer.is_server() and e.variant == "collector":
		e.escaped.connect(_collector_escaped)
		e.rescued.connect(func(_c, by):
			if by and by.is_in_group("players"):
				award(by.get_multiplayer_authority(), 250, "civilian rescued"))
	if multiplayer.is_server():
		e.died.connect(director.on_enemy_killed)
		e.died.connect(_on_robot_killed)
	return e


## Server: send a dropship with `n` robots, split over two drop zones (3-4
## each) to spread the chaos: the first 60-140 m from `near`, the second
## 60-130 m further on and away from every player. Returns 1 when sent, 0
## while another ship is still busy, -1 when no zone with open sky was found.
func call_dropship(near: Vector3, n: int) -> int:
	if ships_root.get_children().any(func(sh): return sh.kind == "drop"):
		return 0
	var players := get_tree().get_nodes_in_group("players")
	var first: Array = _drop_zone(near, 60.0, 140.0, players)
	if first.is_empty():
		return -1
	var stops := [first]
	if n > 4:
		var second: Array = _drop_zone(first[0], 60.0, 130.0, players)
		if not second.is_empty():
			stops.append(second)
	for i in stops.size():         # share the robots out between the zones
		stops[i].append(n / stops.size() + (1 if i < n % stops.size() else 0))
	# once the players are getting on, a ship may bring a heavy mech (last
	# stop) and launch a drone (first stop) too
	# mechs still owed to the phase goal come for sure, one per ship, from a
	# few kills in; beyond the goal (or on free play) only now and then
	var mechs_out := 0
	for e in enemies_root.get_children():
		if e.get("variant") == "mech" and e.is_alive():
			mechs_out += 1
	var owed := _mech_goal() - _phase_mechs - mechs_out
	var mech := 1 if (owed > 0 and director.kills - _phase_kills >= 3) \
			or (director.kills - _phase_kills >= 6 and randf() < 0.4) else 0
	var drone := 1 if director.kills - _phase_kills >= 4 and randf() < 0.4 else 0
	for i in stops.size():
		stops[i].append(mech if i == stops.size() - 1 else 0)
		stops[i].append(drone if i == 0 else 0)
	var heading := Vector3(stops[0][0].x - near.x, 0, stops[0][0].z - near.z).normalized()
	if heading == Vector3.ZERO:
		heading = Vector3.FORWARD
	var cruise: float = max(Dropship.CRUISE_Y, city_top + 15.0)
	var start: Vector3 = stops[0][0] - heading * (map_reach() + 60.0)
	start.y = cruise
	_ship_seq += 1
	ship_spawner.spawn({"id": _ship_seq, "pos": start, "stops": stops, "cruise": cruise})
	return 1


## A street point min_d-max_d from `from`, 45 m+ from every player, reachable,
## with open sky over the beam and room for the hull: [point, hover height]
## (5 m above the highest roof within the 20 m wingspan, at least 22 m).
func _drop_zone(from: Vector3, min_d: float, max_d: float, players: Array) -> Array:
	var map := get_world_3d().navigation_map
	var space := get_world_3d().direct_space_state
	for attempt in 40:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		var pos := NavigationServer3D.map_get_closest_point(map, from + dir * randf_range(min_d, max_d))
		if not in_bounds(pos, 20.0):
			continue
		if players.any(func(pl): return pl.global_position.distance_to(pos) < 45.0):
			continue
		var path := NavigationServer3D.map_get_path(map, spawn_point, pos, true)
		if path.is_empty() or path[path.size() - 1].distance_to(pos) > 1.5:
			continue
		var roof := pos.y
		for dx in range(-13, 14, 3):
			for dz in range(-13, 14, 3):
				if dx * dx + dz * dz > 13 * 13:
					continue
				var top := pos + Vector3(dx, 0, dz)
				var q := PhysicsRayQueryParameters3D.create(top + Vector3(0, city_top + 10.0, 0), top + Vector3(0, -1.0, 0), 1 | ROOF_LAYER)
				var hit := space.intersect_ray(q)
				if hit:
					roof = max(roof, hit.position.y)
		var hover: float = max(Dropship.HOVER_Y, roof - pos.y + 5.0)
		if hover > 60.0:
			continue          # deep street canyon between towers: the beam would be absurd
		var clear := true
		for off in [Vector3.ZERO, Vector3(1.5, 0, 0), Vector3(-1.5, 0, 0), Vector3(0, 0, 1.5), Vector3(0, 0, -1.5)]:
			var q := PhysicsRayQueryParameters3D.create(pos + off + Vector3(0, 1.0, 0), pos + off + Vector3(0, hover, 0), 1)
			if not space.intersect_ray(q).is_empty():
				clear = false
				break
		if clear:
			return [pos, hover]
	return []


func _spawn_ship_node(data: Variant) -> Node:
	var s: Node3D = Dropship.new()
	s.name = "S%d" % data["id"]
	s.kind = data.get("kind", "drop")
	if multiplayer.is_server() and s.kind == "mother" and data.get("bring", false):
		s.carry = get_node_or_null(NodePath(data["container"]))
		s.carry_down = true
		s.on_stop = func(_i: int) -> bool: return true
	elif multiplayer.is_server() and s.kind == "mother":
		s.on_stop = func(_i: int) -> bool:
			var cont := get_node_or_null(NodePath(data["container"]))
			if cont and not cont.people.is_empty():
				s.carry = cont
			return true
		s.finished.connect(func(): _mother_left(s, data["container"]))
	s.position = data["pos"]
	s.stops = data["stops"]
	s.heading = Vector3(s.stops[0][0].x - s.position.x, 0, s.stops[0][0].z - s.position.z).normalized()
	s.cruise_y = data.get("cruise", Dropship.CRUISE_Y)
	s.map_exit = map_reach() + 80.0
	if multiplayer.is_server():
		s.release = func(at: Vector3, variant := "trooper"):
			enemy_spawner.spawn({"id": _next_enemy_id(), "pos": at, "drop": true, "variant": variant})
	return s


# ---- UI --------------------------------------------------------------------

## Title-screen music: the "menu" station.
var _menu_music: AudioStreamPlayer
func _play_menu_music() -> void:
	if Music.tracks("menu").is_empty() or DisplayServer.get_name() == "headless":
		return
	if _menu_music == null:
		_menu_music = AudioStreamPlayer.new()
		_menu_music.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_menu_music)
	_menu_music.volume_db = -6.0
	Music.playlist(_menu_music, "menu")


func _build_menu() -> void:
	_play_menu_music()
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	menu = Control.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(menu)

	# background: generated key art if present, otherwise a dark gradient
	if ResourceLoader.exists(MENU_BG):
		var bg := TextureRect.new()
		bg.texture = load(MENU_BG)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		menu.add_child(bg)
	else:
		var grad := Gradient.new()
		grad.set_color(0, Color(0.05, 0.06, 0.09))
		grad.set_color(1, Color(0.22, 0.07, 0.06))
		var gt := GradientTexture2D.new()
		gt.gradient = grad
		gt.fill_to = Vector2(1, 1)
		var bg := TextureRect.new()
		bg.texture = gt
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		menu.add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.18)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.82)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(36)
	style.border_color = Color(0.85, 0.2, 0.15, 0.9)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var title := Label.new()
	title.text = "City Invaders"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1.0, 0.32, 0.22))
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 10)
	box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Co-op in real cities"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 28)
	subtitle.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	box.add_child(subtitle)
	box.add_child(HSeparator.new())

	map_select = OptionButton.new()
	map_select.custom_minimum_size = Vector2(0, 56)
	map_select.add_theme_font_size_override("font_size", 26)
	for c in available_cities():
		var n: int = c[1].size()
		map_select.add_item("%s  (%d phase%s)" % [c[0], n, "s" if n > 1 else ""] if n > 1 else c[0])
	map_select.tooltip_text = "City (when joining, the host's city is used)"
	box.add_child(map_select)
	phase_select = OptionButton.new()
	phase_select.custom_minimum_size = Vector2(0, 48)
	phase_select.add_theme_font_size_override("font_size", 22)
	phase_select.tooltip_text = "Start at this phase"
	box.add_child(phase_select)
	map_select.item_selected.connect(func(_i): _fill_phases())
	_fill_phases()
	name_edit = _menu_edit("Your name", Settings.player_name)
	box.add_child(name_edit)
	var solo := Button.new()
	solo.text = "Play solo"
	solo.custom_minimum_size = Vector2(0, 64)
	solo.add_theme_font_size_override("font_size", 32)
	solo.pressed.connect(_solo)
	box.add_child(solo)
	box.add_child(_difficulty_button(56, 26))
	# Multiplayer: a screen of its own (host or join, with the host's address)
	var mp := Button.new()
	mp.text = "Multiplayer"
	mp.custom_minimum_size = Vector2(0, 64)
	mp.add_theme_font_size_override("font_size", 32)
	mp.pressed.connect(_show_multiplayer)
	box.add_child(mp)
	# Settings: a screen of its own (controls, sound, friendly fire, steering)
	var settings := Button.new()
	settings.text = "Settings"
	settings.custom_minimum_size = Vector2(0, 56)
	settings.add_theme_font_size_override("font_size", 28)
	settings.pressed.connect(_show_settings)
	box.add_child(settings)
	var extras := HBoxContainer.new()
	extras.add_theme_constant_override("separation", 12)
	box.add_child(extras)
	for spec in [["Studio", _open_studio], ["Mods", _show_mods], ["Quit", func(): get_tree().quit()]]:
		var b2 := Button.new()
		b2.text = spec[0]
		b2.custom_minimum_size = Vector2(0, 52)
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.add_theme_font_size_override("font_size", 26)
		b2.pressed.connect(spec[1])
		extras.add_child(b2)
	Settings.changed.connect(_refresh_sound)
	status_label = Label.new()
	status_label.text = "Mouse look · click shoot · keys in Controls · Esc pause"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 20)
	status_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	box.add_child(status_label)


func _menu_edit(placeholder: String, value: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.custom_minimum_size = Vector2(0, 56)
	e.add_theme_font_size_override("font_size", 28)
	return e


# ---- pause menu (Esc) ------------------------------------------------------
# The world keeps running (other players and robots don't stop in
# multiplayer); only the local player's input is suspended.

## Esc. Alone (solo, or hosting with nobody connected) the whole world
## freezes; with other players online only the menu opens and the round
## carries on for everyone.
func toggle_pause() -> void:
	if menu.visible or (_loading and _loading.visible):
		return
	paused = not paused
	if paused:
		_pause_shot = get_viewport().get_texture().get_image()     # the game as it was (for a report)
	pause_menu.visible = paused
	get_tree().paused = paused and multiplayer.get_peers().is_empty()
	restart_button.disabled = not multiplayer.is_server()   # only the host restarts the round
	restart_button.tooltip_text = "" if multiplayer.is_server() else "Only the host can restart the round"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED


## Freeze the world and fly the camera (solo only: in co-op the others'
## world can't stop). Leaving puts the player back where design mode began.
func toggle_design() -> void:
	if menu.visible or paused or (_loading and _loading.visible):
		return
	var p := _local_player()
	if p == null or p.dead:
		return
	if design and Edits.dirty(map_id) and not _leaving:
		_ask_leave_design()               # unsaved edits: save them first?
		return
	if not design and not multiplayer.get_peers().is_empty():
		if p._hud:
			p.objective = "Design mode is only available in solo games"
		return
	design = not design
	get_tree().paused = design
	p.process_mode = Node.PROCESS_MODE_ALWAYS if design else Node.PROCESS_MODE_INHERIT
	p.set_physics_process(true)     # also releases a DevAgent teleport freeze
	p.design = design
	_ensure_editor()
	editor_tools.visible = design
	inspector.visible = design
	editor_menu.visible = design
	if design:
		_design_from = p.global_transform
		_design_pitch = p.pitch
	else:
		design_deselect()
		p.global_transform = _design_from
		p.pitch = _design_pitch
		p.head.rotation.x = _design_pitch
		p.velocity = Vector3.ZERO
	# the editor works with the mouse (menus, palette, picking); right drag or
	# the arrow keys turn the view
	# the editor's pointer is a free crosshair (the mouse moves it, the view
	# stays; right drag or the arrows turn it); Tab locks the mouse to look around
	if design:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		inspector.show_selection(design_selections)
	else:
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Design mode: what the click picked (also read by the DevAgent).
var design_selection := {}
var design_label := ""
var design_selections: Array = []   # everything picked (Shift+click adds); design_selection is the last
var map_editor: PanelContainer
var editor_tools: PanelContainer
var inspector: PanelContainer
var editor_menu: Control
static var _pending_edit := ""       # File > Open phase: reload, then edit this phase


func _ensure_editor() -> void:
	if map_editor:
		return
	var layer := CanvasLayer.new()
	layer.layer = 30
	layer.process_mode = Node.PROCESS_MODE_ALWAYS       # the world is paused in design mode
	add_child(layer)
	map_editor = MapEditor.new()
	layer.add_child(map_editor)
	editor_tools = EditorTools.new()
	layer.add_child(editor_tools)
	inspector = Inspector.new()
	inspector.tools = editor_tools
	layer.add_child(inspector)
	editor_menu = EditorMenu.new()
	layer.add_child(editor_menu)
	editor_tools.status.connect(func(t): editor_menu.set_status(t))
	# a building's panel stands left of the inspector
	map_editor.offset_right = -410
	map_editor.offset_left = -840
	map_editor.anchor_top = 0.0
	map_editor.offset_top = 48
	for c in [editor_tools, inspector, editor_menu]:
		c.visible = false


## File > Open phase: back through the title screen into that phase, in design mode.
func edit_phase(id: String) -> void:
	_pending_edit = id
	_leave_to_title()
func design_select(from: Vector3, dir: Vector3, additive := false) -> void:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 300.0, 1 | 2 | 16 | 32 | 64 | Photos.PICK_LAYER | props.FOLIAGE_LAYER)
	q.hit_from_inside = true          # flying inside a vehicle or a stall: pick it
	q.collide_with_areas = true       # tree crowns
	var p := _local_player()
	if p:
		q.exclude = [p.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if editor_tools and editor_tools.placing != "" and not hit.is_empty():
		editor_tools.place_at(map_id, hit.position)
		return
	if hit.is_empty():
		if not additive:
			design_deselect()
		return
	# the thing itself: an NPC / vehicle / prop root, or the city mesh that was hit
	var node: Node = hit.collider
	var what := "building"
	var tree_crown: Variant = null
	while node and node != self:
		if node.has_meta("tree_crown"):
			what = "prop"              # an OSM tree: its crown or its trunk
			tree_crown = node.get_meta("tree_crown")
			break
		if node.has_meta("photo"):
			what = "photo"             # a photo on a wall (photos.gd)
			break
		if node.has_meta("landmark") and String(node.get_meta("landmark").get("id", "")) == "prop":
			what = "object"            # a model placed by hand (monument, camp, flag...)
			break
		if node.get_parent() in [civilians_root, enemies_root, traffic_root, pickups_root]:
			what = {civilians_root: "pedestrian", enemies_root: "robot", traffic_root: "vehicle", pickups_root: "pickup"}[node.get_parent()]
			break
		if node.get_parent() == props:
			what = "prop"
			break
		node = node.get_parent()
	if what not in ["pedestrian", "robot", "vehicle", "pickup", "photo"]:
		# a small thing without collision the ray passed over (a pala or a gun on
		# the ground, a chimarrão kit...): the one nearest the line of sight, in
		# front of what was hit - even in front of a tree or a camp's tent
		var reach := from.distance_to(hit.position) + 0.5
		var best_ray := 0.7
		for pk in pickups_root.get_children():
			if not pk.get("active"):
				continue
			var at: Vector3 = (pk as Node3D).global_position + Vector3(0, 0.2, 0)
			var t := (at - from).dot(dir)
			var dr := (from + dir * t).distance_to(at)
			if t > 0.0 and t < reach and dr < best_ray:
				best_ray = dr
				node = pk
				what = "pickup"
				tree_crown = null
		for lm in _landmark_nodes:
			if not is_instance_valid(lm) or not (lm as Node3D).find_children("*", "CollisionObject3D", true, false).is_empty():
				continue
			var at: Vector3 = (lm as Node3D).global_position + Vector3(0, 0.3, 0)
			var t := (at - from).dot(dir)
			var dr := (from + dir * t).distance_to(at)
			if t > 0.0 and t < reach and dr < best_ray:
				best_ray = dr
				node = lm
				what = "object"
	if what == "building":
		# a small placed model without collision (chimarrão kit, kettle...) near the click
		var best_d := 1.5
		for lm in _landmark_nodes:
			if not is_instance_valid(lm):
				continue
			var d := (lm as Node3D).global_position.distance_to(hit.position)
			if d < best_d and (lm as Node3D).find_children("*", "CollisionObject3D", true, false).is_empty():
				best_d = d
				node = lm
				what = "object"
		# a knocked-over bin or lamp has no collision any more
		for dp in props.destructibles:
			if dp["broken"]:
				var d := (dp["root"] as Node3D).global_position.distance_to(hit.position)
				if d < best_d:
					best_d = d
					node = dp["root"]
					what = "prop"
		# pickups are trigger areas the ray passes through (cans, cuias, guns...)
		for pk in pickups_root.get_children():
			var d := (pk as Node3D).global_position.distance_to(hit.position)
			if d < best_d:
				best_d = d
				node = pk
				what = "pickup"
	if what == "building":
		node = hit.collider.get_parent()
		# the city's ground meshes (streets, pavements, grass, water...) are not buildings
		var mesh_name := String(node.name) if node else ""
		for g in ["paving", "asphalt", "sidewalk", "curb", "grass", "ground", "plaza", "water", "promenade", "quay", "markings", "zebra"]:
			if mesh_name.begins_with(g):
				what = "ground"
				break
	var target := node as Node3D
	var box := AABB(hit.position - Vector3.ONE * 0.5, Vector3.ONE)
	if tree_crown != null:
		var c: Vector3 = tree_crown
		box = AABB(Vector3(c.x - 2.5, _ground_y(c), c.z - 2.5), Vector3(5.0, c.y - _ground_y(c) + 2.5, 5.0))
	if target and what != "building":
		var first := true
		for mi in target.find_children("*", "MeshInstance3D", true, false):
			var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
	var extra := ""
	if what == "pedestrian":
		extra = Civilian.MODELS[target.model_idx % Civilian.MODELS.size()].get_file().get_basename()
	elif what == "vehicle":
		extra = Car.MODELS[target.model_idx % Car.MODELS.size()].get_file().get_basename()
	elif what == "robot":
		extra = str(target.get("variant"))
	elif what == "photo":
		extra = String(target.get_meta("photo"))
	elif what == "pickup":
		extra = str(target.get("kind"))
	elif what == "prop" and tree_crown != null:
		extra = "tree"
	elif what == "prop" and target:
		extra = String(target.get_meta("kind", ""))
	elif what == "object":
		extra = String(target.get_meta("landmark", {}).get("model", "")).get_file()
	elif what == "building":
		_ensure_editor()
		map_editor.set("_wall_normal", hit.normal)
		var b: Dictionary = map_editor.select(map_id, what, hit.position)
		extra = ("%s  %s" % [b["name"], b["id"]]) if not b.is_empty() else String(hit.collider.get_parent().name)
	if what != "building" and map_editor:
		map_editor.close()
	var entry := {"what": what, "name": String(target.name) if target else "", "detail": extra,
			"pos": hit.position, "normal": hit.normal, "node": target, "box": box}
	# the same thing again (ground is one big mesh: the same spot of it)
	var same := func(e): return e["what"] == entry["what"] and e["detail"] == entry["detail"] and e["name"] == entry["name"] \
			and (what != "ground" or (e["pos"] as Vector3).distance_to(entry["pos"]) < 1.5)
	var at := -1
	for i in design_selections.size():
		if same.call(design_selections[i]):
			at = i
	if additive:
		# Shift+click: add it, or take it out again
		if at >= 0:
			design_selections.remove_at(at)
		else:
			design_selections.append(entry)
	elif at >= 0 and design_selections.size() == 1:
		design_selections = []      # a second click on the selected thing clears it
	else:
		design_selections = [entry]
	_show_selection()


## Design mode: Q / E turn the selected placed model (15°, saved), unless a
## model is being placed (then they turn that one).
func design_turn(deg: float) -> bool:
	if design_selection.is_empty() or (editor_tools and editor_tools.placing != ""):
		return false
	var node: Node3D = design_selection.get("node")
	if node == null or not is_instance_valid(node) or design_selection["what"] != "object" \
			or String(node.get_meta("landmark", {}).get("id", "")) != "prop":
		return false
	var entry: Dictionary = editor_tools.prop_entry(map_id, node)
	var yaw := float(entry.get("yaw", rad_to_deg(node.rotation.y))) + deg
	editor_tools.update_prop(map_id, node, {"yaw": yaw})
	_show_selection()
	return true


## Design mode drag and drop: press on the selected object and drag - a
## placed model moves over the ground, a wall photo slides on its wall; the
## spot is saved when the button is let go. Generated objects stay put.
var _drag: Dictionary = {}
func design_drag_start(from: Vector3, dir: Vector3) -> bool:
	if design_selection.is_empty():
		return false
	var node: Node3D = design_selection.get("node")
	if node == null or not is_instance_valid(node):
		return false
	var what: String = design_selection["what"]
	var placed: bool = what == "object" and String(node.get_meta("landmark", {}).get("id", "")) == "prop"
	if not placed and what != "photo":
		return false
	# the press must be on (or right by) the selected thing
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 300.0, 1 | 2 | 16 | 32 | 64 | Photos.PICK_LAYER)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var box: AABB = design_selection.get("box", AABB())
	var on_it: bool = box.grow(0.3).intersects_ray(from, dir) != null \
			or (not hit.is_empty() and hit.collider is Node and node.is_ancestor_of(hit.collider))
	if not on_it:
		return false
	_drag = {"node": node, "what": what, "from": node.global_position, "moved": false}
	_drag["ground"] = _ground_y(node.global_position)
	return true


func design_drag_move(from: Vector3, dir: Vector3) -> void:
	if _drag.is_empty() or not is_instance_valid(_drag["node"]):
		return
	var node: Node3D = _drag["node"]
	if _drag["what"] == "photo":
		var p := Photos.entry(map_id, String(node.get_meta("photo")))
		if p.is_empty():
			return
		var b := Photos.basis_of(p)
		var plane := Plane(b.z, node.global_position)
		var at = plane.intersects_ray(from, dir)
		if at == null:
			return
		node.global_position = at
		_drag["moved"] = true
		return
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 400.0, 1)
	var own: Array[RID] = []
	for b in node.find_children("*", "CollisionObject3D", true, false):
		own.append((b as CollisionObject3D).get_rid())
	q.exclude = own
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	# only onto open ground (not up a wall or onto a roof), close to the ground it stood on
	if hit.normal.y < 0.75 or absf(hit.position.y - float(_drag.get("ground", hit.position.y))) > 3.0:
		return
	# furniture stays off the carriageway: no dropping it onto the asphalt
	var under: Node = hit.collider
	while under and under != self:
		if String(under.name).begins_with("asphalt") or String(under.name).begins_with("markings"):
			return
		under = under.get_parent()
	var lift: float = node.global_position.y - _ground_y(node.global_position)
	node.global_position = Vector3(hit.position.x, hit.position.y + maxf(lift, 0.0), hit.position.z)
	_drag["moved"] = true


func design_drag_end() -> void:
	if _drag.is_empty():
		return
	var d := _drag
	_drag = {}
	var node: Node3D = d["node"]
	if not d["moved"] or not is_instance_valid(node):
		return
	if d["what"] == "photo":
		var id := String(node.get_meta("photo"))
		var p := Photos.entry(map_id, id)
		var c: Vector3 = node.global_position - Photos.basis_of(p).z * float(p.get("out", 0.06))
		Photos.update(self, map_id, id, {"pos": [c.x, c.y, c.z]})
	else:
		var to := node.global_position
		node.global_position = d["from"]           # update_prop moves it there and saves
		editor_tools.update_prop(map_id, node, {"x": snappedf(to.x, 0.01), "z": snappedf(to.z, 0.01)}, d["from"])
		node.global_position = to
	design_selection["pos"] = node.global_position
	_show_selection()


func _ground_y(at: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 3, 0), at - Vector3(0, 50, 0), 1)
	var own: Array[RID] = []
	if not _drag.is_empty() and is_instance_valid(_drag["node"]):
		for b in (_drag["node"] as Node3D).find_children("*", "CollisionObject3D", true, false):
			own.append((b as CollisionObject3D).get_rid())
	q.exclude = own
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else at.y


## Draw the selection (yellow paint or wire boxes), tell the panels.
func _show_selection() -> void:
	for m in get_tree().get_nodes_in_group("design_marks"):
		m.free()
	_untint_selection()
	design_selections = design_selections.filter(func(e): return e["node"] == null or is_instance_valid(e["node"]))
	design_selection = {} if design_selections.is_empty() else design_selections[-1]
	var last: Dictionary = design_selection
	if editor_tools:
		editor_tools.on_selection(map_id, last, last.get("node"))
	if inspector:
		inspector.show_selection(design_selections)
	if last.is_empty():
		design_label = ""
		if map_editor:
			map_editor.close()
		return
	if last["what"] != "building" and map_editor:
		map_editor.close()
	if design_selections.size() > 1:
		design_label = "%d OBJECTS SELECTED  ·  Shift+click adds or removes  ·  F1 talks to Claude about them" % design_selections.size()
	else:
		var p: Vector3 = last["pos"]
		design_label = "%s  %s  %s   (%.0f, %.0f, %.0f)" % [String(last["what"]).to_upper(), last["name"] if last["what"] != "building" else "",
				last["detail"], p.x, p.y, p.z]
	for e in design_selections:
		# a separate object is painted yellow; buildings and streets are part of
		# the city mesh, so they get a yellow wire box instead
		var target: Node3D = e["node"]
		if target and not e["what"] in ["building", "ground"] and _tint_selection(target):
			continue
		var box: AABB = e["box"]
		var mark := MeshInstance3D.new()
		mark.name = "DesignMark"
		mark.add_to_group("design_marks")
		var im := ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.1)
		mat.no_depth_test = true
		im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		for edge in [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
			for c in edge:
				im.surface_add_vertex(box.position + box.size * Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1))
		im.surface_end()
		mark.mesh = im
		add_child(mark)


var _tinted: Array = []           # design mode: meshes painted yellow by the selection


var _leave_dialog: ConfirmationDialog


## Esc in design mode with nothing selected: ask before going back to the game.
## Leaving design mode; with unsaved edits: save them, discard them (the
## phase reloads as saved) or stay.
var _leaving := false
func _ask_leave_design() -> void:
	if _leave_dialog == null:
		_leave_dialog = ConfirmationDialog.new()
		_leave_dialog.title = "Design mode"
		_leave_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_leave_dialog)
		_leave_dialog.add_button("Don't save", true, "discard")
		_leave_dialog.confirmed.connect(func():
			Edits.save(map_id)
			_leave_design_now())
		_leave_dialog.custom_action.connect(func(action: StringName):
			if action == "discard":
				_leave_dialog.hide()
				Edits.discard(map_id)
				if studio_session:
					edit_phase(map_id)       # back to the map as saved
				else:
					_leave_design_now())     # what was placed goes away at the next load
		_leave_dialog.canceled.connect(func(): Input.mouse_mode = Input.MOUSE_MODE_CAPTURED)
	if _leave_dialog.visible:
		return
	var unsaved := Edits.dirty(map_id)
	_leave_dialog.dialog_text = "You have unsaved changes on this map.\nSave them before going back to the game?" \
			if unsaved else "Leave design mode and go back to the game?"
	_leave_dialog.ok_button_text = "Save and leave" if unsaved else "Leave"
	_leave_dialog.cancel_button_text = "Stay"
	for b in _leave_dialog.get_children(true):
		if b is Button and b.text == "Don't save":
			b.visible = unsaved
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_leave_dialog.popup_centered()


func _leave_design_now() -> void:
	_leaving = true
	if design:
		toggle_design()
	_leaving = false


func design_deselect() -> void:
	design_selections = []
	_show_selection()


func _tint_selection(target: Node3D) -> bool:
	var meshes := target.find_children("*", "MeshInstance3D", true, false)
	if target is MeshInstance3D:
		meshes.append(target)
	if meshes.is_empty():
		return false
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.55)       # the colour of the wire box
	for mi in meshes:
		(mi as MeshInstance3D).material_overlay = mat
		_tinted.append(mi)
	return true


func _untint_selection() -> void:
	for mi in _tinted:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = null
	_tinted.clear()


var _studio: PanelContainer
var studio_session := false       # a phase opened from the Studio: no robots, design mode


func _open_studio() -> void:
	if _studio == null:
		var layer := CanvasLayer.new()
		layer.layer = 45
		add_child(layer)
		_studio = Studio.new()
		layer.add_child(_studio)
		_studio.closed.connect(func(): _studio.visible = false)
		_studio.edit_phase.connect(_studio_edit)
	_studio.visible = true
	_studio.refresh()


## Studio: open one phase for editing - solo, no robots, already flying in design mode.
func _studio_edit(id: String) -> void:
	if _studio:
		_studio.visible = false
	studio_session = true
	await _solo(id)
	director.set_process(false)
	for e in enemies_root.get_children():
		e.queue_free()
	toggle_design()


func _local_player() -> Node3D:
	for pl in players_root.get_children():
		if pl.is_multiplayer_authority():
			return pl
	return null


## Server: everything back to the start - robots removed, director and
## kills reset, pickups restored, every player respawned at the start.
func _restart_round() -> void:
	if not multiplayer.is_server():
		return
	for e in enemies_root.get_children():
		e.queue_free()
	for sh in ships_root.get_children():
		sh.queue_free()
	reset_containers.rpc()
	if _exit:
		close_exit.rpc()
	_phase_kills = 0
	_phase_mechs = 0
	_phase_civ_lost = 0
	_victory = false
	scores = {}
	for pl in players_root.get_children():
		pl.set_score.rpc_id(pl.get_multiplayer_authority(), 0, 0, "new round")
	director.set_process(true)
	director.reset()
	props.restore_all.rpc()
	for pk in pickups_root.get_children():
		if pk.respawns:
			pk.active = true
		else:
			pk.queue_free()      # director drops
	for pl in players_root.get_children():
		pl.reset_round.rpc_id(pl.get_multiplayer_authority())
	if paused:
		toggle_pause()
	for c in civilians_root.get_children():
		c.queue_free()
	civ_killed = 0
	await get_tree().create_timer(0.5).timeout
	director.populate()
	_spawn_civilians(civilians_wanted())
	_spawn_vendors()
	_spawn_police()
	_spawn_leisure_people()


func _leave_to_title() -> void:
	paused = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	get_tree().reload_current_scene()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if design:
			# Esc stops placing, then clears the selection, then leaves design mode
			if editor_tools and editor_tools.placing != "":
				editor_tools.choose("")
			elif not design_selection.is_empty():
				design_deselect()
			else:
				_ask_leave_design()
			return
		if _controls and _controls.visible:
			_controls.closed.emit()
			_controls.visible = false
			return
		if _settings and _settings.visible:
			_settings.visible = false
			return
		if _multiplayer_menu and _multiplayer_menu.visible:
			_multiplayer_menu.visible = false
			return
		toggle_pause()
	elif Settings.is_event(event, "mute"):
		Settings.toggle_mute()
	elif Settings.is_event(event, "design"):
		toggle_design()


func _show_controls() -> void:
	if _controls == null:
		var layer := CanvasLayer.new()
		layer.layer = 40
		layer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(layer)
		_controls = ControlsMenu.new()
		layer.add_child(_controls)
	_controls.visible = true


var _settings: Control
var _multiplayer_menu: Control


## A sub-screen over the menus (Settings, Multiplayer): shade, framed panel,
## title; returns the box to fill. Esc or its Back button closes it.
func _sub_screen(title_text: String) -> Array:
	var layer := CanvasLayer.new()
	layer.layer = 35                      # over the menus, under Controls (40)
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.6)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.92)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(32)
	style.border_color = Color(0.85, 0.2, 0.15, 0.9)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1.0, 0.32, 0.22))
	box.add_child(title)
	return [root, box]


func _sub_screen_back(root: Control, box: VBoxContainer) -> void:
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(0, 60)
	back.add_theme_font_size_override("font_size", 30)
	back.pressed.connect(func(): root.visible = false)
	box.add_child(back)
	var hint := Label.new()
	hint.text = "Esc goes back"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	box.add_child(hint)


## Multiplayer: host a game or join one by the host's address.
func _show_multiplayer() -> void:
	if _multiplayer_menu == null:
		var s := _sub_screen("Multiplayer")
		_multiplayer_menu = s[0]
		var box: VBoxContainer = s[1]
		address_edit = _menu_edit("Host address (IP, e.g. Tailscale)", "127.0.0.1")
		box.add_child(address_edit)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		box.add_child(row)
		for spec in [["Host game", _host], ["Join game", _join]]:
			var b := Button.new()
			b.text = spec[0]
			b.custom_minimum_size = Vector2(0, 60)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_font_size_override("font_size", 30)
			b.pressed.connect(func():
				_multiplayer_menu.visible = false
				spec[1].call())
			row.add_child(b)
		var hint := Label.new()
		hint.text = "Host: others join your IP on port %d (when joining, the host's city is used)" % PORT
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		hint.add_theme_font_size_override("font_size", 18)
		hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
		box.add_child(hint)
		_sub_screen_back(_multiplayer_menu, box)
	_multiplayer_menu.visible = true


## Settings: its own screen, from the title menu and the pause menu.
func _show_settings() -> void:
	if _settings == null:
		var sc := _sub_screen("Settings")
		_settings = sc[0]
		var box: VBoxContainer = sc[1]
		var ctl := Button.new()
		ctl.text = "Controls"
		ctl.custom_minimum_size = Vector2(0, 60)
		ctl.add_theme_font_size_override("font_size", 30)
		ctl.pressed.connect(_show_controls)
		box.add_child(ctl)
		box.add_child(_sound_button(60, 30))
		box.add_child(_ff_button(60, 30))
		box.add_child(_gfx_button(60, 30))
		box.add_child(_res_button(60, 30))
		box.add_child(_ssao_button(60, 30))
		box.add_child(_difficulty_button(60, 30))
		var steer_row := HBoxContainer.new()
		steer_row.add_theme_constant_override("separation", 16)
		var steer_label := Label.new()
		steer_label.text = "Steering"
		steer_label.add_theme_font_size_override("font_size", 28)
		steer_row.add_child(steer_label)
		var steer := HSlider.new()
		steer.min_value = 0.2
		steer.max_value = 1.0
		steer.step = 0.05
		steer.value = Settings.steering
		steer.custom_minimum_size = Vector2(280, 40)
		steer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		steer.tooltip_text = "How sharply vehicles turn with A / D"
		steer.value_changed.connect(Settings.set_steering)
		steer_row.add_child(steer)
		box.add_child(steer_row)
		_sub_screen_back(_settings, box)
	_settings.visible = true


## The graphics preset (Settings): which screen effects run.
func apply_graphics() -> void:
	var env := get_world_3d().environment if get_world_3d() else null
	if env == null:
		return
	var q: String = Settings.graphics
	env.ssil_enabled = q == "high"
	env.ssao_enabled = q != "low"
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED if q == "low" else Viewport.MSAA_2X
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.directional_shadow_max_distance = 150.0 if q == "low" else 250.0
	for b in _gfx_buttons:
		(b as Button).text = "Graphics: %s" % q.to_upper()
	# the resolution: automatic, or held where the player put it
	dynamic_resolution = Settings.resolution == "auto"
	if not dynamic_resolution:
		_set_render_scale(float(Settings.resolution) / 100.0)
	else:
		_auto_resolution_start()
	env.ssao_enabled = env.ssao_enabled and Settings.ssao
	for b in _res_buttons:
		(b as Button).text = "Resolution: %s" % Settings.resolution_label()
	for b in _ssao_buttons:
		(b as Button).text = "Ambient occlusion: %s" % ("ON" if Settings.ssao else "OFF")


var _diff_buttons := []
func _difficulty_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.tooltip_text = "EASY: as before · MEDIUM: tougher robots, more of them · HARD: tough, accurate, and losing 30% of the people loses the phase"
	b.pressed.connect(Settings.cycle_difficulty)
	_diff_buttons.append(b)
	b.text = "Difficulty: %s" % Settings.difficulty.to_upper()
	if not Settings.changed.is_connected(_refresh_difficulty):
		Settings.changed.connect(_refresh_difficulty)
	return b


func _refresh_difficulty() -> void:
	for b in _diff_buttons:
		if is_instance_valid(b):
			(b as Button).text = "Difficulty: %s" % Settings.difficulty.to_upper()


## Every peer: the round's difficulty (the host's choice).
const Difficulty := preload("res://scripts/difficulty.gd")
@rpc("authority", "call_local", "reliable")
func set_difficulty(lv: String) -> void:
	Difficulty.level = lv
	Tune.robot_sight_m = Difficulty.get_value("sight")
	Tune.pala_absorb = Difficulty.get_value("pala_absorb")


var _res_buttons := []
func _res_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.tooltip_text = "AUTO: lowered when the frame rate drops · 100 %: every pixel drawn · 85 / 67 / 50 %: drawn smaller and scaled up (MetalFX on a Mac, FSR elsewhere): much faster on large screens"
	b.pressed.connect(Settings.cycle_resolution)
	_res_buttons.append(b)
	b.text = "Resolution: %s" % Settings.resolution_label()
	return b


var _ssao_buttons := []
func _ssao_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.tooltip_text = "Soft shadows in corners and under things. Costly on a large screen (about a quarter of the frame)"
	b.pressed.connect(Settings.toggle_ssao)
	_ssao_buttons.append(b)
	b.text = "Ambient occlusion: %s" % ("ON" if Settings.ssao else "OFF")
	return b


var _gfx_buttons := []
func _gfx_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.tooltip_text = "LOW: fastest · MEDIUM: shadows and ambient occlusion · HIGH: also bounced light (costly on large screens)"
	b.pressed.connect(Settings.cycle_graphics)
	_gfx_buttons.append(b)
	b.text = "Graphics: %s" % Settings.graphics.to_upper()
	return b


func _sound_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.pressed.connect(Settings.toggle_mute)
	_sound_buttons.append(b)
	_refresh_sound()
	return b


func _ff_button(height: int, font: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font)
	b.tooltip_text = "Your shots also hurt civilians; officers you shoot shoot back"
	b.pressed.connect(Settings.toggle_friendly_fire)
	_ff_buttons.append(b)
	_refresh_sound()
	return b


func _refresh_sound() -> void:
	for b in _sound_buttons:
		(b as Button).text = "Sound: OFF (%s)" % Settings.key_label("mute") if Settings.muted \
				else "Sound: ON (%s)" % Settings.key_label("mute")
	for b in _ff_buttons:
		(b as Button).text = "Friendly fire: ON" if Settings.friendly_fire else "Friendly fire: OFF"


func _build_pause_menu() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	layer.process_mode = Node.PROCESS_MODE_ALWAYS     # its buttons work while the tree is paused
	add_child(layer)
	pause_menu = Control.new()
	pause_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.visible = false
	layer.add_child(pause_menu)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.9)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(32)
	style.border_color = Color(0.85, 0.2, 0.15, 0.9)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1.0, 0.32, 0.22))
	box.add_child(title)
	for spec in [["Resume", toggle_pause], ["Restart round", _restart_round], ["Settings", _show_settings],
			["Report a problem or an idea", _show_report], ["Main menu", _leave_to_title], ["Quit", func(): get_tree().quit()]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(0, 60)
		b.add_theme_font_size_override("font_size", 30)
		b.pressed.connect(spec[1])
		box.add_child(b)
		if spec[0] == "Restart round":
			restart_button = b
	var keys := Label.new()
	keys.text = "Controls, sound, friendly fire and steering in Settings · Esc resumes"
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.add_theme_font_size_override("font_size", 20)
	keys.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	box.add_child(keys)



## Pause menu > Report: a bug or an idea goes to the City Invaders server
## (Online.report) with the map, your position and, if you like, a picture
## of the game as it was when you paused.
var _pause_shot: Image
var _report: PanelContainer
func _show_report() -> void:
	if _report == null:
		_report = PanelContainer.new()
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.05, 0.06, 0.08, 0.97)
		st.set_corner_radius_all(12)
		st.set_content_margin_all(24)
		st.border_color = Color(0.3, 0.85, 1.0)
		st.set_border_width_all(2)
		_report.add_theme_stylebox_override("panel", st)
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(620, 0)
		box.add_theme_constant_override("separation", 10)
		_report.add_child(box)
		var title := Label.new()
		title.text = "Report a problem or an idea"
		title.add_theme_font_size_override("font_size", 28)
		box.add_child(title)
		var kind := OptionButton.new()
		kind.name = "kind"
		for k in ["Something is wrong (bug)", "An idea / improvement", "Other"]:
			kind.add_item(k)
		box.add_child(kind)
		var text := TextEdit.new()
		text.name = "text"
		text.placeholder_text = "What happened, or what would make the game better?"
		text.custom_minimum_size = Vector2(0, 180)
		text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		box.add_child(text)
		var shot := CheckBox.new()
		shot.name = "shot"
		shot.text = "Attach a picture of the game as it was"
		shot.button_pressed = true
		box.add_child(shot)
		var status := Label.new()
		status.name = "status"
		status.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
		box.add_child(status)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		box.add_child(row)
		var cancel := Button.new()
		cancel.text = "Close"
		cancel.pressed.connect(func(): _report.visible = false)
		row.add_child(cancel)
		var send := Button.new()
		send.name = "send"
		send.text = "Send"
		send.pressed.connect(_send_report)
		row.add_child(send)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.add_child(_report)
		pause_menu.add_child(center)
	_report.find_child("status", true, false).text = "" if Online.enabled() else "No server configured in this build."
	(_report.find_child("text", true, false) as TextEdit).text = ""
	(_report.find_child("send", true, false) as Button).disabled = false
	_report.visible = true
	_report.get_parent().visible = true


func _send_report() -> void:
	var text := (_report.find_child("text", true, false) as TextEdit).text.strip_edges()
	var status: Label = _report.find_child("status", true, false)
	if text.length() < 5:
		status.text = "Please write a few words."
		return
	var kind: String = ["bug", "idea", "other"][(_report.find_child("kind", true, false) as OptionButton).selected]
	var png := PackedByteArray()
	if (_report.find_child("shot", true, false) as CheckBox).button_pressed and _pause_shot:
		var img: Image = _pause_shot.duplicate()
		if img.get_width() > 1600:
			img.resize(1600, int(1600.0 * img.get_height() / img.get_width()))
		png = img.save_png_to_buffer()
	var extra := {"map": map_id}
	var p := _local_player()
	if p:
		extra["position"] = [snappedf(p.global_position.x, 0.1), snappedf(p.global_position.y, 0.1), snappedf(p.global_position.z, 0.1)]
	status.text = "Sending..."
	(_report.find_child("send", true, false) as Button).disabled = true
	Online.report(kind, text, extra, png, func(ok: bool, msg: String):
		status.text = msg
		(_report.find_child("send", true, false) as Button).disabled = ok)


# ---- mods (scripts/mods.gd, docs/MODDING.md) ------------------------------------

const Mods := preload("res://scripts/mods.gd")
var _mods_panel: PanelContainer
var _mods_list: VBoxContainer
var _mods_status: Label


## Title screen > Mods: the published mods, Install / Remove.
func _show_mods() -> void:
	if _mods_panel == null:
		_mods_panel = PanelContainer.new()
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.04, 0.05, 0.07, 0.97)
		st.set_corner_radius_all(12)
		st.set_content_margin_all(22)
		st.border_color = Color(0.3, 0.85, 1.0)
		st.set_border_width_all(2)
		_mods_panel.add_theme_stylebox_override("panel", st)
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(820, 560)
		box.add_theme_constant_override("separation", 10)
		_mods_panel.add_child(box)
		var title := Label.new()
		title.text = "Mods - maps changed by other players"
		title.add_theme_font_size_override("font_size", 30)
		box.add_child(title)
		var how := Label.new()
		how.text = "Share your own: open a phase in the map editor (F2), then File > Share these edits as a mod."
		how.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
		how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(how)
		_mods_status = Label.new()
		_mods_status.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
		box.add_child(_mods_status)
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(scroll)
		_mods_list = VBoxContainer.new()
		_mods_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mods_list.add_theme_constant_override("separation", 8)
		scroll.add_child(_mods_list)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		box.add_child(row)
		var again := Button.new()
		again.text = "Refresh"
		again.pressed.connect(_load_mods)
		row.add_child(again)
		var close := Button.new()
		close.text = "Close"
		close.pressed.connect(func(): _mods_panel.get_parent().visible = false)
		row.add_child(close)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.add_child(_mods_panel)
		menu.add_child(center)
	_mods_panel.get_parent().visible = true
	_load_mods()


## A mod's id as text (JSON numbers come back as floats).
static func _mod_id(it: Dictionary) -> String:
	var v = it.get("id", "")
	return str(int(v)) if v is float else str(v)


func _load_mods() -> void:
	for c in _mods_list.get_children():
		c.queue_free()
	if Edits.has_sources():
		_mods_status.text = "Playing from the sources: installed mods apply in the released game (CITY_INVADERS_NO_SOURCES=1 to try them here)."
	else:
		_mods_status.text = "Loading..."
	Online.list_mods(func(items: Array, ok: bool):
		if not ok:
			_mods_status.text = "No connection to the server."
			return
		if not Edits.has_sources():
			_mods_status.text = "" if not items.is_empty() else "No mods published yet - be the first!"
		var maps := all_maps().map(func(m): return m[0])
		var installed := Mods.installed_mods()
		for it in items:
			var line := HBoxContainer.new()
			var text := Label.new()
			text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			text.text = "%s  v%s  ·  by %s  ·  %d downloads\n%s" % [it.get("name", ""), it.get("version", ""),
					it.get("author", ""), int(it.get("downloads", 0)), String(it.get("description", "")).left(220)]
			line.add_child(text)
			var on_map := ""
			for m in installed:
				if str(installed[m].get("id", "")) == _mod_id(it):
					on_map = m
			var b := Button.new()
			b.custom_minimum_size = Vector2(130, 44)
			b.text = "Remove" if on_map != "" else "Install"
			b.pressed.connect(func():
				if on_map != "":
					Mods.remove(on_map)
					_mods_status.text = "Removed - the map is back to your own edits."
					_load_mods()
					return
				_mods_status.text = "Downloading..."
				Online.download_mod(_mod_id(it), func(bytes: PackedByteArray, dl_ok: bool):
					if not dl_ok:
						_mods_status.text = "Download failed."
						return
					var why := Mods.install(_mod_id(it), bytes, String(it.get("sha256", "")), maps)
					_mods_status.text = why if why != "" else "Installed: play its map to see it."
					_load_mods()))
			line.add_child(b)
			_mods_list.add_child(line))


## Map editor > File > Share these edits as a mod.
var _share: PanelContainer
func share_mod() -> void:
	if _share == null:
		_share = PanelContainer.new()
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.05, 0.06, 0.08, 0.97)
		st.set_corner_radius_all(12)
		st.set_content_margin_all(22)
		st.border_color = Color(0.3, 0.85, 1.0)
		st.set_border_width_all(2)
		_share.add_theme_stylebox_override("panel", st)
		_share.process_mode = Node.PROCESS_MODE_ALWAYS
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(560, 0)
		box.add_theme_constant_override("separation", 8)
		_share.add_child(box)
		var title := Label.new()
		title.text = "Share this map's edits as a mod"
		title.add_theme_font_size_override("font_size", 24)
		box.add_child(title)
		for f in [["name", "Name of the mod"], ["author", "Your name or nickname"], ["version", "Version (1.0)"]]:
			var e := LineEdit.new()
			e.name = f[0]
			e.placeholder_text = f[1]
			e.max_length = 60 if f[0] != "version" else 16
			box.add_child(e)
		var d := TextEdit.new()
		d.name = "description"
		d.placeholder_text = "What does it change? (placed models, items, bus lines, wall photos...)"
		d.custom_minimum_size = Vector2(0, 120)
		d.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		box.add_child(d)
		var note := Label.new()
		note.name = "status"
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
		box.add_child(note)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		box.add_child(row)
		var close := Button.new()
		close.text = "Close"
		close.pressed.connect(func(): _share.get_parent().visible = false)
		row.add_child(close)
		var send := Button.new()
		send.name = "send"
		send.text = "Share"
		send.pressed.connect(_send_mod)
		row.add_child(send)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.process_mode = Node.PROCESS_MODE_ALWAYS
		center.add_child(_share)
		var layer := CanvasLayer.new()
		layer.layer = 30
		layer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(layer)
		layer.add_child(center)
	_share.find_child("status", true, false).text = "It is sent for a review; once published everyone can install it from Mods on the title screen."
	(_share.find_child("send", true, false) as Button).disabled = false
	_share.get_parent().visible = true


func _send_mod() -> void:
	var name_e: LineEdit = _share.find_child("name", true, false)
	var status: Label = _share.find_child("status", true, false)
	if name_e.text.strip_edges().length() < 3:
		status.text = "Give the mod a name."
		return
	var info := {"name": name_e.text.strip_edges(),
			"author": (_share.find_child("author", true, false) as LineEdit).text.strip_edges(),
			"version": (_share.find_child("version", true, false) as LineEdit).text.strip_edges(),
			"description": (_share.find_child("description", true, false) as TextEdit).text.strip_edges()}
	if info["author"] == "":
		info["author"] = "anonymous"
	if info["version"] == "":
		info["version"] = "1.0"
	var zip := Mods.pack(map_id, info)
	if zip.is_empty():
		status.text = "Could not pack the edits."
		return
	status.text = "Sending..."
	(_share.find_child("send", true, false) as Button).disabled = true
	Online.upload_mod(info, zip, func(ok: bool, msg: String):
		status.text = msg
		(_share.find_child("send", true, false) as Button).disabled = ok)


## Every peer: pigeon flocks on squares and promenades (visual only, local).
func _pigeons() -> void:
	if crowd.is_empty() or Pigeon.MODELS.is_empty():
		return
	var root := Node3D.new()
	root.name = "Pigeons"
	root.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(root)
	_map_nodes.append(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map_id)            # the same squares on every peer
	var spots := []
	for attempt in 400:
		var c: Vector3 = crowd[rng.randi() % crowd.size()]
		if spots.all(func(s): return s.distance_to(c) > 45.0):
			spots.append(c)
		if spots.size() >= FLOCKS * 2:
			break
	for i in min(FLOCKS, spots.size()):
		for k in rng.randi_range(8, 14):
			var p: Node3D = Pigeon.new()
			p.home = spots[i] + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
			p.landing_spots = spots
			p.position = p.home
			root.add_child(p)


## The robots' relay antenna (antenna.gd): one per phase with a goal, on a
## high roof away from the start, the same spot on every peer.
const Antenna := preload("res://scripts/antenna.gd")
var _antennas: Array = []
func _place_antenna() -> void:
	for a in _antennas:
		if is_instance_valid(a):
			a.queue_free()
	_antennas = []
	director.reinforce = 1.0
	if _map_spec(map_id)[3] <= 0:
		return                          # free play: no objective
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map_id) + 5
	# several high roofs, well apart, away from the start
	var spots := []
	for attempt in 1500:
		if spots.size() >= int(Difficulty.get_value("antennas")):
			break
		var p := Vector3(rng.randf_range(bounds.position.x, bounds.end.x), 0, rng.randf_range(bounds.position.y, bounds.end.y))
		if not in_bounds(p, 25.0) or Vector2(p.x, p.z).distance_to(Vector2(spawn_point.x, spawn_point.z)) < 70.0:
			continue
		if spots.any(func(q): return Vector2(q.x, q.z).distance_to(Vector2(p.x, p.z)) < 120.0):
			continue
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 400, 0), p - Vector3(0, 100, 0), 64))
		if hit and hit.normal.y > 0.9 and hit.position.y - spawn_point.y > 10.0 and rng.randf() < 0.35:
			spots.append(hit.position)
	for at in spots:
		var a: StaticBody3D = Antenna.new()
		a.name = "RelayAntenna%d" % _antennas.size()
		add_child(a)
		_map_nodes.append(a)
		a.global_position = at
		a.destroyed.connect(_antenna_down)
		_antennas.append(a)
		# nobody found it from the air: after a while a civilian reports it
		if multiplayer.is_server():
			# a weak reference: an antenna brought down (or a new round) before
			# then is simply gone, no "Lambda capture was freed"
			var wa: WeakRef = weakref(a)
			get_tree().create_timer(360.0 + 60.0 * _antennas.size()).timeout.connect(func():
				var ant: Node = wa.get_ref()
				if ant and ant.is_alive() and not ant.spotted:
					ant.mark_spotted.rpc())
	if _antennas.is_empty():
		return
	director.reinforce = Difficulty.get_value("antenna_reinforce")
	# the last phase: the robot commander guards one antenna's building
	if _map_spec(map_id)[2] == "" and multiplayer.is_server():
		await wait_for_navmesh()
		var post: Vector3 = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, spots[0])
		enemy_spawner.spawn({"id": _next_enemy_id(), "pos": post + Vector3(0, 0.5, 0), "variant": "mech",
				"commander": true, "post": post})


## Server: a tower detector bought at a repair shop - the nearest antenna
## not yet spotted is marked (it shows on every GPS).
@rpc("any_peer", "call_local", "reliable")
func detect_antenna(from: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var best: Node3D = null
	var bd := INF
	for a in _antennas:
		if is_instance_valid(a) and a.is_alive() and not a.spotted and a.global_position.distance_to(from) < bd:
			bd = a.global_position.distance_to(from)
			best = a
	if best:
		best.mark_spotted.rpc()
		_announce("TOWER DETECTOR: a relay antenna %d m away is on the GPS" % int(bd))


## While any antenna stands the dropships come sooner.
func _antenna_down() -> void:
	if _antennas.all(func(a): return not is_instance_valid(a) or not a.is_alive()):
		director.reinforce = 1.0


## HUD code: state (0 none, 1 hidden, 2 one spotted, 3 all down) + 10 * down + 100 * total
func antenna_state() -> int:
	if _antennas.is_empty():
		return 0
	var down := 0
	var spotted := false
	for a in _antennas:
		if not is_instance_valid(a) or not a.is_alive():
			down += 1
		elif a.spotted:
			spotted = true
	var st := 3 if down == _antennas.size() else (2 if spotted else 1)
	return st + 10 * down + 100 * _antennas.size()


## Quero-queros, the bird of Rio Grande do Sul: pairs on the lawns (visual and
## local like the pigeons; the same spots on every peer).
func _quero_queros() -> void:
	if Pigeon.QUERO_MODELS.is_empty():
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map_id) + 17
	var lawns := []
	for attempt in 600:
		var p := Vector3(rng.randf_range(bounds.position.x, bounds.end.x), 0, rng.randf_range(bounds.position.y, bounds.end.y))
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 300, 0), p - Vector3(0, 100, 0), 1))
		if hit and hit.collider.get_parent() and String(hit.collider.get_parent().name).begins_with("grass") \
				and lawns.all(func(s): return s.distance_to(hit.position) > 30.0):
			lawns.append(hit.position)
		if lawns.size() >= int(Pigeon.quero_def().get("pairs", 5)) * 2:
			break
	var root := Node3D.new()
	root.name = "QueroQueros"
	root.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(root)
	_map_nodes.append(root)
	for i in min(int(Pigeon.quero_def().get("pairs", 5)), lawns.size()):
		for k in 2:
			var b: Node3D = Pigeon.new()
			b.quero = true
			b.home = lawns[i] + Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
			b.landing_spots = lawns
			b.position = b.home
			root.add_child(b)


## Lake/river surfaces exported as "water" meshes get the animated water shader.
func _water(scene: Node) -> void:
	var mat: ShaderMaterial = null
	for mi in scene.find_children("water*", "MeshInstance3D", true, false):
		if mat == null:
			mat = ShaderMaterial.new()
			mat.shader = load("res://shaders/water.gdshader")
			for k in ["ripples_a", "ripples_b"]:
				var noise := FastNoiseLite.new()
				noise.seed = 3 if k == "ripples_a" else 9
				noise.frequency = 0.02 if k == "ripples_a" else 0.035
				var tex := NoiseTexture2D.new()
				tex.width = 512
				tex.height = 512
				tex.seamless = true
				tex.as_normal_map = true
				tex.bump_strength = 6.0
				tex.noise = noise
				mat.set_shader_parameter(k, tex)
		(mi as MeshInstance3D).material_override = mat
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Invisible walls on the map border (the horizon beyond is scenery).
func _edge_walls() -> void:
	var body := StaticBody3D.new()
	body.name = "EdgeWalls"
	var c := bounds.get_center()
	for side in 4:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		var horizontal := side < 2
		var wall_h := elev.y - elev.x + 60.0
		shape.size = Vector3(bounds.size.x + 4, wall_h, 1) if horizontal else Vector3(1, wall_h, bounds.size.y + 4)
		cs.shape = shape
		match side:
			0: cs.position = Vector3(c.x, elev.x + wall_h / 2 - 5, bounds.end.y + 0.5)
			1: cs.position = Vector3(c.x, elev.x + wall_h / 2 - 5, bounds.position.y - 0.5)
			2: cs.position = Vector3(bounds.end.x + 0.5, elev.x + wall_h / 2 - 5, c.y)
			3: cs.position = Vector3(bounds.position.x - 0.5, elev.x + wall_h / 2 - 5, c.y)
		body.add_child(cs)
	body.collision_layer = 8          # players only, not part of the navmesh
	add_child(body)
	_map_nodes.append(body)


## Looping ambience: distant traffic and wind everywhere, birds in the parks.
func _ambience() -> void:
	for spec in [["amb_traffic", -16.0], ["amb_wind", -22.0]]:
		var stream: AudioStreamWAV = load("res://assets/audio/%s.wav" % spec[0])
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = stream.data.size() / 2
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = spec[1]
		p.autoplay = true
		add_child(p)
		_map_nodes.append(p)
	if not FileAccess.file_exists(_city(".props.json")):
		return
	var birds: AudioStreamWAV = load("res://assets/audio/amb_birds.wav")
	birds.loop_mode = AudioStreamWAV.LOOP_FORWARD
	birds.loop_end = birds.data.size() / 2
	var centres := []
	for pr in JSON.parse_string(FileAccess.get_file_as_string(_city(".props.json"))):
		if pr["type"] in ["shrub", "shrub2", "fern"]:
			var pos := Vector3(pr["pos"][0], 3.0, pr["pos"][2])
			if centres.all(func(c): return c.distance_to(pos) > 40.0):
				centres.append(pos)
	for c in centres:
		var b := AudioStreamPlayer3D.new()
		b.stream = birds
		b.unit_size = 10.0
		b.max_distance = 70.0
		b.volume_db = -6.0
		b.autoplay = true
		b.position = c
		add_child(b)
		_map_nodes.append(b)


# ---- pedestrians and traffic (server) -------------------------------------

func _load_roads() -> void:
	if not FileAccess.file_exists(_city(".roads.json")):
		return
	road_graph = JSON.parse_string(FileAccess.get_file_as_string(_city(".roads.json")))
	var out := {}
	for i in road_graph["edges"].size():
		var e: Dictionary = road_graph["edges"][i]
		out.get_or_add(int(e["a"]), []).append([i, true])
		if not e["oneway"]:
			out.get_or_add(int(e["b"]), []).append([i, false])
	road_graph["out"] = out
	road_graph["len"] = road_graph["edges"].map(func(e): return _edge_length(e))
	road_graph["stops"] = _bus_stops()
	_populate_stops.call_deferred()
	# border entry points: a street end with a single edge, near the map edge
	var degree := {}
	for e in road_graph["edges"]:
		degree[int(e["a"])] = degree.get(int(e["a"]), 0) + 1
		degree[int(e["b"])] = degree.get(int(e["b"]), 0) + 1
	var entries := []
	for i in road_graph["edges"].size():
		var e: Dictionary = road_graph["edges"][i]
		for spec in [[int(e["a"]), true], [int(e["b"]), false]]:
			var n: Array = road_graph["nodes"][spec[0]]
			var at_border: bool = not in_bounds(Vector3(n[0], 0, n[1]), 20.0)
			if degree[spec[0]] == 1 and at_border and (spec[1] or not e["oneway"]):
				entries.append([i, spec[1]])
	road_graph["entries"] = entries


func _start_world() -> void:
	if not multiplayer.is_server():
		return
	await wait_for_navmesh()
	var map := get_world_3d().navigation_map
	_spawn_civilians(civilians_wanted())
	_spawn_vendors()
	_spawn_police()
	_spawn_leisure_people()
	if not road_graph.is_empty():
		var edges: Array = road_graph["edges"]
		for k in int(round(TRAFFIC * density())):
			var ei := (k * 7) % edges.size()
			_car_seq += 1
			var model := Car.pick()
			# the big tractor-trailer only on long streets (avenues)
			while Car.MODELS[model].contains("trailer") and _edge_length(edges[ei]) < 150.0:
				model = Car.pick()
			car_spawner.spawn({"id": _car_seq, "model": model, "driver": Civilian.pick_walker(), "edge": ei,
					"forward": edges[ei]["oneway"] or randf() < 0.5})
	_park_war_machine()
	_park_cars()
	_round_live = true
	_phase_civ_start = civilians_wanted()


## The map's bus stops as [edge, x, z] - the street point nearest each
## shelter. A route designed in the map editor (bus shelters placed by hand,
## kept in the map's user edits) is followed in the order they were placed;
## without one, the OSM shelters (<city>.props.json) in a nearest-next round.
func _bus_stops() -> Array:
	var designed := []
	var lines := {}
	for p in user_edits().get("_props", []):
		if String(p.get("model", "")).contains("bus_shelter") or Entities.of_model(p.get("model", "")).get("tags", []).has("bus_stop"):
			var st: Array = _nearest_street(Vector2(p["x"], p["z"]))
			if st[0] < 0:
				continue
			designed.append(st)
			# a stop belongs to a bus line (the map editor's "Bus line"); 1 if unset
			var n := int(p.get("line", 1))
			if not lines.has(n):
				lines[n] = []
			lines[n].append(st)
	if not designed.is_empty():
		var keys := lines.keys()
		keys.sort()
		road_graph["lines"] = keys.map(func(k): return lines[k])
		return designed
	road_graph.erase("lines")
	if not FileAccess.file_exists(_city(".props.json")):
		return []
	var found := []
	for p in JSON.parse_string(FileAccess.get_file_as_string(_city(".props.json"))):
		if p["type"] != "bus_stop":
			continue
		var at := Vector2(p["pos"][0], p["pos"][2])
		var best := [-1, 0.0, 0.0]
		var bd := 25.0                    # a shelter further than this from any street serves none
		for i in road_graph["edges"].size():
			for pt in road_graph["edges"][i]["pts"]:
				var d := at.distance_to(Vector2(pt[0], pt[1]))
				if d < bd:
					bd = d
					best = [i, pt[0], pt[1]]
		if best[0] >= 0:
			found.append(best)
	var tour := []
	while not found.is_empty():
		var from: Vector2 = Vector2(tour[-1][1], tour[-1][2]) if not tour.is_empty() else Vector2(found[0][1], found[0][2])
		found.sort_custom(func(a, b): return from.distance_to(Vector2(a[1], a[2])) < from.distance_to(Vector2(b[1], b[2])))
		tour.append(found.pop_front())
	return tour


## [edge, x, z] of the road point nearest `at` (edge -1 beyond 25 m).
func _nearest_street(at: Vector2) -> Array:
	var best := [-1, 0.0, 0.0]
	var bd := 25.0
	for i in road_graph["edges"].size():
		for pt in road_graph["edges"][i]["pts"]:
			var d := at.distance_to(Vector2(pt[0], pt[1]))
			if d < bd:
				bd = d
				best = [i, pt[0], pt[1]]
	return best


## Server: people waiting at each stop (beside the street point, on the walkable side).
const WAITING_PER_STOP := 2
func _populate_stops() -> void:
	if not multiplayer.is_server():
		return
	await wait_for_navmesh()
	var map := get_world_3d().navigation_map
	var stops: Array = road_graph.get("stops", [])
	# spread over every stop first (one each), then a second where there's room
	for k in WAITING_PER_STOP:
		for s in stops:
			if k * stops.size() + stops.find(s) >= 20:
				return
			_spawn_waiting(Vector3(s[1], 0, s[2]), map)


func _spawn_waiting(street: Vector3, map: RID) -> void:
	var models := Civilian.models_where("type", "Pedestrian")
	if models.is_empty():
		return
	# a spot off the carriageway: the first direction whose ground is pavement
	var space := get_world_3d().direct_space_state
	var at := Vector3.INF
	var a0 := randf() * TAU
	for k in 12:
		for r in [4.5, 6.0]:
			var a := a0 + k * TAU / 12.0
			var p: Vector3 = NavigationServer3D.map_get_closest_point(map, street + Vector3(cos(a), 0, sin(a)) * r)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 3, 0), p - Vector3(0, 3, 0), 1))
			var ground := String(hit.collider.get_parent().name) if hit and hit.collider.get_parent() else ""
			if hit and not (ground.begins_with("asphalt") or ground.begins_with("markings") or ground.begins_with("zebra")):
				at = p
				break
		if at != Vector3.INF:
			break
	if at == Vector3.INF:
		return                          # no pavement near this stop
	_civ_seq += 1
	civ_spawner.spawn({"id": _civ_seq, "pos": at + Vector3(0, 0.1, 0), "model": models.pick_random(), "wait": at})


## Server: a bus pulled up at stop `s` ([edge, x, z]): the people waiting get
## on, one or two others get off; later someone else comes to wait.
func bus_at_stop(bus: Node3D, s: Array) -> void:
	if not multiplayer.is_server():
		return
	var street := Vector3(s[1], bus.global_position.y, s[2])
	for c in civilians_root.get_children():
		if c.is_alive() and c.get("waiting_at") != Vector3.INF and c.global_position.distance_to(street) < 12.0:
			c.board(bus)
	var map := get_world_3d().navigation_map
	for k in randi_range(0, 2):
		var door: Vector3 = bus.to_global(Vector3(bus._box.size.x / 2 + 0.8, 0, bus._box.size.z * (0.1 + 0.15 * k)))
		var at: Vector3 = NavigationServer3D.map_get_closest_point(map, door)
		_civ_seq += 1
		civ_spawner.spawn({"id": _civ_seq, "pos": at + Vector3(0, 0.1, 0), "model": Civilian.pick()})
	get_tree().create_timer(randf_range(20.0, 40.0)).timeout.connect(func():
		if is_inside_tree() and road_graph.get("stops", []).has(s):
			_spawn_waiting(Vector3(s[1], 0, s[2]), get_world_3d().navigation_map))


## Map editor: the bus route changed (a shelter placed): buses follow it at once.
func refresh_bus_stops() -> void:
	if road_graph.has("edges"):
		road_graph["stops"] = _bus_stops()
		for v in traffic_root.get_children():
			if v.get("kind") == "bus":
				v.set("_stop_i", -1)
				v.set("line", -1)


## Grass is matte: the texture's roughness map left a sun sheen on the lawns
## that looked like plastic.
func _matte_grass(root: Node) -> void:
	for mi in root.find_children("grass*", "MeshInstance3D", true, false):
		for i in (mi as MeshInstance3D).get_surface_override_material_count():
			var m := (mi as MeshInstance3D).get_active_material(i) as StandardMaterial3D
			if m:
				m.roughness_texture = null
				m.roughness = 1.0
				m.metallic_specular = 0.2


func _edge_length(e: Dictionary) -> float:
	var pts: Array = e.get("pts", [])
	var total := 0.0
	for k in range(1, pts.size()):
		total += Vector2(pts[k][0] - pts[k - 1][0], pts[k][1] - pts[k - 1][1]).length()
	return total


## Server: cars parked at the kerb that a player can get into and drive -
## fewer than the map's parking spots, so the streets are not lined with them.
const PARKED_SHARE := 0.4
const PARKED_MAX := 12
func _park_cars() -> void:
	var cars := []
	for i in Car.MODELS.size():
		if Car.kind_of(Car.MODELS[i]) == "car":
			cars.append(i)
	if cars.is_empty() or props == null:
		return
	var spots: Array = props.parked_spots.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map_id) + 3
	for i in range(spots.size() - 1, 0, -1):          # the same shuffle on every run
		var j := rng.randi_range(0, i)
		var t = spots[i]
		spots[i] = spots[j]
		spots[j] = t
	var n := mini(PARKED_MAX, int(round(spots.size() * PARKED_SHARE)))
	for k in n:
		_car_seq += 1
		car_spawner.spawn({"id": _car_seq, "model": cars[rng.randi() % cars.size()],
				"parked": spots[k][0] + Vector3(0, 0.3, 0), "yaw": spots[k][1]})


## Server: the armoured combine harvester waits, empty, on a street near the
## start of every phase.
func _park_war_machine() -> void:
	var idx := Car.MODELS.find("res://assets/rio_grande_do_sul/war/colheitadeira_blindada.glb")
	if idx < 0:
		return
	# on a street of the road graph, along it, with room around (it is 6 m wide)
	var space := get_world_3d().direct_space_state
	var box := BoxShape3D.new()
	box.size = Vector3(6.4, 3.0, 9.0)
	var best: Array = []
	for e in road_graph.get("edges", []):
		var pts: Array = e.get("pts", [])
		if pts.size() < 2:
			continue
		var a: Array = pts[pts.size() / 2 - 1]
		var b: Array = pts[pts.size() / 2]
		var mid := Vector3((a[0] + b[0]) / 2.0, (a[2] if a.size() > 2 else 0.0), (a[1] + b[1]) / 2.0)
		var d := mid.distance_to(spawn_point)
		if d < 15.0 or d > 120.0 or not in_bounds(mid, 20.0):
			continue
		var yaw := atan2(-(b[0] - a[0]), -(b[1] - a[1]))
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = box
		q.transform = Transform3D(Basis(Vector3.UP, yaw), mid + Vector3(0, 2.2, 0))
		q.collision_mask = 1
		if space.intersect_shape(q, 1).is_empty() and (best.is_empty() or d < best[0]):
			best = [d, mid, yaw]
	if best.is_empty():
		return
	# on the asphalt itself: the navmesh floats a little above it
	var spot: Vector3 = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, best[1])
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(spot + Vector3(0, 2.0, 0), spot - Vector3(0, 3.0, 0), 1))
	if hit:
		spot.y = hit.position.y
	_car_seq += 1
	car_spawner.spawn({"id": _car_seq, "model": idx, "parked": spot, "yaw": best[2]})


## Server: Brigada Militar officers patrolling the city (allies).
func _spawn_police() -> void:
	var models := Civilian.models_where("spawn", "patrol")
	if models.is_empty():
		return
	var map := get_world_3d().navigation_map
	for k in int(round(4.0 * sqrt(density()))):
		for attempt in 30:
			var p := NavigationServer3D.map_get_random_point(map, 1, true)
			var path := NavigationServer3D.map_get_path(map, spawn_point, p, true)
			if in_bounds(p, 15.0) and path.size() > 1 and path[path.size() - 1].distance_to(p) < 1.0:
				_civ_seq += 1
				civ_spawner.spawn({"id": _civ_seq, "pos": p + Vector3(0, 0.1, 0), "model": models[k % models.size()]})
				break


## Server: a few surveillance drones already over the city at round start.
func _spawn_drones() -> void:
	if not multiplayer.is_server():
		return
	await wait_for_navmesh()
	var map := get_world_3d().navigation_map
	for k in int(round(2.0 * sqrt(density()))):
		for attempt in 30:
			var p := NavigationServer3D.map_get_random_point(map, 1, true)
			if in_bounds(p, 20.0) and p.distance_to(spawn_point) > 60.0:
				enemy_spawner.spawn({"id": _next_enemy_id(), "pos": p + Vector3(0, 9, 0), "variant": "drone"})
				break


## Server: a vendor behind every stall of the city (props.json "stall").
## DevAgent / Studio: rebuild the street furniture, stalls and landmark models
## of the current map in place (after a model was changed and re-imported),
## and put the vendors back at their stalls. No restart needed.
func reload_objects() -> Dictionary:
	if is_instance_valid(props):
		props.queue_free()
	await get_tree().process_frame
	props = Props.new()
	props.name = "Props"
	nav_region.add_child(props)
	props.build(_city(".props.json"))
	_landmarks()
	var vendors := 0
	if multiplayer.is_server():
		for c in civilians_root.get_children():
			if c.vendor:
				c.queue_free()
				vendors += 1
		await get_tree().process_frame
		_spawn_vendors()
	return {"props": props.get_child_count(), "landmarks": _landmark_nodes.size(), "vendors": vendors}


## Server: football players on the pitches, children at the playgrounds - a
## definition's `spawn` names the landmark's `leisure` kind ("pitch",
## "playground"), `per_place` how many; they keep to it (`roam`).
func _spawn_leisure_people() -> void:
	var map := get_world_3d().navigation_map
	for lm in _landmark_nodes:
		if not is_instance_valid(lm):
			continue
		var kind: String = lm.get_meta("landmark", {}).get("leisure", "")
		var models := Civilian.models_where("spawn", kind) if kind != "" else []
		if kind != "":
			for i in Civilian.MODELS.size():          # a street kind that also goes there (skaters at a skatepark)
				if kind in Civilian.kind_of(i).get("also_at", []):
					models.append(i)
		if models.is_empty():
			continue
		var n: int = int(Civilian.kind_of(models[0]).get("per_place", 4))
		var roam: float = float(Civilian.kind_of(models[0]).get("roam", 5.0))
		for k in n:
			var off := Vector3(randf_range(-roam, roam), 0, randf_range(-roam, roam)) * 0.7
			var at := NavigationServer3D.map_get_closest_point(map, (lm as Node3D).global_position + off)
			_civ_seq += 1
			civ_spawner.spawn({"id": _civ_seq, "pos": at + Vector3(0, 0.1, 0), "model": models[k % models.size()],
					"home": (lm as Node3D).global_position, "home_yaw": randf() * TAU})


func _spawn_vendors() -> void:
	if not FileAccess.file_exists(_city(".props.json")):
		return
	var models := Civilian.models_where("spawn", "stall")
	if models.is_empty():
		return
	var map := get_world_3d().navigation_map
	var k := 0
	for pr in JSON.parse_string(FileAccess.get_file_as_string(_city(".props.json"))):
		if pr["type"] != "stall":
			continue
		var yaw: float = pr["yaw"]
		var at := Vector3(pr["pos"][0], pr["pos"][1], pr["pos"][2])
		var stall: String = pr.get("stall", "")
		var spot: Vector3
		var model: int = models[k % models.size()]
		if stall.contains("kiosk"):
			# inside the newspaper kiosk, behind its counter (it opens to -Z)
			spot = at + Basis(Vector3.UP, yaw) * Vector3(0.2, 0.05, -0.25)
			for i in models:
				if Civilian.MODELS[i].contains("kiosk"):
					model = i
		else:
			# behind the cart: it faces -Z, the vendor stands at +Z facing the same way
			spot = NavigationServer3D.map_get_closest_point(map, at + Vector3(sin(yaw), 0, cos(yaw)) * 1.6)
			for i in models:
				var who: String = Civilian.MODELS[i].get_file()
				if stall != "" and who.contains(stall.get_slice("_", 0)):
					model = i                 # the popcorn man at the popcorn cart, etc.
		_civ_seq += 1
		civ_spawner.spawn({"id": _civ_seq, "pos": spot + Vector3(0, 0.1, 0), "model": model,
				"home": spot, "home_yaw": yaw})
		k += 1


## Hand-modelled landmarks standing on their OSM footprints (the exporter
## leaves those footprints empty and lists them in <city>.landmarks.json).
var _landmark_nodes: Array = []
## Placed models that come with clips keep their resting one looping: boats
## bob on the water, the gaiteiro plays, capybaras graze.
const AUTOPLAY := ["float_idle", "play_seated", "play_standing", "graze", "idle", "hover"]
func _autoplay(m: Node3D) -> void:
	for ap in m.find_children("*", "AnimationPlayer", true, false):
		for clip in AUTOPLAY:
			if (ap as AnimationPlayer).has_animation(clip):
				(ap as AnimationPlayer).get_animation(clip).loop_mode = Animation.LOOP_LINEAR
				(ap as AnimationPlayer).play(clip)
				(ap as AnimationPlayer).seek(randf() * (ap as AnimationPlayer).get_animation(clip).length, true)
				break


## A street musician is heard from a few metres off, through his station's tracks.
const Music := preload("res://scripts/music.gd")
func _street_music(m: Node3D, station: String, range_m := 35.0) -> void:
	var p := AudioStreamPlayer3D.new()
	p.position = Vector3(0, 1.2, 0)
	# loud close by, fading fast: gone a block away (and under the car radio)
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	p.unit_size = 6.0
	p.max_distance = range_m
	p.volume_db = 0.0
	m.add_child(p)
	Music.playlist(p, station)


## A model's sound from its definition (docs/ENTITIES.md): "station" plays
## that music station's tracks (a street musician), "loop" one clip on repeat
## (a fountain); "range" is how far it carries.
var _bands: Array = []
func _model_sound(m: Node3D, def: Dictionary) -> void:
	var snd: Dictionary = def.get("sound", {})
	var range_m := float(snd.get("range", 35.0))
	if snd.has("station"):
		var st: String = snd["station"]
		if Music.tracks(st).is_empty() and snd.has("fallback"):
			st = snd["fallback"]
		# musicians side by side (the gaiteiro and the violonista on the stage)
		# are one band: one song, not two at once
		_bands = _bands.filter(func(b): return is_instance_valid(b))
		for b in _bands:
			if (b as Node3D).global_position.distance_to(m.global_position) < 12.0:
				return
		_bands.append(m)
		_street_music(m, st, range_m)
	elif snd.has("loop") and ResourceLoader.exists(snd["loop"]):
		var p := AudioStreamPlayer3D.new()
		var stream: AudioStream = load(snd["loop"])
		if "loop" in stream:
			stream.set("loop", true)
		elif stream is AudioStreamWAV:
			(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		p.stream = stream
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		p.unit_size = float(snd.get("unit", 4.0))
		p.max_distance = range_m
		p.volume_db = float(snd.get("db", -6.0))
		p.autoplay = true
		m.add_child(p)


func _landmarks() -> void:
	for n in _landmark_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_landmark_nodes = []
	landmark_pickups = []
	_screens = []
	_bands = []
	if not FileAccess.file_exists(_city(".landmarks.json")):
		return
	for l in JSON.parse_string(FileAccess.get_file_as_string(_city(".landmarks.json"))):
		_landmark(l)
	_shells()
	_apply_edits.call_deferred()
	_load_places()


## Small shops as walk-in shells (<city>.shells.json, written at import for a
## one-storey pharmacy, market or lancheria): painted walls, a shop window
## and an open door on the street side, a sign with the place's name (its
## caption), a light, and the interior set's furniture that fits inside.
const SHELL_PAINT := [Color(0.89, 0.83, 0.7), Color(0.84, 0.67, 0.38), Color(0.84, 0.59, 0.5),
		Color(0.66, 0.77, 0.67), Color(0.93, 0.92, 0.89), Color(0.63, 0.73, 0.81), Color(0.81, 0.63, 0.67)]
func _shells() -> void:
	if not FileAccess.file_exists(_city(".shells.json")):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(_city(".shells.json")))
	for sh in (data if data is Array else []):
		_shell(sh)


func _shell(sh: Dictionary) -> void:
	var ring := PackedVector2Array()
	for q in sh["ring"]:
		ring.append(Vector2(q[0], q[1]))
	if ring.size() < 3:
		return
	var base := float(sh["base"])
	# the walk-in floor at the level of the ground around it: on a quay or a
	# raised promenade the terrain under the building is lower than the paving
	var cen := Vector2.ZERO
	for q in ring:
		cen += q
	cen /= ring.size()
	# (the median of the probes round it: the highest one was the top of
	# something next to it - a market at the Gasômetro stood 2.8 m up in the air)
	var space := get_world_3d().direct_space_state
	var ys: Array[float] = []
	for q in ring:
		var out: Vector2 = q + (q - cen).normalized() * 0.8
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(out.x, base + 6.0, out.y), Vector3(out.x, base - 1.0, out.y), 1))
		if hit and hit.normal.y > 0.8:
			ys.append(hit.position.y)
	ys.sort()
	var around: float = ys[ys.size() / 2] if not ys.is_empty() else -INF
	if around > base + 0.1 and around < base + 3.0:
		base = around - 0.02
	var H := float(sh["height"])
	var c := Vector2.ZERO
	for q in ring:
		c += q
	c /= ring.size()
	var root := Node3D.new()
	root.name = "shell_" + String(sh["kind"])
	nav_region.add_child(root)
	_landmark_nodes.append(root)
	root.set_meta("landmark", {"id": "shell", "model": sh["interior"], "label": sh["caption"]})
	var wall := StandardMaterial3D.new()
	wall.albedo_texture = load("res://assets/materials/PaintedPlaster017/color.jpg")
	wall.albedo_color = SHELL_PAINT[abs(hash(sh["id"])) % SHELL_PAINT.size()]
	wall.uv1_triplanar = true
	wall.uv1_world_triplanar = true
	wall.uv1_scale = Vector3.ONE * 0.33
	wall.roughness = 0.95
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.55, 0.7, 0.78, 0.28)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.05
	glass.metallic = 0.3
	var frame := StandardMaterial3D.new()
	frame.albedo_color = Color(0.16, 0.17, 0.18)
	frame.roughness = 0.5
	var front := int(sh.get("front", 0))
	var n_front := Vector2.ZERO
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var L := a.distance_to(b)
		if L < 0.3:
			continue
		var d := (b - a) / L
		var n := Vector2(-d.y, d.x)
		if n.dot((a + b) / 2.0 - c) < 0:
			n = -n                                  # outward
		if i != front or L < 3.2:
			_shell_box(root, a, b, base, base + H, wall)
			continue
		n_front = n
		# the street side: glass below 2.7 m with a door gap in the middle, plaster above
		var mid := L / 2.0
		_shell_box(root, a, b, base + 2.7, base + H, wall)
		_shell_box(root, a, a + d * (mid - 0.9), base, base + 2.7, glass, 0.06)
		_shell_box(root, a + d * (mid + 0.9), b, base, base + 2.7, glass, 0.06)
		for t in [mid - 0.9, mid + 0.9]:
			_shell_box(root, a + d * (t - 0.06), a + d * (t + 0.06), base, base + 2.7, frame, 0.14)
		_shell_box(root, a, b, base, base + 0.35, frame, 0.22, mid - 0.9, mid + 0.9)    # kick plates
		# the sign: the place's name over the window
		var sign_at := (a + b) / 2.0 + n * 0.16
		var y := base + minf(H - 0.5, 3.4)
		var board := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(minf(L - 0.6, 6.0), 0.8, 0.08)
		board.mesh = bm
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.1, 0.32, 0.18) if sh["kind"] == "pharmacy" else Color(0.45, 0.12, 0.08)
		board.material_override = bmat
		root.add_child(board)
		board.global_position = Vector3(sign_at.x, y, sign_at.y)
		board.look_at(board.global_position + Vector3(n.x, 0, n.y), Vector3.UP)
		var text := Label3D.new()
		text.text = String(sh["caption"]).to_upper()
		text.font_size = 72
		text.pixel_size = 0.0075
		text.outline_size = 10
		text.modulate = Color(0.98, 0.95, 0.85)
		text.width = bm.size.x / text.pixel_size
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		root.add_child(text)
		text.global_position = Vector3(sign_at.x, y, sign_at.y) + Vector3(n.x, 0, n.y) * 0.06
		text.look_at(text.global_position + Vector3(n.x, 0, n.y), Vector3.UP)
		text.rotate_object_local(Vector3.UP, PI)     # Label3D reads from its +Z side
	# floor and roof (a ring the triangulation can't take - repeated or
	# collinear points on a round building - falls back to its convex hull:
	# without a floor you would drop out of the map)
	var tris := Geometry2D.triangulate_polygon(ring)
	if tris.is_empty():
		var hull := Geometry2D.convex_hull(ring)
		hull.remove_at(hull.size() - 1)          # convex_hull closes the loop
		ring = hull
		tris = Geometry2D.triangulate_polygon(ring)
	for spec in [[base + 0.04, false], [base + H, true]]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in range(0, tris.size(), 3):
			var order := [0, 1, 2] if spec[1] else [0, 2, 1]
			for o in order:
				var q := ring[tris[k + o]]
				st.add_vertex(Vector3(q.x, spec[0], q.y))
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var fm := StandardMaterial3D.new()
		fm.albedo_color = Color(0.82, 0.8, 0.76) if not spec[1] else Color(0.55, 0.55, 0.55)
		fm.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = fm
		root.add_child(mi)
		mi.create_trimesh_collision()
		# the ring's winding decides which side a one-sided trimesh faces: the
		# floor must hold whichever way the building was mapped
		for cs in mi.find_children("*", "CollisionShape3D", true, false):
			if (cs as CollisionShape3D).shape is ConcavePolygonShape3D:
				((cs as CollisionShape3D).shape as ConcavePolygonShape3D).backface_collision = true
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(c.x, base + H - 0.5, c.y)
	lamp.omni_range = 9.0
	lamp.light_energy = 1.3
	lamp.light_color = Color(1.0, 0.96, 0.88)
	lamp.distance_fade_enabled = true
	lamp.distance_fade_begin = 50.0
	root.add_child(lamp)
	# the interior set's furniture, facing the street, where it fits
	if n_front == Vector2.ZERO or not FileAccess.file_exists(sh["interior"]):
		return
	var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(sh["interior"]))
	var dir: String = String(sh["interior"]).get_base_dir()
	var yaw := atan2(-n_front.x, -n_front.y)       # the layout's front (-Z) to the street
	var t := Vector2(-n_front.y, n_front.x)
	var inner := Geometry2D.offset_polygon(ring, -0.7)
	if inner.is_empty():
		return
	for inst in lay.get("instances", []):
		if inst.get("category", "") != "furniture":
			continue
		var mp := dir.path_join(inst["model"]).simplify_path()
		if not ResourceLoader.exists(mp):
			continue
		var p: Array = inst["position"]
		# layout x -> along the front (t), layout z -> into the shop (-n)
		var w := c + t * float(p[0]) - n_front * float(p[2])
		if not Geometry2D.is_point_in_polygon(w, inner[0]):
			continue
		var m: Node3D = (load(mp) as PackedScene).instantiate()
		root.add_child(m)
		m.global_position = Vector3(w.x, base + float(p[1]), w.y)
		m.rotation.y = yaw - deg_to_rad(float(inst.get("rotation_degrees", [0, 0, 0])[1]))
		for mi in m.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visibility_range_end = 70.0
		_box_collider(m)


## One wall piece of a shell: from a to b, y0..y1 (optionally leaving a gap
## between `gap0` and `gap1` metres along it).
func _shell_box(root: Node3D, a: Vector2, b: Vector2, y0: float, y1: float, mat: Material,
		thick := 0.2, gap0 := -1.0, gap1 := -1.0) -> void:
	var L := a.distance_to(b)
	if gap0 >= 0.0:
		var d := (b - a) / L
		_shell_box(root, a, a + d * gap0, y0, y1, mat, thick)
		_shell_box(root, a + d * gap1, b, y0, y1, mat, thick)
		return
	if L < 0.05 or y1 - y0 < 0.02:
		return
	var body := StaticBody3D.new()
	root.add_child(body)
	var mid := (a + b) / 2.0
	body.global_position = Vector3(mid.x, (y0 + y1) / 2.0, mid.y)
	body.rotation.y = -atan2(b.y - a.y, b.x - a.x)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(L + 0.1, y1 - y0, thick)
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = bm.size
	cs.shape = bs
	body.add_child(cs)


## A landmark in parts (landmark_site.gd): far, near and inside versions
## streamed by distance; E at its entrance loads its rooms.
func _landmark_site(l: Dictionary) -> void:
	var m := LandmarkSite.new()
	var p: Array = l["pos"]
	m.position = Vector3(p[0], p[1], p[2])
	m.rotation.y = l["yaw"] + deg_to_rad(float(l.get("yaw_offset", 0.0)))
	nav_region.add_child(m)       # its structure is a navmesh obstacle like the city's
	m.configure(l["model"], l)
	m.name = String(l["model"]).get_base_dir().get_file()
	m.set_meta("landmark", l)
	_landmark_nodes.append(m)


## The landmark whose entrance the player stands at (E goes in), or null.
func site_near(at: Vector3) -> Node3D:
	for lm in _landmark_nodes:
		if is_instance_valid(lm) and lm is LandmarkSite and lm.has_interiors() \
				and lm.distance_to_entry(at) < LandmarkSite.ENTRY_REACH_M:
			return lm
	return null


## A city mesh's material name: the pipeline splits every material's mesh
## into 80 m cells, named <material>__c<x>_<z>.
static func city_mesh_kind(mi: Node) -> String:
	return String(mi.name).get_slice("__c", 0)


## Occlusion culling: the solid generated buildings (<city>.occluders.json:
## their footprint set a little inside, base, top) block the view, so what
## stands behind them is not drawn. One occluder of wall quads per 80 m cell.
func _occluders() -> void:
	var path := _city(".occluders.json")
	if not FileAccess.file_exists(path):
		return
	var cells := {}
	for o in JSON.parse_string(FileAccess.get_file_as_string(path)):
		var ring: Array = o[0]
		var y0: float = o[1]
		var y1: float = o[2]
		var c: Vector2 = Vector2.ZERO
		for p in ring:
			c += Vector2(p[0], p[1])
		c /= ring.size()
		var key := Vector2i(floori(c.x / 80.0), floori(c.y / 80.0))
		if not cells.has(key):
			cells[key] = [PackedVector3Array(), PackedInt32Array()]
		var verts: PackedVector3Array = cells[key][0]
		var idx: PackedInt32Array = cells[key][1]
		for i in ring.size():
			var a: Array = ring[i]
			var b: Array = ring[(i + 1) % ring.size()]
			var k := verts.size()
			verts.append_array([Vector3(a[0], y0, a[1]), Vector3(b[0], y0, b[1]), Vector3(b[0], y1, b[1]), Vector3(a[0], y1, a[1])])
			idx.append_array([k, k + 1, k + 2, k, k + 2, k + 3])
		cells[key] = [verts, idx]
	for key in cells:
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(cells[key][0], cells[key][1])
		var oi := OccluderInstance3D.new()
		oi.occluder = occ
		oi.name = "occluder_%d_%d" % [key.x, key.y]
		nav_region.add_child(oi)


## The generated buildings' walls baked from the modular kit (osm2gltf
## --kit-facades, assets/common/facades_kit): their height map turns the flat
## wall's windows, sills and cornices into depth (parallax) - glTF has no
## place for it, so it is set here on the materials named kit_<style>_<part>.
const KIT_FACADES := "res://assets/common/facades_kit/"
const KIT_PARALLAX := 10.0          # 0.7 m of relief over a 6 m tile
var _kit_mats: Array = []
func _kit_facades(city: Node) -> void:
	_kit_mats.clear()
	for mi in city.find_children("kit_*", "MeshInstance3D", true, false):
		var base := String(mi.name).get_slice("@", 0)
		var parts := base.trim_prefix("kit_").split("_")
		if parts.size() < 2:
			continue
		var tex := KIT_FACADES + parts[0] + "_" + parts[1] + "_height.png"
		if not ResourceLoader.exists(tex):
			continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as StandardMaterial3D
			if mat == null:
				continue
			mat.heightmap_enabled = true
			mat.heightmap_texture = load(tex)
			mat.heightmap_scale = KIT_PARALLAX
			mat.heightmap_deep_parallax = true
			mat.heightmap_min_layers = 8
			mat.heightmap_max_layers = 24
			_kit_mats.append(mat)
	set_kit_parallax(KIT_PARALLAX_MODE)


## 0 no depth (normal map only), 1 simple parallax (one sample), 2 deep
## (steep parallax, several samples a pixel: the costly one).
const KIT_PARALLAX_MODE := 2
func set_kit_parallax(mode: int) -> void:
	for mat in _kit_mats:
		(mat as StandardMaterial3D).heightmap_enabled = mode > 0
		(mat as StandardMaterial3D).heightmap_deep_parallax = mode > 1


const LAMP_FADE_M := 30.0
## One hand-made model of the map (<city>.landmarks.json, or a user edit).
func _landmark(l: Dictionary) -> void:
	if not (FileAccess.file_exists(l["model"]) if String(l["model"]).ends_with(".json") else ResourceLoader.exists(l["model"])):
		return
	# a shop is only its light outside until someone walks in (E at its door)
	if _closed_shop(l):
		var lod := _lod_path(String(l["model"]))
		l = l.duplicate()
		l["full"] = l["model"]
		if ResourceLoader.exists(lod):
			l["model"] = lod
			l["solid"] = "box"       # closed: one box, the door shut
		# (a model without a light version stands as it is; E still takes you in)
	if String(l["model"]).ends_with("site.json"):
		_landmark_site(l)
		return
	var layout := String(l["model"]).ends_with("layout.json")
	var m: Node3D = _layout_scene(l["model"]) if layout else (load(l["model"]) as PackedScene).instantiate()
	var p: Array = l["pos"]
	m.position = Vector3(p[0], p[1], p[2])
	# the user edits may fit a model to its footprint: "scale", "yaw_offset" (degrees)
	m.rotation.y = l["yaw"] + deg_to_rad(float(l.get("yaw_offset", 0.0)))
	m.scale = Vector3.ONE * float(l.get("scale", 1.0))
	nav_region.add_child(m)       # its walls are navmesh obstacles like the city's
	_storefront_lod.call_deferred(m, l)
	_landmark_nodes.append(m)
	m.set_meta("landmark", l)
	m.name = String(l["model"]).get_file().get_basename()
	# markers left in the model: lights inside, pickups on counters. A light
	# costs every pixel near it: they fade out by LAMP_FADE_M, and a closed
	# shop (its light outside) gets one, for its window - inside, all of them
	var lamps := 0
	var closed: bool = l.has("full")
	for n in m.find_children("*", "Node3D", true, false):
		var nm := String(n.name)
		if nm.begins_with("lamp_"):
			if closed and lamps >= 1:
				continue
			lamps += 1
			var lamp := OmniLight3D.new()
			lamp.light_color = Color(1.0, 0.97, 0.9)
			lamp.light_energy = 1.2
			lamp.omni_range = 7.0
			lamp.distance_fade_enabled = true
			lamp.distance_fade_begin = LAMP_FADE_M
			lamp.distance_fade_length = 10.0
			n.add_child(lamp)
		elif nm == "sign_cross":
			_cross_at(n)                      # a storefront's green pharmacy cross
		elif nm.begins_with("caption_") and String(l.get("caption", "")) != "":
			# a generic model's sign: the place's name from OSM (or its kind)
			var cap := Label3D.new()
			cap.text = String(l["caption"]).to_upper()
			cap.font_size = 72
			# fits a ~5 m sign: smaller letters for a long name
			cap.pixel_size = minf(0.008, 5.0 / maxf(1.0, cap.text.length() * 72.0 * 0.62))
			cap.outline_size = 10
			cap.modulate = Color(0.98, 0.95, 0.85)
			cap.position = Vector3(0, 0, -0.04)
			cap.rotation.y = PI                   # the marker's -Z is the street; a Label3D reads from +Z
			n.add_child(cap)
		elif nm.begins_with("pickup_"):
			var kind := nm.trim_prefix("pickup_").get_slice(".", 0)
			kind = {"counter": "fruki"}.get(kind, kind)     # a shop counter: a can of Fruki on it
			landmark_pickups.append([kind, (n as Node3D).global_position])
	_autoplay(m)
	_model_sound(m, Entities.of_model(l["model"]))
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		_wave_if_flag(mi as MeshInstance3D)
		if String(l["model"]).contains("lacador"):
			_bronze(mi as MeshInstance3D)
	var solid = l.get("solid", true)
	if solid is String and solid == "box":
		_box_collider(m)          # dense sculptures and props: one box, not their triangles
		if l.has("full"):
			_merge_by_material(m)     # a closed shop: its dozen meshes drawn as one per material
		return
	var boxed: Array = m.get_meta("boxed", [])
	for b in boxed:
		_box_collider(b)          # a set's stalls and counters: a box each
	var storefront: bool = String(l["model"]).contains("/storefronts/")
	var shop_faces: Array = []
	_merge_collision.call_deferred(m, shop_faces)
	if storefront and String(l["model"]).contains("_modulo_") and not l.get("open", false):
		_box_collider(m)              # on its building's ground floor: solid (inside: its pocket)
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		if solid is bool and not solid:
			continue
		if boxed.any(func(b): return b.is_ancestor_of(mi)):
			continue
		if String(mi.name) == "floor_ground_pad" and String(l["model"]).contains("/storefronts/") \
				and m.find_children("ceramic*_ground_pad", "MeshInstance3D", true, false).size() > 0:
			mi.queue_free()              # the shop's ceramic floor covers it: both on the ground they flicker
			continue
		if l.has("leisure") and _LEISURE_FLOORS.has(String(mi.name).get_slice(".", 0)):
			# a pitch's or a playground's big surfaces tile the shared atlas (a
			# mosaic in the game): their own plain materials instead
			mi.material_override = _leisure_floor(String(mi.name).get_slice(".", 0))
		if String(mi.name).ends_with("_ground_pad") and String(l["model"]).contains("/storefronts/"):
			# the storefront packs tile their floors over the shared atlas (a mosaic in
			# the game): concrete for a forecourt, light ceramic inside a shop
			mi.material_override = _storefront_floor(String(mi.name).contains("ceramic"))
		if String(mi.name).ends_with("_ground_pad"):
			_landmark_surface(mi as MeshInstance3D)
			props.clear_under(mi as MeshInstance3D)
			_conform_pad.call_deferred(mi, m)
			continue                     # visual only: the street is the floor
		if String(mi.name) == "door" or String(mi.name).begins_with("door."):
			continue                     # a storefront's open door leaf: walk through
		if String(mi.name).contains("island") or String(mi.name).contains("site_details"):
			continue                     # pump-island kerbs and forecourt joints: people tripped on them
		if String(mi.name).ends_with("_screen") and String(l["model"]).contains("cine"):
			_cinema_screen(mi as MeshInstance3D, l.get("film", ""))
		_landmark_surface(mi as MeshInstance3D)
		if storefront:
			if String(l["model"]).contains("_modulo_") and not l.get("open", false):
				continue                       # a street-level module in town: one box, below (inside: its walls)
			if String(mi.name).contains("furniture"):
				_mesh_box(mi as MeshInstance3D, m)      # counters and shelves: a box each
			elif String(mi.name).contains("_wall") or String(mi.name).contains("floor"):
				shop_faces.append(mi)          # the walls and floor: one shape, below
			continue
		if not String(mi.name).ends_with("glass") and not String(mi.name).ends_with("skylight"):
			(mi as MeshInstance3D).create_trimesh_collision()
			# both sides, like the city's: a shop floor only stopped things from below
			for cs in mi.find_children("*", "CollisionShape3D", true, false):
				((cs as CollisionShape3D).shape as ConcavePolygonShape3D).backface_collision = true


## The Laçador's cast bronze: the delivered material is fully metallic and
## reads almost black in daylight; a warm bronze tint, satin, half metallic
## (the granite pedestal keeps its own material).
## the real statue is a dark, weathered bronze: brown with an olive patina,
## lit only by soft highlights - not a polished orange-gold
const BRONZE_TINT := Color(0.40, 0.32, 0.22)
func _bronze(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null or src.resource_name.to_lower().contains("granit") or String(mi.name).to_lower().contains("pedestal"):
			continue
		var b := src.duplicate() as BaseMaterial3D
		b.albedo_texture = null
		b.albedo_color = BRONZE_TINT
		b.metallic = 0.3
		b.metallic_texture = null
		b.roughness = 0.55
		mi.set_surface_override_material(i, b)


## Flags in placed models (their cloth's material is named "flag") wave.
const FLAG_WAVE := preload("res://shaders/flag_wave.gdshader")
func _wave_if_flag(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null or not src.resource_name.to_lower().contains("flag"):
			continue
		var box := mi.get_aabb()
		var w := ShaderMaterial.new()
		w.shader = FLAG_WAVE
		w.set_shader_parameter("albedo_tex", src.albedo_texture)
		w.set_shader_parameter("use_texture", src.albedo_texture != null)
		w.set_shader_parameter("albedo_color", src.albedo_color)
		w.set_shader_parameter("pole_x", box.position.x)
		w.set_shader_parameter("cloth_length", max(box.size.x, 0.3))
		w.set_shader_parameter("amplitude", clamp(box.size.x * 0.07, 0.04, 0.3))
		mi.set_surface_override_material(i, w)


## A forecourt pad is a flat slab in the model; on a sloping square the
## paving came up through it. Rebuild it as a 0.5 m grid laid on the
## ground, 8 cm up: closer than that the terrain's own triangles poked
## through between the samples and flickered as the camera moved.
func _conform_pad(mi: MeshInstance3D, owner_node: Node3D) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(mi):
		return
	var box := mi.get_aabb()
	var mat := mi.get_active_material(0)
	var space := get_world_3d().direct_space_state
	var ex := []
	for b in owner_node.find_children("*", "CollisionObject3D", true, false):
		ex.append((b as CollisionObject3D).get_rid())
	var xf := mi.global_transform
	var inv := xf.affine_inverse()
	if mi.mesh.get_faces().size() > 600:
		# already subdivided (a delivered model): drop its own vertices onto the
		# ground and keep its UVs and materials
		var am := ArrayMesh.new()
		for si in mi.mesh.get_surface_count():
			var mdt := MeshDataTool.new()
			mdt.create_from_surface(mi.mesh as ArrayMesh, si)
			for vi in mdt.get_vertex_count():
				var g := xf * mdt.get_vertex(vi)
				var q := PhysicsRayQueryParameters3D.create(g + Vector3(0, 2.5, 0), g - Vector3(0, 3.0, 0), 1)
				q.exclude = ex
				var hit := space.intersect_ray(q)
				if hit:
					mdt.set_vertex(vi, inv * Vector3(g.x, hit.position.y + 0.08, g.z))
			mdt.commit_to_surface(am)
			am.surface_set_material(si, mi.mesh.surface_get_material(si))
		mi.mesh = am
		return
	var nx := maxi(1, ceili(box.size.x * 2.0))
	var nz := maxi(1, ceili(box.size.z * 2.0))
	var top := box.end.y
	var pts := []
	for i in nx + 1:
		var row := []
		for j in nz + 1:
			var lp := Vector3(box.position.x + box.size.x * i / nx, top, box.position.z + box.size.z * j / nz)
			var g := xf * lp
			var q := PhysicsRayQueryParameters3D.create(g + Vector3(0, 2.5, 0), g - Vector3(0, 3.0, 0), 1)
			q.exclude = ex
			var hit := space.intersect_ray(q)
			if hit:
				g.y = hit.position.y + 0.08
			row.append(inv * g)
		pts.append(row)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in nx:
		for j in nz:
			for v in [pts[i][j], pts[i + 1][j], pts[i][j + 1], pts[i + 1][j], pts[i + 1][j + 1], pts[i][j + 1]]:
				st.set_uv(Vector2(v.x, v.z) / 2.0)
				st.add_vertex(v)
	st.generate_normals()
	mi.mesh = st.commit()
	if mat:
		mi.material_override = mat


## Map editor: put another film on the cinema screens of this map (live).
func set_screen_film(film: String) -> void:
	for s in _screens:
		var player: VideoStreamPlayer = s[0]
		if is_instance_valid(player):
			player.stream = load(film)
			player.play()
			s[2] = film


## A cinema screen: the film plays into a viewport shown on the screen mesh.
## It runs only while someone is near; the sound fades with distance.
## Films live per city in res://assets/rio_grande_do_sul/video/cities/<first map of the city>/:
## intro.ogv opens the city (a cutscene, skippable), any .ogv can be chosen
## for a cinema screen in the map editor ("film" on the building).
const FILMS_ROOT := "res://assets/rio_grande_do_sul/video/cities/"


static func city_of(id: String) -> String:
	for c in available_cities():
		for p in c[1]:
			if p[0] == id:
				return c[1][0][0]
	return id


static func city_films(id: String) -> PackedStringArray:
	var dir := FILMS_ROOT + city_of(id) + "/"
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return out                       # this city has no films (yet)
	for f in DirAccess.get_files_at(dir):
		var n := f.trim_suffix(".import").trim_suffix(".remap")
		if n.ends_with(".ogv") and not out.has(dir + n):
			out.append(dir + n)
	return out


## The city's opening film, full screen, when starting its first phase.
func play_intro(id: String) -> void:
	var cities := available_cities()
	var first := cities.any(func(c): return c[1][0][0] == id)
	var path := FILMS_ROOT + city_of(id) + "/intro.ogv"
	if not first or not ResourceLoader.exists(path):
		return
	_stop_menu_music()                     # the film has its own sound
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var v := VideoStreamPlayer.new()
	v.stream = load(path)
	v.expand = true
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(v)
	var hint := Label.new()
	hint.text = "Esc / click: skip"
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.offset_left = -200
	hint.offset_top = -40
	layer.add_child(hint)
	v.play()
	_skip_intro = false
	while v.is_playing() and not _skip_intro:
		await get_tree().process_frame
	layer.queue_free()


var _skip_intro := false
func _input(event: InputEvent) -> void:
	if (event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE, KEY_SPACE, KEY_ENTER]) \
			or (event is InputEventMouseButton and event.pressed):
		_skip_intro = true
var _screens: Array = []           # [VideoStreamPlayer, screen mesh]
func _cinema_screen(mi: MeshInstance3D, film := "") -> void:
	if film == "" or not ResourceLoader.exists(film):
		var films := city_films(map_id)
		film = FILMS_ROOT + city_of(map_id) + "/intro.ogv" if films.has(FILMS_ROOT + city_of(map_id) + "/intro.ogv") \
				else (films[0] if films.size() > 0 else "")
	if film == "":
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(854, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true                       # a film: no 3D pass of its own
	var player := VideoStreamPlayer.new()
	player.stream = load(film)
	player.loop = true
	player.size = Vector2(854, 480)
	player.expand = true
	player.volume_db = -60.0
	vp.add_child(player)
	mi.add_child(vp)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = vp.get_texture()
	mat.uv1_triplanar = false
	mi.material_override = mat
	_screens.append([player, mi, film])
	player.play()
	player.paused = true


func _update_screens() -> void:
	var p := _local_player()
	for s in _screens:
		var player: VideoStreamPlayer = s[0]
		if not is_instance_valid(player) or p == null:
			continue
		var d: float = (s[1] as Node3D).global_position.distance_to(p.global_position)
		player.paused = d > 45.0
		# far off nobody sees the screen: its viewport stops redrawing too
		(player.get_parent() as SubViewport).render_target_update_mode = \
				SubViewport.UPDATE_DISABLED if player.paused else SubViewport.UPDATE_ALWAYS
		player.volume_db = linear_to_db(clamp(1.0 - d / 30.0, 0.001, 1.0))


## A landmark made of many models (layout.json, like the Mercado Público:
## the building and its 72 stalls): each instance at its place, the stalls
## drawn only near (they share their meshes), lights where LIGHTS.json says.
func _layout_scene(path: String) -> Node3D:
	var root := Node3D.new()
	var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var base := path.get_base_dir()
	var boxed: Array = []
	for inst in lay.get("instances", []):
		var mp := base.path_join(inst["model"]).simplify_path()
		if not ResourceLoader.exists(mp):
			continue
		var n: Node3D = (load(mp) as PackedScene).instantiate()
		var pp: Array = inst.get("position", [0, 0, 0])
		var rr: Array = inst.get("rotation_degrees", [0, 0, 0])
		n.position = Vector3(pp[0], pp[1], pp[2])
		n.rotation_degrees = Vector3(rr[0], rr[1], rr[2])
		root.add_child(n)
		if inst.get("category", "") != "building":
			boxed.append(n)
			for mi in n.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).visibility_range_end = 90.0
				(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.set_meta("boxed", boxed)
	var lights_file := base.path_join("LIGHTS.json")
	if FileAccess.file_exists(lights_file):
		var i := 0
		for lt in JSON.parse_string(FileAccess.get_file_as_string(lights_file)):
			i += 1
			if i % 2 == 0:
				continue                  # every other hall lamp lights: enough, and cheaper
			var o := OmniLight3D.new()
			var lp: Array = lt["position"]
			o.position = Vector3(lp[0], lp[1] - 0.6, lp[2])
			o.light_color = Color(1.0, 0.93, 0.8)
			o.light_energy = 1.6
			o.omni_range = 16.0
			o.distance_fade_enabled = true
			o.distance_fade_begin = 70.0
			root.add_child(o)
	return root


## One mesh per material under `root` instead of one per part: a draw call
## (and a shadow one) each. The parts keep their nodes - markers, lights and
## signs hang under them - with no mesh of their own any more. Parts with a
## material override (a floor, a flag) stay as they are.
func _merge_by_material(root: Node3D) -> void:
	var groups := {}
	var inv := root.global_transform.affine_inverse()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var part := mi as MeshInstance3D
		if part.mesh == null or part.material_override != null or not part.visible:
			continue
		var xf := inv * part.global_transform
		for i in part.mesh.get_surface_count():
			var mat: Material = part.get_surface_override_material(i)
			if mat == null:
				mat = part.mesh.surface_get_material(i)
			if not groups.has(mat):
				var st := SurfaceTool.new()
				groups[mat] = st
			(groups[mat] as SurfaceTool).append_from(part.mesh, i, xf)
		part.mesh = null
	for mat in groups:
		var am: ArrayMesh = (groups[mat] as SurfaceTool).commit()
		if am.get_surface_count() == 0:
			continue
		am.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.name = "merged"
		root.add_child(mi)


func _box_collider(node: Node3D) -> void:
	var box := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = (node.global_transform.affine_inverse() * (mi as MeshInstance3D).global_transform) * (mi as MeshInstance3D).get_aabb()
		box = b if first else box.merge(b)
		first = false
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	cs.shape = shape
	cs.position = box.get_center()
	body.add_child(cs)
	node.add_child(body)


## Render and brickwork on the landmark models: the real PBR scans used by
## the city, projected triplanar in world space (the models carry no UVs for
## them) and tinted with the colour the model was painted.
const LANDMARK_SURFACES := {"_wall": ["PaintedPlaster017", 0.33], "_base": ["PaintedPlaster017", 0.33],
		"_brick": ["Bricks059", 0.6]}
var _surface_cache := {}
func _landmark_surface(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null or src.albedo_texture != null:
			continue                       # a model with its own painted atlas keeps it
		for suffix in LANDMARK_SURFACES:
			if not src.resource_name.ends_with(suffix):
				continue
			var key: String = src.resource_name
			if not _surface_cache.has(key):
				var spec: Array = LANDMARK_SURFACES[suffix]
				var dir := "res://assets/materials/%s/" % spec[0]
				var m := StandardMaterial3D.new()
				m.albedo_texture = load(dir + "color.jpg")
				m.albedo_color = src.albedo_color * 1.15      # the scans are light: tint them, little lift
				m.normal_enabled = true
				m.normal_texture = load(dir + "normalgl.jpg")
				m.roughness_texture = load(dir + "roughness.jpg")
				m.uv1_triplanar = true
				m.uv1_world_triplanar = true
				m.uv1_scale = Vector3.ONE * spec[1]
				_surface_cache[key] = m
			mi.set_surface_override_material(i, _surface_cache[key])


## Server: a driver or rider who just left their vehicle, already running
## from `threat` (model -1: any walker).
func spawn_fleeing(pos: Vector3, threat: Vector3, model := -1, hurt_by: Node3D = null, damage := 0) -> void:
	var p := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, pos)
	_civ_seq += 1
	var c: Node = civ_spawner.spawn({"id": _civ_seq, "pos": p + Vector3(0, 0.1, 0),
			"model": model if model >= 0 else Civilian.pick_walker()})
	if c:
		# the spawner adds it at once; flee on the next frame (navigation agent ready)
		c.call_deferred("_flee_from", threat)
		if damage > 0:
			c.call_deferred("apply_damage", damage, hurt_by)    # thrown off a run-over bike


## The crowd follows the players: most of the city's passers-by are kept
## near someone (as GTA does). Every 2 s, for each player with too few people
## around, one far from everybody leaves and a group appears out of sight
## 45-100 m off: alone, in pairs, in threes and fours, some standing chatting.
## And when no robot is near a player, people come running from where the
## robots are - a hint of where to go.
const BUBBLE_R := 120.0
const BUBBLE_NEAR := 35            # people wanted within BUBBLE_R of each player
var _bubble_cd := 3.0
var _compass_cd := {}
func _bubble(delta: float) -> void:
	_bubble_cd -= delta
	if _bubble_cd > 0 or not multiplayer.is_server() or not _round_live or not nav_ready:
		return
	_bubble_cd = 2.0
	_collectors(2.0)
	_swarms(2.0)
	_announce_t -= 2.0
	var players := players_root.get_children()
	for pl in players:
		var near := 0
		for c in civilians_root.get_children():
			if (c as Node3D).global_position.distance_to(pl.global_position) < BUBBLE_R:
				near += 1
		if near < BUBBLE_NEAR / max(1, players.size()) + 10:
			if civilians_root.get_child_count() >= civilians_wanted() and not _drop_far_walker(players):
				continue
			_spawn_group_near(pl)
		_compass(pl, delta)


## One walker far from every player leaves the streets (false if none).
func _drop_far_walker(players: Array) -> bool:
	for c in civilians_root.get_children():
		if c.get("police") or c.get("vendor") or c.get("waiting_at") != Vector3.INF or c.get("dog"):
			continue
		var far := true
		for pl in players:
			if (pl as Node3D).global_position.distance_to(c.global_position) < BUBBLE_R * 1.8:
				far = false
				break
		if far:
			c.queue_free()
			return true
	return false


## A street point 45-100 m from the player that no player can see.
func _hidden_point_near(pl: Node3D, toward := Vector3.ZERO) -> Vector3:
	var map := get_world_3d().navigation_map
	var space := get_world_3d().direct_space_state
	for attempt in 8:
		var dir := toward if toward != Vector3.ZERO else Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		dir = dir.rotated(Vector3.UP, randf_range(-0.5, 0.5))
		var p := NavigationServer3D.map_get_closest_point(map, pl.global_position + dir * randf_range(45.0, 100.0))
		if not in_bounds(p, 10.0) or p.distance_to(pl.global_position) < 35.0:
			continue
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.6, 0), pl.global_position + Vector3(0, 1.6, 0), 1)
		if not space.intersect_ray(q).is_empty():
			return p                         # a wall in between: it appears unseen
	return Vector3.INF


func _spawn_group_near(pl: Node3D) -> void:
	var at := _hidden_point_near(pl)
	if at == Vector3.INF:
		return
	var r := randf()
	var n := 1 if r < 0.5 else (2 if r < 0.8 else randi_range(3, 4))
	var chat := 0.0 if n == 1 or randf() > 0.25 else randf_range(20.0, 40.0)
	_civ_seq += 1
	var lead := _civ_seq
	civ_spawner.spawn({"id": lead, "pos": at + Vector3(0, 0.1, 0), "model": Civilian.pick_walker()} \
			.merged({"chat": chat} if chat > 0 else {}))
	for k in n - 1:
		_civ_seq += 1
		var off := Vector3([-1.0, 1.0, 0.0][k % 3], 0, 0.9 if k == 2 else 0.0) if chat == 0.0 \
				else Vector3.FORWARD.rotated(Vector3.UP, (k + 1) * TAU / n) * 1.1
		var data := {"id": _civ_seq, "pos": at + off + Vector3(0, 0.1, 0), "model": Civilian.pick_walker(),
				"leader": "C%d" % lead, "offset": off}
		if chat > 0:
			data["chat"] = chat
		civ_spawner.spawn(data)


## Server: URB-C4 Coletores on the prowl (difficulty.gd collectors), a new
## one a minute after one is gone; they come in far from the players.
var _collector_cd := 45.0
func _collectors(delta: float) -> void:
	_collector_cd -= delta
	if _collector_cd > 0 or _map_spec(map_id)[3] <= 0:
		return
	_collector_cd = 60.0
	var alive := 0
	for e in enemies_root.get_children():
		if e.get("variant") == "collector" and e.is_alive():
			alive += 1
	if alive >= int(Difficulty.get_value("collectors")):
		return
	var map := get_world_3d().navigation_map
	for attempt in 40:
		var p := NavigationServer3D.map_get_random_point(map, 1, true)
		if not in_bounds(p, 15.0):
			continue
		if players_root.get_children().any(func(pl): return pl.global_position.distance_to(p) < 90.0):
			continue
		enemy_spawner.spawn({"id": _next_enemy_id(), "pos": p + Vector3(0, 0.5, 0), "variant": "collector"})
		return


## Server: an URB-S2 swarm now and then while the fighting is on (one at a
## time, difficulty.gd swarm_s apart), out of sight of the player it hunts.
var _swarm_cd := 90.0
func _swarms(delta: float) -> void:
	_swarm_cd -= delta
	if _swarm_cd > 0 or _map_spec(map_id)[3] <= 0 or players_root.get_child_count() == 0:
		return
	_swarm_cd = Difficulty.get_value("swarm_s")
	for e in enemies_root.get_children():
		if e.get("variant") == "swarm" and e.is_alive():
			return
	var pl: Node3D = players_root.get_children().pick_random()
	if pl.dead:
		return
	var at := _hidden_point_near(pl)
	if at == Vector3.INF:
		return
	enemy_spawner.spawn({"id": _next_enemy_id(), "pos": at + Vector3(0, 12.0, 0), "variant": "swarm",
			"n": randi_range(Difficulty.get_value("swarm_n")[0], Difficulty.get_value("swarm_n")[1]) + 2 * (players_root.get_child_count() - 1)})


## A street point at the map's edge nearest to `at` (where a Coletor takes its catch).
func edge_point_near(at: Vector3) -> Vector3:
	var x0 := bounds.position.x + 12.0
	var x1 := bounds.end.x - 12.0
	var z0 := bounds.position.y + 12.0
	var z1 := bounds.end.y - 12.0
	var cands := [Vector3(x0, at.y, at.z), Vector3(x1, at.y, at.z), Vector3(at.x, at.y, z0), Vector3(at.x, at.y, z1)]
	cands.sort_custom(func(a, b): return a.distance_to(at) < b.distance_to(at))
	# the nearest edge at least 100 m off, so there is time to chase it down
	var pick: Vector3 = cands[cands.size() - 1]
	for cand in cands:
		if cand.distance_to(at) >= 100.0:
			pick = cand
			break
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, pick)


func _collector_escaped(_c) -> void:
	civ_killed += 1
	_phase_civ_lost += 1
	_announce("A COLETOR GOT AWAY WITH A CIVILIAN")


# ---- people containers -------------------------------------------------------
# A Coletor that catches someone waits at an open spot for a transport ship,
# which beams the captive up and down into a people container. A full
# container is hauled away by the mothership: everyone in it is lost, and
# losing CONTAINERS_LOST_MAX of them ends the round. Players open them (E).

const PeopleContainer := preload("res://scripts/people_container.gd")
const CONTAINERS_LOST_MAX := 3
const POINTS_FREED := 100        # per person let out of a container
const POINTS_CONTAINER_LOST := -300
var _containers: Array = []
var _container_seq := 0
var containers_lost := 0


## Every peer: no containers yet; the server has the mothership bring them.
func _place_containers() -> void:
	for c in _containers:
		if is_instance_valid(c):
			c.queue_free()
	_containers = []
	_container_seq = 0
	containers_lost = 0
	if _map_spec(map_id)[3] <= 0 or not multiplayer.is_server():
		return                          # free play: no objective
	await wait_for_navmesh()
	await get_tree().create_timer(2.0).timeout
	for k in int(Difficulty.get_value("containers")):
		var spot := _container_spot()
		if spot != Vector3.INF:
			_deliver_container(spot)


## Server: where the mothership sets a container down - open ground with sky
## for the ships, as far as it gets from every player (150 m at least when
## the map allows) and from the other containers.
func _container_spot() -> Vector3:
	var map := get_world_3d().navigation_map
	var players := get_tree().get_nodes_in_group("players")
	var away := [spawn_point]
	for pl in players:
		away.append(pl.global_position)
	var best := Vector3.INF
	var best_d := -1.0
	for attempt in 400:
		var p := NavigationServer3D.map_get_closest_point(map, Vector3(randf_range(bounds.position.x, bounds.end.x), 0,
				randf_range(bounds.position.y, bounds.end.y)))
		if not in_bounds(p, 30.0):
			continue
		if _containers.any(func(c): return is_instance_valid(c) and Vector2(c.ground_spot.x, c.ground_spot.z).distance_to(Vector2(p.x, p.z)) < 120.0):
			continue
		var d := INF
		for q in away:
			d = minf(d, Vector2(q.x, q.z).distance_to(Vector2(p.x, p.z)))
		if d <= best_d or not _open_ground(p) or _sky_hover(p, 18) < 0.0:
			continue
		best = p
		best_d = d
		if d > 220.0:
			break
	return best


## Server: the mothership flies in with an empty container under it and
## lowers it onto `spot`.
func _deliver_container(spot: Vector3) -> void:
	var hover: float = max(_sky_hover(spot, 18), 28.0)
	var cruise: float = max(Dropship.CRUISE_Y, city_top + 25.0)
	var dir := Vector3(spot.x, 0, spot.z).normalized()
	if dir == Vector3.ZERO:
		dir = Vector3.BACK
	var start: Vector3 = Vector3(spot.x, 0, spot.z) + dir * (map_reach() + 80.0)
	start.y = cruise
	var hang := start - Vector3(0, Dropship.carry_drop("mother"), 0)
	new_container.rpc(hang, spot)
	_ship_seq += 1
	ship_spawner.spawn({"id": _ship_seq, "pos": start, "kind": "mother", "cruise": cruise, "bring": true,
			"stops": [[spot, hover, 12.0]], "container": str(_containers[-1].get_path())})


func _add_container(at: Vector3, spot: Vector3) -> Node3D:
	var c: StaticBody3D = PeopleContainer.new()
	c.name = "PeopleContainer%d" % _container_seq
	_container_seq += 1
	c.capacity = int(Difficulty.get_value("container_cap"))
	c.position = at
	c.ground_y = spot.y
	c.ground_spot = spot
	c.lifting = true                 # on its way under the mothership
	add_child(c)
	_map_nodes.append(c)
	if multiplayer.is_server():
		c.opened.connect(_container_opened.bind(c))
	_containers.append(c)
	return c


## Server -> every peer: a new round, the containers empty and back in place.
@rpc("authority", "call_local", "reliable")
func reset_containers() -> void:
	_place_containers()


## Server -> every peer: a container (hanging under the mothership at `at`,
## to be set down on `spot`).
@rpc("authority", "call_local", "reliable")
func new_container(at: Vector3, spot: Vector3) -> void:
	_add_container(at, spot)


@rpc("authority", "call_local", "reliable")
func remove_container(path: NodePath) -> void:
	var c := get_node_or_null(path)
	if c:
		_containers.erase(c)
		c.queue_free()


## Room for a container at `p`: a square, park or wide pavement around it,
## not the carriageway (nor a pavement too narrow to walk round it).
func _open_ground(p: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	for off in [Vector3.ZERO, Vector3(3, 0, 0), Vector3(-3, 0, 0), Vector3(0, 0, 3), Vector3(0, 0, -3)]:
		var q: Vector3 = p + off
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(q + Vector3(0, 3, 0), q - Vector3(0, 3, 0), 1))
		if not hit or hit.normal.y < 0.9 or absf(hit.position.y - p.y) > 0.6:
			return false
		var under: Node = hit.collider
		while under and under != self:
			var n := String(under.name)
			if n.begins_with("asphalt") or n.begins_with("markings") or n.begins_with("zebra") or n.begins_with("curb"):
				return false
			under = under.get_parent()
	return true


## The height a ship hovers at over `pos` (5 m above the roofs around, at
## least the dropship's), or -1 when the sky above it is not open.
func _sky_hover(pos: Vector3, radius := 13) -> float:
	var space := get_world_3d().direct_space_state
	var roof := pos.y
	for dx in range(-radius, radius + 1, 3):
		for dz in range(-radius, radius + 1, 3):
			if dx * dx + dz * dz > radius * radius:
				continue
			var top := pos + Vector3(dx, 0, dz)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
					top + Vector3(0, city_top + 10.0, 0), top + Vector3(0, -1.0, 0), 1 | ROOF_LAYER))
			if hit:
				roof = max(roof, hit.position.y)
	var hover: float = max(Dropship.HOVER_Y, roof - pos.y + 5.0)
	if hover > 60.0:
		return -1.0
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pos + Vector3(0, PeopleContainer.HEIGHT + 0.5, 0),
			pos + Vector3(0, hover, 0), 1))
	return -1.0 if hit else hover


## The container (not full, not being hauled) nearest to `at`.
func _free_container(at: Vector3) -> Node3D:
	var best: Node3D = null
	for c in _containers:
		if is_instance_valid(c) and not c.full() and not c.lifting \
				and (best == null or c.global_position.distance_to(at) < best.global_position.distance_to(at)):
			best = c
	return best


## Server: a Coletor caught someone - it carries them on foot to the nearest
## people container with room (the spot beside it it walks to; INF when there
## is none - it then runs for the map edge as before). No ship comes for each
## captive: the mothership only comes for a full container, so the players
## have the time it fills to open it, or to bring a Coletor down on its way.
func container_meet(collector: Node3D) -> Vector3:
	var target := _free_container(collector.global_position)
	if target == null:
		return Vector3.INF
	collector.set_meta("container", str(target.get_path()))
	var side: Vector3 = collector.global_position - target.global_position
	side.y = 0
	side = side.normalized() * 2.8 if side.length() > 0.1 else Vector3.BACK * 2.8
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, target.global_position + side)


## Server: a Coletor reached its container - the captive goes in (a full
## one calls the mothership). False when it is full or being lifted by now:
## the Coletor is sent to another one (container_meet again).
func container_deliver(collector: Node3D) -> bool:
	var cont := get_node_or_null(NodePath(collector.get_meta("container", "")))
	if cont == null or cont.full() or cont.lifting:
		return false
	cont.add_person.rpc(collector.hand_over())
	_announce("A COLETOR PUT SOMEONE IN A PEOPLE CONTAINER (%d / %d) - open it (E) before it is full" % [cont.people.size(), cont.capacity])
	if cont.full():
		_call_mothership(cont)
	return true


## Server: a full container - the mothership comes to haul it away.
func _call_mothership(cont: Node3D) -> void:
	cont.lifting = true
	var hover: float = max(_sky_hover(cont.global_position, 18), 28.0)
	var cruise: float = max(Dropship.CRUISE_Y, city_top + 25.0)
	var dir := Vector3(cont.global_position.x, 0, cont.global_position.z).normalized()
	if dir == Vector3.ZERO:
		dir = Vector3.BACK
	var start: Vector3 = Vector3(cont.global_position.x, 0, cont.global_position.z) - dir * (map_reach() + 80.0)
	start.y = cruise
	_ship_seq += 1
	ship_spawner.spawn({"id": _ship_seq, "pos": start, "kind": "mother", "cruise": cruise,
			"stops": [[cont.global_position, hover, 26.0]], "container": str(cont.get_path())})
	_announce("A PEOPLE CONTAINER IS FULL - THE MOTHERSHIP IS COMING FOR IT! Open it (E) before it is lifted away")


## Server: the mothership left the map. With people in it the container is lost.
func _mother_left(s: Node3D, path: String) -> void:
	var cont := get_node_or_null(NodePath(path))
	if cont == null:
		return
	if s.carry != cont or cont.people.is_empty():
		cont.lifting = false
		return
	var n: int = cont.people.size()
	civ_killed += n
	_phase_civ_lost += n
	containers_lost += 1
	award(0, POINTS_CONTAINER_LOST - 50 * n, "people container taken")
	remove_container.rpc(cont.get_path())
	_check_phase_failed()
	if containers_lost >= CONTAINERS_LOST_MAX:
		_announce("THE ROBOTS TOOK %d PEOPLE CONTAINERS - THE ROUND STARTS OVER" % containers_lost)
		director.set_process(false)
		await get_tree().create_timer(7.0).timeout
		_restart_round()
		return
	_announce("THE MOTHERSHIP TOOK A CONTAINER WITH %d PEOPLE (%d / %d lost)" % [n, containers_lost, CONTAINERS_LOST_MAX])
	# the mothership brings an empty one, somewhere far from the players
	var spot := _container_spot()
	if spot != Vector3.INF:
		_deliver_container(spot)


## A player at a container (any peer -> server): let everyone out.
@rpc("any_peer", "call_local", "reliable")
func open_container(path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var cont := get_node_or_null(path)
	if cont:
		var peer := multiplayer.get_remote_sender_id()
		cont.open_by(peer if peer != 0 else 1)


func _container_opened(peer: int, people: Array, cont: Node3D) -> void:
	for sh in ships_root.get_children():
		if sh.kind == "mother" and sh.carry == cont:
			sh.carry = null              # opened under the mothership: the empty shell drops back
	cont.lifting = false
	cont.position.y -= cont.lift()
	var at: Vector3 = cont.global_position
	for idx in people:
		_civ_seq += 1
		var off := Vector3(randf_range(-2.5, 2.5), 0, randf_range(-2.5, 2.5))
		civ_spawner.spawn({"id": _civ_seq, "pos": at + off + Vector3(0, 0.3, 0), "model": int(idx), "flee_from": at})
	award(peer, POINTS_FREED * people.size(), "%d people freed" % people.size())
	_announce("%d PEOPLE FREED FROM A CONTAINER!" % people.size())


## The container whose hatch a player at `at` can reach (null: none).
func container_near(at: Vector3) -> Node3D:
	for c in _containers:
		if is_instance_valid(c) and not c.people.is_empty() and c.lift() < PeopleContainer.HEIGHT \
				and Vector2(c.global_position.x - at.x, c.global_position.z - at.z).length() < PeopleContainer.RADIUS + 1.8:
			return c
	return null


## A short message over the objective line for every player.
var _announce_text := ""
var _announce_t := 0.0
func _announce(text: String) -> void:
	_announce_text = text
	_announce_t = 6.0


## Quiet around this player: a few people come running from the nearest robots.
func _compass(pl: Node3D, delta: float) -> void:
	var cd: float = _compass_cd.get(pl.name, 8.0) - 2.0
	_compass_cd[pl.name] = cd
	if cd > 0:
		return
	var nearest: Node3D = null
	var nd := 400.0
	for e in enemies_root.get_children():
		if not e.has_method("is_alive") or not e.is_alive():
			continue
		var d := (e as Node3D).global_position.distance_to(pl.global_position)
		if d < 70.0:
			return                            # fighting already: no hints needed
		if d < nd:
			nd = d
			nearest = e
	if nearest == null:
		return
	_compass_cd[pl.name] = randf_range(14.0, 22.0)
	var dir := nearest.global_position - pl.global_position
	dir.y = 0
	var at := _hidden_point_near(pl, dir.normalized())
	if at == Vector3.INF:
		return
	for k in randi_range(2, 3):
		if civilians_root.get_child_count() >= civilians_wanted():
			_drop_far_walker(players_root.get_children())     # the crowd moves, it doesn't grow
		_civ_seq += 1
		civ_spawner.spawn({"id": _civ_seq, "pos": at + Vector3(randf_range(-1.5, 1.5), 0.1, randf_range(-1.5, 1.5)),
				"model": Civilian.pick_walker(), "flee_from": nearest.global_position})


func _spawn_civilians(n: int) -> void:
	var map := get_world_3d().navigation_map
	var players := get_tree().get_nodes_in_group("players")
	var placed := 0
	for attempt in n * 25:
		if placed >= n:
			break
		var pos := NavigationServer3D.map_get_random_point(map, 1, true)
		if not crowd.is_empty() and randf() < 0.45:      # promenades are busier
			pos = NavigationServer3D.map_get_closest_point(map, crowd.pick_random())
		if not in_bounds(pos, 10.0):
			continue
		var visible := false
		for pl in players:
			var d: float = pl.global_position.distance_to(pos)
			if d < 12.0:
				visible = true
			elif d < 60.0:
				var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.5, 0), pl.global_position + Vector3(0, 1.6, 0), 1)
				visible = visible or get_world_3d().direct_space_state.intersect_ray(q).is_empty()
		if visible:
			continue
		var path := NavigationServer3D.map_get_path(map, spawn_point, pos, true)
		if path.is_empty() or path[path.size() - 1].distance_to(pos) > 1.0:
			continue
		_civ_seq += 1
		civ_spawner.spawn({"id": _civ_seq, "pos": pos + Vector3(0, 0.1, 0), "model": Civilian.pick()})
		placed += 1


func _spawn_civilian_node(data: Variant) -> Node:
	var c: CharacterBody3D = Civilian.new()
	c.name = "C%d" % data["id"]
	c.model_idx = data["model"]
	c.home = data.get("home", Vector3.INF)
	c.home_yaw = data.get("home_yaw", 0.0)
	c.waiting_at = data.get("wait", Vector3.INF)
	c.position = data["pos"]
	if multiplayer.is_server():
		# bubble groups and "running from the robots" (see _bubble)
		if data.has("leader"):
			c.ready.connect(func():
				c.leader = civilians_root.get_node_or_null(data["leader"])
				c.group_offset = data.get("offset", Vector3.ZERO), CONNECT_ONE_SHOT)
		if data.has("chat"):
			c.ready.connect(func(): c._pause = data["chat"], CONNECT_ONE_SHOT)
		if data.has("flee_from"):
			c.ready.connect(func(): c._flee_from(data["flee_from"]), CONNECT_ONE_SHOT)
	if multiplayer.is_server():
		c.died.connect(func(dead_civ):
			if not dead_civ.dog:
				civ_killed += 1
				if dead_civ.killed_by_robot or dead_civ.killed_by_player:
					_phase_civ_lost += 1
				if dead_civ.killed_by_player:
					award(dead_civ.killer_peer, POINTS["civilian"], "civilian killed")
				elif dead_civ.killed_by_robot:
					award(0, POINTS["civilian_robot"], "civilian lost"))
	return c


func _spawn_car_node(data: Variant) -> Node:
	var car: AnimatableBody3D = Car.new()
	car.name = "V%d" % data["id"]
	car.model_idx = data["model"]
	car.driver_idx = data.get("driver", -1)
	car.graph = road_graph
	if data.has("parked"):
		car.position = data["parked"]
		car.rotation.y = data.get("yaw", 0.0)
		car.occupied = false
		car.ready.connect(car.settle_parked, CONNECT_ONE_SHOT)
	elif multiplayer.is_server():
		car.ready.connect(func(): car.start(data["edge"], data["forward"]), CONNECT_ONE_SHOT)
	return car


## Server: a fresh reachable street point for a respawning pickup.
func random_pickup_point(avoid: Vector3) -> Vector3:
	var map := get_world_3d().navigation_map
	for attempt in 60:
		var pos := NavigationServer3D.map_get_random_point(map, 1, true)
		if not in_bounds(pos, 10.0) or pos.distance_to(avoid) < 25.0:
			continue
		var crowded := false
		for pk in pickups_root.get_children():
			if pk.global_position.distance_to(pos) < 15.0:
				crowded = true
				break
		if crowded:
			continue
		var path := NavigationServer3D.map_get_path(map, spawn_point, pos, true)
		if not path.is_empty() and path[path.size() - 1].distance_to(pos) < 1.0:
			return pos
	return avoid
