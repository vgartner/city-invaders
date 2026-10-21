extends CharacterBody3D
## A person or a street animal on foot. What it is comes from data
## (docs/ENTITIES.md): the Person type tree in assets/types.json - Pedestrian,
## Skater, Vendor, Police - and Animal/Dog, with a `*.def.json` per group of
## models (`models`: the folders). The type gives the speeds, health, the
## reaction to robots (`react`: flee or fight), whether robots hunt it, the
## capsule, the gait (`shared`: the people's one walk, see _shared_gait),
## where it spawns and how often. Server-simulated: wanders the streets,
## flees when it sees a robot nearby or hears shots, and can be killed.
## Clients receive position/rotation/health and animate locally.

signal died(civ)

const Step := preload("res://scripts/step.gd")
const Library := preload("res://scripts/model_library.gd")
const Entities := preload("res://scripts/entities.gd")
## every model a person or animal can wear, and the definition of each (same
## order on every peer: model_idx is replicated)
static var KINDS: Array = []
static var MODELS: PackedStringArray = _all_models()
## skaters: the push clip sweeps the foot at 3.948 m/s
const ANIM_PUSH := 3.948
## ground speed the in-place clips step at for a stature scale of 1.0
## (set by tools/assets/gait.py); playback is scaled by actual speed /
## (this x the model's stature scale), so feet don't slide
const ANIM_WALK := 1.25
const ANIM_SPRINT := 3.6
const HEIGHT := 1.72         # the stylised fallback set is scaled to this
const THREAT_RADIUS := 20.0
const HEAR_RADIUS := 28.0
const CALM_SECONDS := 7.0
const CORPSE_SECONDS := 8.0

enum State { WANDER, FLEE }

@export var health := 45
@export var model_idx := 0
var person: Dictionary = {}       # the resolved definition (type defaults + its own)
var state := State.WANDER
var agent: NavigationAgent3D
var _anim: AnimationPlayer
var _goal := Vector3.INF
var _pause := 0.0
var _calm := 0.0
var _scan_cd := 0.0
var _last_pos := Vector3.ZERO
var _speed_est := 0.0
var skater := false
var hunted := true              # robots go for it (people yes, street dogs no)
var dog := false
var killed_by_robot := false
var killed_by_player := false   # friendly fire or run over
var killer_peer := 0
var vendor := false
var police := false
var _foe: Node3D                 # police: the robot (or the player who shot it) it is fighting
var _grudge: Node3D              # police: a player who shot at it (friendly fire)
var _grudge_left := 0.0
var _shot_cd := 0.0
var _firing := 0.0
var home := Vector3.INF          # vendors: the spot behind their stall
var waiting_at := Vector3.INF    # waiting for the bus at this stop
var _boarding: Node3D            # walking to the bus door, gets on (and is gone)
var home_yaw := 0.0
var _stature := 1.0
var _win_dist := 0.0
var _win_time := 0.0
var _dying := false
var _stuck := 0.0
## groups (main.gd bubble): a follower keeps this offset from its leader
var leader: Node3D
var group_offset := Vector3.ZERO
var _follow_cd := 0.0
var _unsticks := 0          # unstick attempts without getting free (reset after a clean stretch)
var _free_t := 0.0
var _detour := Vector3.ZERO
var _detour_left := 0.0
var _threat := Vector3.ZERO
var _ask_cd := 0.0               # fleeing: wait before asking for a path again


func _ready() -> void:
	person = KINDS[model_idx % MODELS.size()]
	var types: Array = person.get("types", [])
	dog = "Dog" in types
	vendor = "Vendor" in types
	police = person.get("react", "flee") == "fight"
	skater = "Skater" in types
	health = int(person.get("health", health))
	hunted = bool(person.get("hunted", true))
	add_to_group("civilians")
	collision_layer = 32
	collision_mask = 1 | 16
	floor_max_angle = deg_to_rad(60)       # step over curbs (see player.gd)
	floor_snap_length = 0.3
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = float(person.get("capsule", {}).get("radius", 0.28))
	cap.height = float(person.get("capsule", {}).get("height", HEIGHT))
	cs.shape = cap
	cs.position.y = cap.height / 2
	add_child(cs)
	_build_visual()
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	for prop in [".:position", ".:rotation", ".:health"]:
		cfg.add_property(NodePath(prop))
	sync.replication_config = cfg
	add_child(sync)
	agent = NavigationAgent3D.new()
	agent.radius = 0.35
	agent.path_desired_distance = 0.8
	agent.target_desired_distance = 1.0
	add_child(agent)
	_last_pos = global_position
	set_physics_process(multiplayer.is_server())


