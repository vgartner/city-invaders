extends Node3D
## Camera-local, budgeted grass. Samples the actual lawn triangles and verifies
## the top collision surface, so paving, water and roofs never receive blades.
const CELL := 12.0
const SPACING := 0.58
const RADIUS := 28.0
const BUDGET_US := 1800
const MAX_INSTANCES := 6000
static var _tuft: ArrayMesh
var _index: Dictionary = {}
var _cells: Dictionary = {}
var _pending: Array[Vector2i] = []
var _camera_cell := Vector2i(999999, 999999)
var _ready_index := false
var _instances := 0
var _source: Node3D
var _job_cell := Vector2i.ZERO
var _job_points: Array[Transform3D] = []
var _job_i := 0
var _job_active := false
var diagnostics := {"cells": 0, "instances": 0, "candidates": 0, "rejected_surface": 0, "build_max_us": 0}

func setup(source: Node3D) -> void:
	_source = source
	if _tuft == null:
		_tuft = _mesh()
	_index_lawns.call_deferred()

func _index_lawns() -> void:
	var started: int = Time.get_ticks_usec()
	for node in _source.find_children("grass*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for surface in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				for k in vertices.size():
					indices.append(k)
			for i in range(0, indices.size(), 3):
				var a: Vector3 = mi.global_transform * vertices[indices[i]]
				var b: Vector3 = mi.global_transform * vertices[indices[i + 1]]
				var c: Vector3 = mi.global_transform * vertices[indices[i + 2]]
				var den: float = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
				if absf(den) < 0.001:
					continue
				var lo := _key(a.min(b).min(c))
				var hi := _key(a.max(b).max(c))
				var tri: Array = [a, b, c, den]
				for x in range(lo.x, hi.x + 1):
					for z in range(lo.y, hi.y + 1):
						_index.get_or_add(Vector2i(x, z), []).append(tri)
				if Time.get_ticks_usec() - started > BUDGET_US:
					await get_tree().process_frame
					if not is_instance_valid(_source):
						return
					started = Time.get_ticks_usec()
	_ready_index = true

static func _key(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.z / CELL))

func _height(at: Vector2, cell: Vector2i) -> float:
	var highest: float = -INF
	for tri in _index.get(cell, []):
		var a: Vector3 = tri[0]
		var b: Vector3 = tri[1]
		var c: Vector3 = tri[2]
		var u: float = ((b.z - c.z) * (at.x - c.x) + (c.x - b.x) * (at.y - c.z)) / tri[3]
		var v: float = ((c.z - a.z) * (at.x - c.x) + (a.x - c.x) * (at.y - c.z)) / tri[3]
		var w: float = 1.0 - u - v
		if minf(u, minf(v, w)) >= -0.00001:
			highest = maxf(highest, u * a.y + v * b.y + w * c.y)
	return highest

func _process(_delta: float) -> void:
	if not _ready_index or not visible:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var center := _key(camera.global_position)
	if center != _camera_cell:
		_camera_cell = center
		_pending.clear()
		if _job_active and Vector2(_job_cell - center).length() * CELL > RADIUS + CELL:
			_job_active = false
		for key in _cells.keys():
			if (Vector2(key - center) * CELL).length() > RADIUS + CELL * 0.7:
				var old := _cells[key] as MultiMeshInstance3D
				_instances -= old.multimesh.instance_count
				old.queue_free()
				_cells.erase(key)
		for dx in range(-3, 4):
			for dz in range(-3, 4):
				var key := center + Vector2i(dx, dz)
				if _index.has(key) and not _cells.has(key) and Vector2(dx, dz).length() * CELL < RADIUS + CELL:
					_pending.append(key)
		_pending.sort_custom(func(a, b): return (a - center).length_squared() < (b - center).length_squared())
	if not _job_active and not _pending.is_empty() and _instances >= MAX_INSTANCES:
		var farthest: Vector2i = _cells.keys()[0]
		for key in _cells:
			if (key - center).length_squared() > (farthest - center).length_squared():
				farthest = key
		if (_pending[0] - center).length_squared() < (farthest - center).length_squared():
			var old := _cells[farthest] as MultiMeshInstance3D
			_instances -= old.multimesh.instance_count
			old.queue_free()
			_cells.erase(farthest)
		else:
			_pending.clear()
	if not _job_active and not _pending.is_empty() and _instances < MAX_INSTANCES:
		_job_cell = _pending.pop_front()
		_job_points = []
		_job_i = 0
		_job_active = true
	if _job_active:
		_step_cell()
	diagnostics["cells"] = _cells.size()
	diagnostics["instances"] = _instances

