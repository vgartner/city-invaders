extends Node
## Dev-only scene preparation plus a simulation-time walking take.
## No automatic bot choices, no position writes during a take.
const SCENES := "res://data/video_scenes.json"
var agent: Node
var scene_name := ""
var scene: Dictionary = {}
var preparing := false
var running := false
var elapsed := 0.0
var last: Dictionary = {}
var _created: Array[WeakRef] = []
var _saved: Dictionary = {}
var _samples: Array = []
var _start_frame := 0
var _start_drawn := 0
var _player: Node3D
var _quit_on_end := false
var _pickup_targets: Dictionary = {}
var _collected: Array = []
var _actions: Node
var _take_origin := Vector3.ZERO

static func catalogue() -> Dictionary:
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCENES))
	return value if value is Dictionary else {}

static func smooth_weight(value: float) -> float:
	var x := clampf(value, 0.0, 1.0)
	return x * x * x * (10.0 + x * (-15.0 + 6.0 * x))

static func walking(cue: Dictionary, t: float) -> Vector2:
	var start: float = cue["start"]
	var end: float = cue["end"]
	if t <= start or t >= end:
		return Vector2.ZERO
	var ramp: float = minf(float(cue.get("ramp_s", 0.5)), (end - start) * 0.5)
	var strength := minf(smooth_weight((t - start) / ramp), smooth_weight((end - t) / ramp))
	var direction: Array = cue["direction"]
	return Vector2(direction[0], direction[1]).limit_length() * strength * clampf(float(cue.get("speed_fraction",1.0)),0.0,1.0)

static func looking(keys: Array, t: float) -> Vector2:
	for i in range(1, keys.size()):
		var a: Dictionary = keys[i - 1]
		var b: Dictionary = keys[i]
		if t <= float(b["t"]):
			var f := smooth_weight((t - float(a["t"])) / (float(b["t"]) - float(a["t"])))
			return Vector2(lerp_angle(deg_to_rad(a["yaw"]), deg_to_rad(b["yaw"]), f),
				lerpf(deg_to_rad(a["pitch"]), deg_to_rad(b["pitch"]), f))
	var end: Dictionary = keys[-1]
	return Vector2(deg_to_rad(end["yaw"]), deg_to_rad(end["pitch"]))

func _ready() -> void:
	# Apply input/aim before Player's normal collision/movement physics.
	process_physics_priority = -100
	set_physics_process(false)