static func _all_models() -> PackedStringArray:
	# every Person and Animal definition, by id, and the models in its folders
	var out := PackedStringArray()
	var defs := Entities.all().filter(func(d): return d.get("category", "") in ["person", "animal"])
	defs.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	for d in defs:
		var models := PackedStringArray()
		for dir in d.get("models", []):
			models.append_array(Library._list(dir))
		if models.is_empty() and d.has("fallback"):
			models = Library._list(d["fallback"])
		for m in models:
			if not out.has(m):
				out.append(m)
				KINDS.append(d)
	return out


static func kind_of(i: int) -> Dictionary:
	return KINDS[i % MODELS.size()] if MODELS.size() > 0 else {}


## Model indices whose definition matches: spawn ("street", "stall",
## "patrol"), or a type in its chain.
static func models_where(key: String, value) -> Array:
	var out := []
	for i in MODELS.size():
		var d: Dictionary = KINDS[i]
		if (key == "type" and value in d.get("types", [])) or (key != "type" and d.get(key) == value):
			out.append(i)
	return out


## A plain walker for a car's driver seat (definitions with "drives").
static func pick_walker() -> int:
	var walkers := models_where("drives", true)
	return walkers.pick_random() if not walkers.is_empty() else 0


## A model index for a new pedestrian on the street: each street definition
## weighs its `share` (Pedestrian 1, Skater 0.15, Dog 0.08), spread over its
## models.
static func pick() -> int:
	var by_def := {}
	for i in models_where("spawn", "street"):
		var id: String = KINDS[i]["id"]
		if not by_def.has(id):
			by_def[id] = []
		by_def[id].append(i)
	var total := 0.0
	for id in by_def:
		total += float(KINDS[by_def[id][0]].get("share", 0.0))
	var r := randf() * total
	for id in by_def:
		r -= float(KINDS[by_def[id][0]].get("share", 0.0))
		if r <= 0.0:
			return by_def[id].pick_random()
	return pick_walker()


func _build_visual() -> void:
	var path: String = MODELS[model_idx % MODELS.size()]
	var model: Node3D = (load(path) as PackedScene).instantiate()
	add_child(model)
	# the football shirts without the clubs' crests (theirs are trademarks): a
	# "<model>_sem_escudo_basecolor.png" next to the model replaces its colour map
	var plain := path.get_basename() + "_sem_escudo_basecolor.png"
	if ResourceLoader.exists(plain):
		var tex: Texture2D = load(plain)
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			for si in m.mesh.get_surface_count():
				var mat := m.get_active_material(si) as StandardMaterial3D
				if mat:
					mat = mat.duplicate()
					mat.albedo_texture = tex
					m.set_surface_override_material(si, mat)
	if path.begins_with("res://assets/kenney/"):
		# fallback set: stylised mini characters, facing +Z, scaled to adult height
		var h := 0.0
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			h = max(h, (mi as MeshInstance3D).get_aabb().end.y)
		if h > 0.01:
			model.scale = Vector3.ONE * (HEIGHT / h)
		model.rotation.y = PI
	# generated characters are authored at real height, facing -Z: keep as is;
	# their skeleton sits under a stature wrapper that also scales the stride
	for c in model.get_children():
		if c is Node3D and not (c is MeshInstance3D) and not is_equal_approx((c as Node3D).scale.x, 1.0):
			_stature = (c as Node3D).scale.x
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = 110.0      # far pedestrians aren't drawn
		(mi as MeshInstance3D).visibility_range_end_margin = 8.0
	var players := model.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		_anim = players[0]
		for clip in ["idle", "walk", "sprint", "push", "ride", "trot", "run", "idle_selling", "flee", "idle_alert", "aim", "fire"]:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if person.get("gait", "own") == "shared":
			_shared_gait(model, path)
		var first: String = person.get("idle", "ride" if skater else "idle")
		if _anim.has_animation(first):
			_anim.play(first)


## One way of moving for every person: pedestrians, police and vendors all
## share the Mixamo rig (same bone names and rest pose), so each takes the
## same idle, walk and sprint from one model per sex (PEOPLE_GAIT),
## retargeted to its own skeleton path. A model keeps only what its role
## adds: the police aim, fire, reload and hit, the vendors' selling idle,
## and every model its own fall when it dies. The police's own run squatted
## 40 cm a stride (they hopped); vendors' runs were stiff and splayed.
const PEOPLE_GAIT := {"man": "res://assets/common/people/ped_10_student_man_20s.glb",
		"woman": "res://assets/common/people/ped_01_student_woman_20s.glb"}
