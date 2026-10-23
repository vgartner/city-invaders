extends Node
## Autoplay: plays the local player by itself, for performance runs and for
## finding map problems (docs/DEVAGENT.md "Autoplay"). It presses the same
## keys a person would (Settings.virtual) and turns the body and head; it
## walks the people's navmesh, so buildings, trees and posts are walked round
## the way pedestrians and robots do. Started by the DevAgent (`autoplay`).
##
## Each think step picks one thing to do, by priority: fight a robot in sight
## (the best weapon it has; a Bergamota into a group, a Porongo at drones),
## heal when low, open a people container that has someone in it, trade at a
## repair shop when the parts allow it, now and then drive a car a while,
## take the nearest pickup it can use, else run to a far part of the map.
## Stuck (no progress while walking): a sidestep, then another goal, then a
## hop onto the navmesh - each one logged with where and what blocked it.

const Entities := preload("res://scripts/entities.gd")

var player: CharacterBody3D
var seconds := 600.0
var rng := RandomNumberGenerator.new()
var activity := "start"                 # read by the DevAgent's F5 recorder per frame
var events: Array = []                  # stuck spots, unreachable pickups, falls, deaths
var counts := {"robots_shot": 0, "pickups": 0, "grenades": 0, "drives": 0, "containers": 0, "trades": 0}
var done := false

var _t := 0.0
var _think_cd := 0.0
var _goal := Vector3.INF
var _goal_kind := ""
var _goal_node: Node = null
var _path := PackedVector3Array()
var _pi := 0
var _repath_cd := 0.0
var _target: Node3D = null
var _last_pos := Vector3.ZERO
var _still := 0.0
var _sidestep := 0.0
var _side_dir := 1.0
var _stucks_here := 0
var _reverse := 0.0                     # backing out of a wall in a car
var _car_stucks := 0
var _best_goal_d := INF                 # nearest it has come to the goal
var _goal_left := 0.0                   # time allowed to reach the goal
var _bad: Dictionary = {}               # pickups / spots it could not reach (instance id -> true)
var _drive_left := 0.0
var _drive_cd := 40.0
var _drive_goal := Vector3.INF
var _grenade_cd := 0.0


func _main() -> Node:
	return get_tree().current_scene


func _ready() -> void:
	_last_pos = player.global_position


func stop() -> void:
	done = true
	for a in ["forward", "back", "left", "right", "run", "fire", "jump"]:
		Settings.virtual.erase(a)


func _physics_process(delta: float) -> void:
	if done or not is_instance_valid(player):
		return
	_t += delta
	if _t >= seconds:
		stop()
		return
	_grenade_cd -= delta
	if player.dead:
		activity = "dead"
		_release_all()
		return
	if player.global_position.y < -15.0:
		_event("fell", "below the map")
		var map: RID = player.get_world_3d().navigation_map
		player.global_position = NavigationServer3D.map_get_closest_point(map, player.global_position) + Vector3(0, 0.5, 0)
		player.velocity = Vector3(0, 0, 0)
	if player.vehicle:
		_drive(delta)
		return
	_think_cd -= delta
	if _think_cd <= 0.0:
		_think_cd = 0.4
		_think()
	if is_instance_valid(_target) and _target.has_method("is_alive") and _target.is_alive():
		_fight(delta)
	else:
		Settings.virtual.erase("fire")
		_walk(delta)


# ---- deciding ----------------------------------------------------------------

