extends CharacterBody3D
## URB-D3 surveillance drone. Server-simulated flying robot: patrols 8-10 m
## above the street, and once it sees a player it closes to ~18 m, circles
## and fires short energy bolts. Fragile; when shot down it spins and falls.
## Shares the robot interface (robots group, died signal, apply_damage,
## heard/alerted, is_alive) so the director, HUD and players treat it as one.

signal died(enemy)

const Wreck := preload("res://scripts/wreck.gd")
const MODEL := "res://assets/common/enemies/drone/drone.glb"
const ALTITUDE := 9.0
const SPEED := 6.5
const PATROL_SPEED := 3.0
const SIGHT := 45.0
const STANDOFF := 18.0
const FIRE_INTERVAL := 1.5
const DAMAGE := 4
const CIVILIAN_DAMAGE := 6
const ROOF_MASK := 64          # roofs collide on their own layer (see main.gd)

@export var health := 30           # set from difficulty.gd drone_hp in _ready
const Difficulty := preload("res://scripts/difficulty.gd")
var killed_by_player := false
var killer_peer := 0            # the player who destroyed it (score)   # robots the police take down don't count for the goal
var dropping := false          # interface parity with enemy.gd (drones fly in)
var variant := "drone"
var target: Node3D
var _anim: AnimationPlayer
var _goal := Vector3.INF
var _fire_cd := 1.0
var _look_cd := 0.0
var _orbit := 1.0
var _call_cd := 0.0
var _last_health := 30
var _dying := false
var _overlay: StandardMaterial3D


func _ready() -> void:
	health = Difficulty.get_value("drone_hp")
	_last_health = health
	add_to_group("robots")
	collision_layer = 2
	collision_mask = 1 | ROOF_MASK
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.7
	cs.shape = sph
	add_child(cs)
	_overlay = StandardMaterial3D.new()
	_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay.albedo_color = Color(1, 0.6, 0.2, 0.0)
	if ResourceLoader.exists(MODEL):
		var model: Node3D = (load(MODEL) as PackedScene).instantiate()
		add_child(model)
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_overlay = _overlay
		var players := model.find_children("*", "AnimationPlayer", true, false)
		if players.size() > 0:
			_anim = players[0]
			for c in ["hover", "fly_forward"]:
				if _anim.has_animation(c):
					_anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
			_anim.play("hover")
	var hum := AudioStreamPlayer3D.new()
	var stream: AudioStreamWAV = load("res://assets/audio/ship_engine.wav")
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_end = stream.data.size() / 2
	hum.stream = stream
	hum.pitch_scale = 2.6          # the dropship's drone, small and whiny
	hum.volume_db = -14.0
	hum.unit_size = 6.0
	hum.max_distance = 60.0
	hum.autoplay = true
	add_child(hum)
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	for prop in [".:position", ".:rotation", ".:health"]:
		cfg.add_property(NodePath(prop))
	sync.replication_config = cfg
	add_child(sync)
	set_physics_process(multiplayer.is_server())



func is_alive() -> bool:
	return health > 0


func heard(where: Vector3) -> void:
	if health > 0 and target == null and global_position.distance_to(where) < 40.0:
		_goal = Vector3(where.x, 0, where.z)


func alerted(where: Vector3) -> void:
	heard(where)


## Server: a laço caught it: it is pulled down whole and becomes the
## catcher's (counts as one taken down for the goal and the score).
func lassoed(by: Node3D) -> void:
	if not multiplayer.is_server() or health <= 0:
		return
	health = 0
	killed_by_player = by != null and by.is_in_group("players")
	killer_peer = by.get_multiplayer_authority() if killed_by_player else 0
	collision_layer = 0
	died.emit(self)
	if killed_by_player:
		by.got_drone.rpc_id(killer_peer)
	captured_fx.rpc()


@rpc("authority", "call_local", "reliable")
func captured_fx() -> void:
	set_physics_process(false)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ONE * 0.05, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


## About when a downed drone hits the street: it breaks into its parts.
func _crash_shatter() -> void:
	if is_inside_tree():
		Wreck.shatter(self, Vector3.ZERO, 8.0)
		Sfx.play_at("prop_break", global_position, 0.0, 50.0)


func apply_damage(amount: int, attacker: Node3D = null) -> void:
	if not multiplayer.is_server() or health <= 0:
		return
	health -= amount
	if health > 0 and attacker and attacker.is_in_group("players"):
		target = attacker
	if health <= 0:
		health = 0
		killed_by_player = attacker != null and attacker.is_in_group("players")
		killer_peer = attacker.get_multiplayer_authority() if killed_by_player else 0
		collision_layer = 0
		died.emit(self)
		get_tree().create_timer(4.0).timeout.connect(queue_free)


func _ground_below(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2, 0), p + Vector3(0, -60, 0), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else p.y - ALTITUDE