const GAIT_CLIPS := ["idle", "walk", "sprint"]
static var _gaits := {}
func _shared_gait(model: Node3D, path: String) -> void:
	var skels := model.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty() or skels[0].find_bone("mixamorig_Hips") < 0:
		return                       # not the shared rig
	var skel: Skeleton3D = skels[0]
	_stature = (skel.get_parent() as Node3D).scale.x
	var donor: String = PEOPLE_GAIT["woman" if path.get_file().contains("woman") else "man"]
	var root := _anim.get_node(_anim.root_node)
	var skel_path := str(root.get_path_to(skel))
	var key := donor + "|" + skel_path
	if not _gaits.has(key):
		var src: Node = (load(donor) as PackedScene).instantiate()
		var sap: AnimationPlayer = src.find_children("*", "AnimationPlayer", true, false)[0]
		var clips := {}
		for clip in GAIT_CLIPS:
			var a: Animation = sap.get_animation(clip).duplicate(true)
			for t in a.get_track_count():
				var tp := str(a.track_get_path(t))
				a.track_set_path(t, NodePath(skel_path + tp.substr(tp.find(":"))))
			a.loop_mode = Animation.LOOP_LINEAR
			clips[clip] = a
		src.free()
		_gaits[key] = clips
	var lib := _anim.get_animation_library("")
	var hold: Animation = null
	if police and lib.has_animation("idle_alert"):
		hold = lib.get_animation("idle_alert")
	for clip in _gaits[key]:
		var a: Animation = _gaits[key][clip]
		if hold and clip != "idle":
			a = _with_arms(a, hold, path)
		if lib.has_animation(clip):
			lib.remove_animation(clip)
		lib.add_animation(clip, a)


## The police carry a rifle: on the shared walk and sprint their arms keep the
## ready pose of their own alert idle (its first frame), the rest walks like
## everyone else.
const ARM_BONES := ["Shoulder", "Arm", "Hand"]
static var _armed := {}
func _with_arms(gait: Animation, hold: Animation, path: String) -> Animation:
	var key := "%s|%s" % [path, gait.resource_name if gait.resource_name != "" else str(gait.get_instance_id())]
	if _armed.has(key):
		return _armed[key]
	var a: Animation = gait.duplicate(true)
	for t in range(a.get_track_count() - 1, -1, -1):
		var tp := str(a.track_get_path(t))
		if ARM_BONES.any(func(b): return tp.contains(b)):
			a.remove_track(t)
	for t in hold.get_track_count():
		var tp := str(hold.track_get_path(t))
		if not ARM_BONES.any(func(b): return tp.contains(b)) or hold.track_get_key_count(t) == 0:
			continue
		var n := a.add_track(hold.track_get_type(t))
		a.track_set_path(n, hold.track_get_path(t))
		a.track_insert_key(n, 0.0, hold.track_get_key_value(t, 0))
	_armed[key] = a
	return a


func _standoff() -> float:
	return float(person.get("standoff", 22.0))


func is_alive() -> bool:
	return health > 0


func _process(delta: float) -> void:
	if health <= 0:
		if not _dying:
			_dying = true
			if _anim and _anim.has_animation("die"):
				_anim.play("die", 0.1)
			Sfx.play_at("step", global_position, -6.0, 30.0)
		return
	# speed over ~0.15 s windows: frames and physics/network ticks don't line
	# up, so per-frame distance jitters and the stride would pump
	var moved := global_position - _last_pos
	moved.y = 0
	_last_pos = global_position
	_win_dist += moved.length()
	_win_time += delta
	if _win_time >= 0.15:
		_speed_est = lerp(_speed_est, _win_dist / _win_time, 0.6)
		_win_dist = 0.0
		_win_time = 0.0
	if _anim == null:
		return
	if police:
		_firing = max(0.0, _firing - delta)
		# the legs follow the ground speed first: firing on the move kept the
		# standing fire clip and he glided; the walk clip tops out about 1.8 m/s
		var pclip := "sprint" if _speed_est > 1.8 else ("walk" if _speed_est > 0.4
				else ("fire" if _firing > 0 else ("aim" if is_instance_valid(_foe) else "idle_alert")))
		if _anim.current_animation != pclip:
			_anim.play(pclip, 0.15)
		_anim.speed_scale = clamp(_speed_est / ((ANIM_SPRINT if pclip == "sprint" else ANIM_WALK) * _stature), 0.5, 1.6) \
				if pclip in ["sprint", "walk"] else 1.0
		return
	if vendor and _speed_est <= 0.3:
		# selling at the stall; on the move they walk and run like everyone else
		if _anim.current_animation != "idle_selling":
			_anim.play("idle_selling", 0.25)
		_anim.speed_scale = 1.0
		return
	if dog:
		var dclip := "run" if _speed_est > 3.0 else ("walk" if _speed_est > 0.3 else "idle")
		if _anim.current_animation != dclip:
			_anim.play(dclip, 0.2)
		# the dog pack's clips step at its type's walk and run speeds
		var dstride: float = person.get("speed", {}).get("run" if dclip == "run" else "walk", 1.2)
		_anim.speed_scale = clamp(_speed_est / dstride, 0.5, 1.6) if dclip != "idle" else 1.0
		return
	if skater:
		# push to get going and to keep the speed up; glide on the board when slow
		var sclip := "push" if _speed_est > 0.3 else "ride"
		if _anim.current_animation != sclip:
			_anim.play(sclip, 0.25)
		_anim.speed_scale = clamp(_speed_est / ANIM_PUSH, 0.6, 1.6) if sclip == "push" else 1.0
		return
	var clip := "sprint" if _speed_est > 2.5 else ("walk" if _speed_est > 0.3 else "idle")
	if clip == "sprint" and not _anim.has_animation("sprint"):
		clip = "run"                # the players' and children's packs call it run
	if _anim.current_animation != clip:
		_anim.play(clip, 0.2)
	var stride: float = (ANIM_SPRINT if clip == "sprint" else ANIM_WALK) * _stature
	if person.get("gait", "shared") == "own" and person.has("speed") and not skater and not dog:
		# their own clips step at their type's speeds
		stride = float(person["speed"].get("run" if clip in ["sprint", "run"] else "walk", 1.2)) * _stature
	_anim.speed_scale = clamp(_speed_est / stride, 0.5, 1.8) if clip != "idle" else 1.0