func _think() -> void:
	var main := _main()
	_drive_cd -= 0.4
	if is_instance_valid(_target) and _target.has_method("is_alive") and not _target.is_alive():
		counts["robots_shot"] += 1      # the one it was fighting went down
	_target = _robot_in_sight(45.0)
	if _target:
		activity = "fight"
		_pick_weapon(_target)
		return
	if player.health < 45:
		var heal := _nearest_pickup(func(k): return Entities.get_def(k).get("category", "") == "healing" or k in ["medkit", "churrasco", "chimarrao", "remedio"])
		if heal:
			_set_goal(heal.global_position, "heal", heal)
			return
	if _goal_kind in ["pickup", "heal"] and (not is_instance_valid(_goal_node) or not _goal_node.active):
		if is_instance_valid(_goal_node) and _goal_node.global_position.distance_to(player.global_position) < 3.0 \
				or not is_instance_valid(_goal_node):
			counts["pickups"] += 1      # taken (by it, or freed as it walked in)
		_goal = Vector3.INF
		_goal_kind = ""
	_goal_left -= 0.4
	if _goal != Vector3.INF and _goal_left <= 0.0:
		# walking round and round: the way there is longer than the navmesh says, or it can't get on it
		if _goal_node:
			_bad[_goal_node.get_instance_id()] = true
		_event("slow_goal", "%s at %s" % [_goal_kind, _v(_goal)])
		_goal = Vector3.INF
		_goal_kind = ""
	# people to free come before anything but a fight
	if _goal_kind != "container":
		for c in main.get("_containers") if main.get("_containers") != null else []:
			if is_instance_valid(c) and not c.people.is_empty() and not c.lifting \
					and c.global_position.distance_to(player.global_position) < 120.0 and not _bad.has(c.get_instance_id()):
				_set_goal(c.global_position, "container", c)
				return
	if _goal_kind in ["pickup", "heal", "container", "shop", "car"] and is_instance_valid(_goal_node) and _goal != Vector3.INF:
		if _goal_kind == "car":
			if _goal_node.driver_peer != 0:
				_goal = Vector3.INF         # someone else took it
			else:
				_goal = (_goal_node as Node3D).global_position     # traffic drives on
		return                          # keep at it
	if player._can_trade() and main.props and not main.props.shops.is_empty():
		var best := Vector3.INF
		for at in main.props.shops:
			if best == Vector3.INF or (at as Vector3).distance_to(player.global_position) < best.distance_to(player.global_position):
				best = at
		if best.distance_to(player.global_position) < 250.0:
			_set_goal(best, "shop", main)
			return
	if _drive_cd <= 0.0:
		var car := _free_car(70.0)
		if car:
			_drive_cd = rng.randf_range(50.0, 90.0)
			_set_goal(car.global_position, "car", car)
			return
	var pk := _nearest_pickup(func(k): return player.can_take(k))
	if pk:
		_set_goal(pk.global_position, "pickup", pk)
		return
	if _goal == Vector3.INF or _goal_kind != "roam":
		var map: RID = player.get_world_3d().navigation_map
		for k in 12:
			var p := NavigationServer3D.map_get_random_point(map, 1, false)
			if p.distance_to(player.global_position) > 80.0 and main.in_bounds(p, 10.0):
				_set_goal(p, "roam", null)
				break


func _set_goal(p: Vector3, kind: String, node: Node) -> void:
	if p.distance_to(_goal) < 0.5 and kind == _goal_kind:
		return
	_goal = p
	_goal_kind = kind
	_goal_node = node
	_best_goal_d = INF
	_goal_left = p.distance_to(player.global_position) / 3.0 + 15.0      # it runs at ~6 m/s
	_repath_cd = 0.0
	activity = {"pickup": "pickup", "heal": "pickup", "container": "container", "shop": "shop", "car": "to_car"}.get(kind, "walk")


func _nearest_pickup(ok: Callable) -> Node3D:
	var best: Node3D = null
	var bd := 120.0
	for p in _main().pickups_root.get_children():
		if not p.active or _bad.has(p.get_instance_id()) or not ok.call(p.kind):
			continue
		var d := (p as Node3D).global_position.distance_to(player.global_position)
		if d < bd:
			bd = d
			best = p
	return best


func _free_car(r: float) -> Node3D:
	for v in _main().traffic_root.get_children():
		if v.kind in ["car", "lorry", "truck", "harvester"] and v.driver_peer == 0 and not v.get("_wrecked") \
				and (v as Node3D).global_position.distance_to(player.global_position) < r and not _bad.has(v.get_instance_id()):
			return v
	return null


# ---- walking -----------------------------------------------------------------