func _step_cell() -> void:
	var started: int = Time.get_ticks_usec()
	var side: int = ceili(CELL / SPACING)
	var space := get_world_3d().direct_space_state
	while _job_i < side * side and _instances + _job_points.size() < MAX_INSTANCES:
		var i: int = _job_i
		_job_i += 1
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([_job_cell.x, _job_cell.y, i])
		var at := Vector2(_job_cell) * CELL + Vector2(i % side + rng.randf_range(0.1, 0.9), i / side + rng.randf_range(0.1, 0.9)) * (CELL / side)
		var height: float = _height(at, _job_cell)
		diagnostics["candidates"] += 1
		if is_finite(height):
			var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, height + 1.5, at.y), Vector3(at.x, height - 0.3, at.y), 1)
			q.hit_from_inside = true
			var hit: Dictionary = space.intersect_ray(q)
			if hit and hit.collider.get_parent() is MeshInstance3D and String(hit.collider.get_parent().name).begins_with("grass"):
				var size: float = rng.randf_range(0.65, 1.25)
				_job_points.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size), hit.position - Vector3(_job_cell.x * CELL, 0.015, _job_cell.y * CELL)))
			else:
				diagnostics["rejected_surface"] += 1
		if Time.get_ticks_usec() - started >= BUDGET_US:
			break
	if _job_i >= side * side or _instances + _job_points.size() >= MAX_INSTANCES:
		_finish_cell()
	var elapsed: int = Time.get_ticks_usec() - started
	diagnostics["build_max_us"] = maxi(diagnostics["build_max_us"], elapsed)

func _finish_cell() -> void:
	if _tuft == null:
		_tuft = _mesh()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _tuft
	mm.instance_count = _job_points.size()
	for i in _job_points.size():
		mm.set_instance_transform(i, _job_points[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.transform = global_transform.affine_inverse() * Transform3D(Basis.IDENTITY, Vector3(_job_cell.x * CELL, 0, _job_cell.y * CELL))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = RADIUS + CELL
	add_child(node)
	_instances += mm.instance_count
	_cells[_job_cell] = node
	_job_active = false

static func _mesh() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 92017
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in 24:
		var angle: float = rng.randf() * TAU
		var across := Vector3(cos(angle), 0, sin(angle))
		var lean := Vector3(-sin(angle), 0, cos(angle)) * rng.randf_range(0.025, 0.09)
		var root := Vector3(rng.randf_range(-0.17, 0.17), 0, rng.randf_range(-0.17, 0.17))
		var height: float = rng.randf_range(0.07, 0.15)
		var width: float = rng.randf_range(0.0018, 0.004)
		var points: Array[Vector3] = [root - across * width, root + across * width,
			root + Vector3.UP * height * 0.6 + lean * 0.4 - across * width * 0.5,
			root + Vector3.UP * height * 0.6 + lean * 0.4 + across * width * 0.5,
			root + Vector3.UP * height + lean]
		var shade: float = rng.randf_range(0.8, 1.15)
		for vertex in [0, 1, 3, 0, 3, 2, 2, 3, 4]:
			var tip: float = points[vertex].y / height
			tool.set_color(Color(0.06, 0.11, 0.02).lerp(Color(0.16, 0.23, 0.05), tip) * shade)
			tool.set_normal((Vector3.UP * 0.65 + lean.normalized() * 0.35).normalized())
			tool.set_uv(Vector2(0, tip))
			tool.add_vertex(points[vertex])
	var mesh := tool.commit()
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/common/vegetation/grass.gdshader")
	mesh.surface_set_material(0, material)
	return mesh

## DevAgent smoke audit: sample existing blade anchors against the current surface.
func audit_samples(limit := 200) -> Dictionary:
	var result := {"sampled": 0, "wrong_surface": 0, "max_ground_error_m": 0.0,
		"instances": _instances, "limit": MAX_INSTANCES, "cells": _cells.size()}
	var space := get_world_3d().direct_space_state
	for node in _cells.values():
		var mesh: MultiMesh = node.multimesh
		var stride: int = maxi(1, int(mesh.instance_count / 12.0))
		for i in range(0, mesh.instance_count, stride):
			var at: Vector3 = node.global_transform * mesh.get_instance_transform(i).origin
			var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at - Vector3.UP * 0.3, 1)
			q.hit_from_inside = true
			var hit: Dictionary = space.intersect_ray(q)
			result["sampled"] += 1
			if not hit or not hit.collider.get_parent() is MeshInstance3D or not String(hit.collider.get_parent().name).begins_with("grass"):
				result["wrong_surface"] += 1
			else:
				result["max_ground_error_m"] = maxf(result["max_ground_error_m"], absf(at.y + 0.015 - hit.position.y))
			if result["sampled"] >= limit:
				return result
	return result
