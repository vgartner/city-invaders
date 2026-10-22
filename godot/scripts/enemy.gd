extends CharacterBody3D
## Hostile robot (URB-07). Simulated on the server only (navmesh pathing,
## shooting); clients receive position/rotation/health through a
## MultiplayerSynchronizer and drive the animations locally from them.

signal died(enemy)

const Step := preload("res://scripts/step.gd")
const Wreck := preload("res://scripts/wreck.gd")
const VIEW_CONE_DEG := 120.0
const NEAR_SENSE := 5.0         # noticed from any direction this close
const LOSE_SECONDS := 4.0       # out of sight this long -> search
const SEARCH_SECONDS := 6.0
const ALERT_RADIUS := 20.0
const HEARING_RADIUS := 25.0

enum State { PATROL, CHASE, SEARCH, HUNT }
const CIVILIAN_RANGE := 30.0
const CIVILIAN_DAMAGE := 9       # 5 hits for a civilian (health 45)
const FIRE_INTERVAL := 1.6
const CORPSE_SECONDS := 4.0
## muzzle of the forearm rifle (model faces -Z, rifle on its right = +X)
const DROP_SPEED := 6.0        # m/s down a dropship beam
const BOLT_LENGTH := 1.4
const BOLT_SPEED := 70.0       # m/s: visible in flight, not instant

@export var health := 60
var kind := "trooper"
var target: Node3D
var agent: NavigationAgent3D
var _fire_cd := 0.0
var _repath_cd := 0.0
var _last_health := 60
var _anim: AnimationPlayer
var _overlay: StandardMaterial3D
var _flash_meshes: Array = []     # the overlay is on them only while the hit flash shows (an extra pass each)
var _flash_on := false
var _last_pos := Vector3.ZERO
var _speed_est := 0.0
var _one_shot_left := 0.0
var _dying := false
var _step_cd := 0.0
var state := State.PATROL
var _seen: Node3D
var _last_known := Vector3.ZERO
var _lost_time := 0.0
var _search_left := 0.0
var _patrol_goal := Vector3.INF
var _pause_left := 0.0
var _perceive_cd := 0.0
var _vandal_cd := 6.0
var _vandal_shots := 0
var _face_point := Vector3.INF
var _wants_to_move := false
var _prey: Node3D
var _retarget_cd := 1.0
var _stuck_time := 0.0
var _detour := Vector3.ZERO
var _detour_left := 0.0
var _unsticks := 0              # sidesteps in a row at about the same spot
var _unstick_at := Vector3.INF
var killed_by_player := false
var killer_peer := 0            # the player who destroyed it (score)   # robots the police take down don't count for the goal
var dropping := false          # server: being lowered from a dropship, no AI until it lands
## "trooper" (URB-07) or "mech" (URB-H9 heavy assault mech: dropship only,
## slow, very tough, hits twice as hard); set before the node enters the tree
var variant := "trooper"
## the final phase's robot commander: a mech that guards the relay antenna's
## building - tougher, larger, red, never wandering far from its post
var commander := false
var post := Vector3.INF
const COMMANDER_HEALTH := 900     # (easy; difficulty.gd commander_hp)
const Difficulty := preload("res://scripts/difficulty.gd")
const Rubble := preload("res://scripts/rubble.gd")
const VARIANTS := {
	"trooper": {"model": "res://assets/common/enemies/robot/robot.glb", "health": 60, "walk": 1.4, "chase": 3.2,
			"damage": 7, "radius": 0.45, "height": 2.0, "muzzle": Vector3(0.55, 1.2, -0.55),
			"clips": {"idle": "idle", "walk": "walk", "run": "run", "shoot": "shoot", "hit": "hit", "death": "death"},
			"walk_speed": 1.17, "run_speed": 3.46},
	# URB-C4 Coletor: no gun - it snatches a civilian and runs for the map's edge
	"collector": {"model": "res://assets/common/enemies/coletor/urb_c4_coletor.glb", "health": 150, "walk": 1.0, "chase": 4.6,
			"damage": 0, "radius": 0.55, "height": 2.4, "muzzle": Vector3(0, 1.4, -0.5),
			"clips": {"idle": "idle", "walk": "walk", "run": "run", "shoot": "idle", "hit": "hit", "death": "die"},
			"walk_speed": 1.0, "run_speed": 2.8},
	"mech": {"model": "res://assets/common/enemies/mech/mech.glb", "health": 360, "walk": 1.2, "chase": 1.8,
			"damage": 14, "radius": 1.1, "height": 4.2, "muzzle": Vector3(1.3, 2.7, -1.2),
			"clips": {"idle": "idle", "walk": "walk", "run": "walk", "shoot": "fire_left", "hit": "hit", "death": "die"},
			"walk_speed": 1.5, "run_speed": 1.5},
}
var _v: Dictionary


func _ready() -> void:
	_v = VARIANTS.get(variant, VARIANTS["trooper"]).duplicate(true)
	# toughness and firepower by difficulty
	_v["health"] = Difficulty.get_value("mech_hp" if variant == "mech" else "trooper_hp")
	if variant == "collector":
		_v["health"] = int(_v["health"] * 1.5)
	_v["damage"] = Difficulty.get_value("mech_dmg" if variant == "mech" else "trooper_dmg")
	health = Difficulty.get_value("commander_hp") if commander else _v["health"]
	_last_health = health
	add_to_group("robots")
	collision_layer = 2
	collision_mask = 1 | 2 | 16
	floor_max_angle = deg_to_rad(55)       # step over curbs (see player.gd)
	floor_snap_length = 0.3
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = _v["radius"]
	cap.height = _v["height"]
	cs.shape = cap
	cs.position.y = _v["height"] / 2.0
	add_child(cs)
	_build_visual()

	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:position"))
	cfg.add_property(NodePath(".:rotation"))
	cfg.add_property(NodePath(".:health"))
	sync.replication_config = cfg
	add_child(sync)

	agent = NavigationAgent3D.new()
	agent.path_desired_distance = 1.0
	agent.target_desired_distance = 2.0
	agent.radius = max(0.5, _v["radius"])
	add_child(agent)
	_last_pos = global_position
	set_physics_process(multiplayer.is_server())


