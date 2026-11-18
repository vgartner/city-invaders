extends Node3D
## Reproducible same-camera visual comparison. No third-party code is executed.
const Props := preload("res://scripts/props.gd")
const Trees := preload("res://scripts/vegetation_trees.gd")
const Grass := preload("res://scripts/grass_detail.gd")
var before: Node3D
var after: Node3D
var camera: Camera3D
var detail: Node3D
var out: String
var report: Dictionary = {}

func _ready() -> void:
	out = OS.get_environment("VEGETATION_OUTPUT")
	if out.is_empty():
		out = "/tmp/vegetation-preview"
	DirAccess.make_dir_recursive_absolute(out)
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	_setup()
	_batching_audit()
	_run.call_deferred()

func _setup() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.64, 0.74, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.78, 0.85)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)
	camera = Camera3D.new()
	camera.fov = 65
	camera.current = true
	add_child(camera)
	before = Node3D.new()
	after = Node3D.new()
	add_child(before)
	add_child(after)
	var old_material := StandardMaterial3D.new()
	old_material.albedo_texture = load("res://assets/materials/Grass004/color.jpg")
	old_material.roughness = 1.0
	old_material.uv1_scale = Vector3(32, 32, 1)
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/common/vegetation/lawn.gdshader")
	material.set_shader_parameter("albedo_tex", old_material.albedo_texture)
	material.set_shader_parameter("uv_scale", Vector2(32, 32))
	_ground(before, old_material)
	_ground(after, material)
	var source := Props.new()
	source._tree_mats()
	seed(734)
	var triangles: Array = []
	for i in 3:
		var pos: Vector3 = [Vector3.ZERO, Vector3(-8, 0, -5), Vector3(9, 0, -8)][i]
		var old: Array = source._legacy_tree_template()
		var revised: Array = Trees.template(i)
		for entry in [[before, old[0]], [after, revised[0]]]:
			var mesh := MeshInstance3D.new()
			mesh.mesh = entry[1]
			mesh.position = pos
			entry[0].add_child(mesh)
		triangles.append({"legacy": _triangles(old[0]), "near": _triangles(revised[0]), "far": _triangles(revised[3])})
	source.free()
	detail = Grass.new()
	after.add_child(detail)
	detail.setup(after)
	report["tree_triangles"] = triangles

func _triangles(mesh: Mesh) -> int:
	var count: int = 0
	for i in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(i)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		count += int((indices.size() if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size()) / 3.0)
	return count

func _ground(parent: Node3D, material: Material) -> void:
	var ground := MeshInstance3D.new()
	ground.name = "grass_benchmark"
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	plane.subdivide_width = 15
	plane.subdivide_depth = 15
	ground.mesh = plane
	ground.material_override = material
	parent.add_child(ground)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 0.1, 80)
	shape.shape = box
	shape.position.y = -0.05
	body.add_child(shape)
	ground.add_child(body)

func _run() -> void:
	for view in [["trees", Vector3(10, 3.0, 15), Vector3(0, 3.8, 0)],
		["foliage", Vector3(3, 4.8, 5), Vector3(0, 5.2, 0)],
		["grass_eye", Vector3(1, 1.65, 8), Vector3(1, 0.1, 2)],
		["grass_close", Vector3(1, 0.6, 8), Vector3(1, 0.03, 6)]]:
		camera.position = view[1]
		camera.look_at(view[2])
		for i in 120:
			await get_tree().process_frame
		for revised in [false, true]:
			before.visible = not revised
			after.visible = revised
			for i in 20:
				await get_tree().process_frame
			get_window().mode = Window.MODE_WINDOWED
			get_window().size = Vector2i(1280, 720)
			await get_tree().process_frame
			# Covered macOS windows may never emit frame_post_draw.
			RenderingServer.force_draw(true)
			var image: Image = get_viewport().get_texture().get_image()
			image.save_png(out.path_join(("after_" if revised else "before_") + view[0] + ".png"))
	report["grass"] = detail.diagnostics
	report["placement_audit"] = detail.audit_samples(200)
	assert(report["grass"]["instances"] <= Grass.MAX_INSTANCES)
	assert(report["placement_audit"]["wrong_surface"] == 0)
	assert(report["placement_audit"]["max_ground_error_m"] < 0.025)
	report["note"] = "Visual comparison, not a controlled FPS benchmark; another game may be running."
	FileAccess.open(out.path_join("preview_report.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	get_tree().quit()

func _batching_audit() -> void:
	var batch := preload("res://scripts/batcher.gd").new()
	var mesh := BoxMesh.new()
	var parent := Node3D.new()
	add_child(parent)
	batch.add(mesh, Transform3D.IDENTITY, null, 60.0, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "tree", 0.0, 0.0)
	batch.add(mesh, Transform3D.IDENTITY, null, 0.0, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "tree", 60.0, 0.0)
	assert(batch.build(parent) == 2)
	assert(batch.ref("tree").size() == 2)
	for child in parent.get_children():
		assert(child.visibility_range_begin_margin == 0.0)
		if child.visibility_range_end > 0.0:
			assert(child.visibility_range_end_margin == 0.0)
	parent.free()
	report["near_far_batch_references"] = true
	for i in 8:
		var template: Array = Trees.template(i)
		var arrays: Array = template[0].surface_get_arrays(1)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			assert(vertex.distance_to(Vector3(0, template[4], 0)) <= float(template[2]) + 0.0001)
	report["all_leaf_cards_inside_hit_sphere"] = true
	var props := Props.new()
	add_child(props)
	props._tree(Vector3(30, 0, 30))
	props._batch.build(props)
	assert(props.crowns.size() == 1)
	assert(props._batch.ref("tree0").size() == 2)
	props.leaves(props.crowns[0][1], 2)
	props.free()
	report["actual_tree_builder_and_leaf_hit"] = true
