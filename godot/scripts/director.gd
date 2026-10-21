extends Node
## AI Director (Left 4 Dead style), server side.
##
## Tracks an "intensity" per player that rises with damage taken and nearby
## enemies and decays over time. The director cycles BUILD_UP -> PEAK ->
## RELAX: it spawns waves out of the players' sight while intensity is low,
## stops at the peak, and gives a breather before building up again. Wave
## size scales with the number of players and how well they are doing.

signal phase_changed(phase: String)

enum Phase { BUILD_UP, PEAK, RELAX }

const PEAK_INTENSITY := 70.0
const Difficulty := preload("res://scripts/difficulty.gd")
## (how many robots per player and the rest between waves: difficulty.gd)
const START_POPULATION := 10
const SHIP_MIN_ROOM := 3       # robots missing before a dropship brings more

var phase := Phase.BUILD_UP
var intensity := {}          # peer id -> 0..100
var spawn_enemy: Callable    # func(position: Vector3) -> void, set by main
var drop_item: Callable      # func(kind: String, position: Vector3) -> void
var call_ship: Callable      # func(near: Vector3, n: int) -> int (1 sent, 0 busy, -1 no spot)
var enemies_root: Node
var _relax_left := 0.0
var _spawn_cd := 3.0
var kills := 0
var reinforce := 1.0         # < 1 while the robots' relay antenna stands: ships come sooner


func on_player_hurt(peer: int, amount: int) -> void:
	intensity[peer] = min(100.0, intensity.get(peer, 0.0) + amount * 1.5)


## Only robots a player destroys count (the phase goal is the players' tally).
func on_enemy_killed(enemy) -> void:
	if enemy.killed_by_player:
		kills += 1


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	var top := 0.0
	for p in players:
		var id: int = p.get_multiplayer_authority()
		var near := 0
		for e in enemies_root.get_children():
			if e.is_alive() and e.global_position.distance_to(p.global_position) < 20.0:
				near += 1
		var v: float = intensity.get(id, 0.0) + near * 2.0 * delta - 4.0 * delta
		intensity[id] = clamp(v, 0.0, 100.0)
		top = max(top, intensity[id])

	match phase:
		Phase.BUILD_UP:
			if top >= PEAK_INTENSITY:
				_set_phase(Phase.PEAK)
			else:
				_spawn_cd -= delta
				var cap := int(Difficulty.get_value("enemies_per_player") * players.size() * _spread())
				var room := cap - _alive()
				# reinforcements come by dropship once a few robots are down
				if _spawn_cd <= 0 and room >= SHIP_MIN_ROOM:
					# a full ship splits into two drop zones of three
					var wave: int = min(room, 4 + 2 * players.size() + int(kills / 10))
					var sent: int = call_ship.call(players.pick_random().global_position, wave) \
							if call_ship.is_valid() else -1
					if sent == 1:
						_spawn_cd = randf_range(18.0, 26.0) * reinforce
					elif sent == 0:
						_spawn_cd = 2.0        # a ship is still out: try again shortly
					else:
						for i in wave:         # nowhere to land: sneak them in out of sight
							_spawn_near(players.pick_random())
						_spawn_cd = randf_range(6.0, 10.0)
		Phase.PEAK:
			# let the fight play out; relax once the pressure drops
			if top < PEAK_INTENSITY * 0.5 or _alive() == 0:
				_relax_left = Difficulty.get_value("relax_s") * reinforce
				_set_phase(Phase.RELAX)
		Phase.RELAX:
			_relax_left -= delta
			if _relax_left <= 0:
				_set_phase(Phase.BUILD_UP)


func _set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(Phase.keys()[p])
	if p == Phase.RELAX:
		_drop_medkit()


## Breather reward: a medkit close to the most hurt player.
func _drop_medkit() -> void:
	var worst: Node3D = null
	for pl in get_tree().get_nodes_in_group("players"):
		if not pl.dead and pl.health < 80 and (worst == null or pl.health < worst.health):
			worst = pl
	if worst == null or not drop_item.is_valid():
		return
	var map := worst.get_world_3d().navigation_map
	for attempt in 10:
		var guess := worst.global_position + Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * randf_range(4.0, 8.0)
		var pos := NavigationServer3D.map_get_closest_point(map, guess)
		var path := NavigationServer3D.map_get_path(map, worst.global_position, pos, true)
		if not path.is_empty() and path[path.size() - 1].distance_to(pos) < 1.0:
			drop_item.call("churrasco" if randf() < 0.5 else "chimarrao", pos)
			return


func _spawn_near(player: Node3D) -> void:
	# random navmesh point 25-60 m away and out of the player's line of sight
	var map := player.get_world_3d().navigation_map
	for attempt in 20:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		var guess := player.global_position + dir * randf_range(30.0, 70.0)
		var pos := NavigationServer3D.map_get_closest_point(map, guess)
		if pos == Vector3.ZERO or pos.distance_to(player.global_position) < 20.0:
			continue
		if not get_tree().current_scene.in_bounds(pos, 6.0):
			continue    # keep away from the open map edge
		# must be reachable: the path from the player has to end at the spawn
		var path := NavigationServer3D.map_get_path(map, player.global_position, pos, true)
		if path.is_empty() or path[path.size() - 1].distance_to(pos) > 1.5:
			continue
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.5, 0),
				player.global_position + Vector3(0, 1.5, 0), 1)
		if player.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue    # visible: try elsewhere
		spawn_enemy.call(pos + Vector3(0, 0.2, 0))
		return


## Bigger cities hold proportionally more robots, spread over the whole map.
func _spread() -> float:
	return get_tree().current_scene.density()


func _alive() -> int:
	var n := 0
	for e in enemies_root.get_children():
		if e.is_alive():
			n += 1
	return n


func reset() -> void:
	phase = Phase.BUILD_UP
	intensity = {}
	kills = 0
	_relax_left = 0.0
	_spawn_cd = 3.0
	phase_changed.emit("BUILD_UP")


## Server: robots already patrolling the city when the round starts, spread
## over reachable streets away from the players and out of their sight.
func populate() -> void:
	if not multiplayer.is_server():
		return
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	await get_tree().current_scene.wait_for_navmesh()
	var map: RID = players[0].get_world_3d().navigation_map
	var origin: Vector3 = players[0].global_position
	var placed := 0
	for attempt in 300:
		if placed >= int(START_POPULATION * _spread()):
			break
		var pos := NavigationServer3D.map_get_random_point(map, 1, true)
		if not get_tree().current_scene.in_bounds(pos, 8.0):
			continue
		if players.any(func(pl): return pl.global_position.distance_to(pos) < 45.0):
			continue
		var path := NavigationServer3D.map_get_path(map, origin, pos, true)
		if path.is_empty() or path[path.size() - 1].distance_to(pos) > 1.5:
			continue
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.5, 0), origin + Vector3(0, 1.5, 0), 1)
		if players[0].get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue
		spawn_enemy.call(pos + Vector3(0, 0.2, 0))
		placed += 1
