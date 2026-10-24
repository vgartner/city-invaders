extends Node
const Bot = preload("res://scripts/autoplay.gd")
const Wreck = preload("res://scripts/wreck.gd")
const PlayerScript = preload("res://scripts/player.gd")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := Node3D.new()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	var player := CharacterBody3D.new()
	scene.add_child(player)
	var bot := Bot.new()
	bot.player = player
	scene.add_child(bot)
	bot.set_physics_process(false)
	await get_tree().physics_frame
	# Switching destinations at the same wall must not count as progress.
	bot._stucks_here = 2
	bot._set_goal(Vector3(20, 0, 20), "shop", scene)
	bot._check_stuck(0.0)
	assert(bot._stucks_here == 2)
	bot._mark_goal_bad()
	assert(bot._bad_shops.has(Vector3(20, 0, 20)))
	assert(not bot._bad.has(scene.get_instance_id()), "One shop must not blacklist every shop")
	bot._best_goal_d = 50.0
	bot._goal = Vector3(10, 0, 0)
	bot._check_stuck(0.0)
	assert(bot._stucks_here == 0, "Real goal progress must clear recovery attempts")
	bot.activity = "stuck"
	bot._last_pos = Vector3(-2, 0, 0)
	bot._check_stuck(0.0)
	assert(bot.activity == "shop", "Resumed movement must not remain tagged as stuck")
	# A source animation's zero-scale hidden accessory must not gain a
	# phantom collider or send a singular orientation to Jolt on death.
	var model := Node3D.new()
	scene.add_child(model)
	for visible_piece in [true, false]:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		model.add_child(mi)
		mi.scale = Vector3(0.2, 0.3, 0.4) if visible_piece else Vector3.ZERO
	# Exercise the skinned-bone case as well as a rigid zero-scale mesh.
	var skel := Skeleton3D.new()
	model.add_child(skel)
	skel.add_bone("HiddenAccessory")
	skel.set_bone_pose_scale(0, Vector3.ZERO)
	var arrays := BoxMesh.new().surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices := PackedInt32Array()
	var weights := PackedFloat32Array()
	indices.resize(vertices.size() * 4)
	weights.resize(vertices.size() * 4)
	for vertex in vertices.size():
		weights[vertex * 4] = 1.0
	arrays[Mesh.ARRAY_BONES] = indices
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var hidden_mesh := ArrayMesh.new()
	hidden_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var hidden := MeshInstance3D.new()
	hidden.mesh = hidden_mesh
	hidden.skin = Skin.new()
	hidden.skin.add_named_bind("HiddenAccessory", Transform3D.IDENTITY)
	skel.add_child(hidden)
	hidden.skeleton = NodePath("..")
	Wreck.shatter(model)
	var bodies := scene.find_children("*", "RigidBody3D", true, false)
	assert(bodies.size() == 1, "Only the visible piece should become a body")
	assert(is_equal_approx((bodies[0] as Node3D).global_basis.determinant(), 1.0))
	var normal := PlayerScript._make_impact(false)
	var repeat := PlayerScript._make_impact(false)
	var metal := PlayerScript._make_impact(true)
	assert(normal.mesh == repeat.mesh and normal.mesh != metal.mesh)
	assert(normal.amount == 14 and is_equal_approx(normal.lifetime, 0.45))
	assert(is_equal_approx(normal.mesh.radius, 0.025) and is_equal_approx(normal.mesh.height, 0.05))
	assert((metal.mesh.material as StandardMaterial3D).albedo_color == Color(1, 0.75, 0.3))
	normal.free()
	repeat.free()
	metal.free()
	print("Recovery, wreck and impact resource tests passed")
	scene.free()
	get_tree().quit()
