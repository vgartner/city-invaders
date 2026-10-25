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
var counts := {"robots_shot": 0, "pickups": 0, "grenades": 0, "drives": 0, "containers": 0, "trades": 0, "shots": 0, "reloads": 0}
var done := false
var finish_reason := ""
var attempts := {"drives": 0, "grenades": 0}
var metrics := preload("res://scripts/autoplay_metrics.gd").new()
var _observed_vehicle_id := 0
var _observed_reload := false

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
var _rev_still := 0.0                   # backing into something too: pull forward instead
var _pull := 0.0
var _queue := 0.0                       # behind a stopped vehicle this long
var _overtake := 0.0                    # passing it in the other lane
var _ahead_cd := 0.0
var _ahead := false
var _box: BoxShape3D                    # the look ahead for a vehicle in the way
var _hp_seen := -1.0                    # the target's health when it last went down
var _no_hit := 0.0                      # shooting this long without hurting it
var _watched_target := 0
var _blocked_targets: Dictionary = {}   # temporarily skip enemies that took no damage
var _combat_shots_start := 0
var _observed_weapon := ""
var _observed_mag := 0
var _press := false                     # missing from here: go in close
var _car_stucks := 0
var _best_goal_d := INF                 # nearest it has come to the goal
var _goal_left := 0.0                   # time allowed to reach the goal
var _bad_shops: Dictionary = {}         # shop position -> true (shops share the main node)
var _bad: Dictionary = {}               # pickups / spots it could not reach (instance id -> true)
var _drive_left := 0.0
var drive_every := 70.0                 # seconds between drives, on average
var _drive_cd := 40.0
var _drive_goal := Vector3.INF
var _grenade_cd := 0.0


func _main() -> Node:
	return get_tree().current_scene


func _ready() -> void:
	_last_pos = player.global_position
	var vehicle: Node3D = player.get("vehicle")
	_observed_vehicle_id = vehicle.get_instance_id() if is_instance_valid(vehicle) else 0
	metrics.reset(vehicle.global_position if is_instance_valid(vehicle) else player.global_position, is_instance_valid(vehicle))


func stop(reason := "manual_stop") -> void:
	finish_reason = reason
	done = true
	for a in ["forward", "back", "left", "right", "run", "fire", "jump"]:
		Settings.virtual.erase(a)


func _physics_process(delta: float) -> void:
	if done:
		return
	if not is_instance_valid(player):
		stop("player_missing")
		return
	_observe_shots()
	var driving := is_instance_valid(player.vehicle)
	metrics.sample(player.vehicle.global_position if driving else player.global_position,
			driving, delta, activity, player.weapon)
	_t += delta
	if _t >= seconds:
		stop("duration_reached")
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
		metrics.relocate(player.global_position, false)
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
		_mark_goal_bad()
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
			if _bad_shops.has(at):
				continue
			if best == Vector3.INF or (at as Vector3).distance_to(player.global_position) < best.distance_to(player.global_position):
				best = at
		if best.distance_to(player.global_position) < 250.0:
			_set_goal(best, "shop", main)
			return
	if _drive_cd <= 0.0:
		var car := _free_car(70.0)
		if car:
			_drive_cd = rng.randf_range(0.7, 1.3) * drive_every
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
	activity = _goal_activity()


func _goal_activity() -> String:
	return {"pickup": "pickup", "heal": "pickup", "container": "container", "shop": "shop", "car": "to_car"}.get(_goal_kind, "walk")


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
			_mark_goal_bad()
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
			if is_instance_valid(_goal_node) and _goal_node.driver_peer == 0 and not _goal_node.get("_wrecked"):
				attempts["drives"] += 1
				player.request_vehicle.rpc_id(1, str(_goal_node.name))
				_drive_left = rng.randf_range(25.0, 45.0)
				_drive_goal = Vector3.INF
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
		# A newly selected goal starts at INF: selecting it is not progress.
		if is_finite(_best_goal_d):
			_stucks_here = 0
		_best_goal_d = dg
	if Vector2(here.x - _last_pos.x, here.z - _last_pos.z).length() > 0.6:
		_last_pos = here
		_still = 0.0
		if activity == "stuck" and _sidestep <= 0.0:
			activity = "fight" if is_instance_valid(_target) else _goal_activity()
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
		_mark_goal_bad()
		_goal = Vector3.INF             # another goal
	else:
		_recover_to_navmesh()


