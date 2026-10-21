extends Node3D
## A landmark built in parts (assets/<collection>/landmarks/<set>/<site>/site.json):
## a light silhouette far away (lod2), a volume nearer (lod1), the detailed
## exterior close by - with its doors and stairs, its windows dark while the
## rooms are not there - and interiors loaded only when someone asks to go in (E at the
## entrance): the doors open once the rooms are ready, and walking away
## unloads them again. Parts load in the background, one instanced a frame.
##
## site.json (written with the models): "size_m", "entry" (local x, y, z),
## "parts": {key: {"file", "triangles", "bounds", "collisions": [{centre,
## size, rotation_y, occluder}], "markers"}}. All parts share one origin
## (the plan's centre on the ground, front -Z).
##
## The exterior's structural boxes (and a gate across the entrance while it
## is shut) exist from the start, whatever is drawn: the navmesh, the robots
## and the bullets see the building from anywhere. Every peer streams for its
## own player. Based on the landmark pack's example component (CC0).

const DETAIL_M := 85.0          # from the building's edge: the detailed exterior
const LOD1_M := 230.0           # then the volume; beyond, the silhouette
const HYSTERESIS_M := 12.0
const SECTOR_M := 40.0          # interiors within this of the player load once asked for
const ENTRY_REACH_M := 4.5      # E works this close to the entrance
const RELEASE_M := 85.0         # gone this far, the interiors are let go
const MAX_LAMPS := 6            # interior lights a site makes (lamp_* markers)

static var _materials := {}     # one material per name across every site

var site := {}
var base_dir := ""
var title := ""
var parts_wanted: Array = []    # for a square: which parts stand (monument, furniture...)
var entry_requested := false
var entry_ready := false

var _loaded := {}
var _pending := {}
var _failed := {}
var _wanted := {}
var _level := ""
var _interiors: Array[String] = []
var _base: Array[String] = []
var _gate: CollisionShape3D
var _pivots: Array[Node3D] = []
var _door := 0.0
var _player_at := Vector3.INF


func configure(json_path: String, l: Dictionary) -> void:
	site = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	base_dir = json_path.get_base_dir()
	title = String(l.get("caption", site.get("title", "")))
	for key in site["parts"]:
		if String(key).begins_with("interior_") and key != "interior_proxy":
			_interiors.append(String(key))
	if site["parts"].has("exterior"):
		_base.append("exterior")
	else:
		# a square: the chosen parts (the map has its own ground and trees)
		for key in l.get("parts", ["monument"]):
			if site["parts"].has(key):
				_base.append(key)
	_structure()
	set_process(true)


## The exterior's collision boxes (or a square's base parts'), always there.
func _structure() -> void:
	var body := StaticBody3D.new()
	body.name = "structure"
	add_child(body)
	for key in _base + (["stairs"] if site["parts"].has("stairs") else []):
		for item in site["parts"][key].get("collisions", []):
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(item["size"][0], item["size"][1], item["size"][2])
			cs.shape = box
			cs.position = Vector3(item["centre"][0], item["centre"][1], item["centre"][2])
			cs.rotation.y = float(item.get("rotation_y", 0.0))
			body.add_child(cs)
	if _interiors.is_empty():
		return
	# the entrance stays shut until the rooms behind it are there
	var gate := StaticBody3D.new()
	gate.name = "entry_gate"
	add_child(gate)
	_gate = CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.8, 4.8, 0.28)
	_gate.shape = shape
	gate.add_child(_gate)
	var e: Array = site["entry"]
	gate.position = Vector3(e[0], 2.4, e[2])
	if absf(float(e[0])) > absf(float(e[2])) * 0.25 and site.get("size_m", [0, 0, 0])[2] > 40.0:
		gate.rotation.y = -PI / 2.0      # an entrance in a side wall (the Casa de Cultura's passage)


func has_interiors() -> bool:
	return not _interiors.is_empty()


func distance_to_building(at: Vector3) -> float:
	var p := to_local(at)
	var size: Array = site.get("size_m", [30, 15, 30])
	return Vector2(maxf(absf(p.x) - float(size[0]) * 0.5, 0), maxf(absf(p.z) - float(size[2]) * 0.5, 0)).length()


func distance_to_entry(at: Vector3) -> float:
	var e: Array = site["entry"]
	var p := to_local(at)
	return Vector2(p.x - float(e[0]), p.z - float(e[2])).length()


func entrance() -> Vector3:
	var e: Array = site["entry"]
	return to_global(Vector3(e[0], 0, e[2]))


