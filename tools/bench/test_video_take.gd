extends Node3D
const Stage := preload("res://scripts/video_stage.gd")
var paused := false
class QuietPlayer:
	extends "res://scripts/player.gd"
	func _ready() -> void:
		set_process(false)
		collision_layer = 4
		collision_mask = 1
		var shape := CollisionShape3D.new()
		shape.shape = CapsuleShape3D.new()
		shape.position.y = 1.0
		add_child(shape)
		head = Node3D.new()
		add_child(head)
		camera = Camera3D.new()
		head.add_child(camera)
class Agent:
	extends Node
	func _v(p: Vector3) -> Array: return [p.x,p.y,p.z]
	func _main() -> Node3D: return get_tree().current_scene

func _ready() -> void:
	call_deferred("_run")
func _run() -> void:
	# The shortest arc through +/-180 must not spin the camera around.
	var wrap := Stage.looking([{"t":0,"yaw":179,"pitch":0},{"t":1,"yaw":-179,"pitch":0}],0.5)
	assert(absf(absf(wrap.x) - PI) < 0.001)
	var cue := {"start":0.0,"end":4.0,"direction":[0,-1],"ramp_s":0.65}
	assert(Stage.walking(cue,0).is_zero_approx() and Stage.walking(cue,4).is_zero_approx())
	assert(Stage.walking(cue,0.01).length() < 0.001)
	var floor_body := StaticBody3D.new()
	floor_body.position.y = -0.5
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100,1,100)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	var player := QuietPlayer.new()
	player.name = "1"
	player.position.y = 0.05
	add_child(player)
	var stage := Stage.new()
	stage.agent = Agent.new()
	add_child(stage.agent)
	add_child(stage)
	stage._player = player
	stage.scene_name = "usina_walk"
	stage.scene = Stage.catalogue()["usina_walk"]
	await get_tree().physics_frame
	stage.play()
	while stage.running: await get_tree().physics_frame
	var samples: Array = stage.last.samples
	assert(samples.size() == 720, "A 12 s take must have exactly 720 physics samples at 60 Hz")
	var travelled := 0.0
	var max_step := 0.0
	var max_turn := 0.0
	for i in range(1,samples.size()):
		var a: Array = samples[i-1].position
		var b: Array = samples[i].position
		var step := Vector2(b[0]-a[0],b[2]-a[2]).length()
		travelled += step
		max_step = maxf(max_step,step)
		max_turn = maxf(max_turn,absf(angle_difference(samples[i-1].yaw,samples[i].yaw)))
	assert(travelled > 8 and travelled < 10, "Real movement should cover the intended walking distance")
	assert(max_step <= 2.25 / 60.0 + 0.002, "No in-take teleport or skipped position updates")
	assert(max_turn < deg_to_rad(1), "Camera turns must be gradual")
	assert(not player.scripted_control and player.scripted_move.is_zero_approx())
	stage.play()
	await get_tree().physics_frame
	stage.stop()
	assert(not stage.running and not stage.last.completed and not player.scripted_control)
	# After cancellation, ordinary virtual W must use the unchanged full walk speed.
	var before := player.global_position
	Settings.virtual["forward"] = true
	for frame in 30: await get_tree().physics_frame
	Settings.virtual.erase("forward")
	var normal_distance := Vector2(player.global_position.x-before.x,player.global_position.z-before.z).length()
	assert(normal_distance > 2.3 and normal_distance < 2.7, "Normal walking input must still work after the take")
	print("Video take passed: distance=",travelled," max step=",max_step," max turn deg=",rad_to_deg(max_turn))
	for node in get_children(): node.queue_free()
	for node in Sfx.get_children(): node.queue_free()
	await get_tree().process_frame
	# Fixed simulation time does not advance the native audio mixing thread.
	OS.delay_msec(150)
	get_tree().quit()
