extends Node3D
## A pigeon of a square's flock. Purely visual and local to every peer: it
## pecks and wanders around its spot, and when a shot goes off nearby or
## someone walks right up to it, it takes off, flies to another square and
## lands there. Main scatters flocks on the promenade/plaza points.

const Library := preload("res://scripts/model_library.gd")
static var MODELS: PackedStringArray = Library._list("res://assets/common/pigeons")
## quero-queros (southern lapwings) share the behaviour: they live in pairs on
## the lawns, put on their alarm display when someone comes near and only
## take off, low, when that someone keeps coming
static var QUERO_MODELS: PackedStringArray = Library._list("res://assets/rio_grande_do_sul/birds")
var quero := false
const Entities := preload("res://scripts/entities.gd")
## a quero-quero's numbers come from its definition (quero_quero.def.json,
## docs/ENTITIES.md): alarm_m - closer than this, the alarm display and a
## feint forward; charge_m - closer still, it runs at the intruder (run m/s)
## and pecks (peck damage every peck_s); give_up_s / patch_m - it lets go
## after that long or once the intruder is that far from its patch;
## health; run_over_mps - a vehicle faster than that over it kills it
static func quero_def() -> Dictionary:
	var d := Entities.get_def("quero_quero")
	return d if not d.is_empty() else {"health": 30, "pairs": 5}
var health := 0
var _q := {}
var _alarm_cd := 0.0
var _foe: Node3D                 # who it is chasing off
var _peck_cd := 0.0
const WALK := 0.35
const FLY := 7.0
const CRUISE := 9.0             # metres above the ground while flying
const SCARE_RADIUS := 22.0

enum State { GROUND, TAKEOFF, FLY, LAND, CHARGE, DEAD }
const LAYER := 256              # a quero-quero's body: only the player's shots look for it

var home := Vector3.ZERO        # flock spot it pecks around
var landing_spots: Array = []   # other squares to fly to (Vector3, on the ground)
var state := State.GROUND
var _anim: AnimationPlayer
var _goal := Vector3.ZERO
var _cd := 0.0
var _t := 0.0


func _ready() -> void:
	add_to_group("pigeons")
	if quero:
		_q = quero_def()
		health = int(_q.get("health", 30))
		# something to hit: a small sphere no one walks into (not on the world layer)
		var body := StaticBody3D.new()
		body.collision_layer = LAYER
		body.collision_mask = 0
		body.set_meta("bird", self)
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.28
		cs.shape = sph
		cs.position.y = 0.28
		body.add_child(cs)
		add_child(body)
	var models: PackedStringArray = QUERO_MODELS if quero else MODELS
	if models.is_empty():
		return
	var model: Node3D = (load(models[randi() % models.size()]) as PackedScene).instantiate()
	add_child(model)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = 70.0
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var players := model.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		_anim = players[0]
		for c in ["idle", "walk", "run", "peck", "fly"]:
			if _anim.has_animation(c):
				_anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
		_anim.play("idle")
		_anim.seek(randf() * 2.0)
	rotation.y = randf() * TAU
	_cd = randf_range(0.5, 3.0)


## A gunshot / explosion at `at`: everyone in range flies off.
func scare(at: Vector3) -> void:
	if quero:
		return                     # gunfire doesn't move a quero-quero off its patch
	if state == State.GROUND and global_position.distance_to(at) < SCARE_RADIUS:
		_take_off(at)


func _take_off(from: Vector3, heading := Vector3.ZERO) -> void:
	state = State.TAKEOFF
	_t = 0.0
	_play("takeoff")
	var away := global_position - from
	away.y = 0
	# someone walking through the flock: the birds go off ahead of them
	if heading.length() > 0.5:
		away = away.normalized() + Vector3(heading.x, 0, heading.z).normalized() * 1.5
	# fly to the landing spot farthest along the escape direction
	var best := home + away.normalized() * 30.0
	var best_score := -INF
	for s in landing_spots:
		var to: Vector3 = s - global_position
		var score: float = to.normalized().dot(away.normalized()) * 2.0 - to.length() / 120.0
		if to.length() > 25.0 and to.normalized().dot(away.normalized()) > 0.3 and score > best_score:
			best_score = score
			best = s
	_goal = best + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))


