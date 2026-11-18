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
var hashed := 0                 # files whose SHA-256 this pass computed (prepare)
var _collect := false           # prepare(): note the files, change nothing
var _paths: Dictionary = {}     # path -> true, the imported files seen while collecting
var _keys: Dictionary = {}      # path -> payload key, from prepare()
var _work: PackedStringArray = []
var _lengths: PackedInt64Array = []
var _sums: Array = []
# What was hashed before: path -> [modified time, length, key], kept in
# user://texture_hashes.json between runs. A file that changed (artwork
# imported again) is hashed again; another build of the game (its version,
# its executable's date - files inside a PCK have no date of their own)
# starts from nothing.
const KNOWN_FILE := "user://texture_hashes.json"
static var _known: Dictionary = {}
static var _known_read := false


static func _stamp() -> String:
	return "%s %d" % [ProjectSettings.get_setting("application/config/version", ""),
			FileAccess.get_modified_time(OS.get_executable_path())]


static func _read_known() -> void:
	_known_read = true
	if not FileAccess.file_exists(KNOWN_FILE):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(KNOWN_FILE))
	if data is Dictionary and data.get("build", "") == _stamp() and data.get("files") is Dictionary:
		for path in data["files"]:
			var k: Array = data["files"][path]
			if k.size() == 3:
				_known[path] = [int(k[0]), int(k[1]), String(k[2])]


static func _write_known() -> void:
	var file := FileAccess.open(KNOWN_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"build": _stamp(), "files": _known}))


## Before resource() and tree(): work out the payload key of every imported
## texture under `values` (as resource() takes them) and `root` on worker
## threads, while the caller's frames go on. Hashing 1,430 files (1.2 GiB)
## took 7.2 s on the main thread behind the loading screen; a file whose
## length no other file shares needs no hash at all, the rest are hashed in
## parallel, and what a session hashed once it remembers.
func prepare(values: Variant, root: Node, scene_tree: SceneTree) -> void:
	_collect = true
	resource(values)
	tree(root)
	_collect = false
	_visited.clear()
	_work = PackedStringArray(_paths.keys())
	_paths.clear()
	if _work.is_empty():
		return
	if not _known_read:
		_read_known()
	_lengths.resize(_work.size())
	var task := WorkerThreadPool.add_group_task(_length, _work.size())
	while not WorkerThreadPool.is_group_task_completed(task):
		await scene_tree.process_frame
	WorkerThreadPool.wait_for_group_task_completion(task)
	var by_length := {}
	for i in _work.size():
		by_length[_lengths[i]] = by_length.get(_lengths[i], 0) + 1
	var todo := PackedStringArray()
	var todo_at := PackedInt32Array()
	for i in _work.size():
		var path := _work[i]
		if by_length[_lengths[i]] < 2:
			_keys[path] = "only:" + path             # no other file is this long: nothing to share with
			continue
		var known: Array = _known.get(path, [])
		if known.size() == 3 and known[0] == FileAccess.get_modified_time(path) and known[1] == _lengths[i]:
			_keys[path] = known[2]
			continue
		todo.append(path)
		todo_at.append(i)
	if todo.is_empty():
		return
	_work = todo
	_sums.resize(todo.size())
	task = WorkerThreadPool.add_group_task(_sum, todo.size())
	while not WorkerThreadPool.is_group_task_completed(task):
		await scene_tree.process_frame
	WorkerThreadPool.wait_for_group_task_completion(task)
	for k in todo.size():
		var key := String(_sums[k])
		if key.is_empty():
			continue
		_keys[todo[k]] = key
		_known[todo[k]] = [FileAccess.get_modified_time(todo[k]), _lengths[todo_at[k]], key]
		hashed += 1
	_write_known()


func _length(i: int) -> void:
	var file := FileAccess.open(_work[i], FileAccess.READ)
	_lengths[i] = file.get_length() if file else -1 - i


func _sum(i: int) -> void:
	_sums[i] = FileAccess.get_sha256(_work[i])

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
	if _collect:
		_paths[path] = true
		return texture
	var key: String = _keys[path] if _keys.has(path) else FileAccess.get_sha256(path)
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
