extends Node3D
## URB-S2 Enxame: a flock of small drones (urb_s2_enxame.glb) in two roles.
## A third are kamikazes: they circle a player close and low, and one at a
## time a drone blinks (explode_windup) and dives at where the player was
## when it began to blink - moving then dodges it - blowing up there and
## hurting whoever is close, players, people and robots alike. The rest are
## gunners: higher up and further out, each fires a small bolt now and then
## (a red glint first) when it can see the player, so cover helps. With the
## kamikazes gone a gunner now and then turns kamikaze. One shot brings a
## drone down. Damage, rates and the swarm's size come from difficulty.gd
## (swarm_*). The server flies them; every peer draws them from the
## replicated positions.

const MODEL := "res://assets/common/enemies/enxame/urb_s2_enxame.glb"
const UNIT_HP := 15
const ORBIT_R := 7.0
const ORBIT_H := 3.5
const DIVE_SPEED := 16.0
const BLAST_R := 2.8
const BLAST_OTHERS := 40
const SIGHT := 130.0
const GUN_R := 13.0                  # gunners: orbit radius and height above the player
const GUN_H := Vector2(8.0, 12.0)
const GLINT_S := 0.3                 # the red glint before a gunner fires
const TURN_KAMIKAZE_S := 6.0         # no kamikaze left: a gunner turns one this often
const Difficulty := preload("res://scripts/difficulty.gd")
const Enemy := preload("res://scripts/enemy.gd")

signal died(swarm)

@export var count := 8
@export var positions := PackedVector3Array()
@export var alive_mask := 0          # bit i: drone i still flying
var variant := "swarm"
var health := 1                      # > 0 while any drone flies (enemies_root conventions)
var killed_by_player := false
var killer_peer := 0
var _units: Array = []               # [Node3D] visuals, one per drone
var _hp: Array = []
var _dive: Array = []                # per drone: 0 orbiting, > 0 windup time left, -1 diving
var _dive_t: Array = []
var _dive_at: Array = []             # per drone: the point its dive goes for (locked at the blink)
var _gunner: Array = []              # per drone: true = gunner, false = kamikaze
var _fire_cd: Array = []
var _glint: Array = []               # per gunner: > 0 glinting, fires when it runs out
var _target: Node3D
var _attack_cd := 2.0
var _turn_cd := TURN_KAMIKAZE_S
var _angle := 0.0


class Unit extends StaticBody3D:
	var swarm: Node
	var index := 0
	func apply_damage(amount: int, attacker: Node3D = null) -> void:
		swarm.hit_unit(index, amount, attacker)


func _ready() -> void:
	var packed := load(MODEL) as PackedScene
	for i in count:
		var v := Node3D.new()
		if packed:
			var m := packed.instantiate()
			v.add_child(m)
			for ap in m.find_children("*", "AnimationPlayer", true, false):
				if (ap as AnimationPlayer).has_animation("hover"):
					(ap as AnimationPlayer).get_animation("hover").loop_mode = Animation.LOOP_LINEAR
					(ap as AnimationPlayer).play("hover")
		var body := Unit.new()
		body.swarm = self
		body.index = i
		body.collision_layer = 2
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.4
		cs.shape = sph
		body.add_child(cs)
		v.add_child(body)
		add_child(v)
		v.top_level = true
		_units.append(v)
		_hp.append(UNIT_HP)
		_dive.append(0.0)
		_dive_t.append(0.0)
		_dive_at.append(Vector3.ZERO)
		_gunner.append(i >= int(ceil(count / 3.0)))
		_fire_cd.append(randf_range(1.0, 3.0))
		_glint.append(0.0)
	if multiplayer.is_server():
		alive_mask = (1 << count) - 1
		positions.resize(count)
		for i in count:
			positions[i] = global_position + Vector3(randf_range(-3, 3), randf_range(0, 2), randf_range(-3, 3))
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:positions"))
	cfg.add_property(NodePath(".:alive_mask"))
	sync.replication_config = cfg
	add_child(sync)
	set_physics_process(multiplayer.is_server())


func is_alive() -> bool:
	return alive_mask != 0


func heard(_where: Vector3) -> void:
	pass


func alerted(_where: Vector3) -> void:
	pass


func lassoed(_seconds: float) -> void:
	pass