func _build_visual() -> void:
	# hit flash: additive overlay on the whole model
	_overlay = StandardMaterial3D.new()
	_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay.albedo_color = Color(1, 0.6, 0.2, 0.0)
	if ResourceLoader.exists(_v["model"]):
		var model: Node3D = (load(_v["model"]) as PackedScene).instantiate()
		model.name = "Model"
		add_child(model)
		if commander:
			# the commander: a size up, a red command light on its back
			model.scale *= 1.3
			var lamp := OmniLight3D.new()
			lamp.light_color = Color(1, 0.12, 0.08)
			lamp.light_energy = 4.0
			lamp.omni_range = 9.0
			lamp.position = Vector3(0, _v["height"] * 1.35, 0.6)
			add_child(lamp)
		_flash_meshes = model.find_children("*", "MeshInstance3D", true, false)
		var players := model.find_children("*", "AnimationPlayer", true, false)
		if players.size() > 0:
			_anim = players[0]
			for clip in ["idle", "walk", "run"]:
				clip = _v["clips"][clip]
				if _anim.has_animation(clip):
					_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
			_play("idle")
		return
	# fallback when the asset is missing: plain capsule
	var body := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.4
	m.height = 1.9
	body.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.12, 0.1)
	body.material_override = mat
	_flash_meshes = [body]
	body.position.y = 0.95
	add_child(body)


func _set_flash(on: bool) -> void:
	_flash_on = on
	for mi in _flash_meshes:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = _overlay if on else null


func _play(clip: String, blend := 0.2, speed := 1.0) -> void:
	clip = _v["clips"].get(clip, clip)
	if clip == "fire_left" and randf() < 0.5:
		clip = "fire_right"            # the mech alternates its arm cannons
	if _anim == null or not _anim.has_animation(clip):
		return
	if _anim.current_animation == clip and _anim.is_playing():
		_anim.speed_scale = speed
		return
	_anim.play(clip, blend)
	_anim.speed_scale = speed


func _process(delta: float) -> void:
	# every peer animates from the replicated state
	if health < _last_health:
		_overlay.albedo_color.a = 0.7
		_set_flash(true)
		Sfx.play_at("robot_hit" if health > 0 else "robot_death", global_position + Vector3(0, 1.2, 0),
				-4.0 if health > 0 else 2.0)
		if health > 0 and _one_shot_left <= 0:
			_play("hit", 0.05)
			_one_shot_left = 0.5
	_last_health = health
	if _flash_on:
		_overlay.albedo_color.a = max(0.0, _overlay.albedo_color.a - delta * 3.0)
		if _overlay.albedo_color.a <= 0.0:
			_set_flash(false)
	if health <= 0:
		if not _dying:
			_dying = true
			if variant == "mech":
				_topple()
			else:
				_play("death", 0.1)
				get_tree().create_timer(0.35).timeout.connect(_break_apart.bind(1.0))
		return
	var moved := global_position - _last_pos
	moved.y = 0
	_speed_est = lerp(_speed_est, moved.length() / max(delta, 1e-4), 0.2)
	_last_pos = global_position
	_one_shot_left -= delta
	if _one_shot_left > 0:
		return
	if _speed_est > 0.3:
		_step_cd -= delta
		if _step_cd <= 0:
			_step_cd = 0.32 if _speed_est > 2.2 else 0.6
			Sfx.play_at("robot_step", global_position, -10.0, 40.0)
	# clip ground speeds measured with tools/assets/anim_speed.py (trooper walk 1.17, run 3.46 m/s)
	if _speed_est > 2.2:
		_play("run", 0.2, _speed_est / _v["run_speed"])
	elif _speed_est > 0.3:
		_play("walk", 0.2, _speed_est / _v["walk_speed"])
	else:
		_play("idle", 0.3)


const LOD_FAR := 110.0
const LOD_STEP := 0.1
var _lod_t := 0.0
var _lod_check := 0.0
var _far := false
var _step_scale := 1.0