func _walk(delta: float) -> void:
	if _goal == Vector3.INF:
		_release_all()
		return
	_repath_cd -= delta
	if _repath_cd <= 0.0 or _pi >= _path.size():
		_repath_cd = 1.5
		var map: RID = player.get_world_3d().navigation_map
		_path = NavigationServer3D.map_get_path(map, player.global_position, _goal, true)
		_pi = 1
		if _path.size() < 2 or _path[_path.size() - 1].distance_to(_goal) > 2.5:
			if _goal_node:
				_bad[_goal_node.get_instance_id()] = true
				_event("unreachable", "%s at %s" % [_goal_kind, _v(_goal)])
			_goal = Vector3.INF
			return
	var here := player.global_position
	# a car's or a container's middle is inside it: close enough is beside it
	if Vector2(_goal.x - here.x, _goal.z - here.z).length() < {"car": 4.0, "container": 2.6, "pickup": 0.5, "heal": 0.5}.get(_goal_kind, 1.6):
		_arrived()
		return
	while _pi < _path.size() - 1 and Vector2(_path[_pi].x - here.x, _path[_pi].z - here.z).length() < 1.5:
		_pi += 1
	var next := _path[min(_pi, _path.size() - 1)]
	var err := _face(next, 0.0, delta)
	# running (9 m/s, more on adrenaline) it circles a point it can't turn onto:
	# a sharp turn is made on the spot, and the last metres to a goal at a walk
	if err > 0.7:
		Settings.virtual.erase("forward")
	else:
		Settings.virtual["forward"] = true
	if Vector2(_goal.x - here.x, _goal.z - here.z).length() < 4.0:
		Settings.virtual.erase("run")
	else:
		Settings.virtual["run"] = true
	if _sidestep > 0.0:
		_sidestep -= delta
		Settings.virtual["left" if _side_dir < 0 else "right"] = true
	else:
		Settings.virtual.erase("left")
		Settings.virtual.erase("right")
	_check_stuck(delta)


func _arrived() -> void:
	var main := _main()
	match _goal_kind:
		"container":
			if is_instance_valid(_goal_node):
				main.open_container.rpc_id(1, _goal_node.get_path())
				counts["containers"] += 1
		"shop":
			if player._near_shop:
				for offer in player.SHOP:
					var ok := true
					for k in offer[1]:
						if player.parts.get(k, 0) < offer[1][k]:
							ok = false
					if ok:
						player._open_shop()
						player._buy(offer)
						player._close_shop()
						counts["trades"] += 1
						break
		"car":
			if is_instance_valid(_goal_node) and _goal_node.driver_peer == 0:
				player.request_vehicle.rpc_id(1, str(_goal_node.name))
				_drive_left = rng.randf_range(25.0, 45.0)
				_drive_goal = Vector3.INF
				counts["drives"] += 1
		"pickup", "heal":
			if is_instance_valid(_goal_node) and _goal_node.active:
				# stood on it and it is still there: out of reach (up on something, or refused)
				_bad[_goal_node.get_instance_id()] = true
				_event("pickup_not_taken", "%s at %s" % [_goal_node.kind, _v(_goal)])
	_goal = Vector3.INF
	_goal_kind = ""
	_goal_node = null
	_release_all()