func _mark_goal_bad() -> void:
	if _goal_kind == "shop":
		_bad_shops[_goal] = true
	elif is_instance_valid(_goal_node):
		_bad[_goal_node.get_instance_id()] = true


## Last resort for the test bot only. A navmesh point can be too close to a
## wall for the player's capsule even if a pedestrian route reaches it.
func _recover_to_navmesh() -> void:
	var collider: CollisionShape3D = null
	for child in player.get_children():
		if child is CollisionShape3D and not child.disabled:
			collider = child
			break
	if collider == null:
		return
	var here := player.global_position
	var map: RID = player.get_world_3d().navigation_map
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collider.shape
	query.collision_mask = player.collision_mask
	query.exclude = [player.get_rid()]
	query.margin = 0.02
	for radius in [2.0, 4.0, 8.0]:
		for k in 8:
			var angle := player.rotation.y + PI + k * TAU / 8.0
			var sample: Vector3 = here + Vector3(sin(angle), 0, cos(angle)) * float(radius)
			var point := NavigationServer3D.map_get_closest_point(map, sample)
			if point.distance_to(here) < 1.0 or absf(point.y - here.y) > 3.0:
				continue
			var target := point + Vector3(0, 0.1, 0)
			query.transform = Transform3D(player.global_basis, target) * collider.transform
			if not space.intersect_shape(query, 1).is_empty():
				continue
			_event("nav_recovery", "from %s to %s after %d stuck attempts" % [_v(here), _v(target), _stucks_here])
			player.global_position = target
			metrics.relocate(target, false)
			player.velocity = Vector3.ZERO
			_last_pos = target
			_still = 0.0
			_stucks_here = 0
			_sidestep = 0.0
			_repath_cd = 0.0
			activity = _goal_activity()
			_release_all()
			return
	_event("recovery_blocked", "no free capsule placement within 8 m")


# ---- fighting ----------------------------------------------------------------

func _combat_targets() -> Array:
	var targets: Array = []
	for enemy in _main().enemies_root.get_children():
		if enemy.has_method("combat_targets"):
			targets.append_array(enemy.combat_targets())
		else:
			targets.append(enemy)
	return targets


func _aim_point(enemy: Node3D) -> Vector3:
	if enemy.has_method("aim_position"):
		return enemy.aim_position()
	return enemy.global_position + Vector3(0, 2.4 if enemy.get("variant") == "mech" else 1.1, 0)


func _robot_in_sight(r: float) -> Node3D:
	var best: Node3D = null
	var bd := r
	var eye: Vector3 = player.camera.global_position
	for e in _combat_targets():
		if not e.has_method("is_alive") or not e.is_alive():
			continue
		var id: int = e.get_instance_id()
		if float(_blocked_targets.get(id, 0.0)) > _t:
			continue
		_blocked_targets.erase(id)
		var d := (e as Node3D).global_position.distance_to(player.global_position)
		if d >= bd:
			continue
		var q := PhysicsRayQueryParameters3D.create(eye, _aim_point(e), 1 | 64)
		if player.get_world_3d().direct_space_state.intersect_ray(q):
			continue                    # behind a wall or roof
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