func _sees(p: Node3D) -> bool:
	if global_position.distance_to(p.global_position) > SIGHT:
		return false
	var q := PhysicsRayQueryParameters3D.create(global_position, p.global_position + Vector3(0, 1.5, 0), 1 | ROOF_MASK)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	if health <= 0:
		# shot down: fall and tumble
		velocity.y -= 9.8 * delta
		rotation.z += delta * 6.0
		move_and_slide()
		return
	_look_cd -= delta
	if _look_cd <= 0:
		_look_cd = 0.3
		if target == null or not is_instance_valid(target) or target.dead or not _sees(target):
			target = null
			for p in get_tree().get_nodes_in_group("players"):
				if not p.dead and _sees(p):
					target = p
					break
	var want: Vector3
	var speed := PATROL_SPEED
	if target:
		# spotter: call robots nearby that have no one to fight to where the player is
		_call_cd -= delta
		if _call_cd <= 0:
			_call_cd = 3.0
			for e in get_tree().get_nodes_in_group("robots"):
				if e != self and e.is_alive() and not e.get("state") in [1, 3] and e.has_method("alerted") \
						and e.global_position.distance_to(global_position) < 45.0:
					e.alerted(target.global_position)
		# hold a stand-off distance and circle the player
		var to := target.global_position - global_position
		to.y = 0
		var side := Vector3(-to.z, 0, to.x).normalized() * _orbit
		var radial := to.normalized() * (to.length() - STANDOFF)
		want = global_position + radial + side * 6.0
		speed = SPEED
		_face(target.global_position)
		_fire_cd -= delta
		if _fire_cd <= 0:
			_fire_cd = FIRE_INTERVAL * randf_range(0.8, 1.3)
			_fire_at(target)
		if randf() < delta * 0.2:
			_orbit = -_orbit
	else:
		if _goal == Vector3.INF or Vector2(_goal.x - global_position.x, _goal.z - global_position.z).length() < 3.0:
			var main := get_tree().current_scene
			for attempt in 10:
				var g := global_position + Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * randf_range(20, 50)
				if main.in_bounds(g, 20.0):
					_goal = g
					break
		want = _goal
		_face(want)
	var ground := _ground_below(global_position)
	var flat := Vector3(want.x - global_position.x, 0, want.z - global_position.z)
	var v: Vector3 = flat.normalized() * min(speed, flat.length() * 2.0) if flat.length() > 0.2 else Vector3.ZERO
	var alt := ground + ALTITUDE + sin(Time.get_ticks_msec() * 0.0015 + float(name.hash() % 100)) * 0.6
	v.y = clamp((alt - global_position.y) * 2.0, -4.0, 4.0)
	velocity = velocity.lerp(v, min(1.0, delta * 3.0))
	move_and_slide()
	# blocked by a building: climb over it
	if get_slide_collision_count() > 0 and flat.length() > 1.0:
		velocity.y = 5.0


func _face(p: Vector3) -> void:
	var to := p - global_position
	if Vector2(to.x, to.z).length() > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), 0.15)


func _fire_at(p: Node3D) -> void:
	var dist := global_position.distance_to(p.global_position)
	var hit: bool = randf() < clamp(0.9 - dist / SIGHT, 0.15, Difficulty.get_value("aim_max") * 0.75)
	var aim := p.global_position + Vector3(0, 1.3, 0)
	if not hit:
		aim += Vector3(randf_range(-1.5, 1.5), randf_range(-0.5, 1.0), randf_range(-1.5, 1.5))
	show_shot.rpc(aim)
	if hit:
		p.hurt.rpc_id(p.get_multiplayer_authority(), DAMAGE, global_position)


## Every peer: a short green bolt from the turret, and the turret clip.
@rpc("authority", "call_local", "unreliable")
func show_shot(to: Vector3) -> void:
	if _anim and _anim.has_animation("fire"):
		_anim.play("fire", 0.05)
		_anim.queue("hover")
	Sfx.play_at("robot_fire", global_position, -9.0, 60.0)
	get_tree().call_group("pigeons", "scare", global_position)
	var from := global_position + Vector3(0, -0.3, 0)
	var bolt := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.025
	cyl.bottom_radius = 0.025
	cyl.height = 0.9
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 1.0, 0.6)
	cyl.material = mat
	bolt.mesh = cyl
	get_tree().current_scene.add_child(bolt)
	var dir := (to - from).normalized()
	bolt.global_position = from
	bolt.look_at(to, Vector3.UP if abs(dir.y) < 0.99 else Vector3.RIGHT)
	bolt.rotate_object_local(Vector3.RIGHT, PI / 2)
	var tw := bolt.create_tween()
	tw.tween_property(bolt, "global_position", to, max(0.05, from.distance_to(to) / 70.0))
	tw.tween_callback(bolt.queue_free)


func _process(delta: float) -> void:
	if health < _last_health:
		_overlay.albedo_color.a = 0.7
		Sfx.play_at("robot_hit" if health > 0 else "robot_death", global_position, -6.0 if health > 0 else 0.0)
		if health <= 0 and not _dying:
			_dying = true
			if _anim and _anim.has_animation("crash"):
				_anim.play("crash", 0.05)
			# about when it hits the street: it breaks into its parts
			# a method of the drone, not a lambda holding it: lassoed and gone
			# before then, the timer just lets go
			get_tree().create_timer(1.3).timeout.connect(_crash_shatter)
		elif _anim and _anim.has_animation("damaged"):
			_anim.play("damaged", 0.05)
			_anim.queue("hover")
	_last_health = health
	_overlay.albedo_color.a = max(0.0, _overlay.albedo_color.a - delta * 3.0)
