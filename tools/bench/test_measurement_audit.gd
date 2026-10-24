extends Node3D
const Metrics = preload("res://scripts/autoplay_metrics.gd")

class QuietPlayer:
	extends "res://scripts/player.gd"
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)

class RefusingCar:
	extends Node3D
	var driver_peer := 0
	var _wrecked := true
	var take_calls := 0
	func take(_peer: int, _by: Node3D) -> void:
		take_calls += 1 # Deliberately refuses ownership.

var traffic_root: Node3D

func _ready() -> void:
	traffic_root = Node3D.new()
	add_child(traffic_root)
	var car := RefusingCar.new()
	car.name = "TestCar"
	traffic_root.add_child(car)
	var driver := QuietPlayer.new()
	driver.name = "1"
	add_child(driver)
	driver.request_vehicle("TestCar")
	assert(driver.vehicle == null and car.take_calls == 0, "Wrecks cannot be entered")
	car._wrecked = false
	driver.request_vehicle("TestCar")
	assert(driver.vehicle == null and car.take_calls == 1, "A refused take must not attach the player")
	driver.free()
	var metrics := Metrics.new()
	metrics.reset(Vector3.ZERO, false)
	metrics.sample(Vector3(1, 0, 0), false, 1.0, "walk", "pistol")
	metrics.sample(Vector3(100, 0, 0), false, 1.0, "walk", "pistol")
	assert(metrics.foot_m == 1.0 and metrics.discontinuity_m == 99.0)
	metrics.relocate(Vector3(200, 0, 0), false)
	metrics.sample(Vector3(201, 0, 0), false, 1.0, "walk", "pistol")
	metrics.sample(Vector3(250, 0, 0), true, 1.0, "drive", "pistol")
	metrics.sample(Vector3(260, 0, 0), true, 1.0, "drive", "pistol")
	metrics.sample(Vector3(260, 0, 0), true, 1.0, "fight", "pistol")
	assert(metrics.foot_m == 2.0 and metrics.vehicle_m == 10.0)
	assert(metrics.relocation_m == 100.0 and metrics.stationary_combat_s == 1.0)
	assert(metrics.snapshot()["unique_cells_50m"] == 4)
	# The new status query must never create a bot, including after completion.
	for k in 10:
		assert(not DevAgent._m_autoplay_status({})["active"])
	assert(DevAgent._autoplay == null)
	DevAgent._ensure_hitch_history()
	var before: int = DevAgent._effect_counts["CPUParticles3D"]
	var particles := CPUParticles3D.new()
	add_child(particles)
	assert(DevAgent._effect_counts["CPUParticles3D"] == before + 1)
	particles.free()
	assert(DevAgent._effect_counts["CPUParticles3D"] == before)
	print("Coverage, read-only status and effect lifetime tests passed")
	get_tree().quit()