func _ground(main: Node3D, wanted: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(main.get_world_3d().navigation_map, wanted)

func prepare(name: String) -> Dictionary:
	if preparing or running:
		return {"__error":"A video setup/take is active; stop it before staging another scene"}
	var all := catalogue()
	if not all.has(name):
		return {"__error":"Unknown video scene: " + name}
	if agent._m_autoplay_status({}).get("active", false):
		return {"__error":"Stop autoplay before staging a shot"}
	if not multiplayer.get_peers().is_empty():
		return {"__error":"Video staging requires an isolated solo game"}
	var main: Node3D = agent._main()
	var wanted: Dictionary = all[name]
	if agent._player() != null and main.map_id != wanted["map"]:
		return {"__error":"This preset needs a fresh solo game on " + str(wanted["map"])}
	preparing = true
	await agent._m_start_solo({"map":wanted["map"]})
	_player = agent._player()
	if _player == null:
		preparing = false
		return {"__error":"No local player after loading"}
	if _player.vehicle or _player.passenger or _player.design:
		preparing = false
		return {"__error":"Leave the vehicle/editor before staging"}
	clear()
	scene_name = name
	scene = wanted
	_saved = {"director":main.director.is_processing(), "swarm_cd":main._swarm_cd,"dynamic_resolution":main.dynamic_resolution,
		"scale":main.get_viewport().scaling_3d_scale,"window_size":get_window().size,
		"master_mute":AudioServer.is_bus_mute(0)}
	if OS.has_feature("movie"):
		# Match the capture viewport, avoiding a cropped HUD on macOS/Retina.
		get_window().size = Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")),
			int(ProjectSettings.get_setting("display/window/size/viewport_height")))
		main.dynamic_resolution = false
		main.get_viewport().scaling_3d_scale = 1.0
		AudioServer.set_bus_mute(0,false)
	main.director.set_process(false)
	main._swarm_cd = 1e9
	# Explicit staging replaces the round's robots; never use in a shared round.
	for enemy in main.enemies_root.get_children(): enemy.queue_free()
	for ship in main.ships_root.get_children(): ship.queue_free()
	if _player._drone: _player._land_drone()
	_player.set_meta("god", true)
	_player.health = 100
	# Reset collection eligibility for a repeatable rehearsal, before the take.
	_player.armor = 0
	_player._adrenaline = 0.0
	var pos: Array = wanted["position"]
	var at := _ground(main, Vector3(pos[0], pos[1], pos[2]))
	_player.global_position = at + Vector3(0, 0.15, 0)
	_player.velocity = Vector3.ZERO
	_player.rotation.y = deg_to_rad(wanted["yaw"])
	_player.pitch = deg_to_rad(wanted["pitch"])
	_player.head.rotation.x = _player.pitch
	_player.reset_physics_interpolation()
	_player.give(wanted["weapon"])
	_player._switch(wanted["weapon"])
	_player._mags[wanted["weapon"]] = _player.WEAPONS[wanted["weapon"]]["mag"]
	_player._reserves[wanted["weapon"]] = _player.WEAPONS[wanted["weapon"]]["reserve_max"]
	_player._fire_cd = 0.0
	_player._reload_left = 0.0
	_player.grenades["bergamota"] = 3
	_player.grenades["porongo"] = 3
	_player.drones = int(wanted.get("drones", 0))
	for spec in wanted.get("pickups", []):
		var offset: Array = spec["offset"]
		var p := _ground(main, at + Vector3(offset[0], offset[1], offset[2]))
		var pickup: Area3D = main._spawn_pickup(spec["kind"], p, false)
		_created.append(weakref(pickup))
		_pickup_targets[spec["kind"]] = pickup.global_position
		pickup.body_entered.connect(_pickup_entered.bind(pickup))
	for spec in wanted.get("enemies", []):
		var offset: Array = spec["offset"]
		var p := _ground(main, at + Vector3(offset[0], 0, offset[2])) + Vector3(0, offset[1] + 0.2, 0)
		agent._m_spawn_enemy({"x":p.x,"y":p.y,"z":p.z,"variant":spec["variant"]})
		_created.append(weakref(main.enemies_root.get_child(main.enemies_root.get_child_count() - 1)))
	_take_origin = _player.global_position
	if wanted.get("take",{}).has("presentation"):
		_actions = preload("res://scripts/video_actions.gd").new()
		add_child(_actions)
		_actions.setup(self)
	await get_tree().create_timer(float(wanted.get("settle_s", 8))).timeout
	preparing = false
	return status()

func _pickup_entered(body: Node, pickup: Area3D) -> void:
	# Pickup's own handler runs first. Observe its normal grant/removal, never give items here.
	if running and body == _player and pickup.is_queued_for_deletion():
		_collected.append({"kind":pickup.kind,"t":elapsed,"armor":_player.armor,
			"adrenaline_s":_player._adrenaline})

func _approach(cue: Dictionary, t: float) -> Vector2:
	if t <= float(cue["start"]) or t >= float(cue["end"]): return Vector2.ZERO
	var target: Vector3 = _pickup_targets.get(cue["pickup"], _player.global_position)
	var offset := target - _player.global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance <= 0.12: return Vector2.ZERO
	var speed := float(cue["speed_mps"]) * minf(
		smooth_weight((t - float(cue["start"])) / float(cue.get("ramp_s",0.7))),
		smooth_weight(distance / 1.2))
	# Player physics applies Fruki's real speed multiplier to this normal input.
	var local := _player.global_basis.inverse() * offset.normalized()
	return Vector2(local.x,local.z) * speed / _player.WALK_SPEED

func clear() -> void:
	stop()
	if is_instance_valid(_actions):
		_actions.finish()
		_actions.queue_free()
	_actions = null
	for ref in _created:
		var node: Node = ref.get_ref()
		if is_instance_valid(node): node.queue_free()
	_created.clear()
	_pickup_targets.clear()
	if not _saved.is_empty():
		var main: Node3D = agent._main()
		main.director.set_process(_saved["director"])
		main._swarm_cd = _saved["swarm_cd"]
		main.dynamic_resolution = _saved["dynamic_resolution"]
		main.get_viewport().scaling_3d_scale = _saved["scale"]
		AudioServer.set_bus_mute(0,_saved["master_mute"])
		if OS.has_feature("movie"): get_window().size = _saved["window_size"]
	_saved.clear()
	scene_name = ""
	scene = {}