func _observe_shots() -> void:
	# Observe real ammunition consumption, rather than attempted trigger presses.
	var weapon: String = player.weapon
	var mag: int = player._mags.get(weapon, 0)
	if weapon == _observed_weapon and _observed_reload and player._reload_left <= 0 and mag > _observed_mag:
		counts["reloads"] += 1
	_observed_reload = player._reload_left > 0
	var vehicle_id: int = player.vehicle.get_instance_id() if is_instance_valid(player.vehicle) else 0
	if vehicle_id != 0 and vehicle_id != _observed_vehicle_id and not player.vehicle.get("_wrecked") \
			and player.vehicle.driver_peer == player.get_multiplayer_authority():
		counts["drives"] += 1
	_observed_vehicle_id = vehicle_id
	if weapon == _observed_weapon and mag < _observed_mag:
		counts["shots"] += _observed_mag - mag
	_observed_weapon = weapon
	_observed_mag = mag


func _fight(delta: float) -> void:
	var id := _target.get_instance_id()
	if id != _watched_target:
		_watched_target = id
		_hp_seen = -1.0
		_no_hit = 0.0
		_press = false
		_combat_shots_start = counts["shots"]
	activity = "fight"
	Settings.virtual.erase("left")
	Settings.virtual.erase("right")
	var at := _aim_point(_target)
	var d := at.distance_to(player.global_position)
	var err := _face(at, 1.0, delta)
	# missing at range (a moving Coletor, a drone up high): after 5 s without
	# a hit, go in close
	var hp: float = float(_target.get("health")) if _target.get("health") != null else -1.0
	if hp != _hp_seen:
		_hp_seen = hp
		_no_hit = 0.0
		_press = false
	else:
		_no_hit += delta
		if _no_hit > 5.0:
			_press = true
	if _no_hit >= 15.0:
		_event("combat_stalled", "target=%s weapon=%s ammo=%d/%d hp=%.1f shots=%d no_damage=%.1fs" % [
			_target.name, player.weapon, player.ammo, player.reserve, hp,
			counts["shots"] - _combat_shots_start, _no_hit])
		_blocked_targets[id] = _t + 30.0
		_target = null
		_watched_target = 0
		_think_cd = 0.0
		_release_all()
		return
	if d > 28.0 or (_press and d > 7.0) or (player.WEAPONS[player.weapon].get("melee", false) and d > 2.0) or player.WEAPONS[player.weapon].get("unarmed", false):
		Settings.virtual["forward"] = true
		Settings.virtual["run"] = true
		_check_stuck(delta)
	else:
		Settings.virtual.erase("forward")
		Settings.virtual.erase("run")
		_last_pos = player.global_position
	# Semi-auto weapons require a new trigger edge. Holding fire forever
	# fires once, then stalls even with a full magazine after reloading.
	var trigger_ready: bool = player._fire_cd <= 0.0 and player._reload_left <= 0.0
	var automatic: bool = player.WEAPONS[player.weapon].get("auto", false)
	if err < 0.06 and (automatic or (trigger_ready and not player._trigger_held)):
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
	for e in _combat_targets():
		if e.has_method("is_alive") and e.is_alive() and (e as Node3D).global_position.distance_to(at) < 7.0:
			near += 1
			if e.get("variant") in ["drone", "swarm_unit"]:
				drones += 1
	var kind := ""
	if drones > 0 and player.grenades["porongo"] > 0:
		kind = "porongo"
	elif (near >= 2 or _target.get("variant") == "mech") and player.grenades["bergamota"] > 0:
		kind = "bergamota"
	if kind == "":
		return
	player.grenade = kind
	var before: int = player.grenades[kind]
	attempts["grenades"] += 1
	player._throw_grenade() # Respect the normal cooldown and action restrictions.
	if player.grenades[kind] < before:
		counts["grenades"] += 1
		_grenade_cd = 6.0
	else:
		_grenade_cd = 1.0


# ---- driving -----------------------------------------------------------------