func _process(delta: float) -> void:
	for i in _units.size():
		var v: Node3D = _units[i]
		var up := (alive_mask >> i) & 1 == 1
		v.visible = up
		if not up or i >= positions.size():
			continue
		v.global_position = v.global_position.lerp(positions[i], min(1.0, delta * 12.0)) \
				if v.global_position.distance_to(positions[i]) < 6.0 else positions[i]
		if is_instance_valid(_target):
			var to := _target.global_position - v.global_position
			to.y = 0
			if to.length() > 0.1:
				v.rotation.y = atan2(-to.x, -to.z)


func _physics_process(delta: float) -> void:
	if alive_mask == 0:
		return
	if not is_instance_valid(_target) or _target.get("dead"):
		_target = _nearest_player()
		if _target == null:
			return
	_angle += delta * 0.8
	var chest := _target.global_position + Vector3(0, 1.1, 0)
	var centre := _target.global_position + Vector3(0, ORBIT_H, 0)
	_attack_cd -= delta
	if _attack_cd <= 0:
		_attack_cd = Difficulty.get_value("swarm_dive_s")
		for i in count:
			if (alive_mask >> i) & 1 == 1 and _dive[i] == 0.0 and not _gunner[i]:
				_dive[i] = 0.4                  # blinking: about to dive
				_dive_at[i] = chest             # where the player is now: moving dodges it
				windup.rpc(i)
				break
	_turn_cd -= delta
	if _turn_cd <= 0:
		_turn_cd = TURN_KAMIKAZE_S
		var kamikazes := 0
		var last_gunner := -1
		for i in count:
			if (alive_mask >> i) & 1 == 1:
				if _gunner[i]:
					last_gunner = i
				else:
					kamikazes += 1
		if kamikazes == 0 and last_gunner >= 0:
			_gunner[last_gunner] = false
	for i in count:
		if (alive_mask >> i) & 1 == 0:
			continue
		var p := positions[i]
		if _dive[i] > 0.0:
			_dive[i] -= delta
			if _dive[i] <= 0.0:
				_dive[i] = -1.0
				_dive_t[i] = 0.0
		elif _dive[i] < 0.0:
			# diving at where the player was at the blink, and on through it a little
			_dive_t[i] += delta
			var aim: Vector3 = _dive_at[i]
			p = p.move_toward(aim, DIVE_SPEED * delta)
			if p.distance_to(aim) < 0.3 or p.distance_to(chest) < 1.3 or _dive_t[i] > 2.5 or _hit_ground(p):
				_explode(i, p)
				continue
		elif _gunner[i]:
			var a := -_angle * 0.7 + i * TAU / count
			var h := lerpf(GUN_H.x, GUN_H.y, fmod(i * 0.37, 1.0))
			var want := _target.global_position + Vector3(cos(a) * GUN_R, h + sin(a * 3.0) * 0.8, sin(a) * GUN_R)
			p = p.move_toward(want, 8.0 * delta)
			_gun(i, p, chest, delta)
		else:
			var a := _angle + i * TAU / count
			var want := centre + Vector3(cos(a), sin(a * 2.0) * 0.3, sin(a)) * ORBIT_R
			p = p.move_toward(want, 9.0 * delta)
		positions[i] = p


## Server: gunner i - a glint, then a bolt at the player when it sees them.
func _gun(i: int, p: Vector3, chest: Vector3, delta: float) -> void:
	if _glint[i] > 0.0:
		_glint[i] -= delta
		if _glint[i] > 0.0:
			return
		var dist := p.distance_to(chest)
		var hit: bool = randf() < clamp(1.1 - dist / 40.0, 0.25, Difficulty.get_value("aim_max"))
		var to := chest
		if not hit:
			to += Vector3(randf_range(-1.6, 1.6), randf_range(-0.6, 1.0), randf_range(-1.6, 1.6))
		var q := PhysicsRayQueryParameters3D.create(p, to + (to - p).normalized() * 0.5, 1)
		var wall := get_world_3d().direct_space_state.intersect_ray(q)
		if wall:
			to = wall.position
			hit = false
		bolt.rpc(p, to)
		if hit:
			_target.hurt.rpc_id(_target.get_multiplayer_authority(), int(Difficulty.get_value("swarm_bolt")), p)
		return
	_fire_cd[i] -= delta
	if _fire_cd[i] > 0.0:
		return
	_fire_cd[i] = Difficulty.get_value("swarm_fire_s") * randf_range(0.8, 1.25)
	# only with a clear line to the player: under an awning or round a corner is cover
	var q := PhysicsRayQueryParameters3D.create(p, chest, 1)
	if get_world_3d().direct_space_state.intersect_ray(q):
		_fire_cd[i] *= 0.5
		return
	_glint[i] = GLINT_S
	glint.rpc(i)


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var bd := SIGHT
	for pl in get_tree().get_nodes_in_group("players"):
		if pl.dead:
			continue
		var d: float = (pl as Node3D).global_position.distance_to(global_position if positions.is_empty() else positions[0])
		if d < bd:
			bd = d
			best = pl
	return best