func _play(clip: String) -> void:
	if _anim and _anim.has_animation(clip) and _anim.current_animation != clip:
		_anim.play(clip, 0.15)


func _process(delta: float) -> void:
	_t += delta
	if state == State.DEAD:
		return
	if quero and state in [State.GROUND, State.CHARGE] and fmod(_t, 0.2) < delta:
		_run_over()
	if state == State.GROUND or state == State.CHARGE:
		_stick_to_ground(delta)
	match state:
		State.GROUND:
			_cd -= delta
			if _cd <= 0:
				_cd = randf_range(1.0, 4.0)
				var r := randf()
				if r < 0.45:
					_play("peck")
				elif r < 0.8:
					_play("idle")
				else:
					_goal = home + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))
					_play("walk")
			if _anim and _anim.current_animation == "walk":
				var to := _goal - global_position
				to.y = 0
				if to.length() < 0.1:
					_play("idle")
				else:
					global_position += to.normalized() * min(WALK * delta, to.length())
					rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), min(1.0, delta * 6.0))
			# people walking right up to it
			_alarm_cd -= delta
			if fmod(_t, 0.5) < delta:
				for p in get_tree().get_nodes_in_group("players") + get_tree().get_nodes_in_group("robots"):
					var n := p as Node3D
					var d := n.global_position.distance_to(global_position)
					if quero and d < float(_q.get("charge_m", 4.0)):
						_foe = n                  # it kept coming: attack
						state = State.CHARGE
						_t = 0.0
						_play("run")
						Sfx.play_at("quero_quero", global_position + Vector3(0, 0.3, 0), 0.0, 50.0)
						break
					if quero and d < float(_q.get("alarm_m", 8.0)):
						# face the intruder, wings half open, calling, a feint forward
						var to := n.global_position - global_position
						rotation.y = atan2(-to.x, -to.z)
						if _alarm_cd <= 0:
							_alarm_cd = 2.5
							_play("alarm")
							global_position += to.normalized() * 0.4
							Sfx.play_at("quero_quero", global_position + Vector3(0, 0.3, 0), -2.0, 50.0)
						break
					if not quero and d < Tune.pigeon_spook_m:
						var v: Vector3 = n.get("velocity") if n.get("velocity") != null else Vector3.ZERO
						_take_off(n.global_position, v)
						break
		State.CHARGE:
			_charge(delta)
		State.TAKEOFF:
			if _t > 0.5:
				state = State.FLY
				_play("fly")
		State.FLY:
			var to := _goal - global_position
			var flat := Vector3(to.x, 0, to.z)
			var dist := flat.length()
			# climb to cruise height, glide down over the last stretch
			var cruise: float = float(_q.get("cruise_m", 4.0)) if quero else CRUISE      # quero-queros keep low over the lawn
			var want_y: float = _goal.y + (cruise if dist > 15.0 else dist / 15.0 * cruise)
			global_position.y = move_toward(global_position.y, want_y, 4.0 * delta)
			global_position += flat.normalized() * min(FLY * delta, dist)
			rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), min(1.0, delta * 4.0))
			if dist < 0.5:
				state = State.LAND
				_t = 0.0
				_play("land")
		State.LAND:
			global_position.y = move_toward(global_position.y, _goal.y, 2.0 * delta)
			if _t > 0.6:
				global_position.y = _goal.y
				home = _goal
				state = State.GROUND
				_play("idle")


## On foot the bird follows the ground (lawns slope: walking or running off
## its spot it would sink into the hill or float above it).
var _ground_cd := 0.0
var _ground_y := INF
func _stick_to_ground(delta: float) -> void:
	_ground_cd -= delta
	if _ground_cd <= 0:
		_ground_cd = 0.15
		# the fixed ground only: something moving through the flock (a wreck's
		# piece, a knocked-over prop) lifted the birds onto it, and once it had
		# gone the ray found nothing and they walked on 6 m up in the air
		var space := get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.5, 0), global_position - Vector3(0, 3.0, 0), 1)
		var hit := space.intersect_ray(q)
		if hit and not hit.collider is StaticBody3D:
			q.exclude = [hit.rid]
			hit = space.intersect_ray(q)
		if not hit:
			q = PhysicsRayQueryParameters3D.create(global_position, global_position - Vector3(0, 60.0, 0), 1)
			hit = space.intersect_ray(q)
		if hit and hit.collider is StaticBody3D:
			_ground_y = hit.position.y
	if _ground_y != INF:
		global_position.y = move_toward(global_position.y, _ground_y, 3.0 * delta) if abs(global_position.y - _ground_y) < 1.0 else _ground_y