## Level of detail: far from every player (LOD_FAR m) a pedestrian thinks and
## moves at LOD_STEP intervals, covering the same ground in fewer, longer steps.
const LOD_FAR := 50.0
const LOD_STEP := 0.1
var _lod_t := 0.0
var _lod_check := 0.0
var _far := false
var _step_scale := 1.0     # this tick stands for this many physics frames
## Asleep: further than SLEEP_M from every player and SLEEP_ROBOT_M from every
## robot, a passer-by stops being simulated at all (no AI, no physics, its
## animation stopped) - about half the physics of a round went on people no
## one could see. When someone comes near it wakes where its walk would
## have taken it meanwhile: the same people stay in the same streets, and
## the robots still find them (they wake before a robot gets to them).
const SLEEP_M := 150.0
const SLEEP_ROBOT_M := 40.0
var asleep := false
var _slept := 0.0


func _physics_process(delta: float) -> void:
	if health <= 0:
		return
	if global_position.y < -5:
		queue_free()
		return
	_lod_check -= delta
	if _lod_check <= 0:
		_lod_check = 0.5 + randf() * 0.2
		_far = state != State.FLEE and not police
		var near_pl := INF
		for pl in get_tree().get_nodes_in_group("players"):
			near_pl = minf(near_pl, (pl as Node3D).global_position.distance_to(global_position))
		if near_pl < LOD_FAR:
			_far = false
		_update_sleep(near_pl)
	if asleep:
		_slept += delta
		return
	_lod_t += delta
	if _far and _lod_t < LOD_STEP:
		return
	_step_scale = _lod_t / delta
	delta = _lod_t
	_lod_t = 0.0
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	_scan_cd -= delta
	if police:
		if _police_tick(delta):
			return
	elif _scan_cd <= 0:
		_scan_cd = 0.3
		var threat := _nearest_threat()
		if threat != Vector3.INF:
			_flee_from(threat)
	var speed: float = person.get("speed", {}).get("walk", 1.2)
	if state == State.FLEE:
		speed = person.get("speed", {}).get("run", 4.0)
		_calm -= delta
		if _calm <= 0:
			state = State.WANDER
			_goal = Vector3.INF
	if state == State.WANDER and is_instance_valid(_boarding):
		# to the bus's rear door; there they get on
		var door: Vector3 = _boarding.to_global(Vector3(_boarding._box.size.x / 2 + 0.4, 0, _boarding._box.size.z * 0.25))
		var flat := Vector2(global_position.x - door.x, global_position.z - door.z).length()
		if flat < 3.0 or _boarding.get("_dwell") <= 0.0:
			if flat < 3.0 and multiplayer.is_server():
				queue_free()               # on board
			_boarding = null               # missed it: back to the stop for the next one
		elif Vector2(_goal.x - door.x, _goal.z - door.z).length() > 0.5:
			_goal = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, door)
			agent.target_position = _goal
	elif waiting_at != Vector3.INF and state == State.WANDER:
		# waiting at the stop: stand by the shelter
		if global_position.distance_to(waiting_at) > 1.2:
			if _goal != waiting_at:
				_goal = waiting_at
				agent.target_position = waiting_at
		else:
			velocity.x = 0
			velocity.z = 0
			move_and_slide()
			return
	if not vendor and home != Vector3.INF and state == State.WANDER and float(person.get("roam", 0.0)) > 0.0:
		# a footballer on its pitch, a child at the playground: wander about the spot
		if _goal == Vector3.INF or global_position.distance_to(_goal) < 1.2 or global_position.distance_to(home) > float(person["roam"]) * 2.0:
			_pause -= delta
			if _pause <= 0.0:
				var r := float(person["roam"])
				_goal = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map,
						home + Vector3(randf_range(-r, r), 0, randf_range(-r, r)))
				agent.target_position = _goal
				_pause = randf_range(1.0, 4.0)
			else:
				velocity.x = 0
				velocity.z = 0
				move_and_slide()
				return
	if vendor and state == State.WANDER and home != Vector3.INF:
		# back to the stall, then stand behind the counter facing the customers
		if global_position.distance_to(home) > 1.0:
			if _goal != home:
				_goal = home
				agent.target_position = home
		else:
			velocity.x = 0
			velocity.z = 0
			rotation.y = lerp_angle(rotation.y, home_yaw, min(1.0, delta * 4.0))
			move_and_slide()
			return
	# arrived - or the path ended short of an unreachable goal (against a wall)
	# walking in a group: keep to the leader's side, stop when it stops
	if state == State.WANDER and is_instance_valid(leader) and leader.state == State.WANDER:
		_follow_cd -= delta
		if _follow_cd <= 0:
			_follow_cd = 0.5
			var spot: Vector3 = leader.global_position + leader.global_transform.basis * group_offset
			if spot.distance_to(global_position) > 1.2:
				_goal = spot
				agent.target_position = spot
				_pause = 0.0
			else:
				_goal = Vector3.INF
				_pause = 1.0
				rotation.y = lerp_angle(rotation.y, leader.rotation.y, 0.3)
	var arrived := _goal == Vector3.INF or agent.is_navigation_finished() \
			or global_position.distance_to(_goal) < 1.5
	if state == State.WANDER and arrived and not _route.is_empty():
		_goal = _route.pop_front()          # next leg: over the zebra, then on
		agent.target_position = _goal
	elif state == State.WANDER and arrived:
		_pause -= delta
		if _pause > 0:
			velocity.x = 0
			velocity.z = 0
			move_and_slide()
			return
		_pick_goal(30.0)
	elif state == State.FLEE and arrived:
		# keep running: next goal further away from the threat (any direction if cornered)
		_ask_cd -= delta
		if _ask_cd <= 0:
			var away := global_position - _threat
			away.y = 0
			_pick_goal(28.0, global_position, away.normalized() if randf() < 0.7 else Vector3.ZERO)
	var next := agent.get_next_path_position()
	var move := next - global_position
	move.y = 0
	move = move.normalized() * speed if move.length() > 0.05 else Vector3.ZERO
	if _detour_left > 0:
		_detour_left -= delta
		move = _detour * speed
	velocity.x = move.x
	velocity.z = move.z
	var before := global_position
	Step.try_step(self, Vector3(velocity.x, 0, velocity.z) * get_physics_process_delta_time() * 3.0)
	if _step_scale > 1.01:
		# a far LOD tick: one move covering the skipped frames
		velocity.x *= _step_scale
		velocity.z *= _step_scale
		move_and_slide()
		velocity.x /= _step_scale
		velocity.z /= _step_scale
	else:
		move_and_slide()
	# unstick: pushing into something without progress -> sidestep and re-path
	var progressed := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	if move.length() > 0.1 and progressed < speed * delta * 0.25:
		_stuck += delta
		_free_t = 0.0
		if _stuck > 0.6:
			_stuck = 0.0
			_unsticks += 1
			var side := Vector3(-move.z, 0, move.x).normalized() * (1.0 if randf() < 0.5 else -1.0)
			_detour = (side - move.normalized() * 0.4).normalized()
			_detour_left = 0.5
			if _unsticks >= 5:
				# wedged (in a corner, against a wall): back onto the walkable mesh
				var map := get_world_3d().navigation_map
				var on_mesh := NavigationServer3D.map_get_closest_point(map, global_position)
				global_position = Vector3(on_mesh.x, max(global_position.y, on_mesh.y + 0.1), on_mesh.z)
				_unsticks = 0
			if _unsticks >= 3:
				# the same goal keeps leading into it: go somewhere else
				_pick_goal(20.0, global_position, -move.normalized())
			else:
				agent.target_position = _goal if _goal != Vector3.INF else global_position
	else:
		_stuck = 0.0
		_free_t += delta
		if _free_t > 4.0:
			_free_t = 0.0
			_unsticks = 0
	if move.length() > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(-move.x, -move.z), min(1.0, delta * 8.0))