func _physics_process(delta: float) -> void:
	if health <= 0:
		return
	if global_position.y < -5.0:     # fell out of the world: drop it, the director sends another
		queue_free()
		return
	if dropping:
		# steady descent down the dropship's beam, then a heavy landing
		velocity = Vector3(0, -DROP_SPEED, 0)
		move_and_slide()
		if is_on_floor():
			dropping = false
			velocity = Vector3.ZERO
			landed.rpc()
		return
	# level of detail: patrolling far from every player, it thinks and moves
	# in LOD_STEP steps (the same ground covered, a fraction of the cost)
	_lod_check -= delta
	if _lod_check <= 0:
		_lod_check = 0.5 + randf() * 0.2
		_far = state == State.PATROL
		for pl in get_tree().get_nodes_in_group("players"):
			if (pl as Node3D).global_position.distance_to(global_position) < LOD_FAR:
				_far = false
				break
	_lod_t += delta
	if _far and _lod_t < LOD_STEP and is_on_floor():
		return
	_step_scale = _lod_t / delta
	delta = _lod_t
	_lod_t = 0.0
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	if _lasso_left > 0.0:
		_lasso_left -= delta
		if variant != "mech":
			# roped: it stands there struggling, no walking, no shooting
			velocity.x = 0
			velocity.z = 0
			move_and_slide()
			return
	_think(delta)
	var move := Vector3.ZERO
	var speed: float = _v["walk"] if state == State.PATROL else _v["chase"]
	if _lasso_left > 0.0:
		speed *= 0.35                    # a mech drags the laço along, slowly
	if _wants_to_move:
		var next := agent.get_next_path_position()
		move = next - global_position
		move.y = 0
		# next point is where it stands (path done): don't jitter on the spot
		move = move.normalized() * speed if move.length() > 0.05 else Vector3.ZERO
	if _detour_left > 0:
		_detour_left -= delta
		move = _detour * speed
	velocity.x = move.x
	velocity.z = move.z
	var before := global_position
	Step.try_step(self, Vector3(velocity.x, 0, velocity.z) * get_physics_process_delta_time() * 3.0)
	if _step_scale > 1.01:
		velocity.x *= _step_scale
		velocity.z *= _step_scale
		move_and_slide()
		velocity.x /= _step_scale
		velocity.z /= _step_scale
	else:
		move_and_slide()
	# unstick: blocked while it should be walking -> sidestep for a moment
	var progressed := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	if _wants_to_move and progressed < speed * delta * 0.2:
		_stuck_time += delta
		if _stuck_time > 0.8:
			_stuck_time = 0.0
			# a parked car or truck in the way (the navmesh doesn't know vehicles):
			# a robot just shoves it aside
			for i in get_slide_collision_count():
				var other := get_slide_collision(i).get_collider()
				if other and other.has_method("shove") and other.get("driver_peer") == 0:
					other.shove(move.normalized() * 3.0)
			var side := Vector3(-move.z, 0, move.x).normalized() * (1 if randf() < 0.5 else -1)
			_detour = (side - move.normalized() * 0.5).normalized()
			_detour_left = 0.6
			_repath_cd = 0.0
			_unsticks = _unsticks + 1 if _unstick_at != Vector3.INF and _unstick_at.distance_to(global_position) < 3.0 else 1
			_unstick_at = global_position
			if state == State.PATROL:
				_pick_patrol_goal()
			elif _unsticks >= 3:
				# the same squeeze again and again (a gap between a wall, a tree and
				# a truck): a searching robot gives up that spot, a chasing one goes
				# well round before it tries the path again
				_unsticks = 0
				if state == State.SEARCH:
					state = State.PATROL
					_pick_patrol_goal()
				else:
					_detour_left = 1.6
	else:
		_stuck_time = 0.0
	# face what matters: the target when engaging, else the walking direction
	var face := Vector3.ZERO
	if _face_point != Vector3.INF:
		face = _face_point - global_position
	elif move.length() > 0.1:
		face = move
	face.y = 0
	if face.length() > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(-face.x, -face.z), min(1.0, delta * 8.0))


## URB-C4 Coletor (server): find a civilian on their own, grab them (1.5 s),
## and carry them to an open spot where a transport ship takes them up its
## beam to a people container (main.transport_meet); with no container on
## the map it runs for the nearest map edge instead (they are lost there).
## Brought down, it drops them alive. The captive shows in its capsule.
var _captive: Node3D
var _to_edge := false
var _grab_left := 0.0
var _escape := Vector3.INF
signal escaped(collector)
signal rescued(collector, by)


func has_captive() -> bool:
	return is_instance_valid(_captive)


## Server: the transport's beam takes the captive (their model index goes
## with the ship); the Coletor goes hunting again.
func hand_over() -> int:
	var idx: int = _captive.model_idx
	_captive.queue_free()
	_captive = null
	hide_captive.rpc()
	_v["clips"]["run"] = "run"
	return idx


## Every peer: the captive, standing in the glass capsule on its back (the
## model's capsule_slot; a little smaller than life to fit) as a plain grey
## figure - anyone taken looks the same in there.
const CAPTIVE_SCALE := 0.8
const Captive := preload("res://scripts/people_container.gd")
var _capsule_figure: Node3D
@rpc("authority", "call_local", "reliable")
func show_captive(model_idx: int) -> void:
	hide_captive()
	var models: PackedStringArray = preload("res://scripts/civilian.gd").MODELS
	if models.is_empty():
		return
	var fig: Node3D = (load(models[model_idx % models.size()]) as PackedScene).instantiate()
	var slot := find_child("capsule_slot", true, false) as Node3D
	if slot:
		slot.add_child(fig)
		fig.scale = Vector3.ONE * CAPTIVE_SCALE / slot.global_transform.basis.get_scale().x
	else:
		add_child(fig)
		fig.position = Vector3(0, 0.6, 0.5)
		fig.scale = Vector3.ONE * CAPTIVE_SCALE
	_capsule_figure = fig
	Captive.grey(fig)
	var ap: Array = fig.find_children("*", "AnimationPlayer", true, false)
	if not ap.is_empty():
		var anim: AnimationPlayer = ap[0]
		for clip in ["idle", "idle_alert", "idle_selling"]:
			if anim.has_animation(clip):
				anim.play(clip)
				break


@rpc("authority", "call_local", "reliable")
func hide_captive() -> void:
	if is_instance_valid(_capsule_figure):
		_capsule_figure.queue_free()
	_capsule_figure = null


func _collect_think(delta: float) -> void:
	_face_point = Vector3.INF
	if _grab_left > 0.0:
		_grab_left -= delta              # stowing them in the capsule
		_wants_to_move = false
		return
	if is_instance_valid(_captive):
		state = State.CHASE                 # at a run, with the capsule full
		var left := Vector2(global_position.x - _escape.x, global_position.z - _escape.z).length()
		if not _to_edge:
			if left < 3.0:
				_wants_to_move = false      # waiting under the transport
				_play("idle", 0.3)
			else:
				_go_to(_escape, true)
			return
		_go_to(_escape, true)
		if left < 4.0:
			escaped.emit(self)
			_captive.queue_free()
			_captive = null
			health = 0
			collision_layer = 0
			queue_free()
		return
	_perceive_cd -= delta
	# Drop dead/freed prey immediately, but an empty result still waits for
	# the next search. Otherwise an idle collector scans every physics tick.
	if not is_instance_valid(_prey) or not _prey.is_alive():
		_prey = null
	if _perceive_cd <= 0:
		_perceive_cd = 1.0
		_prey = _lone_civilian()
	if not is_instance_valid(_prey):
		state = State.PATROL
		_patrol(delta)
		return
	state = State.CHASE
	var d := _prey.global_position.distance_to(global_position)
	if d < 2.4:
		# caught on contact, then 1.5 s to put them in the capsule
		_captive = _prey
		_captive.captured(self)
		_v["clips"]["run"] = "carry_run"
		_grab_left = 1.5
		_play("grab", 0.1)
		_one_shot_left = 1.5
		show_captive.rpc(_captive.model_idx)
		var b := get_parent().get_parent()
		_escape = b.transport_meet(self) if b.has_method("transport_meet") else Vector3.INF
		_to_edge = _escape == Vector3.INF
		if _to_edge:
			_escape = b.edge_point_near(global_position) if b.has_method("edge_point_near") else global_position
		if b.has_method("_announce"):
			b._announce("A COLETOR HAS TAKEN A CIVILIAN - bring it down before %s!" % (
					"it reaches the edge" if _to_edge else "the transport ship picks them up"))
	else:
		_go_to(_prey.global_position, true)


