extends Node3D

const RoadPath := preload("res://scripts/road_path.gd")
const Autoplay := preload("res://scripts/autoplay.gd")
var road_graph := {}
var failures := 0

class TestPlayer extends CharacterBody3D:
	var vehicle: Node3D

func expect(value: bool, reason: String) -> void:
	if not value:
		failures += 1
		push_error(reason)

func _ready() -> void:
	expect(is_zero_approx(RoadPath.turn_angle(Vector3(0, -0.3, -1), Vector3.FORWARD)),
		"Hill pitch must not steer a car away from a straight street")
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0), Vector3(100, 0, 100)])
	var projection := RoadPath.project(path, Vector3(60, 5, 1))
	expect(projection.segment == 0, "A mid-segment join must not skip the next bend")
	expect(is_equal_approx(projection.distance, 1.0), "Road deviation is horizontal")
	var target := RoadPath.ahead(path, projection, 6.0)
	expect(target.is_equal_approx(Vector3(66, 0, 0)), "Pursuit must follow the street, not cut a diagonal")
	expect(is_equal_approx(RoadPath.remaining(path, projection), 140.0), "Remaining distance follows the bend")
	projection = RoadPath.project(path, Vector3(98, 0, 0))
	target = RoadPath.ahead(path, projection, 6.0)
	expect(target.is_equal_approx(Vector3(100, 0, 4)), "Lookahead continues around a corner by arc length")
	expect(RoadPath.speed_limit(path, projection) < 4.0, "Brake before reaching a right-angle junction")
	projection = RoadPath.project(path, Vector3(80, 0, 0))
	expect(RoadPath.speed_limit(path, projection) < 10.0, "Braking begins before the bend, not after turning")
	var tight := PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 2), Vector3(0.8, 0, 4)])
	expect(RoadPath.speed_limit(tight, RoadPath.project(tight, Vector3(0, 0, 1.9))) < 4.0,
		"Dense points with modest angles still require slow cornering")
	var degenerate := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3(10, 0, 0)])
	target = RoadPath.ahead(degenerate, RoadPath.project(degenerate, Vector3.ZERO), 5)
	expect(target.is_finite() and is_equal_approx(target.x, 5.0), "Duplicate OSM points must remain finite")

	var steer := 0.0
	var mean := 0.0
	for i in 180:
		var key := RoadPath.steer_key(0.25, steer, 4.0 / 60.0)
		steer = move_toward(steer, 0.0, 8.0 / 60.0) if key == "" else move_toward(steer, -1.0 if key == "left" else 1.0, 4.0 / 60.0)
		if i >= 60: mean += steer / 120.0
	expect(absf(mean - 0.25) < 0.04, "Real-key feedback must hold the requested filtered steering angle")
	expect(RoadPath.steer_key(-1.0, 0, 0.1) == "left", "Positive pursuit yaw requires left steering")
	road_graph = {"edges": [
		{"a": 0, "b": 1, "oneway": false, "pts": [[0, 0], [100, 0], [100, 100]]},
		{"a": 1, "b": 2, "oneway": true, "pts": [[100, 100], [200, 100]]}],
		"out": {1: [[0, false], [1, true]], 2: [[1, false]]}}
	var car := Node3D.new()
	add_child(car)
	car.position = Vector3(60, 0, 1.7)
	var player := TestPlayer.new()
	player.vehicle = car
	add_child(player)
	var bot := Autoplay.new()
	bot.player = player
	add_child(bot)
	bot.set_physics_process(false)
	bot._road_follow(0, true)
	expect(bot._pi == 1, "Joining a sparse road must select its segment, not its nearest vertex")
	var size_before: int = bot._path.size()
	bot._road_next()
	expect(bot._road_edge == 1, "A junction must prefer a continuation over an immediate U-turn")
	expect(bot._path.size() > size_before, "Plan the next road before dropping the current junction")
	bot._road_follow(1, true)
	bot._road_next()
	expect(bot._path.size() == 2, "A map-edge dead end retains its path for controlled braking")
	car.position = Vector3(500, 0, 500)
	bot._drive_left = 10.0
	bot._road_start(car.position)
	expect(bot._path.is_empty() and is_zero_approx(bot._drive_left),
		"A parked car far from mapped streets must not drive through a block to join them")
	expect(bot.road_metrics.rejected_joins == 1 and bot._bad.has(car.get_instance_id()),
		"Refused off-street joins are measured and skipped for the run")
	print("Road following regression failures: ", failures)
	get_tree().quit(1 if failures else 0)
