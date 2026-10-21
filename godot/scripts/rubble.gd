extends RefCounted
## What a mech's cannon leaves on a building: a scorched crater on the wall
## and a pile of broken concrete and brick on the ground below, which stays
## (it blocks a little of the sidewalk). Placeholders built from boxes until
## rubble models arrive.

const MAX_PILES := 40
static var _piles: Array = []
static var _concrete: StandardMaterial3D
static var _brick: StandardMaterial3D
static var _scorch: StandardMaterial3D


static func _mats() -> void:
	if _concrete:
		return
	_concrete = StandardMaterial3D.new()
	_concrete.albedo_color = Color(0.55, 0.54, 0.52)
	_concrete.roughness = 1.0
	_brick = StandardMaterial3D.new()
	_brick.albedo_color = Color(0.55, 0.3, 0.22)
	_brick.roughness = 1.0
	_scorch = StandardMaterial3D.new()
	_scorch.albedo_color = Color(0.05, 0.04, 0.04, 0.85)
	_scorch.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_scorch.roughness = 1.0


## A dark blast mark on the wall, facing out along `normal`.
static func crater(main: Node, at: Vector3, normal: Vector3) -> void:
	_mats()
	var q := MeshInstance3D.new()
	var m := QuadMesh.new()
	m.size = Vector2(2.6, 2.2)
	q.mesh = m
	q.material_override = _scorch
	main.add_child(q)
	q.global_position = at + normal * 0.05
	q.look_at(at + normal, Vector3.UP if abs(normal.y) < 0.9 else Vector3.FORWARD)
	q.rotate_object_local(Vector3.UP, PI)    # the quad's face towards the street
	_track(main, q)


## Broken pieces heaped where the wall meets the ground.
static func pile(main: Node, at: Vector3, normal: Vector3) -> void:
	_mats()
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var base := at + normal * 1.0
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(base + Vector3(0, 1, 0), base - Vector3(0, 30, 0), 1))
	if hit:
		base = hit.position
	var root := StaticBody3D.new()
	root.collision_layer = 1
	main.add_child(root)
	root.global_position = base
	for k in randi_range(9, 14):
		var mi := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = Vector3(randf_range(0.25, 0.9), randf_range(0.15, 0.5), randf_range(0.25, 0.8))
		mi.mesh = b
		mi.material_override = _concrete if randf() < 0.6 else _brick
		mi.position = Vector3(randf_range(-1.3, 1.3), b.size.y * 0.4 + randf_range(0, 0.3), randf_range(-0.9, 0.9)) \
				+ normal * randf_range(-0.3, 0.6)
		mi.rotation = Vector3(randf_range(-0.6, 0.6), randf() * TAU, randf_range(-0.6, 0.6))
		mi.visibility_range_end = 160.0
		root.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.4, 0.5, 1.6)
	cs.shape = shape
	cs.position = Vector3(0, 0.25, 0)
	root.add_child(cs)
	_track(main, root)


static func _track(main: Node, n: Node) -> void:
	_piles.append(n)
	while _piles.size() > MAX_PILES * 2:
		var old = _piles.pop_front()
		if is_instance_valid(old):
			old.queue_free()