## The nearest civilian with nobody else (officer, player) close by.
func _lone_civilian() -> Node3D:
	var best: Node3D = null
	var bd := 90.0
	for c in get_tree().get_nodes_in_group("civilians"):
		if not c.is_alive() or c.get("police") or c.get("dog") or c.get("vendor") or c.get("_captor"):
			continue
		var d: float = c.global_position.distance_to(global_position)
		if d < bd:
			var guarded := false
			for pl in get_tree().get_nodes_in_group("players"):
				if (pl as Node3D).global_position.distance_to(c.global_position) < 8.0:
					guarded = true
			if not guarded:
				bd = d
				best = c
	return best


## Mech cannon (server): now and then a missile at its target. It flies
## (CANNON_SPEED, a slight arc, a smoke trail you can see coming) to where
## the target was when it fired - running off in time dodges it - and
## bursts there: a blast that kills people near it; a wall in the way takes
## the hit: a scorched crater on the facade and a pile of rubble. The burst
## is the game's (main.cannon_land), so a mech shot down mid-flight still
## has its missile land.
const CANNON_EVERY := 12.0
const CANNON_R := 4.0
const CANNON_SPEED := 32.0      # m/s
var _cannon_cd := 6.0


func _cannon(delta: float) -> void:
	_cannon_cd -= delta
	if _cannon_cd > 0 or not is_instance_valid(target) or not (state in [State.CHASE, State.HUNT]):
		return
	_cannon_cd = CANNON_EVERY * randf_range(0.8, 1.3)
	var from: Vector3 = global_transform * _v["muzzle"]
	var aim: Vector3 = target.global_position + Vector3(0, 1.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, aim + (aim - from).normalized() * 2.0, 1 | 4 | 32)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var at: Vector3 = hit.position if hit else aim
	var wall: bool = not hit.is_empty() and hit.collider is StaticBody3D and absf((hit.normal as Vector3).y) < 0.5
	var flight: float = maxf(from.distance_to(at) / CANNON_SPEED, 0.2)
	cannon_launch.rpc(from, at, flight)
	var main := get_tree().current_scene
	get_tree().create_timer(flight).timeout.connect(
			main.cannon_land.bind(from, at, hit.normal if hit else Vector3.UP, wall, CANNON_R))


## Every peer: the missile leaving the mech's arm and flying to `at`.
@rpc("authority", "call_local", "reliable")
func cannon_launch(from: Vector3, at: Vector3, flight: float) -> void:
	Sfx.play_at("robot_fire", from, 4.0, 120.0)
	var main := get_tree().current_scene
	var m := Missile.new()
	main.add_child(m)
	m.fly(from, at, flight, fx_light(Color(1.0, 0.6, 0.25), 3.0, 5.0))     # the motor's glow (capped like every effect light)


## A mech's missile, drawn on every peer: a grey body, a red nose, four fins,
## the motor's glow and a smoke trail left hanging in the air behind it.
class Missile extends Node3D:
	var _from := Vector3.ZERO
	var _to := Vector3.ZERO
	var _t := 0.0
	var _flight := 1.0
	var _arc := 0.0
	var _trail: CPUParticles3D
	static var _parts: Array = []

	static func _meshes() -> Array:
		if not _parts.is_empty():
			return _parts
		var metal := StandardMaterial3D.new()
		metal.albedo_color = Color(0.32, 0.34, 0.36)
		metal.metallic = 0.7
		metal.roughness = 0.35
		var red := StandardMaterial3D.new()
		red.albedo_color = Color(0.75, 0.12, 0.08)
		red.emission_enabled = true
		red.emission = Color(0.5, 0.05, 0.02)
		var glow := StandardMaterial3D.new()
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.albedo_color = Color(1.0, 0.75, 0.3)
		var body := CylinderMesh.new()
		body.top_radius = 0.13
		body.bottom_radius = 0.13
		body.height = 1.1
		body.radial_segments = 10
		body.material = metal
		var nose := CylinderMesh.new()
		nose.top_radius = 0.0
		nose.bottom_radius = 0.13
		nose.height = 0.35
		nose.radial_segments = 10
		nose.material = red
		var fin := BoxMesh.new()
		fin.size = Vector3(0.03, 0.28, 0.3)
		fin.material = metal
		var flame := SphereMesh.new()
		flame.radius = 0.16
		flame.height = 0.5
		flame.material = glow
		_parts = [body, nose, fin, flame]
		return _parts

	func fly(from: Vector3, to: Vector3, flight: float, light: OmniLight3D) -> void:
		_from = from
		_to = to
		_flight = flight
		_arc = minf(from.distance_to(to) * 0.05, 3.0)
		var p := _meshes()
		# modelled along -Z (its front), like everything else in the game
		var shape := Node3D.new()
		shape.scale = Vector3.ONE * 1.4      # 2 m long: it reads at 30 m
		add_child(shape)
		for mesh_at in [[p[0], Vector3.ZERO, Vector3(-PI / 2, 0, 0)], [p[1], Vector3(0, 0, -0.72), Vector3(-PI / 2, 0, 0)],
				[p[3], Vector3(0, 0, 0.62), Vector3(-PI / 2, 0, 0)]]:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh_at[0]
			mi.position = mesh_at[1]
			mi.rotation = mesh_at[2]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			shape.add_child(mi)
		for k in 4:
			var f := MeshInstance3D.new()
			f.mesh = p[2]
			f.rotation = Vector3(0, 0, k * PI / 2)
			f.position = Vector3(0, 0, 0.42) + Basis(Vector3.BACK, k * PI / 2) * Vector3(0, 0.16, 0)
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			shape.add_child(f)
		if light:
			light.position = Vector3(0, 0, 0.8)
			add_child(light)
		_trail = CPUParticles3D.new()
		_trail.amount = 60
		_trail.lifetime = 1.6
		_trail.local_coords = false
		_trail.spread = 8.0
		_trail.direction = Vector3(0, 0, 1)
		_trail.initial_velocity_min = 0.5
		_trail.initial_velocity_max = 1.5
		_trail.gravity = Vector3(0, 0.4, 0)
		_trail.scale_amount_min = 0.6
		_trail.scale_amount_max = 1.4
		var puff := SphereMesh.new()
		puff.radius = 0.18
		puff.height = 0.36
		var smoke := StandardMaterial3D.new()
		smoke.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smoke.albedo_color = Color(0.7, 0.68, 0.65, 0.35)
		puff.material = smoke
		_trail.mesh = puff
		_trail.position = Vector3(0, 0, 0.75)
		add_child(_trail)
		_place(0.0)

	func _place(u: float) -> void:
		var pos := _from.lerp(_to, u) + Vector3(0, _arc * 4.0 * u * (1.0 - u), 0)
		var ahead := _from.lerp(_to, minf(u + 0.02, 1.0)) + Vector3(0, _arc * 4.0 * minf(u + 0.02, 1.0) * (1.0 - minf(u + 0.02, 1.0)), 0)
		global_position = pos
		if ahead.distance_to(pos) > 0.01:
			look_at(ahead, Vector3.UP if absf((ahead - pos).normalized().y) < 0.99 else Vector3.RIGHT)

	func _process(delta: float) -> void:
		_t += delta
		var u := minf(_t / _flight, 1.0)
		_place(u)
		if u >= 1.0:
			# the trail stays hanging a moment where the missile flew
			var main := get_parent()
			var at := _trail.global_position
			remove_child(_trail)
			main.add_child(_trail)
			_trail.global_position = at
			_trail.emitting = false
			main.get_tree().create_timer(_trail.lifetime + 0.2).timeout.connect(_trail.queue_free)
			queue_free()