func _check_stuck(delta: float) -> void:
	var here := player.global_position
	# only getting nearer the goal clears the stucks: a step aside and back is no way out
	var dg := Vector2(_goal.x - here.x, _goal.z - here.z).length() if _goal != Vector3.INF else 0.0
	if dg < _best_goal_d - 2.0:
		_best_goal_d = dg
		_stucks_here = 0
	if Vector2(here.x - _last_pos.x, here.z - _last_pos.z).length() > 0.6:
		_last_pos = here
		_still = 0.0
		return
	_still += delta
	if _still < 1.5:
		return
	_still = 0.0
	_stucks_here += 1
	var fwd := -player.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(here + Vector3(0, 0.8, 0), here + Vector3(0, 0.8, 0) + fwd * 1.5, 1 | 16 | 32)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	var what := String(hit.collider.name) if hit else "nothing in front"
	if hit and hit.collider.get_parent():
		what += " (%s)" % hit.collider.get_parent().name
	_event("stuck", "%s, going to %s %s" % [what, _goal_kind, _v(_goal)])
	activity = "stuck"
	if _stucks_here == 1:
		_sidestep = 0.7                 # a step aside
		_side_dir = -_side_dir
	elif _stucks_here == 2:
		_repath_cd = 0.0
		if _goal_node:
			_bad[_goal_node.get_instance_id()] = true
		_goal = Vector3.INF             # another goal
	else:
		var map: RID = player.get_world_3d().navigation_map
		var p := NavigationServer3D.map_get_closest_point(map, here + fwd * -1.5 + Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)))
		player.global_position = p + Vector3(0, 0.2, 0)      # hopped onto the walkable mesh
		_stucks_here = 0


# ---- fighting ----------------------------------------------------------------

func _robot_in_sight(r: float) -> Node3D:
	var best: Node3D = null
	var bd := r
	var eye: Vector3 = player.camera.global_position
	for e in _main().enemies_root.get_children():
		if e.get("variant") == "swarm" or not e.has_method("is_alive") or not e.is_alive():
			continue
		var d := (e as Node3D).global_position.distance_to(player.global_position)
		if d >= bd:
			continue
		var q := PhysicsRayQueryParameters3D.create(eye, (e as Node3D).global_position + Vector3(0, 1.2, 0), 1)
		if player.get_world_3d().direct_space_state.intersect_ray(q):
			continue                    # behind a wall
		bd = d
		best = e
	return best


func _pick_weapon(e: Node3D) -> void:
	var d := e.global_position.distance_to(player.global_position)
	var order := ["canhao", "machinegun", "shotgun", "revolver", "pistol", "espeto"] if e.get("variant") == "mech" \
			else (["shotgun", "machinegun", "revolver", "pistol", "espeto"] if d < 8.0 else ["machinegun", "revolver", "pistol", "shotgun", "espeto"])
	for w in order:
		if w in player.owned and (player.WEAPONS[w].get("melee", false) or player._mags.get(w, 0) + player._reserves.get(w, 0) > 0):
			if player.weapon != w:
				player._switch(w)
			return


func _fight(delta: float) -> void:
	activity = "fight"
	Settings.virtual.erase("left")
	Settings.virtual.erase("right")
	var at := _target.global_position + Vector3(0, 1.1 if _target.get("variant") != "mech" else 2.4, 0)
	var d := at.distance_to(player.global_position)
	var err := _face(at, 1.0, delta)
	# close in when far or with a blade; else hold the ground and shoot
	if d > 28.0 or (player.WEAPONS[player.weapon].get("melee", false) and d > 2.0) or player.WEAPONS[player.weapon].get("unarmed", false):
		Settings.virtual["forward"] = true
		Settings.virtual["run"] = true
		_check_stuck(delta)
	else:
		Settings.virtual.erase("forward")
		Settings.virtual.erase("run")
		_last_pos = player.global_position
	if err < 0.06:
		Settings.virtual["fire"] = true
	else:
		Settings.virtual.erase("fire")
	_grenades(at)
	if _target.has_method("is_alive") and not _target.is_alive():
		counts["robots_shot"] += 1
		_target = null


func _grenades(at: Vector3) -> void:
	if _grenade_cd > 0.0:
		return
	var d := at.distance_to(player.global_position)
	if d < 9.0 or d > 20.0:
		return
	var near := 0
	var drones := 0
	for e in _main().enemies_root.get_children():
		if e.has_method("is_alive") and e.is_alive() and (e as Node3D).global_position.distance_to(at) < 7.0:
			near += 1
			if e.get("variant") in ["drone", "swarm"]:
				drones += 1
	var kind := ""
	if drones > 0 and player.grenades["porongo"] > 0:
		kind = "porongo"
	elif (near >= 2 or _target.get("variant") == "mech") and player.grenades["bergamota"] > 0:
		kind = "bergamota"
	if kind == "":
		return
	player.grenade = kind
	player._grenade_cd = 0.0
	player._throw_grenade()
	counts["grenades"] += 1
	_grenade_cd = 6.0