## Walking (not fleeing) across a street: go over the nearest zebra crossing
## instead of straight through the traffic. _route holds the remaining
## waypoints (near kerb, far kerb) before the real goal.
var _route: Array = []
func _via_crossing(goal: Vector3) -> void:
	_route = []
	if dog or police or state == State.FLEE:
		return
	var main := get_tree().current_scene
	var graph: Dictionary = main.road_graph
	var zebras: Array = graph.get("crossings", [])
	if zebras.is_empty():
		return
	var a := Vector2(global_position.x, global_position.z)
	var b := Vector2(goal.x, goal.z)
	var hit := Vector2.INF
	for e in graph.get("edges", []):
		var pts: Array = e.get("pts", [])
		for k in range(1, pts.size()):
			var q = Geometry2D.segment_intersects_segment(a, b, Vector2(pts[k - 1][0], pts[k - 1][1]), Vector2(pts[k][0], pts[k][1]))
			if q != null and (hit == Vector2.INF or a.distance_to(q) < a.distance_to(hit)):
				hit = q
	if hit == Vector2.INF:
		return                               # same side of every street
	var best: Array = []
	var bd := 70.0
	for z in zebras:
		var d := hit.distance_to(Vector2(z[0], z[1]))
		if d < bd:
			bd = d
			best = z
	if best.is_empty() or bd < 5.0:
		return                               # crossing right at a zebra anyway
	var c := Vector2(best[0], best[1])
	var across := Vector2(best[2], best[3])
	# kerb on our side first, then the far one
	var s := signf((a - c).dot(across))
	var map := get_world_3d().navigation_map
	for p in [c + across * 6.0 * s, c - across * 6.0 * s]:
		_route.append(NavigationServer3D.map_get_closest_point(map, Vector3(p.x, global_position.y, p.y)))
	_route.append(goal)
	_goal = _route.pop_front()
	agent.target_position = _goal