func _drive(delta: float) -> void:
	activity = "drive"
	var car: Node3D = player.vehicle
	if car.get("_wrecked") or car.driver_peer != player.get_multiplayer_authority():
		_event("vehicle_invalid", "left %s: wrecked or driver ownership lost" % car.name)
		_bad[car.get_instance_id()] = true
		var at := NavigationServer3D.map_get_closest_point(player.get_world_3d().navigation_map,
				car.global_position - car.global_basis.x * 3.0) + Vector3(0, 0.1, 0)
		player.left_vehicle(at)
		metrics.relocate(at, false)
		_drive_left = 0.0
		_goal = Vector3.INF
		_think_cd = 0.0
		_release_all()
		return
	_drive_left -= delta
	if _drive_left <= 0.0:
		_release_all()
		player._use_vehicle()           # out
		return
	var here := car.global_position
	# along the streets, the way the traffic goes (the walkers' navmesh would
	# take it over pavements and through the parks): the nearest street, then
	# a random turn at each crossing
	if _drive_goal == Vector3.INF:
		_road_start(here)
	elif _pi >= _path.size() - 1 and Vector2(_path[_path.size() - 1].x - here.x, _path[_path.size() - 1].z - here.z).length() < 5.0:
		_road_next()
	# aim at a point some way ahead, not the one under the bonnet: no zigzag
	while _pi < _path.size() - 1 and Vector2(_path[_pi].x - here.x, _path[_pi].z - here.z).length() < 7.0:
		_pi += 1
	if _path.size() < 2:
		_drive_left = 0.0               # no streets here: get out
		return
	var next := _path[min(_pi, _path.size() - 1)]
	var fwd := -car.global_transform.basis.z
	var to := Vector3(next.x - here.x, 0, next.z - here.z).normalized()
	if _overtake > 0.0:
		_overtake -= delta
		next += to.cross(Vector3.UP) * -3.4         # the other lane
		to = Vector3(next.x - here.x, 0, next.z - here.z).normalized()
	var turn := fwd.signed_angle_to(to, Vector3.UP)
	var speed: float = float(car.get("_speed"))
	_ahead_cd -= delta
	if _ahead_cd <= 0.0:
		_ahead_cd = 0.2
		_ahead = _vehicle_ahead(car)
	for k in ["forward", "back", "left", "right"]:
		Settings.virtual.erase(k)
	if _reverse > 0.0:
		# backing out: the wheels turned away from the way it wants, so the nose comes round to it
		_reverse -= delta
		Settings.virtual["back"] = true
		if absf(turn) > 0.15:
			Settings.virtual["right" if turn > 0.0 else "left"] = true
		_rev_still = _rev_still + delta if absf(speed) < 0.3 else 0.0
		if _rev_still > 0.8:
			_reverse = 0.0              # no room behind either: forward, full lock, then back again
			_pull = 1.2
		if _reverse <= 0.0 or absf(turn) < 0.3:
			_reverse = 0.0
		_still = 0.0
		return
	if _pull > 0.0:
		_pull -= delta
		Settings.virtual["forward"] = true
		Settings.virtual["left" if turn > 0.0 else "right"] = true
		_rev_still = 0.0
		return
	if absf(turn) > 1.3:
		_reverse = 2.0                  # the street is behind: back and round (a three-point turn)
		return
	# steer in short taps on a gentle bend, a full lock only on a sharp one
	var lock := absf(turn) > 0.35 or fmod(_t * 5.0, 1.0) < absf(turn) / 0.35
	if absf(turn) > 0.05 and lock:
		Settings.virtual["left" if turn > 0.0 else "right"] = true
	# slow for the corners, keep to town speed on the straight
	var limit := 6.0 if absf(turn) > 0.5 else (10.0 if absf(turn) > 0.2 else 15.0)
	if _ahead:
		# a car or bus in front: wait behind it, and pass it once it has stood a while (a bus stop, a jam)
		limit = 0.0
		_queue += delta
		_still = 0.0
		if _queue > 2.5 and _overtake <= 0.0:
			_overtake = 5.0
			_queue = 0.0
	else:
		_queue = 0.0
	if speed < limit:
		Settings.virtual["forward"] = true
	elif speed > limit + 3.0:
		Settings.virtual["back"] = true # brake
	# a wall: back out, and find the street again
	if absf(speed) < 0.5:
		_still += delta
		if _still > 2.0:
			_still = 0.0
			_car_stucks += 1
			_event("car_stuck", "%s at %s" % [car.kind, _v(here)])
			if _car_stucks >= 3:
				_car_stucks = 0
				_drive_left = 0.0       # give up on this car, and don't come back for it
				_bad[car.get_instance_id()] = true
			else:
				_reverse = 2.0
				_drive_goal = Vector3.INF
	else:
		_still = 0.0
		if speed > 4.0:
			_car_stucks = 0