# ---- driving -----------------------------------------------------------------

func _drive(delta: float) -> void:
	activity = "drive"
	var car: Node3D = player.vehicle
	_drive_left -= delta
	if _drive_left <= 0.0:
		_release_all()
		player._use_vehicle()           # out
		return
	var here := car.global_position
	if _drive_goal == Vector3.INF or Vector2(_drive_goal.x - here.x, _drive_goal.z - here.z).length() < 6.0:
		var map: RID = car.get_world_3d().navigation_map
		for k in 12:
			var p := NavigationServer3D.map_get_random_point(map, 1, false)
			if p.distance_to(here) > 90.0 and _main().in_bounds(p, 15.0):
				_drive_goal = p
				_path = NavigationServer3D.map_get_path(map, here, p, true)
				_pi = 1
				break
	while _pi < _path.size() - 1 and Vector2(_path[_pi].x - here.x, _path[_pi].z - here.z).length() < 5.0:
		_pi += 1
	if _path.size() < 2:
		_drive_goal = Vector3.INF
		return
	var next := _path[min(_pi, _path.size() - 1)]
	var fwd := -car.global_transform.basis.z
	var to := Vector3(next.x - here.x, 0, next.z - here.z).normalized()
	var turn := fwd.signed_angle_to(to, Vector3.UP)
	Settings.virtual["forward"] = true
	Settings.virtual.erase("back")
	Settings.virtual.erase("left")
	Settings.virtual.erase("right")
	if turn > 0.12:
		Settings.virtual["left"] = true
	elif turn < -0.12:
		Settings.virtual["right"] = true
	if absf(turn) > 1.4:
		Settings.virtual.erase("forward")
		Settings.virtual["back"] = true     # a hard turn: back and round
	# a wall: back out a bit and pick another way
	if _reverse > 0.0:
		_reverse -= delta
		Settings.virtual.erase("forward")
		Settings.virtual["back"] = true
		Settings.virtual.erase("left" if turn > 0.0 else "right")
		Settings.virtual["right" if turn > 0.0 else "left"] = true      # backing, the wheels the other way
		return
	var speed: float = absf(float(car.get("_speed")))
	if speed < 0.5:
		_still += delta
		if _still > 2.5:
			_still = 0.0
			_car_stucks += 1
			_event("car_stuck", "%s at %s" % [car.kind, _v(here)])
			if _car_stucks >= 3:
				_car_stucks = 0
				_drive_left = 0.0       # give up on this car
			else:
				_reverse = 1.5
				_drive_goal = Vector3.INF
	else:
		_still = 0.0
		if speed > 4.0:
			_car_stucks = 0


# ---- helpers -----------------------------------------------------------------

## Turn body and head towards `p`; the angle left to turn (radians).
func _face(p: Vector3, pitch_weight: float, delta: float) -> float:
	var to: Vector3 = p - player.camera.global_position
	var yaw_err := (-player.global_transform.basis.z).signed_angle_to(Vector3(to.x, 0, to.z).normalized(), Vector3.UP)
	player.rotate_y(clampf(yaw_err, -10.0 * delta, 10.0 * delta))
	var want_pitch := atan2(to.y, Vector2(to.x, to.z).length()) * pitch_weight
	player.pitch = lerpf(player.pitch, clampf(want_pitch, -1.4, 1.4), minf(1.0, delta * 8.0))
	player.head.rotation.x = player.pitch
	return absf(yaw_err) + absf(want_pitch - player.pitch)


func _release_all() -> void:
	for a in ["forward", "back", "left", "right", "run", "fire"]:
		Settings.virtual.erase(a)


func _event(kind: String, what: String) -> void:
	events.append({"t": snappedf(_t, 0.1), "kind": kind, "what": what, "pos": _v(player.global_position)})


func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.1), snappedf(p.y, 0.1), snappedf(p.z, 0.1)]