## Perception and state machine (server only).
func _think(delta: float) -> void:
	if variant == "collector":
		_collect_think(delta)
		return
	if variant == "mech":
		_cannon(delta)
	_perceive_cd -= delta
	if _perceive_cd <= 0:
		_perceive_cd = 0.2
		_seen = _spot_player()
	_face_point = Vector3.INF
	_wants_to_move = false
	match state:
		State.PATROL:
			if _seen:
				_engage(_seen, true)
				return
			_civ_cd -= delta
			var civ: Node3D = null
			if _civ_cd <= 0:
				_civ_cd = CIV_SCAN_S
				civ = _spot_civilian()
			if civ:
				state = State.HUNT
				_prey = civ
				_fire_cd = randf_range(0.5, 1.0)
				return
			_patrol(delta)
		State.HUNT:
			# killing civilians is part of the robots' mission; players come first
			if _seen:
				_engage(_seen, true)
				return
			if not is_instance_valid(_prey) or not _prey.is_alive():
				_prey = null
				state = State.PATROL
				_pick_patrol_goal()
				return
			_retarget_cd -= delta
			if _retarget_cd <= 0:
				_retarget_cd = 1.0
				# someone clearly closer walks by: go for them (an officer who shot it stays the target)
				if not bool(_prey.get("police")):
					var other := _spot_civilian()
					if other and other != _prey and global_position.distance_to(other.global_position) \
							< global_position.distance_to(_prey.global_position) - 4.0:
						_prey = other
			var pd := global_position.distance_to(_prey.global_position)
			_face_point = _prey.global_position
			_go_to(_prey.global_position, pd > 14.0)
			_fire_cd -= delta
			if _fire_cd <= 0 and pd < 26.0 and _line_of_sight(_prey):
				var officer := bool(_prey.get("police"))
				# slower than against players (time to intervene); officers get the full rate
				_fire_cd = FIRE_INTERVAL * (randf_range(0.9, 1.3) if officer else randf_range(1.4, 2.0))
				var aim := _prey.global_position + Vector3(0, 1.1, 0)
				# poor marksmen against people on foot; an officer firing back is a proper target
				var chance: float = clamp(Tune.robot_aim_officer + (20.0 - pd) / 40.0, 0.2, 0.8) if officer \
						else clamp(0.85 - pd / 30.0, 0.15, 0.55)
				if float(_prey.get("_speed_est")) > 2.5:
					chance *= 0.6
				var hit: bool = randf() < chance
				if not hit:
					aim += Vector3(randf_range(-1.2, 1.2), randf_range(-0.4, 0.8), randf_range(-1.2, 1.2))
				var stop := _shot_blocked(aim, _prey.global_position + Vector3(0, 1.1, 0))
				if stop != Vector3.INF:
					hit = false              # the car in between took it
					aim = stop
				show_shot.rpc(aim)
				if hit:
					_prey.apply_damage(_v["damage"] if officer else CIVILIAN_DAMAGE, self)
			elif pd > 45.0:
				_prey = null
				state = State.PATROL
		State.CHASE:
			if _seen:
				target = _seen
				_last_known = _seen.global_position
				_lost_time = 0.0
				var dist := global_position.distance_to(_last_known)
				_face_point = _last_known
				# close in on a flank instead of queueing behind the others
				_go_to(_flank_point(_seen, dist), dist > 6.0)
				_fire_cd -= delta
				if _fire_cd <= 0:
					_fire_at_player(_seen, dist)
			else:
				_lost_time += delta
				_go_to(_last_known, true)
				if _lost_time > LOSE_SECONDS:
					state = State.SEARCH
					_search_left = SEARCH_SECONDS
		State.SEARCH:
			if _seen:
				_engage(_seen, true)
				return
			if global_position.distance_to(_last_known) > 2.5:
				_go_to(_last_known, true)
			else:
				# look around the last known position
				_search_left -= delta
				rotation.y += delta * 1.6
				if _search_left <= 0:
					state = State.PATROL
					_pick_patrol_goal()