## Path searches over the city's navmesh are costly: at most PATHS_PER_TICK of
## them a physics tick for everyone together (a gunfight sent dozens of people
## planning their escape in the same frame). Who is left over tries next tick.
const PATHS_PER_TICK := 1
static var _budget_tick := -1
static var _budget_left := 0
static func _path_budget() -> bool:
	var t := Engine.get_physics_frames()
	if t != _budget_tick:
		_budget_tick = t
		_budget_left = PATHS_PER_TICK
	if _budget_left <= 0:
		return false
	_budget_left -= 1
	return true


func _pick_goal(radius: float, from := Vector3.INF, away := Vector3.ZERO) -> void:
	if not _path_budget():
		if state == State.WANDER:
			_pause = randf_range(0.05, 0.3)      # a stroll can wait a moment
		else:
			_ask_cd = randf_range(0.05, 0.2)     # fleeing: asks again very soon
		return
	var map := get_world_3d().navigation_map
	var base := global_position if from == Vector3.INF else from
	var crowd: Array = get_tree().current_scene.crowd
	# a goal is taken when the agent's own path reaches it: one path search per
	# try (the agent keeps it to walk), not a test search and then the real one.
	# Paths over the city's navmesh are costly: few tries, near goals first
	if away == Vector3.ZERO and not crowd.is_empty() and randf() < 0.35:
		# strolling: often towards a promenade nearby
		for k in 6:
			var c: Vector3 = crowd.pick_random()
			if c.distance_to(base) < radius * 2.5 and c.distance_to(global_position) > 6.0:
				var cp := NavigationServer3D.map_get_closest_point(map, c)
				if _reaches(cp):
					_pause = randf_range(1.0, 5.0)
					_via_crossing(cp)
					return
				break                          # one path search for a promenade, then a plain stroll
	for attempt in PICK_TRIES:
		# the preferred direction first; if that is blocked (cornered), anywhere
		var dir := away if away != Vector3.ZERO and attempt < PICK_TRIES / 2 else Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		dir = dir.rotated(Vector3.UP, randf_range(-0.6, 0.6))
		var pos := NavigationServer3D.map_get_closest_point(map, base + dir * randf_range(radius * 0.5, radius))
		if not get_tree().current_scene.in_bounds(pos, 10.0) or pos.distance_to(global_position) < radius * 0.3:
			continue    # off the map, or snapped back next to us (a wall in the way)
		if _reaches(pos):
			_pause = randf_range(1.0, 5.0)
			if away == Vector3.ZERO:
				_via_crossing(pos)
			return
	# nothing reachable this time: keep the goal it had and wait a little
	# before trying again (without the wait a cornered one searched every tick)
	agent.target_position = _goal if _goal != Vector3.INF else global_position
	_pause = randf_range(2.0, 5.0)
	# fleeing too: a cornered one asked every tick, and the one search a tick
	# goes to whoever asks first in the tree - two cornered runners left the
	# people after them with no goal at all (a group standing still)
	_ask_cd = randf_range(0.6, 1.2)