## Quero-quero defending its patch: run at the intruder, peck when in reach,
## give up once they are well away from the nest (or after a while).
func _charge(delta: float) -> void:
	_peck_cd -= delta
	if not is_instance_valid(_foe) or _t > float(_q.get("give_up_s", 8.0)) \
			or _foe.global_position.distance_to(home) > float(_q.get("patch_m", 14.0)) \
			or (_foe.has_method("is_alive") and not _foe.is_alive()) or _foe.get("dead") == true:
		_foe = null
		state = State.GROUND
		_goal = home
		_play("walk")
		_alarm_cd = 3.0
		return
	var to := _foe.global_position - global_position
	to.y = 0
	rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), min(1.0, delta * 10.0))
	if to.length() > 0.8:
		global_position += to.normalized() * min(float(_q.get("run", 3.2)) * delta, to.length() - 0.7)
		_play("run")
		return
	if _peck_cd <= 0:
		_peck_cd = float(_q.get("peck_s", 1.5))
		_play("alarm")
		Sfx.play_at("quero_quero", global_position + Vector3(0, 0.3, 0), 0.0, 50.0)
		# every peer runs its own birds: each hurts its own player, the server the robots
		if _foe.is_in_group("players") and _foe.is_multiplayer_authority():
			_foe.hurt(int(_q.get("peck", 4)), global_position)
		elif _foe.is_in_group("robots") and multiplayer.is_server():
			_foe.apply_damage(int(_q.get("peck", 4)), null)



## A quero-quero shot (the player's bullet, on the shooter's peer - birds are
## local to every peer) or caught in a blast: wounded it flies off low,
## calling, to another lawn; at no health left it falls.
func apply_damage(amount: int, _by: Node = null) -> void:
	if not quero or state == State.DEAD:
		return
	health -= amount
	Sfx.play_at("quero_quero", global_position + Vector3(0, 0.3, 0), 2.0, 60.0)
	if health <= 0:
		_die()
		return
	_foe = null
	var from: Vector3 = _by.global_position if _by is Node3D else global_position - Vector3(0, 0, 1)
	_take_off(from)


func _die() -> void:
	state = State.DEAD
	_foe = null
	if _anim:
		_anim.pause()
	for c in get_children():
		if c is StaticBody3D:
			c.queue_free()
	var y := _ground_y if _ground_y != INF else global_position.y
	var tw := create_tween().set_parallel()
	tw.tween_property(self, "global_position:y", y, 0.4)
	tw.tween_property(self, "rotation:z", PI / 2, 0.4)
	get_tree().create_timer(float(_q.get("corpse_s", 12.0))).timeout.connect(queue_free)


## A car, bus or motorbike driving over it (traffic is the same on every peer).
func _run_over() -> void:
	var main := get_tree().current_scene
	if main == null or not "traffic_root" in main:
		return
	var fast := float(_q.get("run_over_mps", 3.0))
	for v in main.traffic_root.get_children():
		var car := v as Node3D
		if car == null or absf(float(car.get("_speed") if car.get("_speed") != null else 0.0)) < fast:
			continue
		if car.global_position.distance_to(global_position) > 8.0:
			continue
		var local := car.to_local(global_position)
		var size: Vector3 = car._box.size if car.get("_box") is BoxShape3D else Vector3(2.0, 1.5, 4.4)
		var c: Vector3 = car.get("_box_centre") if car.get("_box_centre") != null else Vector3.ZERO
		if absf(local.x - c.x) < size.x * 0.5 + 0.1 and absf(local.z - c.z) < size.z * 0.5 + 0.1:
			_die()
			return