## Where to stand against `p`: robots chasing the same player fan out
## around them (slot 0 straight on, then alternately +/-55, +/-110 degrees),
## holding ~11 m, so they surround the player instead of forming a queue.
func _flank_point(p: Node3D, dist: float) -> Vector3:
	if dist > 24.0:
		return _last_known                 # still far: just head for them
	var mates := []
	for e in get_parent().get_children():
		if e.is_alive() and e.get("target") == p and e.get("state") == State.CHASE:
			mates.append(e)
	if mates.size() < 2:
		return _last_known
	mates.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	var slot := mates.find(self)
	var angle: float = deg_to_rad(55.0) * ceil(slot / 2.0) * (1.0 if slot % 2 == 1 else -1.0)
	var from := global_position - p.global_position
	from.y = 0
	var dir := from.normalized().rotated(Vector3.UP, angle) if from.length() > 0.1 else Vector3.FORWARD
	var want: Vector3 = p.global_position + dir * clamp(dist, 9.0, 13.0)
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, want)


func _go_to(point: Vector3, move: bool) -> void:
	_repath_cd -= get_physics_process_delta_time()
	if _repath_cd <= 0 or agent.target_position.distance_to(point) > 3.0:
		agent.target_position = point
		_repath_cd = 0.5
	_wants_to_move = move


func _patrol(delta: float) -> void:
	# arrived - or the path ended short of an unreachable goal: pick another
	var arrived := _patrol_goal == Vector3.INF or global_position.distance_to(_patrol_goal) < 2.5 \
			or (agent.target_position.distance_to(_patrol_goal) < 0.5 and agent.is_navigation_finished())
	if arrived:
		_pause_left -= delta
		if _pause_left > 0:
			return
		_pick_patrol_goal()
	# nobody to hunt: fire into a car with people in it nearby; they bail out
	# and run, and the robot goes after them (it spots them as they flee)
	_car_cd -= delta
	if _car_cd <= 0:
		var car := _spot_car()
		if car:
			_face_point = car.global_position + Vector3(0, 1.0, 0)
			_fire_cd -= delta
			if _fire_cd <= 0:
				_fire_cd = FIRE_INTERVAL * randf_range(0.8, 1.2)
				show_shot.rpc(_face_point)
				car.apply_damage(5, self)
				if not car.get("occupied"):
					# the driver got out: go after them (they come out on the far side)
					var driver := _nearest_civilian(car.global_position, 6.0)
					if driver:
						_prey = driver
						state = State.HUNT
						_fire_cd = randf_range(0.6, 1.0)
			return
		_car_cd = 1.0
	# vandalism: now and then shoot an intact lamp/signal/bin nearby, one it can see
	_vandal_cd -= delta
	if _vandal_cd <= 0:
		var props = get_tree().current_scene.get("props")
		var idx: int = props.find_target(global_position, 18.0, global_position + Vector3(0, 1.5, 0)) if props else -1
		if idx >= 0:
			var at: Vector3 = props.prop_position(idx) + Vector3(0, 1.5, 0)
			_face_point = at
			_fire_cd -= delta
			if _fire_cd <= 0:
				_fire_cd = 0.7
				_hit_vehicle(at)
				show_shot.rpc(at)
				props.damage_prop(idx, 20)
				_vandal_shots += 1
			if _vandal_shots >= 3 or props.destructibles[idx]["broken"]:
				_vandal_shots = 0
				_vandal_cd = randf_range(10.0, 22.0)
			return
		_vandal_cd = 3.0
	_go_to(_patrol_goal, true)


func _pick_patrol_goal() -> void:
	var map := get_world_3d().navigation_map
	for attempt in 8:
		var guess := global_position + Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * randf_range(15.0, 45.0)
		if commander and post != Vector3.INF:
			guess = post + Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * randf_range(3.0, 14.0)
		var pos := NavigationServer3D.map_get_closest_point(map, guess)
		if not get_tree().current_scene.in_bounds(pos, 10.0):
			continue
		# only goals on the street network it stands on
		var path := NavigationServer3D.map_get_path(map, global_position, pos, true)
		if path.size() > 1 and path[path.size() - 1].distance_to(pos) < 1.0:
			_patrol_goal = pos
			_pause_left = randf_range(1.0, 4.0)
			return


## Start chasing; optionally alert nearby robots (they learn where you are).
func _engage(p: Node3D, alert_others: bool) -> void:
	state = State.CHASE
	target = p
	_last_known = p.global_position
	_lost_time = 0.0
	_fire_cd = randf_range(0.4, 0.9)    # reaction time before the first shot
	if alert_others:
		for e in get_parent().get_children():
			if e != self and e.is_alive() and e.global_position.distance_to(global_position) < ALERT_RADIUS:
				e.alerted(p.global_position)


func alerted(where: Vector3) -> void:
	if state != State.CHASE:
		state = State.SEARCH
		_last_known = where
		_search_left = SEARCH_SECONDS


## A gunshot was heard: go and look at where it came from (not at the shooter).
func heard(where: Vector3) -> void:
	if health > 0 and state == State.PATROL and global_position.distance_to(where) < HEARING_RADIUS:
		state = State.SEARCH
		_last_known = where
		_search_left = SEARCH_SECONDS


## A living player inside the view cone (or very close) with clear line of sight.
func _spot_player() -> Node3D:
	var fwd := -global_transform.basis.z
	var best: Node3D = null
	var bd := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p.dead:
			continue
		var to: Vector3 = p.global_position - global_position
		var d := to.length()
		if d > Tune.robot_sight_m:
			continue
		var flat := Vector3(to.x, 0, to.z).normalized()
		var in_cone := d < NEAR_SENSE or fwd.dot(flat) > cos(deg_to_rad(VIEW_CONE_DEG / 2.0))
		# once chasing, keep tracking the target regardless of facing
		if not in_cone and not (state == State.CHASE and p == target):
			continue
		if d < bd and _line_of_sight(p):
			bd = d
			best = p
	return best


