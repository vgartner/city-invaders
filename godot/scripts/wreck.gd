extends RefCounted
## A destroyed robot comes apart. The robots are one skinned mesh each, but
## segmented: every plate follows one bone. The mesh is split once per model
## (during loading) into one piece per bone - triangles go to their vertices'
## dominant bone, groups too small to matter merge into the parent bone - and
## each piece is stored in its bone's rest space. On death every piece becomes
## a short-lived rigid body at its bone's current pose, thrown outwards.
## Purely visual: every peer breaks its own copy.

const MIN_TRIS := 120             # smaller groups join the parent bone's piece
const LIFETIME := 9.0

static var _cache := {}           # Mesh -> Array of {bone, mesh, aabb}


## Split the model's meshes ahead of time (a few hundred ms per robot type).
static func prepare(scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		return
	var model: Node3D = (load(scene_path) as PackedScene).instantiate()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		_pieces(mi)
	model.free()


static func _pieces(mi: MeshInstance3D) -> Array:
	var mesh := mi.mesh
	if mesh == null or mi.skin == null:
		return []
	if _cache.has(mesh):
		return _cache[mesh]
	var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D
	if skel == null:
		return []
	var skin := mi.skin
	var bind_bone := PackedInt32Array()
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(skin.get_bind_name(b))
		bind_bone.append(bone)
	var out := []
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if pos.is_empty() or bones.is_empty() or idx.is_empty():
			continue
		var per := bones.size() / pos.size()
		var vbone := PackedInt32Array()
		vbone.resize(pos.size())
		for v in pos.size():
			var best := 0
			var bw := -1.0
			for k in per:
				if weights[v * per + k] > bw:
					bw = weights[v * per + k]
					best = bones[v * per + k]
			vbone[v] = bind_bone[best] if best < bind_bone.size() else 0
		# triangles by bone (majority of the three corners)
		var groups := {}
		for t in range(0, idx.size(), 3):
			var b0 := vbone[idx[t]]
			var b1 := vbone[idx[t + 1]]
			var b2 := vbone[idx[t + 2]]
			var b := b0 if (b0 == b1 or b0 == b2) else (b1 if b1 == b2 else b0)
			if not groups.has(b):
				groups[b] = PackedInt32Array()
			var g: PackedInt32Array = groups[b]
			g.append(idx[t])
			g.append(idx[t + 1])
			g.append(idx[t + 2])
			groups[b] = g
		# children come after their parents in the skeleton: fold small leaves up
		var keys := groups.keys()
		keys.sort()
		keys.reverse()
		for b in keys:
			var g: PackedInt32Array = groups[b]
			var parent := skel.get_bone_parent(b)
			if g.size() / 3 < MIN_TRIS and parent >= 0:
				var into: PackedInt32Array = groups.get(parent, PackedInt32Array())
				into.append_array(g)
				groups[parent] = into
				groups.erase(b)
		var mat := mi.get_active_material(s)
		for b in groups:
			var inv := skel.get_bone_global_rest(b).affine_inverse()
			var remap := {}
			var p2 := PackedVector3Array()
			var n2 := PackedVector3Array()
			var u2 := PackedVector2Array()
			var i2 := PackedInt32Array()
			for i in groups[b]:
				if not remap.has(i):
					remap[i] = p2.size()
					p2.append(inv * pos[i])
					n2.append((inv.basis * nrm[i]).normalized() if not nrm.is_empty() else Vector3.UP)
					u2.append(uv[i] if not uv.is_empty() else Vector2.ZERO)
				i2.append(remap[i])
			var a2 := []
			a2.resize(Mesh.ARRAY_MAX)
			a2[Mesh.ARRAY_VERTEX] = p2
			a2[Mesh.ARRAY_NORMAL] = n2
			a2[Mesh.ARRAY_TEX_UV] = u2
			a2[Mesh.ARRAY_INDEX] = i2
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)
			am.surface_set_material(0, mat)
			out.append({"bone": b, "mesh": am, "aabb": am.get_aabb()})
	_cache[mesh] = out
	return out


## Break `model` apart where it stands. `push` is added to every piece's
## velocity (e.g. the direction the killing shot came from).
static func shatter(model: Node3D, push := Vector3.ZERO, spin := 6.0) -> void:
	var scene := model.get_tree().current_scene
	var centre := model.global_position + Vector3(0, 1.0, 0)
	var any := false
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var skel := m.get_node_or_null(m.skeleton) as Skeleton3D
		var pieces := _pieces(m)
		if (skel == null or pieces.is_empty()) and m.mesh and m.skin == null and m.visible:
			# rigid sub-mesh (drone rotors, turret): it is its own piece
			pieces = [{"xf": m.global_transform, "mesh": m.mesh, "aabb": m.mesh.get_aabb()}]
		if pieces.is_empty():
			continue
		any = true
		for p in pieces:
			var xf: Transform3D = p["xf"] if p.has("xf") else skel.global_transform * skel.get_bone_global_pose(p["bone"])
			var scale := xf.basis.get_scale()
			var body := RigidBody3D.new()
			body.collision_layer = 0
			body.collision_mask = 1
			var vis := MeshInstance3D.new()
			vis.mesh = p["mesh"]
			vis.scale = scale
			body.add_child(vis)
			var box: AABB = p["aabb"]
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = (box.size * scale).max(Vector3.ONE * 0.08)
			cs.shape = shape
			cs.position = box.get_center() * scale
			body.add_child(cs)
			body.mass = clamp(shape.size.x * shape.size.y * shape.size.z * 400.0, 2.0, 200.0)
			scene.add_child(body)
			body.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
			var at := body.global_transform * cs.position
			var out := at - centre
			out.y = 0
			body.linear_velocity = out.normalized() * randf_range(1.5, 4.5) + Vector3(0, randf_range(1.0, 4.0), 0) + push
			body.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * spin
			var tw := body.create_tween()
			tw.tween_interval(LIFETIME)
			tw.tween_property(vis, "scale", Vector3.ZERO, 0.6)
			tw.tween_callback(body.queue_free)
	if any:
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = false