func _vehicle_ahead(car: Node3D) -> bool:
	if _box == null:
		_box = BoxShape3D.new()
		_box.size = Vector3(2.0, 1.4, 5.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _box
	var fwd := -car.global_transform.basis.z
	var half: float = float(car.get("_length")) / 2.0 if car.get("_length") else 2.3
	q.transform = Transform3D(car.global_transform.basis, car.global_position + fwd * (half + 3.0) + Vector3(0, 0.8, 0))
	q.collision_mask = 16
	q.exclude = [car.get_rid()]
	return not car.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


var _road_node := -1


## Onto the nearest street, heading the way it may be driven that is nearer the car's nose.
func _road_start(here: Vector3) -> void:
	var g: Dictionary = _main().road_graph
	var best := INF
	var pick := [-1, true]
	var fwd: Vector3 = -player.vehicle.global_transform.basis.z
	for i in g.get("edges", []).size():
		var e: Dictionary = g["edges"][i]
		var pts: Array = e["pts"]
		for k in range(1, pts.size()):
			var a := Vector2(pts[k - 1][0], pts[k - 1][1])
			var b := Vector2(pts[k][0], pts[k][1])
			var d := Geometry2D.get_closest_point_to_segment(Vector2(here.x, here.z), a, b).distance_to(Vector2(here.x, here.z))
			if d < best:
				best = d
				var along := Vector2(fwd.x, fwd.z).dot(b - a) >= 0.0
				pick = [i, true if e["oneway"] else along]
	_drive_goal = here
	if pick[0] < 0:
		_path = PackedVector3Array()
		return
	_road_follow(pick[0], pick[1])


func _road_next() -> void:
	var g: Dictionary = _main().road_graph
	var options: Array = g["out"].get(_road_node, [])
	if options.is_empty():
		_drive_goal = Vector3.INF       # a dead end at the map's edge: the nearest street again
		_path = PackedVector3Array()
		return
	var o: Array = options[rng.randi() % options.size()]
	_road_follow(o[0], o[1])


func _road_follow(edge: int, forward: bool) -> void:
	var e: Dictionary = _main().road_graph["edges"][edge]
	var pts: Array = e["pts"].duplicate()
	if not forward:
		pts.reverse()
	_road_node = int(e["b"]) if forward else int(e["a"])
	var off := 0.9 if e["oneway"] else 1.7    # the right-hand lane, as the traffic keeps
	_path = PackedVector3Array()
	var y: float = player.vehicle.global_position.y
	for k in pts.size():
		var p := Vector3(pts[k][0], y, pts[k][1])
		var n: int = mini(k + 1, pts.size() - 1)
		var dir := (Vector3(pts[n][0], y, pts[n][1]) - p).normalized() if n != k \
				else (p - Vector3(pts[k - 1][0], y, pts[k - 1][1])).normalized()
		_path.append(p + dir.cross(Vector3.UP) * off)
	# start from the point ahead of the car, not the street's far beginning
	_pi = 1
	var here: Vector3 = player.vehicle.global_position
	var bd := INF
	for k in _path.size():
		var d := Vector2(_path[k].x - here.x, _path[k].z - here.z).length()
		if d < bd:
			bd = d
			_pi = mini(k + 1, _path.size() - 1)


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
