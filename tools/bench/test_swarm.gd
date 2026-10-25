extends "res://scripts/main.gd"

class QuietPlayer:
	extends "res://scripts/player.gd"
	var test_damage := 0
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
	@rpc("any_peer", "call_local", "reliable")
	func hurt(amount: int, _from: Vector3) -> void:
		test_damage += amount

var test_points := 0
var failures := 0
var baseline := false
var shooter: QuietPlayer
var results := {}

func _ready() -> void:
	set_process(false)
	baseline = "--baseline" in OS.get_cmdline_user_args()
	enemies_root = _root("Enemies")
	players_root = _root("Players")
	director = Director.new()
	add_child(director)
	director.set_process(false)
	shooter = QuietPlayer.new()
	shooter.name = "1"
	players_root.add_child(shooter)
	call_deferred("_tests")

func award(_peer: int, points: int, _reason: String) -> void:
	test_points += points

@rpc("any_peer", "call_local", "reliable")
func blast_fx(_from: Vector3, _at: Vector3, _normal: Vector3, _wall: bool) -> void:
	pass # Exercise cannon damage without unrelated particle/tween resources.

func expect(value: bool, reason: String) -> void:
	if not value and not baseline:
		failures += 1
		push_error(reason)

func spawn_test(n: int, points: PackedVector3Array):
	var swarm = _spawn_enemy_node({"id": _next_enemy_id(), "pos": points[0], "variant": "swarm", "n": n})
	enemies_root.add_child(swarm)
	swarm.set_process(false)
	swarm.set_physics_process(false)
	swarm.positions = points
	for i in n:
		swarm._units[i].global_position = points[i]
	return swarm

func box(at: Vector3, size: Vector3, layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	body.position = at
	return body

func _tests() -> void:
	await get_tree().physics_frame
	var swarm = spawn_test(2, PackedVector3Array([Vector3(0, 2, -5), Vector3(0, 2, -7)]))
	await get_tree().physics_frame
	await get_tree().physics_frame
	shooter.server_shoot(Vector3(0, 2, 0), Vector3.FORWARD, "pistol")
	expect(swarm.alive_mask == 2, "The first bullet must down its drone")
	swarm._process(1.0)
	await get_tree().physics_frame
	shooter.server_shoot(Vector3(0, 2, 0), Vector3.FORWARD, "pistol")
	results["mask_after_two_bullets"] = swarm.alive_mask
	results["phase_kills"] = director.kills
	results["points"] = test_points
	expect(swarm.alive_mask == 0, "An invisible dead drone must not shield the next one")
	expect(director.kills == 1, "Completing a swarm must count once for the phase")
	expect(test_points == 80, "Keep the existing 40 points per drone without a duplicate group bonus")
	swarm.free()

	box(Vector3(10, 3, 0), Vector3(10, 6, 0.2), 1)
	shooter.position = Vector3(10, 0, -4)
	swarm = spawn_test(1, PackedVector3Array([Vector3(10, 2, 2)]))
	swarm._target = shooter
	swarm._attack_cd = 100
	swarm._turn_cd = 100
	swarm._dive[0] = -1.0
	swarm._dive_at[0] = Vector3(10, 1.1, -4)
	var min_z := 2.0
	for i in 8:
		await get_tree().physics_frame
		if swarm.alive_mask == 0: break
		swarm._physics_process(0.1)
		min_z = minf(min_z, swarm.positions[0].z)
		swarm._process(1.0)
	results["dive_wall_min_z"] = min_z
	expect(min_z >= 0.49, "A fast dive must collide with a thin wall, not tunnel through it")
	swarm.free()

	shooter.position = Vector3(10, 0, -0.7)
	shooter.test_damage = 0
	swarm = spawn_test(1, PackedVector3Array([Vector3(10, 1.1, 0.6)]))
	await get_tree().physics_frame
	swarm._explode(0, Vector3(10, 1.1, 0.6))
	results["damage_behind_wall"] = shooter.test_damage
	expect(shooter.test_damage == 0, "A wall must protect the player from the contact blast")
	swarm.free()

	box(Vector3(20, 3, 0), Vector3(10, 0.2, 10), 64)
	shooter.position = Vector3(20, 0, 0)
	swarm = spawn_test(1, PackedVector3Array([Vector3(20, 5, 0)]))
	swarm._target = shooter
	swarm._attack_cd = 100
	swarm._turn_cd = 100
	swarm._dive[0] = -1.0
	swarm._dive_at[0] = Vector3(20, 1.1, 0)
	var min_y := 5.0
	for i in 8:
		await get_tree().physics_frame
		if swarm.alive_mask == 0: break
		swarm._physics_process(0.1)
		min_y = minf(min_y, swarm.positions[0].y)
		swarm._process(1.0)
	results["dive_roof_min_y"] = min_y
	expect(min_y >= 3.49, "Roofs on layer 64 must stop dives")
	swarm.free()
	# Orbit movement uses the same swept body, but slides/climbs instead of exploding.
	swarm = spawn_test(1, PackedVector3Array([Vector3(10, 2, 2)]))
	await get_tree().physics_frame
	for i in 5:
		swarm._move_unit(0, Vector3(0, 0, -2), 0.1, false)
	expect(swarm.alive_mask == 1, "Orbiting wall contact must not kill the drone")
	expect(swarm.positions[0].z >= 0.49, "Orbit movement must not cross a wall")
	expect(swarm.positions[0].y > 2.0, "Orbiters must climb to get around a facade")
	results["orbit_wall_z"] = swarm.positions[0].z
	results["orbit_climb_y"] = swarm.positions[0].y
	# Simulate a client receiving two safe endpoints on opposite sides of a wall.
	swarm._units[0].global_position = Vector3(10, 2, 2)
	swarm.positions[0] = Vector3(10, 2, -2)
	swarm._render_unit(0, 0.04)
	expect(swarm._units[0].global_position.is_equal_approx(swarm.positions[0]), "Network smoothing must not draw a drone inside a wall")
	var safe_spawn: Vector3 = swarm._spawn_position(Vector3(10, 2, 0))
	expect(safe_spawn.y > 6.4, "Initial spread must place the full drone outside a building")
	swarm.free()

	# The root stays far away: area damage must use the individual drone positions.
	swarm = spawn_test(2, PackedVector3Array([Vector3(40, 2, 0), Vector3(60, 2, 0)]))
	swarm.position = Vector3(100, 2, 100)
	player_cannon_land(Vector3(40, 2, 10), Vector3(40, 2, 0), Vector3.UP, false, 3.0, 100, 1)
	expect(swarm.alive_mask == 2, "Cannon splash must hit a nearby unit, not the distant swarm root")
	var kills_before: int = director.kills
	var points_before: int = test_points
	swarm.hit_unit(0, 100, shooter)
	expect(director.kills == kills_before and test_points == points_before, "Repeated hits on dead units must not pay or count again")
	swarm.free()
	print("SWARM_RESULTS ", JSON.stringify(results))
	print("Swarm regression failures: ", failures)
	await get_tree().create_timer(3.2).timeout
	get_tree().quit(1 if failures else 0)