func inside(at: Vector3) -> bool:
	var p := to_local(at)
	for key in _interiors:
		var b: Dictionary = site["parts"][key].get("bounds", {})
		if b.is_empty():
			continue
		var lo: Array = b["min"]
		var hi: Array = b["max"]
		if p.x > float(lo[0]) and p.x < float(hi[0]) and p.z > float(lo[2]) and p.z < float(hi[2]) \
				and p.y > float(lo[1]) - 0.1 and p.y < maxf(float(hi[1]), float(lo[1]) + 3.2):
			return true
	return false


## E at the entrance: ask for the rooms (or, outside again, let them go).
func interact() -> void:
	if _interiors.is_empty():
		return
	if entry_requested and inside(_player_at):
		return
	entry_requested = not entry_requested


func _part_distance(key: String, p: Vector3) -> float:
	var b: Dictionary = site["parts"][key].get("bounds", {})
	if b.is_empty():
		return INF
	var lo: Array = b["min"]
	var hi: Array = b["max"]
	return Vector2(maxf(maxf(float(lo[0]) - p.x, p.x - float(hi[0])), 0),
			maxf(maxf(float(lo[2]) - p.z, p.z - float(hi[2])), 0)).length()


func _choose_level(d: float) -> String:
	if not site["parts"].has("lod1"):
		return "exterior"                    # a square's parts: no lighter versions
	if entry_requested or inside(_player_at):
		return "exterior"
	if _level == "exterior" and d < DETAIL_M + HYSTERESIS_M:
		return "exterior"
	if _level == "lod1" and d > DETAIL_M - HYSTERESIS_M and d < LOD1_M + HYSTERESIS_M:
		return "lod1"
	if _level == "lod2" and d > LOD1_M - HYSTERESIS_M:
		return "lod2"
	return "exterior" if d < DETAIL_M else ("lod1" if d < LOD1_M else "lod2")


func _keys(level: String) -> Array[String]:
	if level == "exterior":
		return _base.duplicate()
	var out: Array[String] = [level]
	return out


func _ask(key: String) -> void:
	if not site["parts"].has(key):
		return
	_wanted[key] = true
	if _loaded.has(key) or _pending.has(key) or _failed.has(key):
		return
	var path := base_dir.path_join(String(site["parts"][key]["file"]).get_file())
	if ResourceLoader.load_threaded_request(path, "PackedScene") == OK:
		_pending[key] = path
	else:
		_failed[key] = true


func _process(delta: float) -> void:
	var main := get_tree().current_scene
	var pl: Node3D = main._local_player() if main.has_method("_local_player") else null
	if pl == null:
		pl = get_viewport().get_camera_3d()
	if pl == null:
		return
	var at := pl.global_position
	_player_at = at
	_wanted.clear()
	var is_in := inside(at)
	if entry_requested and not is_in and distance_to_entry(at) > RELEASE_M:
		entry_requested = false
	var target := _choose_level(distance_to_building(at))
	for key in _keys(target):
		_ask(key)
	var ready := _keys(target).all(func(k): return _loaded.has(k))
	if ready:
		_level = target
	elif _level != "":
		for key in _keys(_level):
			_ask(key)                        # keep what shows until its replacement is in
	if target == "exterior":
		for key in ["doors", "stairs"]:
			_ask(key)
	if entry_requested:
		for key in _interiors:
			if is_in or _part_distance(key, to_local(at)) < SECTOR_M:
				_ask(key)
	_poll()
	entry_ready = entry_requested and _level == "exterior"
	for key in _interiors:
		if _wanted.has(key):
			entry_ready = entry_ready and _loaded.has(key)
	for key in _loaded.keys():
		if not _wanted.has(key):
			if key == "doors":
				_pivots.clear()
			_loaded[key].queue_free()
			_loaded.erase(key)
			continue
		var show: bool = _keys(_level).has(String(key))
		if key in ["doors", "stairs"]:
			show = _level == "exterior"
		elif String(key).begins_with("interior_"):
			show = entry_ready
		_loaded[key].visible = show
	if _gate:
		_gate.set_deferred("disabled", entry_ready)
	_shade_glass(not entry_ready)
	_door = move_toward(_door, 1.0 if entry_ready else 0.0, delta * 2.5)
	for pivot in _pivots:
		if is_instance_valid(pivot):
			pivot.rotation.y = _door * deg_to_rad(100.0) * float(pivot.get_meta("swing", 1.0))


func _poll() -> void:
	var made := false
	for key in _pending.keys():
		var path: String = _pending[key]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_failed[key] = true
			_pending.erase(key)
			continue
		if status != ResourceLoader.THREAD_LOAD_LOADED or made:
			continue
		var packed := ResourceLoader.load_threaded_get(path) as PackedScene
		_pending.erase(key)
		if not _wanted.has(key) or packed == null:
			continue
		var part := packed.instantiate() as Node3D
		part.name = "part_" + String(key)
		part.visible = false
		_share_materials(part)
		add_child(part)
		_part_physics(part, String(key))
		if key == "doors":
			_doors(part)
		if String(key).begins_with("interior_"):
			_lamps(part)
		_loaded[key] = part
		made = true                          # one a frame: no hitch