const PICK_TRIES := 3
## Walk to `pos` if the agent's path gets there (its one search), else not.
func _reaches(pos: Vector3) -> bool:
	agent.target_position = pos
	if agent.get_final_position().distance_to(pos) < 1.0:
		_goal = pos
		return true
	return false


func _nearest_threat() -> Vector3:
	var best := Vector3.INF
	var bd := THREAT_RADIUS
	for e in get_tree().get_nodes_in_group("robots"):
		if not e.is_alive():
			continue
		var d: float = e.global_position.distance_to(global_position)
		if d < bd:
			var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.5, 0),
					e.global_position + Vector3(0, 1.5, 0), 1)
			if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
				bd = d
				best = e.global_position
	return best


func _flee_from(threat: Vector3) -> void:
	_threat = threat
	_route = []                              # running for it: straight across
	var away := global_position - threat
	away.y = 0
	if state != State.FLEE or _calm < CALM_SECONDS - 1.5:
		_pick_goal(28.0, global_position, away.normalized())
	state = State.FLEE
	_calm = CALM_SECONDS


## Honked at: step off the carriageway, sideways from the car, onto the
## pavement (the nearest walkable point 5 m to that side), then carry on.
## Server: the bus pulled up at their stop.
func board(bus: Node3D) -> void:
	_boarding = bus


func step_aside(dir: Vector3) -> void:
	if health <= 0 or vendor or state == State.FLEE:
		return
	var want := global_position + dir.normalized() * 5.0
	_goal = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, want)
	agent.target_position = _goal
	_pause = 0.0
	_detour_left = 0.0


## Gunshots and robot fire: run away from where the noise came from (police
## officers go and look instead).
var _heard_ms := -100000
func heard(where: Vector3) -> void:
	if health <= 0 or global_position.distance_to(where) >= HEAR_RADIUS:
		return
	if police:
		# towards the shots - once a second, not at every shot (each is a path search)
		var now := Time.get_ticks_msec()
		if not is_instance_valid(_foe) and now - _heard_ms > 1000 and _path_budget():
			_heard_ms = now
			_goal = NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, where)
			agent.target_position = _goal
			_pause = 0.0
		return
	_flee_from(where)


## Server, police: pick the nearest robot in sight within range; close in to
## a stand-off distance and shoot. Returns true when it handled this tick
## (standing and firing).
## Carried off in a URB-C4 Coletor's capsule: out of sight and still until
## it is brought down (released) or gets away with them.
var _captor: Node3D
func captured(by: Node3D) -> void:
	_captor = by
	visible = false
	collision_layer = 0
	set_physics_process(false)


func released(at: Vector3) -> void:
	_captor = null
	global_position = at + Vector3(randf_range(-1, 1), 0.3, randf_range(-1, 1))
	visible = true
	collision_layer = 32
	set_physics_process(multiplayer.is_server())
	_flee_from(at + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)))


var _closing := false
func _police_tick(delta: float) -> bool:
	_grudge_left -= delta
	if _grudge_left <= 0 or not is_instance_valid(_grudge) or _grudge.dead:
		_grudge = null
	if _scan_cd <= 0:
		_scan_cd = 0.4
		_foe = null
		var best := Tune.police_range_m
		var foes := get_tree().get_nodes_in_group("robots")
		if _grudge:
			foes = [_grudge]            # whoever shot it comes first
			best = Tune.police_range_m * 1.5
		for e in foes:
			if not _alive(e):
				continue
			var d: float = e.global_position.distance_to(global_position)
			if d < best:
				var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.5, 0),
						e.global_position + Vector3(0, 1.2, 0), 1 | 16)     # no shooting through cars
				if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
					best = d
					_foe = e
	if not is_instance_valid(_foe) or not _alive(_foe):
		_foe = null
		if state == State.FLEE and _calm <= 0.0:
			state = State.WANDER          # fight over: back on patrol
			_goal = Vector3.INF
		return false
	var to := _foe.global_position - global_position
	to.y = 0
	# close in until well inside the standoff, only run again once the robot
	# is clearly out of it (no flicker between running and firing at its edge)
	var dist := to.length()
	if _closing and dist < _standoff() - 2.0:
		_closing = false
	elif not _closing and dist > _standoff() + 4.0:
		_closing = true
	if _closing:
		var want := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, _foe.global_position)
		if _goal == Vector3.INF or _goal.distance_to(want) > 2.0:
			_goal = want                  # re-path only when the robot has really moved
			agent.target_position = _goal
		state = State.FLEE              # FLEE = moving at a run; the target is the robot
		_calm = 2.0
		return false
	# in range: stand, face and fire
	velocity.x = 0
	velocity.z = 0
	rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), min(1.0, delta * 8.0))
	move_and_slide()
	_shot_cd -= delta
	if _shot_cd <= 0:
		_shot_cd = randf_range(0.9, 1.4)
		var hit: bool = randf() < clamp(0.85 - to.length() / 50.0, 0.3, 0.7)
		var aim := _foe.global_position + Vector3(0, 1.2, 0)
		if not hit:
			aim += Vector3(randf_range(-1.2, 1.2), randf_range(-0.4, 0.8), randf_range(-1.2, 1.2))
		police_shot.rpc(aim)
		if hit and _foe.is_in_group("players"):
			_foe.hurt.rpc_id(_foe.get_multiplayer_authority(), int(Tune.police_damage), global_position)
		elif hit:
			_foe.apply_damage(int(Tune.police_damage), self)
		for e in get_tree().get_nodes_in_group("robots"):
			e.heard(global_position)
	return true