## The living person closest to `at`, within `radius` (e.g. a driver who just bailed).
func _nearest_civilian(at: Vector3, radius: float) -> Node3D:
	var best: Node3D = null
	var bd := radius
	for c in get_tree().get_nodes_in_group("civilians"):
		if not c.is_alive() or not c.hunted:
			continue
		var d: float = c.global_position.distance_to(at)
		if d < bd:
			bd = d
			best = c
	return best


## An occupied car, bus or truck within reach that this robot can see.
const CAR_RANGE := 22.0
var _car_cd := 0.0
func _spot_car() -> Node3D:
	var best: Node3D = null
	var bd := CAR_RANGE
	for v in get_tree().current_scene.traffic_root.get_children():
		if not v.get("occupied") or v.get("driver_peer") != 0 or v.get("_wrecked") \
				or not v.kind in ["car", "bus", "truck", "lorry", "motoboy"]:
			continue
		var d: float = v.global_position.distance_to(global_position)
		if d > bd:
			continue
		var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.5, 0),
				v.global_position + Vector3(0, 1.0, 0), 1)
		if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			bd = d
			best = v
	return best


## A living civilian inside the view cone with clear line of sight.
## A patrolling robot looks for people this often (each from its own phase),
## not every physics tick: the scan walks the whole crowd.
const CIV_SCAN_S := 0.3
var _civ_cd := randf() * CIV_SCAN_S


## The nearest hunted person in view: candidates by distance first, the ray
## (line of sight) only for them, nearest first, the first seen wins.
func _spot_civilian() -> Node3D:
	var fwd := -global_transform.basis.z
	var cone := cos(deg_to_rad(VIEW_CONE_DEG / 2.0))
	var cands := []
	for c in get_tree().get_nodes_in_group("civilians"):
		if not c.is_alive() or not c.hunted:     # robots hunt people, not the street dogs (the type says)
			continue
		var to: Vector3 = c.global_position - global_position
		var d2 := to.length_squared()
		if d2 > CIVILIAN_RANGE * CIVILIAN_RANGE:
			continue
		var flat := Vector3(to.x, 0, to.z).normalized()
		if fwd.dot(flat) < cone and d2 > NEAR_SENSE * NEAR_SENSE:
			continue
		cands.append([d2, c])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	for k in mini(cands.size(), 4):
		if _line_of_sight(cands[k][1]):
			return cands[k][1]
	return null


func _fire_at_player(p: Node3D, dist: float) -> void:
	_fire_cd = Difficulty.get_value("fire_interval") * randf_range(0.8, 1.3)
	# accuracy drops with distance
	var hit: bool = randf() < clamp(1.2 - dist / Tune.robot_sight_m, 0.15, Difficulty.get_value("aim_max"))
	var aim := p.global_position + Vector3(0, 1.3, 0)
	if not hit:
		aim += Vector3(randf_range(-1.5, 1.5), randf_range(-0.5, 1.0), randf_range(-1.5, 1.5))
	var stop := _shot_blocked(aim, p.global_position + Vector3(0, 1.3, 0))
	if stop != Vector3.INF:
		hit = false                      # the car in between took it
		aim = stop
	show_shot.rpc(aim)
	if hit:
		p.hurt.rpc_id(p.get_multiplayer_authority(), _v["damage"], global_position)


func _line_of_sight(p: Node3D) -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.5, 0),
			p.global_position + Vector3(0, 1.5, 0), 1)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func is_alive() -> bool:
	return health > 0


## `attacker`: the player who shot. Being hit overrides whatever the robot
## was doing (patrolling, hunting a civilian, chasing someone else): it turns
## on the shooter and alerts the robots around it.
## Server: caught in a laço for `seconds` (a mech is only slowed).
var _lasso_left := 0.0
func lassoed(seconds: float) -> void:
	if not multiplayer.is_server() or health <= 0:
		return
	_lasso_left = seconds
	lasso_fx.rpc(seconds)


## Every peer: the rope loop round its middle while it is held.
@rpc("authority", "call_local", "reliable")
func lasso_fx(seconds: float) -> void:
	var ring := MeshInstance3D.new()
	var t := TorusMesh.new()
	var r: float = _v.get("radius", 0.5) * 1.15
	t.inner_radius = r
	t.outer_radius = r + 0.06
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.38, 0.2)
	m.roughness = 0.9
	t.material = m
	ring.mesh = t
	ring.position = Vector3(0, _v.get("height", 2.0) * 0.55, 0)
	add_child(ring)
	get_tree().create_timer(seconds).timeout.connect(ring.queue_free)


## A bullet's damage factor where it struck (weak points, every difficulty):
## a mech's front plates halve it, its exposed reactor at the back doubles
## it; a trooper's head takes double, its legs less.
func hit_scale(at: Vector3, from: Vector3) -> float:
	if variant == "mech":
		var fwd := -global_transform.basis.z
		var to_shooter := from - global_position
		to_shooter.y = 0
		var facing := fwd.dot(to_shooter.normalized())
		return Difficulty.MECH_FRONT if facing > 0.35 else (Difficulty.MECH_BACK if facing < -0.35 else 1.0)
	var h: float = (at.y - global_position.y) / (_v["height"] * scale.y)
	return Difficulty.HEAD if h > 0.8 else (Difficulty.LEGS if h < 0.4 else 1.0)


