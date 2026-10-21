extends RefCounted
## Draw-call batching: many copies of the same mesh (street furniture, shrubs,
## tree templates) become one MultiMeshInstance3D per map cell. Each cell is
## culled on its own, so batching does not draw the whole city at once.
##
## add() collects instances; build() makes the MultiMeshes under `parent` and
## returns nothing; ref() tells where an added instance ended up, so a single
## one can still be moved or hidden later (a tree shaking, a prop knocked over).

const CELL := 64.0

var _groups := {}       # key -> {mesh, material, shadow, vis_end, xforms: [], ids: []}
var _where := {}        # id -> [MultiMesh, index]


## Queue one copy of `mesh` at global transform `xf`. `id` (any value) lets
## ref() find it after build().
func add(mesh: Mesh, xf: Transform3D, material: Material = null, vis_end := 0.0,
		shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON, id: Variant = null) -> void:
	var cell := Vector2i(floori(xf.origin.x / CELL), floori(xf.origin.z / CELL))
	var key := [mesh.get_rid(), material.get_rid() if material else RID(), cell, vis_end, shadow]
	if not _groups.has(key):
		_groups[key] = {"mesh": mesh, "material": material, "shadow": shadow, "vis_end": vis_end,
				"xforms": [], "ids": []}
	_groups[key]["xforms"].append(xf)
	_groups[key]["ids"].append(id)


## Queue every MeshInstance3D under `node` (as it stands now) and free it.
func absorb(node: Node3D, vis_end := -1.0, id: Variant = null) -> void:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not m.visible:
			continue
		var ve: float = m.visibility_range_end if vis_end < 0.0 else vis_end
		add(m.mesh, m.global_transform, m.material_override, ve, m.cast_shadow, id)
		m.get_parent().remove_child(m)
		m.queue_free()


func build(parent: Node3D) -> int:
	var made := 0
	for key in _groups:
		var g: Dictionary = _groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = g["mesh"]
		mm.instance_count = g["xforms"].size()
		for i in mm.instance_count:
			mm.set_instance_transform(i, g["xforms"][i])
			if g["ids"][i] != null:
				if not _where.has(g["ids"][i]):
					_where[g["ids"][i]] = []
				_where[g["ids"][i]].append([mm, i, g["xforms"][i]])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = g["material"]
		mmi.cast_shadow = g["shadow"]
		if g["vis_end"] > 0.0:
			mmi.visibility_range_end = g["vis_end"]
			mmi.visibility_range_end_margin = 5.0
		parent.add_child(mmi)
		made += 1
	_groups.clear()
	return made


## [[MultiMesh, index, original transform], ...] for an id given to add().
func ref(id: Variant) -> Array:
	return _where.get(id, [])