func _alive(n: Node) -> bool:
	return not n.dead if n.is_in_group("players") else n.is_alive()


## Every peer: an officer's rifle shot.
@rpc("authority", "call_local", "unreliable")
func police_shot(to: Vector3) -> void:
	_firing = 0.35
	var from := global_position + Vector3(0, 1.35, 0) - global_transform.basis.z * 0.6
	Sfx.play_at("machinegun", from, -6.0, 80.0)
	get_tree().call_group("pigeons", "scare", global_position)
	var tracer := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.012
	cyl.bottom_radius = 0.012
	cyl.height = from.distance_to(to)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.5)
	cyl.material = mat
	tracer.mesh = cyl
	get_tree().current_scene.add_child(tracer)
	var dir := (to - from).normalized()
	tracer.global_position = (from + to) / 2
	tracer.look_at(to, Vector3.UP if abs(dir.y) < 0.99 else Vector3.RIGHT)
	tracer.rotate_object_local(Vector3.RIGHT, PI / 2)
	get_tree().create_timer(0.06).timeout.connect(tracer.queue_free)


func apply_damage(amount: int, attacker: Node3D = null) -> void:
	if person.get("invulnerable", false):
		return                     # children: nobody gets hurt at the playground
	if not multiplayer.is_server() or health <= 0:
		return
	health -= amount
	if health <= 0 and attacker and attacker.is_in_group("robots"):
		killed_by_robot = true
	if health <= 0 and attacker and attacker.is_in_group("players"):
		killed_by_player = true
		killer_peer = attacker.get_multiplayer_authority()
	if police and attacker and attacker.is_in_group("players"):
		_grudge = attacker              # shot by a player: shoot back for a while
		_grudge_left = 20.0
		_scan_cd = 0.0
		if health > 0:
			return
	if health <= 0:
		health = 0
		collision_layer = 0
		velocity = Vector3.ZERO
		died.emit(self)
		get_tree().create_timer(CORPSE_SECONDS).timeout.connect(queue_free)
	else:
		_flee_from(global_position + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)))


func _update_sleep(near_player: float) -> void:
	var can := near_player > SLEEP_M and state == State.WANDER and not police \
			and not is_instance_valid(_boarding) and multiplayer.is_server()
	if can:
		for r in get_tree().get_nodes_in_group("robots"):
			if (r as Node3D).global_position.distance_to(global_position) < SLEEP_ROBOT_M:
				can = false
				break
	if can == asleep:
		return
	asleep = can
	if asleep:
		_slept = 0.0
		velocity = Vector3.ZERO
		if _anim:
			_anim.active = false
		return
	if _anim:
		_anim.active = true
	_walk_on(_slept)


## Waking: on along the path it was walking, as far as it would have got.
func _walk_on(seconds: float) -> void:
	if _goal == Vector3.INF or waiting_at != Vector3.INF or vendor:
		return
	var left: float = person.get("speed", {}).get("walk", 1.2) * seconds
	var path := agent.get_current_navigation_path()
	var p := global_position
	for i in range(agent.get_current_navigation_path_index(), path.size()):
		var seg: Vector3 = path[i] - p
		if seg.length() >= left:
			p += seg.normalized() * left
			left = 0.0
			break
		p = path[i]
		left -= seg.length()
	global_position = p + Vector3(0, 0.1, 0)
	if left > 0.0:
		_goal = Vector3.INF                  # it got there: a new stroll from here
	else:
		agent.target_position = _goal
