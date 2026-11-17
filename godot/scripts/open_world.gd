extends Node
## Open-world prototype (docs/OPEN_WORLD.md): neighbouring map tiles come in
## and go out round the player while the round's own map stays as it is.
## A tile is another map of the same source and frame (res://city/<id>.glb,
## <id>_collision.glb, <id>.spawn.json with its bounds): its meshes and
## collision only - no navigation mesh, people, traffic, props or landmarks.
##
## Started by `main.open_world("owb")` (DevAgent `eval`) or `-- --open-world=owb`.
## Each step is timed (`report()`): reading the files on a loader thread,
## building the scene and its collision on a worker thread, and the frame
## that puts it into the tree - the one the player can feel.

const LOAD_M := 120.0       # a tile comes in when the player is this near its bounds
const UNLOAD_M := 220.0     # and goes out beyond this
const CHECK_S := 0.25

var main: Node
var threaded := true        # false: build on the main thread (to compare the hitch)
var tiles := {}             # id -> {rect, state, node, task, t0, ...}
var events: Array = []      # [{id, what, ms}, ...] in order
var _since := 0.0
var _walls: StaticBody3D


func add_tile(id: String) -> bool:
	var spawn := "res://city/%s.spawn.json" % id
	if tiles.has(id) or not FileAccess.file_exists(spawn) or not ResourceLoader.exists(_glb(id)):
		return false
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(spawn))
	var b: Array = data["bounds"]       # [min_x, max_x, min_z, max_z]
	tiles[id] = {"rect": Rect2(b[0], b[2], b[1] - b[0], b[3] - b[2]), "state": "out", "node": null}
	_edge_walls()
	# the round's map draws its own far ground and towers where the tiles are
	var horizon := main.get_node_or_null("Horizon") as Node3D
	if horizon:
		horizon.visible = false
	return true


func report() -> Dictionary:
	var states := {}
	for id in tiles:
		states[id] = tiles[id]["state"]
	return {"tiles": states, "events": events, "threaded": threaded}


func _glb(id: String) -> String:
	return "res://city/%s.glb" % id


func _col(id: String) -> String:
	return "res://city/%s_collision.glb" % id


func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for id in tiles:
		var t: Dictionary = tiles[id]
		match t["state"]:
			"loading":
				_poll_loading(id, t)
			"building":
				if WorkerThreadPool.is_task_completed(t["task"]):
					WorkerThreadPool.wait_for_task_completion(t["task"])
					_note(id, "build (worker thread)", t["t0"])
					_enter(id, t)
	_since += dt
	if _since < CHECK_S:
		return
	_since = 0.0
	var p := Vector2(cam.global_position.x, cam.global_position.z)
	for id in tiles:
		var t: Dictionary = tiles[id]
		var d := _distance(t["rect"], p)
		if t["state"] == "out" and d < LOAD_M:
			t["state"] = "loading"
			t["t0"] = Time.get_ticks_usec()
			ResourceLoader.load_threaded_request(_glb(id), "", true)
			if ResourceLoader.exists(_col(id)):
				ResourceLoader.load_threaded_request(_col(id), "", true)
		elif t["state"] == "in" and d > UNLOAD_M:
			var t0 := Time.get_ticks_usec()
			(t["node"] as Node).queue_free()
			t["node"] = null
			t["state"] = "out"
			_note(id, "unload", t0)


func _distance(r: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - p.y, p.y - r.end.y), 0.0)
	return Vector2(dx, dz).length()


func _poll_loading(id: String, t: Dictionary) -> void:
	var paths := [_glb(id)]
	if ResourceLoader.exists(_col(id)):
		paths.append(_col(id))
	for path in paths:
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		if st != ResourceLoader.THREAD_LOAD_LOADED:
			t["state"] = "failed"
			return
	t["scenes"] = paths.map(func(path: String) -> PackedScene: return ResourceLoader.load_threaded_get(path))
	_note(id, "read files (loader thread)", t["t0"])
	t["t0"] = Time.get_ticks_usec()
	if threaded:
		t["state"] = "building"
		t["task"] = WorkerThreadPool.add_task(_build.bind(id))
	else:
		_build(id)
		_note(id, "build (main thread)", t["t0"])
		_enter(id, t)


## The tile's scene with its collision, not yet in the tree (so a worker
## thread may build it): the same rules as main.gd _load_city.
func _build(id: String) -> void:
	var t: Dictionary = tiles[id]
	var scenes: Array = t["scenes"]
	var root := Node3D.new()
	root.name = "Tile_" + id
	var city: Node = (scenes[0] as PackedScene).instantiate()
	city.name = "City"
	root.add_child(city)
	var custom := scenes.size() > 1
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		var kind: String = main.city_mesh_kind(mi)
		if (custom and kind in main.VISUAL_ONLY) or kind in main.NO_COLLISION:
			continue
		(mi as MeshInstance3D).create_trimesh_collision()
		if kind in main.ROOFS:
			for body in mi.find_children("*", "StaticBody3D", false, false):
				(body as StaticBody3D).collision_layer = main.ROOF_LAYER
	if custom:
		var col: Node = (scenes[1] as PackedScene).instantiate()
		col.name = "SidewalkCollision"
		root.add_child(col)
		for mi in col.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).create_trimesh_collision()
			(mi as MeshInstance3D).visible = false
	for cs in root.find_children("*", "CollisionShape3D", true, false):
		var shape: Shape3D = (cs as CollisionShape3D).shape
		if shape is ConcavePolygonShape3D:
			(shape as ConcavePolygonShape3D).backface_collision = true
	t["node"] = root
	t.erase("scenes")


func _enter(id: String, t: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var root: Node3D = t["node"]
	add_child(root)
	var city := root.get_node("City")
	main._water(city)
	main._matte_grass(city)
	main._kit_facades(city, true)
	t["state"] = "in"
	_note(id, "enter the tree (main thread)", t0)


func _note(id: String, what: String, t0: int) -> void:
	events.append({"id": id, "what": what, "ms": snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1)})


## The map's invisible border walls, moved out to enclose the tiles too.
func _edge_walls() -> void:
	var old := main.get_node_or_null("EdgeWalls")
	if old:
		old.queue_free()
		old.name = "EdgeWallsOld"
	if _walls:
		_walls.queue_free()
	var r: Rect2 = main.bounds
	for id in tiles:
		r = r.merge(tiles[id]["rect"])
	_walls = StaticBody3D.new()
	_walls.name = "OpenWorldWalls"
	var elev: Vector2 = main.elev
	var h := elev.y - elev.x + 120.0
	var c := r.get_center()
	for side in 4:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(r.size.x + 4, h, 1) if side < 2 else Vector3(1, h, r.size.y + 4)
		cs.shape = shape
		match side:
			0: cs.position = Vector3(c.x, elev.x + h / 2 - 30, r.end.y + 0.5)
			1: cs.position = Vector3(c.x, elev.x + h / 2 - 30, r.position.y - 0.5)
			2: cs.position = Vector3(r.end.x + 0.5, elev.x + h / 2 - 30, c.y)
			3: cs.position = Vector3(r.position.x - 0.5, elev.x + h / 2 - 30, c.y)
		_walls.add_child(cs)
	_walls.collision_layer = 8          # players only
	add_child(_walls)