func apply_damage(amount: int, attacker: Node3D = null) -> void:
	if not multiplayer.is_server() or health <= 0:
		return
	health -= amount
	if health > 0 and attacker and attacker.is_in_group("players") and not attacker.dead:
		_prey = null
		if target != attacker or state != State.CHASE:
			_engage(attacker, true)
		else:
			_last_known = attacker.global_position
			_lost_time = 0.0
	elif health > 0 and attacker and attacker.is_in_group("civilians") and attacker.get("police") \
			and state != State.CHASE and _prey != attacker:
		# shot by an officer: drop whoever it was chasing and turn on the
		# shooter, like it does with players (players still come first)
		_prey = attacker
		state = State.HUNT
		_fire_cd = randf_range(0.4, 0.9)
		for e in get_parent().get_children():
			if e != self and e.is_alive() and e.global_position.distance_to(global_position) < ALERT_RADIUS:
				e.alerted(attacker.global_position)
	if health <= 0:
		health = 0
		if is_instance_valid(_captive):
			_captive.released(global_position)      # the capsule opens: they run for it
			rescued.emit(self, attacker)
			_captive = null
			hide_captive.rpc()
		killed_by_player = attacker != null and attacker.is_in_group("players")
		killer_peer = attacker.get_multiplayer_authority() if killed_by_player else 0
		collision_layer = 0          # corpse: no longer shootable or blocking
		velocity = Vector3.ZERO
		died.emit(self)
		get_tree().create_timer(CORPSE_SECONDS).timeout.connect(queue_free)


## The heavy mech goes over backwards like a felled tree, then bursts apart
## where it hits the ground.
func _topple() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null:
		return
	if _anim:
		_anim.pause()
	var tw := create_tween()
	tw.tween_property(model, "rotation:x", deg_to_rad(86), 1.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_break_apart.bind(2.2))


## Every peer: the robot comes apart into its plates (see wreck.gd).
func _break_apart(size: float) -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null or not is_inside_tree():
		return
	Wreck.shatter(model, Vector3.ZERO, 6.0 / size)
	var main := get_tree().current_scene
	var at := model.global_transform * Vector3(0, 1.0, 0)
	if main.get("props"):
		main.props._sparks(at)
	Sfx.play_at("robot_step", global_position, 4.0 * size, 70.0)
	Sfx.play_at("prop_break", at, -2.0 + 2.0 * size, 60.0)


## Server: a car or bike in the line of fire takes the shot - its driver
## or rider bails out.
func _hit_vehicle(aim: Vector3) -> Vector3:
	var from := global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, aim + (aim - from).normalized() * 2.0, 16)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit and hit.collider.has_method("apply_damage"):
		hit.collider.apply_damage(5, self)
		return hit.position
	return Vector3.INF


## A vehicle between the muzzle and `target` takes the shot: true when the
## round stopped in it (the shot shows there, the target is not hit).
func _shot_blocked(aim: Vector3, target: Vector3) -> Vector3:
	var stop := _hit_vehicle(aim)
	var from := global_position + Vector3(0, 1.2, 0)
	if stop != Vector3.INF and from.distance_to(stop) < from.distance_to(target) - 0.3:
		return stop
	return Vector3.INF


## A robot lowered by a dropship touched down: heavy thump on every peer.
@rpc("authority", "call_local", "unreliable")
func landed() -> void:
	Sfx.play_at("robot_step", global_position, 6.0, 60.0)
	Sfx.play_at("prop_break", global_position, -8.0, 40.0)


## Short-lived effect lights (muzzle flashes, hits): a light makes every pixel
## near it costlier and each new one reworks the lighting, so at most
## FX_LIGHTS of them at a time - past that a flash shows without its light.
const FX_LIGHTS := 8
static var _fx_alive := 0
static func fx_light(color: Color, energy: float, reach: float) -> OmniLight3D:
	if _fx_alive >= FX_LIGHTS:
		return null
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = reach
	l.shadow_enabled = false
	_fx_alive += 1
	l.tree_exited.connect(func(): _fx_alive -= 1)
	return l


static var _bolt: CylinderMesh
static func _bolt_mesh() -> CylinderMesh:
	if _bolt == null:
		_bolt = CylinderMesh.new()
		_bolt.top_radius = 0.035
		_bolt.bottom_radius = 0.035
		_bolt.height = BOLT_LENGTH
		_bolt.radial_segments = 6
		_bolt.rings = 1
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.7, 1.0, 0.6)
		mat.emission_enabled = true
		mat.emission = Color(0.4, 1.0, 0.4)
		mat.emission_energy_multiplier = 3.0
		_bolt.material = mat
	return _bolt


## Visible muzzle flash and tracer on every peer, so incoming fire can be seen.
@rpc("authority", "call_local", "unreliable")
func show_shot(to: Vector3) -> void:
	_play("shoot", 0.05)
	_one_shot_left = 0.45
	if multiplayer.is_server():
		for c in get_tree().get_nodes_in_group("civilians"):
			c.heard(global_position)
	Sfx.play_at("robot_fire", global_transform * _v["muzzle"], -3.0)
	get_tree().call_group("pigeons", "scare", global_position)
	var from: Vector3 = global_transform * (_v["muzzle"] as Vector3)
	var flash := fx_light(Color(0.4, 1.0, 0.4), 4.0, 5.0)
	if flash:
		flash.position = _v["muzzle"]
		add_child(flash)
		var tw := flash.create_tween()
		tw.tween_property(flash, "light_energy", 0.0, 0.12)
		tw.tween_callback(flash.queue_free)
	# a short energy bolt flying to the target, not a beam spanning the street
	# (one mesh and material for every bolt; its glow is the emission, no light)
	var bolt := MeshInstance3D.new()
	bolt.mesh = _bolt_mesh()
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(bolt)
	var dir := (to - from).normalized()
	bolt.global_position = from + dir * BOLT_LENGTH / 2
	bolt.look_at(to, Vector3.UP if abs(dir.y) < 0.99 else Vector3.RIGHT)
	bolt.rotate_object_local(Vector3.RIGHT, PI / 2)
	var travel: float = max(from.distance_to(to) - BOLT_LENGTH / 2, 0.1)
	var bt := bolt.create_tween()
	bt.tween_property(bolt, "global_position", to, travel / BOLT_SPEED)
	bt.tween_callback(func():
		var hit := fx_light(Color(0.5, 1.0, 0.4), 3.0, 2.5)
		if hit and bolt.is_inside_tree():
			bolt.get_parent().add_child(hit)
			hit.global_position = to
			var ht := hit.create_tween()
			ht.tween_property(hit, "light_energy", 0.0, 0.15)
			ht.tween_callback(hit.queue_free)
		bolt.queue_free())