func _share_materials(node: Node) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat == null or mat.resource_name == "":
				continue
			if not _materials.has(mat.resource_name):
				_materials[mat.resource_name] = mat
			else:
				mesh.surface_set_material(i, _materials[mat.resource_name])
	for c in node.get_children():
		_share_materials(c)


## A loaded part's own collision: an interior's boxes, its curved floors;
## the glass panes of the exterior (the structure is already there).
func _part_physics(root: Node3D, key: String) -> void:
	if key.begins_with("lod") or key in ["doors", "interior_proxy"]:
		return
	if key.begins_with("interior_"):
		var body := StaticBody3D.new()
		root.add_child(body)
		for item in site["parts"][key].get("collisions", []):
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(item["size"][0], item["size"][1], item["size"][2])
			cs.shape = box
			cs.position = Vector3(item["centre"][0], item["centre"][1], item["centre"][2])
			cs.rotation.y = float(item.get("rotation_y", 0.0))
			body.add_child(cs)
		for mi in root.find_children("*floor*", "MeshInstance3D", true, false):
			if String(mi.name).contains("bridge") or String(mi.name).contains("tier_"):
				(mi as MeshInstance3D).create_trimesh_collision()
	for glass in root.find_children("*_glass", "MeshInstance3D", true, false):
		var gb := StaticBody3D.new()
		glass.add_child(gb)
		var gs := CollisionShape3D.new()
		var shape: ConcavePolygonShape3D = (glass as MeshInstance3D).mesh.create_trimesh_shape()
		shape.backface_collision = true
		gs.shape = shape
		gb.add_child(gs)


## With the rooms not there the windows are dark, nearly opaque glass: the
## empty shell behind them does not show (the pack's dark "interior_proxy"
## box did that, but on sites with walls set back - the Catedral's nave,
## MARGS between its pilasters - it covered the walls themselves).
static var _dark_glass: StandardMaterial3D
var _glass_shaded := false
var _glass_on: Node = null          # the exterior instance the glass was set on
func _shade_glass(dark: bool) -> void:
	var ext: Node = _loaded.get("exterior")
	if ext == null or (ext == _glass_on and dark == _glass_shaded):
		return
	if _dark_glass == null:
		_dark_glass = StandardMaterial3D.new()
		_dark_glass.albedo_color = Color(0.05, 0.07, 0.07)
		_dark_glass.metallic = 0.3
		_dark_glass.roughness = 0.15
	for g in ext.find_children("*glass*", "MeshInstance3D", true, false):
		(g as MeshInstance3D).material_override = _dark_glass if dark else null
	_glass_on = ext
	_glass_shaded = dark


## The door leaves turn on their hinge markers (*_pivot).
func _doors(root: Node3D) -> void:
	for marker in root.find_children("*_pivot", "Node3D", true, false):
		var leaf := String(marker.name).trim_suffix("_pivot")
		var found := root.find_children(leaf, "MeshInstance3D", true, false)
		if found.is_empty():
			continue
		var mesh: MeshInstance3D = found[0]
		mesh.reparent(marker, true)
		var body := AnimatableBody3D.new()
		body.sync_to_physics = false
		mesh.add_child(body)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var bb := mesh.get_aabb()
		box.size = bb.size.max(Vector3(0.04, 0.04, 0.04))
		cs.shape = box
		cs.position = bb.get_center()
		body.add_child(cs)
		_pivots.append(marker)
		marker.set_meta("swing", -1.0 if leaf.ends_with("_l") else 1.0)


## Light inside a loaded room (a few of its lamp_* markers).
func _lamps(root: Node3D) -> void:
	var n := 0
	for m in root.find_children("lamp*", "Node3D", true, false):
		if n >= MAX_LAMPS or m is MeshInstance3D:
			continue
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.95, 0.85)
		lamp.light_energy = 1.4
		lamp.omni_range = 10.0
		lamp.light_specular = 0.0          # the shared atlas has glossy spots: bright discs all over a room
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = 40.0
		lamp.distance_fade_length = 10.0
		m.add_child(lamp)
		n += 1


func stats() -> Dictionary:
	return {"title": title, "level": _level, "parts": _loaded.keys(), "pending": _pending.size(),
			"entry_requested": entry_requested, "entry_ready": entry_ready, "failed": _failed.keys()}
