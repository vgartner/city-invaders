extends RefCounted
## Original branched broadleaf templates. Local seeds never perturb gameplay RNG.
static var _templates: Array = []
static var _leaf: StandardMaterial3D
static var _bark: StandardMaterial3D

static func template(index: int) -> Array:
	if _templates.is_empty():
		_materials()
		for i in 8:
			_templates.append(_make(i))
	return _templates[index % _templates.size()]

static func _materials() -> void:
	_leaf = StandardMaterial3D.new()
	_leaf.albedo_texture = preload("res://assets/common/vegetation/broadleaf_twigs.png")
	_leaf.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_leaf.alpha_scissor_threshold = 0.48
	_leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
	_leaf.vertex_color_use_as_albedo = true
	_leaf.roughness = 0.95
	_leaf.metallic_specular = 0.15
	_leaf.backlight_enabled = true
	_leaf.backlight = Color(0.22, 0.27, 0.14)
	_bark = StandardMaterial3D.new()
	_bark.albedo_texture = preload("res://city/bark.png")
	_bark.roughness = 1.0

static func _tube(tool: SurfaceTool, a: Vector3, b: Vector3, ra: float, rb: float, sides: int) -> void:
	var up := (b - a).normalized()
	var right := up.cross(Vector3.FORWARD).normalized()
	if right.length_squared() < 0.5:
		right = up.cross(Vector3.RIGHT).normalized()
	var front := right.cross(up).normalized()
	for i in sides:
		for corner in [Vector2(i, 0), Vector2(i + 1, 0), Vector2(i + 1, 1),
				Vector2(i, 0), Vector2(i + 1, 1), Vector2(i, 1)]:
			var angle: float = corner.x * TAU / sides
			var normal: Vector3 = right * cos(angle) + front * sin(angle)
			tool.set_normal(normal)
			tool.set_uv(Vector2(corner.x / sides, (a.y + corner.y * a.distance_to(b)) * 0.7))
			tool.add_vertex((a - up * 0.035).lerp(b + up * 0.035, corner.y) + normal * lerpf(ra, rb, corner.y))

static func _card(tool: SurfaceTool, center: Vector3, right: Vector3, up: Vector3,
		outward: Vector3, size: float, quadrant: int, tint: Color) -> void:
	var normal := right.cross(up).normalized()
	for q in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
		var offset: Vector3 = right * (q.x - 0.5) * size + up * (q.y - 0.5) * size
		tool.set_normal((normal * 0.28 + (outward + offset * 0.6 + Vector3.UP * 0.5).normalized() * 0.72).normalized())
		tool.set_color(tint)
		tool.set_uv((Vector2(quadrant % 2, quadrant / 2) + Vector2(q.x, 1.0 - q.y) * 0.96 + Vector2.ONE * 0.02) * 0.5)
		tool.add_vertex(center + offset)

static func _make(index: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 53201 + index * 971
	var form: int = index % 3
	var height: float = rng.randf_range(6.4, 8.8)
	var radius: float = [2.7, 3.3, 2.1][form]
	var fork: float = height * 0.39
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var distant_wood := SurfaceTool.new()
	distant_wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf := SurfaceTool.new()
	leaf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var far_leaf := SurfaceTool.new()
	far_leaf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := Vector3.ZERO
	for k in 5:
		var q := Vector3(0.08 * sin(k * 1.4 + index), fork * (k + 1) / 5.0, 0.06 * cos(k + index))
		_tube(wood, p, q, lerpf(0.27, 0.14, k / 5.0), lerpf(0.27, 0.14, (k + 1) / 5.0), 9)
		_tube(distant_wood, p, q, lerpf(0.27, 0.14, k / 5.0), lerpf(0.27, 0.14, (k + 1) / 5.0), 5)
		p = q
	var leaders: Array[Vector3] = []
	for limb in 4:
		var angle: float = limb * TAU / 4.0 + index * 0.4
		var tip := p + Vector3(cos(angle), 0, sin(angle)) * radius * 0.35 + Vector3.UP * height * 0.28
		_tube(wood, p, tip, 0.13, 0.055, 8)
		_tube(distant_wood, p, tip, 0.13, 0.055, 5)
		leaders.append(tip)
	for branch in 14:
		var angle: float = branch * 2.39996 + rng.randf_range(-0.25, 0.25)
		var radial := Vector3(cos(angle), 0, sin(angle))
		var ring: float = 0.55 + 0.45 * sin((branch + 0.5) / 14.0 * PI)
		var end := radial * radius * ring
		end.y = fork + height * rng.randf_range(0.12, 0.45)
		if form == 2:
			end.y += height * 0.1
		var branch_start := p.lerp(leaders[branch % 4], rng.randf_range(0.35, 0.95))
		var middle := branch_start + radial * radius * 0.25 + Vector3.UP * rng.randf_range(0.2, 0.7)
		_tube(wood, branch_start, middle, 0.065, 0.035, 7)
		_tube(wood, middle, end, 0.035, 0.009, 6)
		_tube(distant_wood, branch_start, middle, 0.065, 0.035, 4)
		_tube(distant_wood, middle, end, 0.035, 0.009, 4)
		for twig in 3:
			var tip := end + Vector3(rng.randf_range(-0.65, 0.65), rng.randf_range(-0.2, 0.65), rng.randf_range(-0.65, 0.65))
			_tube(wood, middle.lerp(end, 0.6), tip, 0.024, 0.006, 5)
			for card in 9:
				var center := tip + Vector3(rng.randf_range(-0.55, 0.55), rng.randf_range(-0.35, 0.45), rng.randf_range(-0.55, 0.55))
				var rotation := Basis.from_euler(Vector3(rng.randf_range(-1.0, 1.0), rng.randf() * TAU, rng.randf_range(-0.7, 0.7)))
				var size: float = rng.randf_range(0.9, 1.35)
				var shade: float = rng.randf_range(0.78, 1.0)
				var tint := Color(shade, shade, shade * 0.94)
				var quadrant: int = rng.randi_range(0, 3)
				_card(leaf, center, rotation.x, rotation.y, radial, size, quadrant, tint)
				if card % 3 == 0:
					_card(far_leaf, center, rotation.x, rotation.y, radial, size * 1.65, quadrant, tint)
	var wood_arrays: Array = wood.commit_to_arrays()
	var near := ArrayMesh.new()
	near.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wood_arrays)
	near.surface_set_material(0, _bark)
	var leaf_arrays: Array = leaf.commit_to_arrays()
	near.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arrays)
	near.surface_set_material(1, _leaf)
	var far := ArrayMesh.new()
	far.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, distant_wood.commit_to_arrays())
	far.surface_set_material(0, _bark)
	far.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, far_leaf.commit_to_arrays())
	far.surface_set_material(1, _leaf)
	var vertices: PackedVector3Array = leaf_arrays[Mesh.ARRAY_VERTEX]
	var low: float = INF
	var high: float = -INF
	for vertex in vertices:
		low = minf(low, vertex.y)
		high = maxf(high, vertex.y)
	var center_y: float = (low + high) * 0.5
	var hit_radius: float = 0.0
	for vertex in vertices:
		hit_radius = maxf(hit_radius, vertex.distance_to(Vector3(0, center_y, 0)))
	return [near, fork, hit_radius, far, center_y]