func _hit_ground(p: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.5, 0), p - Vector3(0, 0.3, 0), 1)
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Server: drone i blows up at p.
func _explode(i: int, p: Vector3) -> void:
	alive_mask &= ~(1 << i)
	boom.rpc(p)
	for pl in get_tree().get_nodes_in_group("players"):
		if (pl as Node3D).global_position.distance_to(p) < BLAST_R:
			pl.hurt.rpc_id(pl.get_multiplayer_authority(), int(Difficulty.get_value("swarm_blast")), p)
	for group in ["civilians", "robots"]:
		for n in get_tree().get_nodes_in_group(group):
			if n != self and n.has_method("apply_damage") and (n as Node3D).global_position.distance_to(p) < BLAST_R:
				n.apply_damage(BLAST_OTHERS, null)
	_check_gone()


## Server: a shot hit drone i.
func hit_unit(i: int, amount: int, attacker: Node3D) -> void:
	if not multiplayer.is_server() or (alive_mask >> i) & 1 == 0:
		return
	_hp[i] -= amount
	if _hp[i] > 0:
		return
	alive_mask &= ~(1 << i)
	shot_down.rpc(positions[i])
	if attacker and attacker.is_in_group("players"):
		killed_by_player = true
		killer_peer = attacker.get_multiplayer_authority()
		get_tree().current_scene.award(killer_peer, get_tree().current_scene.POINTS["swarm"], "swarm drone down")
	_check_gone()


func _check_gone() -> void:
	if alive_mask == 0:
		health = 0
		died.emit(self)
		get_tree().create_timer(3.0).timeout.connect(queue_free)


@rpc("authority", "call_local", "reliable")
func windup(i: int) -> void:
	var v: Node3D = _units[i]
	for ap in v.find_children("*", "AnimationPlayer", true, false):
		if (ap as AnimationPlayer).has_animation("explode_windup"):
			(ap as AnimationPlayer).play("explode_windup")
	Sfx.play_at("robot_fire", v.global_position, -6.0, 40.0)


@rpc("authority", "call_local", "reliable")
func boom(at: Vector3) -> void:
	Sfx.play_at("robot_death", at, 0.0, 70.0)
	var main := get_tree().current_scene
	if main.get("props"):
		main.props._sparks(at)


@rpc("authority", "call_local", "reliable")
func shot_down(at: Vector3) -> void:
	Sfx.play_at("robot_hit", at, -2.0, 50.0)
	var main := get_tree().current_scene
	if main.get("props"):
		main.props._sparks(at)


@rpc("authority", "call_local", "unreliable")
func glint(i: int) -> void:
	var l := Enemy.fx_light(Color(1.0, 0.15, 0.1), 3.0, 2.0)
	if l and i < _units.size():
		(_units[i] as Node3D).add_child(l)
		var tw := l.create_tween()
		tw.tween_property(l, "light_energy", 0.0, GLINT_S)
		tw.tween_callback(l.queue_free)


## Every peer: a gunner's bolt (the robots' bolt mesh, its glow the emission).
@rpc("authority", "call_local", "unreliable")
func bolt(from: Vector3, to: Vector3) -> void:
	Sfx.play_at("robot_fire", from, -9.0, 50.0)
	get_tree().call_group("pigeons", "scare", from)
	var b := MeshInstance3D.new()
	b.mesh = Enemy._bolt_mesh()
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(b)
	var dir := (to - from).normalized()
	b.global_position = from + dir * Enemy.BOLT_LENGTH / 2
	b.look_at(to, Vector3.UP if abs(dir.y) < 0.99 else Vector3.RIGHT)
	b.rotate_object_local(Vector3.RIGHT, PI / 2)
	var tw := b.create_tween()
	tw.tween_property(b, "global_position", to, max(from.distance_to(to) - Enemy.BOLT_LENGTH / 2, 0.1) / Enemy.BOLT_SPEED)
	tw.tween_callback(b.queue_free)
