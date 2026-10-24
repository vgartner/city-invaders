class_name TextureSharing
extends RefCounted
## Lossless sharing of imported 3D textures. Run behind the loading screen,
## after threaded model loads have completed. No import settings or pixels change.
## Per-pass weak indices neither retain textures nor outlive an artwork reload.
var _by_payload: Dictionary = {}
var _by_id: Dictionary = {}
var _visited: Dictionary = {}
var checked := 0
var shared := 0
var shared_bytes := 0

func _texture(texture: Texture2D) -> Texture2D:
	if not texture is CompressedTexture2D:
		return texture # Never read back live render targets or procedural textures.
	var id := texture.get_instance_id()
	if _by_id.has(id):
		var cached = _by_id[id].get_ref()
		if cached != null:
			return cached
	# Hash the imported payload, including format, mipmaps and import flags.
	# get_image() would read pixels back from Metal and can stall for seconds.
	# This path is inside the PCK in exported builds too, so no source PNGs
	# or precomputed alias manifest are required.
	var path: String = (texture as CompressedTexture2D).get_load_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return texture
	var key := FileAccess.get_sha256(path)
	if key.is_empty():
		return texture
	checked += 1
	var canonical: Texture2D = null
	if _by_payload.has(key):
		canonical = _by_payload[key].get_ref()
	if canonical == null:
		canonical = texture
		_by_payload[key] = weakref(texture)
	elif canonical != texture:
		shared += 1
		var file := FileAccess.open(path, FileAccess.READ)
		if file:
			shared_bytes += file.get_length()
	_by_id[id] = weakref(canonical)
	return canonical

func resource(value: Variant) -> void:
	if value is Array:
		for item in value:
			resource(item)
	elif value is Dictionary:
		for item in value.values():
			resource(item)
	elif value is Resource:
		var id: int = value.get_instance_id()
		if _visited.has(id):
			return
		_visited[id] = true
		if value is BaseMaterial3D:
			for slot in BaseMaterial3D.TEXTURE_MAX:
				var texture: Texture2D = value.get_texture(slot)
				if texture != null:
					var canonical := _texture(texture)
					if canonical != texture:
						value.set_texture(slot, canonical)
			resource(value.next_pass)
		elif value is ShaderMaterial and value.shader != null:
			for uniform in value.shader.get_shader_uniform_list():
				var parameter = value.get_shader_parameter(uniform.name)
				if parameter is Texture2D:
					var canonical := _texture(parameter)
					if canonical != parameter:
						value.set_shader_parameter(uniform.name, canonical)
			resource(value.next_pass)
		elif value is Mesh:
			for surface in value.get_surface_count():
				resource(value.surface_get_material(surface))
		elif value is PackedScene:
			var state: SceneState = value.get_state()
			for node in state.get_node_count():
				resource(state.get_node_instance(node))
				for property in state.get_node_property_count(node):
					resource(state.get_node_property_value(node, property))

func tree(root: Node) -> void:
	if root is GeometryInstance3D:
		resource(root.material_override)
		resource(root.material_overlay)
	if root is MeshInstance3D:
		resource(root.mesh)
		for surface in root.get_surface_override_material_count():
			resource(root.get_surface_override_material(surface))
	elif root is MultiMeshInstance3D and root.multimesh != null:
		resource(root.multimesh.mesh)
	for child in root.get_children():
		tree(child)