func play(quit_on_end := false) -> Dictionary:
	if preparing or running or not scene.has("take"):
		return {"__error":"Prepare a scene with a scripted take first (usina_walk)"}
	if not is_instance_valid(_player):
		return {"__error":"Prepare a fresh stage after changing rounds"}
	if get_tree().paused or agent._main().paused:
		return {"__error":"Unpause the game before starting the take"}
	if _player.dead or _player.design or _player.vehicle or _player._drone:
		return {"__error":"The walking take needs a live player on foot"}
	elapsed = 0.0
	_samples = []
	_collected = []
	_start_frame = Engine.get_process_frames()
	_start_drawn = Engine.get_frames_drawn()
	_quit_on_end = quit_on_end
	_player.scripted_control = true
	_player.scripted_move = Vector2.ZERO
	running = true
	if is_instance_valid(_actions): _actions.begin()
	set_physics_process(true)
	print("VIDEO_TAKE_START ", JSON.stringify({"scene":scene_name,"process_frame":_start_frame,"drawn_frame":_start_drawn}))
	return status()

func _physics_process(delta: float) -> void:
	if not running: return
	if not is_instance_valid(_player) or _player.dead:
		stop()
		return
	var take: Dictionary = scene["take"]
	var look := looking(take["look"], elapsed)
	_player.rotation.y = look.x
	_player.pitch = look.y
	_player.head.rotation.x = look.y
	var movement := Vector2.ZERO
	for cue in take.get("walk", []): movement += walking(cue, elapsed)
	for cue in take.get("approach", []): movement += _approach(cue, elapsed)
	_player.scripted_move = movement.limit_length()
	if is_instance_valid(_actions): _actions.tick(elapsed,delta)
	_samples.append({"t":elapsed,"position":[_player.position.x,_player.position.y,_player.position.z],
		"yaw":_player.rotation.y,"pitch":_player.pitch,"move":[movement.x,movement.y],"frame":Engine.get_process_frames()})
	elapsed += delta
	if elapsed + 1e-6 >= float(take["duration_s"]):
		stop(true)

func stop(completed := false) -> void:
	if is_instance_valid(_player):
		_player.scripted_control = false
		_player.scripted_move = Vector2.ZERO
	set_physics_process(false)
	if not running: return
	running = false
	var missing: Array = []
	for kind in scene.get("take",{}).get("expect_pickups",[]):
		if not _collected.any(func(event: Dictionary) -> bool: return event["kind"] == kind): missing.append(kind)
	last = {"scene":scene_name,"completed":completed,"seconds":elapsed,
		"collected":_collected,"missing_pickups":missing,
		"events":_actions.ledger if is_instance_valid(_actions) else [],
		"player_state":{"drones":_player.drones,"score":_player.score,"armor":_player.armor},
		"start_process_frame":_start_frame,"start_drawn_frame":_start_drawn,
		"end_process_frame":Engine.get_process_frames(),"samples":_samples}
	var dir := "user://devagent/takes"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("take_%d_%d.json" % [OS.get_process_id(),Time.get_ticks_usec()])
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(last))
	last["log"] = ProjectSettings.globalize_path(path)
	print("VIDEO_TAKE_END ", JSON.stringify({"completed":completed,"log":last["log"],"seconds":elapsed,"collected":_collected,"missing_pickups":missing}))
	if is_instance_valid(_actions) and not (completed and _quit_on_end): _actions.finish()
	if completed and _quit_on_end: get_tree().quit.call_deferred()

func status() -> Dictionary:
	var summary := last.duplicate()
	summary.erase("samples")
	return {"scene":scene_name,"preparing":preparing,"running":running,"elapsed_s":elapsed,
		"guide":scene.get("guide",""),"scripted_take":scene.has("take"),"movie_mode":OS.has_feature("movie"),
		"window_px":[get_window().size.x,get_window().size.y],
		"viewport_px":[get_viewport().get_visible_rect().size.x,get_viewport().get_visible_rect().size.y],
		"master_muted":AudioServer.is_bus_mute(0),
		"player_position":agent._v(_player.global_position) if is_instance_valid(_player) else [],"last":summary}
