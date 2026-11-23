extends Node
## Open-world prototype (docs/OPEN_WORLD.md): neighbouring map tiles come in
## and go out round the player while the round's own map stays as it is.
## A tile is another map of the same source and frame (res://city/<id>.glb,
## <id>_collision.glb, <id>.spawn.json with its bounds): its meshes, its
## collision and a navigation mesh of its own, baked on a thread once it is
## in and joined to the meshes round it by links across the edge, so people
## and robots walk over; its street furniture and its landmarks; and its
## streets, joined to the round's road graph, so traffic drives in and out.
##
## A round on a tile of a world (tools/map/tiles.py, <name>.world.json) starts
## it by itself; or `main.open_world("<id or world>")` (DevAgent `eval`), or
## `-- --open-world=<id or world>`.
## Each step is timed (`report()`): reading the files on a loader thread,
## building the scene and its collision on a worker thread, and the frame
## that puts it into the tree - the one the player can feel.

const BusRoutes := preload("res://scripts/bus_routes.gd")
const LOAD_M := 120.0       # a tile comes in when the player is this near its bounds
const UNLOAD_M := 220.0     # and goes out beyond this
const CHECK_S := 0.25
const LINK_STEP_M := 2.5    # a navigation link every so often along a tile's edge
const LINK_REACH_M := 1.2   # from this far outside the edge to this far inside
const TILE_PEOPLE := 14     # passers-by a tile brings
const TILE_ROBOTS := 4      # robots on patrol a tile brings
const TILE_TRAFFIC := 6     # vehicles a tile's streets bring
const ROBOT_CLEAR_M := 60.0 # no robot is born nearer a player than this
const EVEN_S := 1.5         # traffic is evened out between the map and the tiles this often,
const EVEN_GAP := 2.5       # when one has this many vehicles over its share and another under,
const EVEN_CLEAR_M := 100.0 # by moving one no player is this near to a street no player is this near
const FRAME_MS := 4.0       # street furniture: this much building a frame
const HOME := "@home"       # the round's own map in the events and the builder
const HOME_KEEPERS := ["mech", "collector"]   # robots that keep the round's map in: a goal of the round, people aboard

var main: Node
var threaded := true        # false: build on the main thread (to compare the hitch)
var tiles := {}             # id -> {rect, state, node, task, t0, ...}
var events: Array = []      # [{id, what, ms}, ...] in order
var _since := 0.0
var _even := 0.0
var _map_edges := -1        # how many of the road graph's edges are the round's map's
var _map_vehicles := -1     # the vehicles of the round's map, parked ones too, before any tile's
var _walls: StaticBody3D
var home := {}              # the round's own map, which leaves and comes back like a tile (_home_check)
var far := {}               # tile id (HOME for the round's map) -> its far model (tools/map/far_view.py)
var _jobs: Array[int] = []  # worker tasks after a bake, waited for when done (_reap) or when the world goes
var _baking: Array[NavigationMesh] = []    # meshes the navigation server is baking


## The tiles of a world (res://city/<name>.world.json, made by
## tools/map/tiles.py), or none if there is no such world.
static func world_tiles(world: String) -> Array:
	var path := "res://city/%s.world.json" % world
	if not FileAccess.file_exists(path):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	var out := []
	for t in (data.get("tiles", []) if data is Dictionary else []):
		out.append(String(t["id"]))
	return out


## The world a map is a tile of, or "".
static func world_of(map_id: String) -> String:
	for f in DirAccess.get_files_at("res://city"):
		if f.ends_with(".world.json") and world_tiles(f.trim_suffix(".world.json")).has(map_id):
			return f.trim_suffix(".world.json")
	return ""


## The far view of a world (tools/map/far_view.py): every tile's light model
## (<tile>_far.glb: its buildings as plain boxes on a coarse ground), shown
## while the tile is not in, and the ring round the world (the list's "far"),
## shown all the time. No collision, no shadows; a few MB in all.
func add_far(world: String) -> int:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://city/%s.world.json" % world))
	if not data is Dictionary:
		return 0
	var n := 0
	var ids: Array = []
	for t in data.get("tiles", []):
		ids.append(String(t["id"]))
	if data.has("far"):
		ids.append(String(data["far"]))
	for id in ids:
		var key: String = HOME if id == main.map_id else id
		var path := "res://city/%s.glb" % (id if id == data.get("far", "") else id + "_far")
		if far.has(key) or not ResourceLoader.exists(path):
			continue
		var node: Node3D = (load(path) as PackedScene).instantiate()
		node.name = "Far_" + id
		for mi in node.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if mi is MeshInstance3D:
				_far_windows(mi as MeshInstance3D)
		add_child(node)
		far[key] = node
		n += 1
	_far_update()
	return n


## The far walls carry UVs in window bays (far_view.py: 3.6 m along, a
## storey up): a window texture made here, one per bay, over the wall's own
## colour. One material per colour for all the far models.
var _far_mats := {}
var _window_tex: ImageTexture
func _far_windows(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null or not src.resource_name.begins_with("far_wall"):
			continue
		if not _far_mats.has(src.resource_name):
			if _window_tex == null:
				var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
				img.fill(Color.WHITE)
				img.fill_rect(Rect2i(10, 7, 12, 15), Color(0.30, 0.34, 0.40))      # the pane
				img.fill_rect(Rect2i(9, 22, 14, 2), Color(0.86, 0.86, 0.86))       # the sill
				img.generate_mipmaps()
				_window_tex = ImageTexture.create_from_image(img)
			var m := StandardMaterial3D.new()
			m.resource_name = src.resource_name
			m.albedo_color = src.albedo_color
			m.albedo_texture = _window_tex
			m.roughness = 0.95
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			_far_mats[src.resource_name] = m
		mi.set_surface_override_material(i, _far_mats[src.resource_name])


## A tile's far model shows while the tile itself is not in the tree.
func _far_update() -> void:
	for key in far:
		var node: Node3D = far[key]
		if key == HOME:
			node.visible = not home.is_empty() and home["state"] != "in"
		elif tiles.has(key):
			node.visible = tiles[key]["state"] != "in"
		else:
			node.visible = true                  # the ring round the world


func add_tile(id: String) -> bool:
	var spawn := "res://city/%s.spawn.json" % id
	if tiles.has(id) or not FileAccess.file_exists(spawn) or not ResourceLoader.exists(_glb(id)):
		return false
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(spawn))
	var b: Array = data["bounds"]       # [min_x, max_x, min_z, max_z]
	var ev: Array = data.get("elev", [0.0, 0.0])
	tiles[id] = {"rect": Rect2(b[0], b[2], b[1] - b[0], b[3] - b[2]), "state": "out", "node": null,
			"nav": false, "elev": Vector2(ev[0], ev[1]), "foreign": data.get("foreign", [])}
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
	if not home.is_empty():
		states[HOME] = home["state"]
	return {"tiles": states, "events": events, "threaded": threaded}


## People, robots and vehicles in each tile now, and in the round's map
## ("map"); "driving": the vehicles with their own driver aboard.
func census() -> Dictionary:
	var out := {}
	var rects := {"map": main.bounds}
	for id in tiles:
		rects[id] = tiles[id]["rect"]
	for id in rects:
		var r: Rect2 = rects[id]
		var n := [0, 0, 0, 0]
		for k in 3:
			for c in ([main.civilians_root, main.enemies_root, main.traffic_root][k] as Node).get_children():
				var p: Vector3 = (c as Node3D).global_position
				if r.has_point(Vector2(p.x, p.z)):
					n[k] += 1
					if k == 2 and c.get("occupied") and c.get("driver_peer") == 0:
						n[3] += 1
		out[id] = {"people": n[0], "robots": n[1], "vehicles": n[2], "driving": n[3]}
	return out


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
	_home_poll()
	_reap()
	_since += dt
	if _since < CHECK_S:
		return
	_since = 0.0
	_even += CHECK_S
	if _even >= EVEN_S:
		_even = 0.0
		_even_traffic()
	var p := Vector2(cam.global_position.x, cam.global_position.z)
	_home_check(cam.global_position)
	_far_update()
	var others := _others()
	for id in tiles:
		var t: Dictionary = tiles[id]
		var d := _distance(t["rect"], p)
		for q in others:
			d = minf(d, _distance(t["rect"], q))
		if t["state"] == "in" and not t.get("streets", false):
			_streets_in(id, t)
		if t["state"] == "in" and t.get("streets", false) and not t.get("cars", false):
			_traffic_in(t)
		if t["state"] == "out" and d < LOAD_M:
			t["state"] = "loading"
			t["t0"] = Time.get_ticks_usec()
			t["paths"] = _files(id)
			for path in t["paths"]:
				ResourceLoader.load_threaded_request(path, "", true)
		elif t["state"] == "in" and d > UNLOAD_M:
			if not _vacate(t):
				continue                       # a robot of the round is in it: the tile stays
			var t0 := Time.get_ticks_usec()
			t["nav"] = false
			for lm in t.get("landmarks", []):
				main._landmark_nodes.erase(lm)
			t.erase("landmarks")
			t.erase("held")
			(t["node"] as Node).queue_free()
			t["node"] = null
			t["state"] = "out"
			_note(id, "unload", t0)


## Multiplayer: the server keeps the tiles in round every player, not only
## round its own camera - the robots, the people and the traffic it runs
## need the ground, the collision and the navigation mesh where a client
## walks. A client loads round its own camera only.
func _others() -> Array:
	var out := []
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return out
	for pl in main.players_root.get_children():
		if pl is Node3D and pl.name != str(multiplayer.get_unique_id()):
			out.append(Vector2((pl as Node3D).global_position.x, (pl as Node3D).global_position.z))
	return out


## What a tile reads on the loader thread: its city, its collision, and the
## models of its landmarks (a shop closed until someone walks in: its light
## version; a set laid out from pieces: the pieces).
func _files(id: String) -> Array:
	var out := [_glb(id)]
	if ResourceLoader.exists(_col(id)):
		out.append(_col(id))
	var path := "res://city/%s.landmarks.json" % id
	var data = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else []
	for l in (data if data is Array else []):
		var model := String(l.get("model", ""))
		var models := []
		if model.ends_with("layout.json") and FileAccess.file_exists(model):
			var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(model))
			for inst in lay.get("instances", []):
				models.append(model.get_base_dir().path_join(inst["model"]).simplify_path())
		elif not model.ends_with(".json"):
			var lod: String = main._lod_path(model)
			models.append(lod if main._closed_shop(l) and ResourceLoader.exists(lod) else model)
		for m in models:
			if ResourceLoader.exists(m) and not out.has(m):
				out.append(m)
	# the shops the game draws itself: their interior set's furniture (read on
	# the main thread it cost a frame of 200 ms) and the wall plaster
	path = "res://city/%s.shells.json" % id
	var shells = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else []
	for sh in (shells if shells is Array else []):
		var interior := String(sh.get("interior", ""))
		if not FileAccess.file_exists(interior):
			continue
		var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(interior))
		for inst in lay.get("instances", []):
			var m := interior.get_base_dir().path_join(inst["model"]).simplify_path()
			if inst.get("category", "") == "furniture" and ResourceLoader.exists(m) and not out.has(m):
				out.append(m)
		if not out.has(main.SHELL_PLASTER):
			out.append(main.SHELL_PLASTER)
	return out


func _distance(r: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - p.y, p.y - r.end.y), 0.0)
	return Vector2(dx, dz).length()


func _poll_loading(id: String, t: Dictionary) -> void:
	var paths: Array = t["paths"]
	for path in paths:
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		if st != ResourceLoader.THREAD_LOAD_LOADED:
			t["state"] = "failed"
			return
	# the city and its collision first; the landmarks' models are held so the
	# main thread's load() of each finds it ready
	var loaded: Array = paths.map(func(path: String) -> Resource: return ResourceLoader.load_threaded_get(path))
	var n := 2 if ResourceLoader.exists(_col(id)) else 1
	t["scenes"] = loaded.slice(0, n)
	t["held"] = loaded.slice(n)
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
	var t: Dictionary = home if id == HOME else tiles[id]
	var scenes: Array = t["scenes"]
	var root := Node3D.new()
	root.name = "Tile_" + id
	var city: Node = (scenes[0] as PackedScene).instantiate()
	city.name = "City"
	root.add_child(city)
	var custom := scenes.size() > 1
	var top := 0.0
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		top = maxf(top, (mi as MeshInstance3D).get_aabb().end.y)
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
	t["top"] = top
	t.erase("scenes")


func _enter(id: String, t: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var root: Node3D = t["node"]
	add_child(root)
	var city := root.get_node("City")
	main._water(city)
	main._matte_grass(city)
	main._add_grass_detail(city)
	main._kit_facades(city, true)
	main.city_top = maxf(main.city_top, t.get("top", 0.0))    # ships cruise over the tallest roof loaded
	_wake(t.get("asleep", []))
	t.erase("asleep")
	t["state"] = "in"
	_note(id, "enter the tree (main thread)", t0)
	await _furnish(id, t, root)
	if is_instance_valid(root) and t["node"] == root:
		_bake(id, t)


## The tile's street furniture (<id>.props.json: trees, lamps, signs, benches)
## and its landmarks and shops (<id>.landmarks.json, <id>.shells.json), built
## the way the round's map builds its own, a few per frame. They are scenery
## with collision: a tile's lamp cannot be shot out or knocked over.
func _furnish(id: String, t: Dictionary, root: Node3D) -> void:
	var t0 := Time.get_ticks_usec()
	var props: Node3D = main.Props.new()
	props.name = "Props"
	props.set("tile", id)
	root.add_child(props)
	await props.call("build", "res://city/%s.props.json" % id, FRAME_MS)
	if not is_instance_valid(root) or t["node"] != root:
		return
	t["props"] = props
	for d in t.get("down", []):                 # shot out or run over before the tile left
		_prop_fall(props, d[0], d[1], d[2])
	_note(id, "street furniture, %d pieces, %d ms a frame (main thread)" % [props.get_child_count(), FRAME_MS], t0)
	var worst := 0.0
	var total := 0.0
	var slow := []
	var n0: int = main._landmark_nodes.size()
	var pickups: int = main.landmark_pickups.size()
	var todo := []
	var shaping := []
	for kind in ["landmarks", "shells"]:
		var path := "res://city/%s.%s.json" % [id, kind]
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			for l in (data if data is Array else []):
				todo.append([kind, l])
	for item in todo:
		await get_tree().process_frame
		if not is_instance_valid(root) or t["node"] != root:
			return
		var t1 := Time.get_ticks_usec()
		main.landmark_into = root
		if item[0] == "landmarks":
			main._landmark(item[1])
		else:
			main._shell(item[1])
		main.landmark_into = null
		if not main.trimesh_later.is_empty():
			shaping.append(_shape_later(main.trimesh_later.duplicate()))
			main.trimesh_later.clear()
		var ms := (Time.get_ticks_usec() - t1) / 1000.0
		if ms > 20.0:
			slow.append("%s %.0f ms" % [String(item[1].get("model", item[1].get("kind", "?"))).get_file(), ms])
		worst = maxf(worst, ms)
		total += ms
	t["landmarks"] = main._landmark_nodes.slice(n0)
	main.landmark_pickups.resize(pickups)        # the round's pickups are already out
	events.append({"id": id, "what": "%d landmarks and shops, one a frame (main thread): worst %.1f ms %s" % [todo.size(), worst, ", ".join(slow)],
			"ms": snappedf(total, 0.1)})
	# their triangle collision, built on a worker thread: put in one mesh a frame
	var t2 := Time.get_ticks_usec()
	var tris := 0
	worst = 0.0
	for job in shaping:
		while not job["done"][0]:
			await get_tree().process_frame
		if not is_instance_valid(root) or t["node"] != root:
			return
		tris += job["done"][1]
		for i in job["nodes"].size():
			var t3 := Time.get_ticks_usec()
			_shape_in(job, i)
			worst = maxf(worst, (Time.get_ticks_usec() - t3) / 1000.0)
			await get_tree().process_frame
			if not is_instance_valid(root) or t["node"] != root:
				return
	if not shaping.is_empty():
		_note(id, "landmark collision, %d triangles (worker thread), worst frame %.1f ms to put in" % [tris, worst], t2)
	# their collision is merged a frame later: the navmesh bake reads it
	for k in 2:
		await get_tree().physics_frame


## Every peer: a tile's lamp shot out or bin run over (props.gd, _fall). The
## tile keeps it until the round ends, also while it is out.
func prop_down(id: String, index: int, crushable: bool, dir: Vector3) -> void:
	if not tiles.has(id):
		return
	var t: Dictionary = tiles[id]
	if not t.has("down"):
		t["down"] = []
	t["down"].append([index, crushable, dir])
	var props = t.get("props")
	if t["state"] == "in" and is_instance_valid(props):
		_prop_fall(props, index, crushable, dir)


func _prop_fall(props: Node, index: int, crushable: bool, dir: Vector3) -> void:
	var n: int = (props.get("crushables") if crushable else props.get("destructibles")).size()
	if index < 0 or index >= n:
		return
	if crushable:
		props.call("knock_over", index, dir)
	else:
		props.call("break_prop", index)


## A new round: the tiles' street furniture stands again.
func restore_props() -> void:
	for t in tiles.values():
		t.erase("down")
		if t["state"] == "in" and is_instance_valid(t.get("props")):
			t["props"].call("restore_all")


## The triangle collision of a landmark's meshes, made on a worker thread:
## the job's "shapes" and "done" (and the triangles) are sized before it starts, so the thread
## only fills them in.
func _shape_later(meshes: Array[MeshInstance3D]) -> Dictionary:
	var job := {"nodes": meshes, "meshes": meshes.map(func(mi): return mi.mesh), "done": [false, 0]}
	var shapes := []
	shapes.resize(meshes.size())
	job["shapes"] = shapes
	_jobs.append(WorkerThreadPool.add_task(_make_shapes.bind(job["meshes"], shapes, job["done"])))
	return job


func _make_shapes(meshes: Array, shapes: Array, done: Array) -> void:
	for i in meshes.size():
		var shape: Shape3D = (meshes[i] as Mesh).create_trimesh_shape()
		if shape is ConcavePolygonShape3D:
			(shape as ConcavePolygonShape3D).backface_collision = true     # both sides, like the city's
		shapes[i] = shape
		done[1] += (meshes[i] as Mesh).get_faces().size() / 3
	done[0] = true


## A finished job's shape `i` under its mesh, the way create_trimesh_collision
## puts it.
func _shape_in(job: Dictionary, i: int) -> void:
	var mi: MeshInstance3D = job["nodes"][i]
	var shape: Shape3D = job["shapes"][i]
	if not is_instance_valid(mi) or shape == null:
		return
	var body := StaticBody3D.new()
	body.name = String(mi.name) + "_col"
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	mi.add_child(body)


## No tile on its way in: everything near the player is loaded (or failed)
## with its navigation mesh. The round waits for it before placing the
## antenna and the first containers in the whole loaded world.
func settled() -> bool:
	for id in tiles:
		var t: Dictionary = tiles[id]
		if t["state"] in ["loading", "building", "entering"] or (t["state"] == "in" and not t["nav"]):
			return false
	return home.is_empty() or home["state"] in ["in", "out", "failed"]


## The tiles people can walk in now, as rectangles.
func areas() -> Array:
	var out := []
	for id in tiles:
		if tiles[id]["nav"]:
			out.append(tiles[id]["rect"])
	return out


## Things of the round standing where a tile or the map goes out (a people
## container, an antenna; in the map also who and what is in it) sleep in
## place - hidden, stopped, out of the physics - until it is back.
func _sleep(nodes: Array, area: Rect2) -> Array:
	var asleep := []
	for n in nodes:
		if is_instance_valid(n) and n is Node3D and not n.has_meta("asleep") \
				and area.has_point(Vector2((n as Node3D).global_position.x, (n as Node3D).global_position.z)):
			asleep.append([n, (n as Node).process_mode, (n as Node3D).visible])
			n.set_meta("asleep", true)
			(n as Node3D).visible = false
			(n as Node).process_mode = Node.PROCESS_MODE_DISABLED
	return asleep


func _wake(asleep: Array) -> void:
	for a in asleep:
		if is_instance_valid(a[0]):
			(a[0] as Node).process_mode = a[1]
			(a[0] as Node3D).visible = a[2]
			a[0].remove_meta("asleep")


## Is the point inside a tile people can walk in (its navigation mesh is in)?
func walkable(p: Vector3, margin := 0.0) -> bool:
	for id in tiles:
		var t: Dictionary = tiles[id]
		if t["nav"] and (t["rect"] as Rect2).grow(-margin).has_point(Vector2(p.x, p.z)):
			return true
	return false


## The neighbouring tiles' buildings that stand in a tile (<id>.spawn.json
## "foreign"), as obstacles the navigation mesh bake cuts out.
static func obstacles(parent: Node, foreign: Array) -> void:
	for f in foreign:
		var o := NavigationObstacle3D.new()
		var ring := PackedVector3Array()
		for p in f["ring"]:
			ring.append(Vector3(p[0], 0.0, p[1]))
		o.vertices = ring
		o.position.y = float(f["base"]) - 1.0
		o.height = float(f["height"]) + 2.0
		o.affect_navigation_mesh = true
		o.avoidance_enabled = false
		parent.add_child(o)


## A baked mesh has islands nobody can walk to: the top of a newsstand, of a
## wall, of a parked lorry. People were born on them (and stood on a kiosk
## roof), goals were picked on them, and a path asked for across a link to
## one makes Godot's search report an error. This drops every group of
## joined polygons, but the largest (the streets), that does not reach the
## edge of `rect` (where a neighbouring tile may carry it on). Returns how
## many groups and polygons went.
const ISLAND_EDGE_M := 2.0
static func drop_islands(nm: NavigationMesh, rect: Rect2) -> Vector2i:
	var verts := nm.get_vertices()
	var count := nm.get_polygon_count()
	var parent := PackedInt32Array()
	parent.resize(count)
	for i in count:
		parent[i] = i
	var edges := {}                              # an edge by its two ends (to 5 cm) -> the first polygon with it
	var polys := []
	for i in count:
		var poly := nm.get_polygon(i)
		polys.append(poly)
		var keys := []
		for v in poly:
			var q: Vector3 = verts[v]
			keys.append(Vector3i(roundi(q.x * 20.0), roundi(q.y * 20.0), roundi(q.z * 20.0)))
		for k in keys.size():
			var a: Vector3i = keys[k]
			var b: Vector3i = keys[(k + 1) % keys.size()]
			var key := [a, b] if a < b else [b, a]
			if not edges.has(key):
				edges[key] = i
				continue
			var x: int = edges[key]
			while parent[x] != x:
				x = parent[x]
			var y := i
			while parent[y] != y:
				y = parent[y]
			if x != y:
				parent[y] = x
	var inner := rect.grow(-ISLAND_EDGE_M)
	var area := {}                               # group -> square metres
	var edge := {}                               # group -> it reaches the edge
	var root := PackedInt32Array()
	root.resize(count)
	for i in count:
		var x := i
		while parent[x] != x:
			x = parent[x]
		root[i] = x
		var poly: PackedInt32Array = polys[i]
		var m2 := 0.0
		for k in range(2, poly.size()):
			m2 += (verts[poly[k - 1]] - verts[poly[0]]).cross(verts[poly[k]] - verts[poly[0]]).length() / 2.0
		area[x] = area.get(x, 0.0) + m2
		if not edge.has(x):
			for v in poly:
				if not inner.has_point(Vector2(verts[v].x, verts[v].z)):
					edge[x] = true
					break
	# the street network is the largest group; any other that does not reach
	# the edge cannot be walked to, however big (a closed courtyard, a
	# fenced yard: the search error came back from one of those)
	var main_group := -1
	for x in area:
		if main_group < 0 or area[x] > area[main_group]:
			main_group = x
	var gone := {}
	for x in area:
		if x != main_group and not edge.has(x):
			gone[x] = true
	if gone.is_empty():
		return Vector2i.ZERO
	nm.clear_polygons()
	var dropped := 0
	for i in count:
		if gone.has(root[i]):
			dropped += 1
		else:
			nm.add_polygon(polys[i])
	return Vector2i(gone.size(), dropped)


## The tile's own navigation mesh: its colliders are read here, the mesh is
## baked on a thread, and when it is in, links join it to what is round it.
## A mesh once baked is kept (_nav_path) and read back the next time the
## tile comes in, while the tile's files and the bake settings are the same
## (_nav_stamp): no colliders read, no bake.
func _bake(id: String, t: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var root: Node3D = t["node"]
	var nm: NavigationMesh = (main.nav_region as NavigationRegion3D).navigation_mesh.duplicate()
	nm.clear()
	var stamp := _nav_stamp(id, nm)
	var kept := await _kept_nav(id, stamp)
	if not is_instance_valid(root) or not tiles.has(id) or tiles[id]["node"] != root:
		return                                  # the tile left while its mesh was read
	if kept:
		_note(id, "navmesh read back (thread), %d polygons" % kept.get_polygon_count(), t0)
		_baked(id, root.get_instance_id(), kept, Time.get_ticks_usec(), Vector2i.ZERO, false)
		return
	t0 = Time.get_ticks_usec()
	obstacles(root, t["foreign"])
	var r: Rect2 = t["rect"]
	var elev: Vector2 = t["elev"]
	nm.filter_baking_aabb = AABB(Vector3(r.position.x, elev.x - 2, r.position.y), Vector3(r.size.x, elev.y - elev.x + 6, r.size.y))
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, source, root)
	_note(id, "read colliders for the navmesh (main thread)", t0)
	var t1 := Time.get_ticks_usec()
	# the tile by its instance id, not the node: a tile that leaves while its
	# mesh bakes is freed. The callbacks are bound methods, not lambdas: a
	# lambda the navigation server still held when the game quit mid-bake was
	# freed after GDScript and aborted the game (recursive_mutex lock failed)
	var root_id := root.get_instance_id()
	_baking.append(nm)
	NavigationServer3D.bake_from_source_geometry_data_async(nm, source,
			_bake_done.bind(id, root_id, nm, t1, r, stamp))


## The navigation server's callback (main thread): the rest off the main thread.
func _bake_done(id: String, root_id: int, nm: NavigationMesh, t1: int, r: Rect2, stamp: String) -> void:
	_baking.erase(nm)
	_jobs.append(WorkerThreadPool.add_task(_finish_bake.bind(id, root_id, nm, t1, r, stamp)))


## Worker thread: drop the mesh's islands and keep it (_nav_path).
func _finish_bake(id: String, root_id: int, nm: NavigationMesh, t1: int, r: Rect2, stamp: String) -> void:
	var went := drop_islands(nm, r)
	nm.set_meta("stamp", stamp)
	var err := ResourceSaver.save(nm, _nav_path(id), ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_warning("open world: could not keep %s's navigation mesh (%d)" % [id, err])
	_baked.call_deferred(id, root_id, nm, t1, went, true)


## Every worker task is waited for once it is done.
func _reap() -> void:
	for i in range(_jobs.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_jobs[i]):
			WorkerThreadPool.wait_for_task_completion(_jobs[i])
			_jobs.remove_at(i)


## The game quits or the round ends: nothing of the world may still run on
## another thread when the engine shuts down - a tile being built, a mesh
## being baked or finished.
func _exit_tree() -> void:
	var t0 := Time.get_ticks_msec()
	for nm in _baking:
		while NavigationServer3D.is_baking_navigation_mesh(nm) and Time.get_ticks_msec() - t0 < 10000:
			OS.delay_msec(5)
	_baking.clear()
	for t in tiles.values() + [home]:
		if t.get("state", "") == "building" and t.has("task"):
			WorkerThreadPool.wait_for_task_completion(t["task"])
			t["state"] = "out"
	for job in _jobs:
		WorkerThreadPool.wait_for_task_completion(job)
	_jobs.clear()


## Where a tile's baked navigation mesh is kept: next to the tile while the
## game runs from the project (a developer's tiles, git-ignored with them),
## in the user's folder in a released game, whose files are read-only.
func _nav_path(id: String) -> String:
	if OS.has_feature("editor"):
		return "res://city/%s.nav.res" % id
	DirAccess.make_dir_recursive_absolute("user://tile_nav")
	return "user://tile_nav/%s.nav.res" % id


## What a tile's mesh is baked from: the tile's files (a rebuilt tile bakes
## again) and the bake's settings.
func _nav_stamp(id: String, nm: NavigationMesh) -> String:
	var parts := []
	for f in [_glb(id), _col(id), "res://city/%s.props.json" % id, "res://city/%s.landmarks.json" % id,
			"res://city/%s.spawn.json" % id]:
		parts.append("%s:%d" % [f.get_file(), FileAccess.get_modified_time(f)])
	parts.append("%s %s %s %s %s %s" % [nm.cell_size, nm.cell_height, nm.agent_radius, nm.agent_height,
			nm.agent_max_climb, nm.agent_max_slope])
	return ";".join(parts)


## The tile's kept mesh, read on a loader thread, or null if there is none
## or it was baked from other files.
func _kept_nav(id: String, stamp: String) -> NavigationMesh:
	var path := _nav_path(id)
	if not ResourceLoader.exists(path):
		return null
	if ResourceLoader.load_threaded_request(path, "NavigationMesh", false, ResourceLoader.CACHE_MODE_IGNORE) != OK:
		return null
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var nm := ResourceLoader.load_threaded_get(path) as NavigationMesh
	if nm == null or str(nm.get_meta("stamp", "")) != stamp:
		return null
	return nm


func _baked(id: String, root_id: int, nm: NavigationMesh, t1: int, went: Vector2i, fresh: bool) -> void:
	var root := instance_from_id(root_id) as Node3D
	if root == null or not tiles.has(id) or tiles[id]["node"] != root:
		return                                  # the tile left while its mesh was baking
	if fresh:
		_note(id, "bake the navmesh (thread), %d polygons, %d islands of %d polygons dropped" % [nm.get_polygon_count(), went.x, went.y], t1)
	var t0 := Time.get_ticks_usec()
	var region := NavigationRegion3D.new()
	region.name = "Navigation"
	region.navigation_mesh = nm
	root.add_child(region)
	# the map takes the new region in on a later sync (built on a thread): link after it
	var map: RID = main.get_world_3d().navigation_map
	var probe := Vector3.INF
	if nm.get_polygon_count() > 0:
		probe = nm.get_vertices()[nm.get_polygon(0)[0]]
	for k in 600:
		await get_tree().physics_frame
		if probe == Vector3.INF or NavigationServer3D.map_get_closest_point(map, probe).distance_to(probe) < 0.3:
			break
	if not is_instance_valid(root):
		return
	_note(id, "navigation region taken in by the map", t0)
	t0 = Time.get_ticks_usec()
	var n := _link(root, tiles[id]["rect"])
	tiles[id]["nav"] = true
	_note(id, "%d links across the edge (main thread)" % n, t0)
	# passers-by of its own (the server's): they leave with the tile
	if multiplayer.is_server():
		for k in TILE_PEOPLE:
			var at := NavigationServer3D.region_get_random_point(region.get_rid(), 1, true)
			if at != Vector3.ZERO:
				main._civ_seq += 1
				main.civ_spawner.spawn({"id": main._civ_seq, "pos": at + Vector3(0, 0.1, 0), "model": main.Civilian.pick()})
		_robots_in(id, region)


## Server: the tile's own robots on patrol, away from the players. They carry
## the tile's id (meta "tile") and leave with whatever tile they are in when
## it goes; those of the tile still alive elsewhere are not made again.
func _robots_in(id: String, region: NavigationRegion3D) -> void:
	var have := 0
	for e in main.enemies_root.get_children():
		if e.get_meta("tile", "") == id and e.has_method("is_alive") and e.is_alive():
			have += 1
	var players: Array = main.players_root.get_children()
	for attempt in 40:
		if have >= TILE_ROBOTS:
			break
		var at := NavigationServer3D.region_get_random_point(region.get_rid(), 1, true)
		if at == Vector3.ZERO or not (tiles[id]["rect"] as Rect2).grow(-8.0).has_point(Vector2(at.x, at.z)):
			continue
		if players.any(func(pl): return (pl as Node3D).global_position.distance_to(at) < ROBOT_CLEAR_M):
			continue
		var e: Node = main.enemy_spawner.spawn({"id": main._next_enemy_id(), "pos": at + Vector3(0, 0.2, 0)})
		e.set_meta("tile", id)
		have += 1


## Two meshes baked apart stop an agent's radius short of the shared edge:
## along the tile's edge, wherever both sides can be walked, a link joins them.
func _link(root: Node3D, r: Rect2) -> int:
	var map: RID = main.get_world_3d().navigation_map
	var n := 0
	var corners := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	var centre := r.get_center()
	for side in 4:
		var a: Vector2 = corners[side]
		var b: Vector2 = corners[(side + 1) % 4]
		var out := (b - a).normalized().orthogonal()
		if out.dot((a + b) / 2.0 - centre) < 0:
			out = -out
		var beyond := (a + b) / 2.0 + out * 5.0
		if not main.in_world(Vector3(beyond.x, 0.0, beyond.y)):
			continue                             # nothing walkable on that side
		var steps := int(a.distance_to(b) / LINK_STEP_M)
		for k in range(1, steps):
			var e := a.lerp(b, float(k) / steps)
			var p_in := _on_mesh(map, e - out * LINK_REACH_M)
			var p_out := _on_mesh(map, e + out * LINK_REACH_M)
			if p_in == Vector3.INF or p_out == Vector3.INF or absf(p_in.y - p_out.y) > 0.8:
				continue
			var link := NavigationLink3D.new()
			root.add_child(link)
			link.set_global_start_position(p_out)
			link.set_global_end_position(p_in)
			n += 1
	return n


## The navigation mesh's point at (x, z), or INF if nobody can stand there.
func _on_mesh(map: RID, at: Vector2) -> Vector3:
	var elev: Vector2 = main.elev
	var q := NavigationServer3D.map_get_closest_point(map, Vector3(at.x, (elev.x + elev.y) / 2.0, at.y))
	q = NavigationServer3D.map_get_closest_point(map, Vector3(at.x, q.y, at.y))
	return q if Vector2(q.x, q.z).distance_to(at) < 0.7 else Vector3.INF


## The tile's streets (<id>.roads.json) join the round's road graph, which
## every vehicle drives by: its nodes and edges are added once (a node at a
## place the graph already has one - a street cut at the edge - is that
## node), and the ways out of its nodes are opened while the tile is in.
## Traffic then turns into the tile like into any street.
const NODE_MATCH_M := 1.0
func _streets_in(id: String, t: Dictionary) -> void:
	var g: Dictionary = main.road_graph
	if not g.has("edges") or not g.has("out"):
		return                                   # the round's streets are not in yet
	t["streets"] = true
	if not t.has("ways"):
		var path := "res://city/%s.roads.json" % id
		t["ways"] = []
		if not FileAccess.file_exists(path):
			return
		var t0 := Time.get_ticks_usec()
		var tg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		if _map_edges < 0:
			_map_edges = g["edges"].size()
		var e0: int = g["edges"].size()
		var nodes: Array = g["nodes"]
		var index := []                          # the tile's node -> the graph's
		var known: int = nodes.size()
		var joined := 0
		for n in tg["nodes"]:
			var at := Vector2(n[0], n[1])
			var found := -1
			for k in known:                          # not the tile's own nodes just added
				if absf(nodes[k][0] - at.x) < NODE_MATCH_M and absf(nodes[k][1] - at.y) < NODE_MATCH_M:
					found = k
					break
			if found < 0:
				nodes.append(n)
				found = nodes.size() - 1
			else:
				joined += 1
			index.append(found)
		for e in tg["edges"]:
			var edge: Dictionary = e.duplicate()
			edge["a"] = index[int(e["a"])]
			edge["b"] = index[int(e["b"])]
			g["edges"].append(edge)
			g["len"].append(main._edge_length(edge))
			var i: int = g["edges"].size() - 1
			t["ways"].append([int(edge["a"]), [i, true]])
			if not edge["oneway"]:
				t["ways"].append([int(edge["b"]), [i, false]])
		t["stops"] = _tile_stops(id, e0, g["edges"].size())
		_note(id, "streets: %d edges joined to the road graph at %d nodes, %d bus stops" % [tg["edges"].size(), joined, t["stops"].size()], t0)
	for w in t["ways"]:
		(g["out"] as Dictionary).get_or_add(w[0], []).append(w[1])
	_entries()
	BusRoutes.invalidate(g)
	_bus_round()


## The tile's bus shelters (<id>.props.json) as stops, [edge, x, z]: the
## point of the tile's own streets (edges e0..e1) nearest each, as the map
## takes its own (main._bus_stops).
func _tile_stops(id: String, e0: int, e1: int) -> Array:
	var path := "res://city/%s.props.json" % id
	var props = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else []
	var g: Dictionary = main.road_graph
	var out := []
	for p in (props if props is Array else []):
		if p.get("type", "") != "bus_stop":
			continue
		var at := Vector2(p["pos"][0], p["pos"][2])
		var best := [-1, 0.0, 0.0]
		var bd := 25.0                    # a shelter further than this from any street serves none
		for i in range(e0, e1):
			for pt in g["edges"][i]["pts"]:
				var d := at.distance_to(Vector2(pt[0], pt[1]))
				if d < bd:
					bd = d
					best = [i, pt[0], pt[1]]
		if best[0] >= 0:
			out.append(best)
	return out


## The buses' round: the map's stops (while the map is in) and those of the
## tiles whose streets are open, nearest-next like the map's own. A bus keeps
## the stop it was making for if that stop is still served. Bus lines
## designed in the map editor stay the map's.
var _map_stops = null
func _bus_round() -> void:
	var g: Dictionary = main.road_graph
	if not g.has("edges") or not g.get("lines", []).is_empty():
		return
	if _map_stops == null:
		_map_stops = g.get("stops", []).duplicate()
	var found: Array = _map_stops.duplicate() if home.get("streets", true) else []
	for t in tiles.values():
		if t.get("streets", false):
			found.append_array(t.get("stops", []))
	var tour := []
	while not found.is_empty():
		var from: Vector2 = Vector2(tour[-1][1], tour[-1][2]) if not tour.is_empty() else Vector2(found[0][1], found[0][2])
		found.sort_custom(func(a, b): return from.distance_to(Vector2(a[1], a[2])) < from.distance_to(Vector2(b[1], b[2])))
		tour.append(found.pop_front())
	var old: Array = g.get("stops", [])
	for v in main.traffic_root.get_children():
		if v.get("kind") == "bus":
			var i: int = v.get("_stop_i")
			v.set("_stop_i", tour.find(old[i]) if i >= 0 and i < old.size() else -1)
	g["stops"] = tour


## The tile leaves: the ways into its streets close (the edges stay in the
## graph, unreachable, for when it comes back).
func _streets_out(t: Dictionary) -> void:
	t["streets"] = false
	t["cars"] = false
	var g: Dictionary = main.road_graph
	if not g.has("out"):
		return
	for w in t.get("ways", []):
		var ways: Array = (g["out"] as Dictionary).get(w[0], [])
		for k in ways.size():
			if ways[k][0] == w[1][0] and ways[k][1] == w[1][1]:
				ways.remove_at(k)
				break
	_entries()
	BusRoutes.invalidate(g)
	_bus_round()


## Where traffic drives in: the dead ends of the streets open now, at the edge
## of what is loaded (the same rule as main._load_roads, with the tiles).
func _entries() -> void:
	var g: Dictionary = main.road_graph
	var open := {}                               # edge -> true: a way leads onto it
	for node in g["out"]:
		for w in g["out"][node]:
			open[int(w[0])] = true
	var degree := {}
	for i in open:
		var e: Dictionary = g["edges"][i]
		degree[int(e["a"])] = degree.get(int(e["a"]), 0) + 1
		degree[int(e["b"])] = degree.get(int(e["b"]), 0) + 1
	var entries := []
	for i in open:
		var e: Dictionary = g["edges"][i]
		for spec in [[int(e["a"]), true], [int(e["b"]), false]]:
			var n: Array = g["nodes"][spec[0]]
			if degree[spec[0]] == 1 and (spec[1] or not e["oneway"]) and not _inside(Vector2(n[0], n[1]), 20.0):
				entries.append([i, spec[1]])
	g["entries"] = entries


## In the map or a tile whose streets are open, `margin` from the edge of
## their union (a point on the seam between two of them is inside).
func _inside(p: Vector2, margin: float) -> bool:
	for d in [Vector2(margin, 0), Vector2(-margin, 0), Vector2(0, margin), Vector2(0, -margin)]:
		var q: Vector2 = p + d
		var found: bool = home.get("streets", true) and main.in_bounds(Vector3(q.x, 0.0, q.y))
		for id in tiles:
			if found:
				break
			found = tiles[id].get("streets", false) and (tiles[id]["rect"] as Rect2).has_point(q)
		if not found:
			return false
	return true


## The round's moving traffic: its own driver aboard, no player's.
func _moving() -> Array:
	var out := []
	for v in main.traffic_root.get_children():
		if v.get("occupied") and v.get("driver_peer") == 0 and not v.has_meta("taken") and not v.has_meta("asleep"):
			out.append(v)
	return out


## The moving traffic of the round's map while its streets are open.
func _map_share() -> int:
	return int(round(main.TRAFFIC * main.density())) if home.get("streets", true) else 0


## Traffic the loaded world should hold: the map's, and each open tile's.
func _traffic_wanted() -> int:
	var n := _map_share()
	for id in tiles:
		if tiles[id].get("streets", false):
			n += TILE_TRAFFIC
	return n


## Server: traffic left to itself gathers where the one-way streets lead and
## thins out elsewhere (most of all in the round's map, which the tiles'
## streets drain). Each area - the map, each tile with its streets open - has
## its share of the moving traffic (16 to 6); when one is EVEN_GAP over it and
## another as much under, a vehicle of the first that no player is near starts
## again on a street of the second that no player is near.
func _even_traffic() -> void:
	if not multiplayer.is_server() or _map_edges < 0 or not main._round_live:
		return
	var areas := []
	if home.get("streets", true):
		areas.append({"rect": main.bounds, "want": float(_map_share()), "ways": [], "have": [], "map": true})
	for id in tiles:
		if tiles[id].get("streets", false) and not (tiles[id]["ways"] as Array).is_empty():
			areas.append({"rect": tiles[id]["rect"], "want": float(TILE_TRAFFIC), "ways": tiles[id]["ways"], "have": []})
	if areas.size() < 2:
		return
	var moving := _moving()
	var wanted := 0.0
	for a in areas:
		wanted += a["want"]
	for v in moving:
		var at := Vector2((v as Node3D).global_position.x, (v as Node3D).global_position.z)
		for a in areas:
			if (a["rect"] as Rect2).has_point(at):
				a["have"].append(v)
				break
	var most: Dictionary = areas[0]
	var least: Dictionary = areas[0]
	for a in areas:
		a["gap"] = a["have"].size() - a["want"] * moving.size() / wanted
		if a["gap"] > most["gap"]:
			most = a
		if a["gap"] < least["gap"]:
			least = a
	if most["gap"] < EVEN_GAP or least["gap"] > -EVEN_GAP:
		return
	var players: Array = main.players_root.get_children()
	var clear := func(x: float, z: float) -> bool:
		for pl in players:
			var p: Vector3 = (pl as Node3D).global_position
			if Vector2(p.x - x, p.z - z).length() < EVEN_CLEAR_M:
				return false
		return true
	var g: Dictionary = main.road_graph
	for v in most["have"]:
		if v.get("kind") == "bus" or not clear.call((v as Node3D).global_position.x, (v as Node3D).global_position.z):
			continue
		for attempt in 8:
			var way: Array
			if least.has("map"):
				var i: int = randi() % _map_edges
				way = [i, g["edges"][i]["oneway"] or randf() < 0.5]
			else:
				way = (least["ways"] as Array).pick_random()[1]
			var pts: Array = g["edges"][way[0]]["pts"]
			var mid: Array = pts[pts.size() / 2]
			if clear.call(mid[0], mid[1]):
				v.call("start", way[0], way[1])
				return
		return


## Server: vehicles start on the tile's streets, up to what the world should hold.
func _traffic_in(t: Dictionary) -> void:
	var ways: Array = t["ways"]
	if not multiplayer.is_server() or ways.is_empty() or not main._round_live:
		return
	t["cars"] = true
	var g: Dictionary = main.road_graph
	if _map_vehicles < 0:
		_map_vehicles = main.traffic_root.get_child_count()
	# vehicles their drivers ran from stay in the map: they count, or every
	# tile coming in after a fight would add to them without end
	var room: int = _map_vehicles + _traffic_wanted() - _map_share() - main.traffic_root.get_child_count()
	for k in mini(mini(TILE_TRAFFIC, room), _traffic_wanted() - _moving().size()):
		var way: Array = ways.pick_random()[1]
		var model: int = main.Car.pick()
		while main.Car.kind_of(main.Car.MODELS[model]) == "bus" \
				or (main.Car.MODELS[model].contains("trailer") and g["len"][way[0]] < 150.0):
			model = main.Car.pick()
		main._car_seq += 1
		main.car_spawner.spawn({"id": main._car_seq, "model": model, "driver": main.Civilian.pick_walker(),
				"edge": way[0], "forward": way[1]})


## Before a tile leaves: a robot of the round in it, or a vehicle a player
## drives or has driven, keeps the tile (false). Else its streets close; the
## robots the tiles brought, the passers-by and the vehicles their drivers ran
## from go with it; of the traffic in it, what the world now holds too much of
## goes too and the rest drives back in at an edge.
func _vacate(t: Dictionary) -> bool:
	var area: Rect2 = (t["rect"] as Rect2).grow(3.0)
	var robots := []
	for e in main.enemies_root.get_children():
		if area.has_point(Vector2((e as Node3D).global_position.x, (e as Node3D).global_position.z)):
			if not e.has_meta("tile"):
				return false
			robots.append(e)
	var traffic := []
	for v in main.traffic_root.get_children():
		if area.has_point(Vector2((v as Node3D).global_position.x, (v as Node3D).global_position.z)):
			if v.get("driver_peer") != 0 or v.has_meta("taken"):
				return false
			traffic.append(v)
	_streets_out(t)
	t["asleep"] = _sleep(main._containers + main._antennas, area)
	if not multiplayer.is_server():
		return true
	for e in robots:
		e.queue_free()
	var spare: int = _moving().size() - _traffic_wanted()
	for v in traffic:
		if not v.get("occupied"):
			v.queue_free()
		elif spare > 0 and v.get("kind") != "bus":
			spare -= 1
			v.queue_free()
		else:
			v.call("_enter_from_edge")
	for c in main.civilians_root.get_children():
		if area.has_point(Vector2((c as Node3D).global_position.x, (c as Node3D).global_position.z)):
			c.queue_free()
	return true


## The round's own map as a tile. Everything it built hangs under its
## navigation region (main._load_city): the city and its collision, the
## street furniture, the landmarks, the occluders. When the player is
## UNLOAD_M away and stands on a tile, the map goes: the city's meshes and
## collision are freed (the memory), the rest is put to sleep where it is -
## hidden, out of the physics, its navigation mesh off - with the people,
## the vehicles and the pickups in it, and its streets close like a tile's.
## The round's state lives outside it (main: goals, score, the exit, the
## Director's robots), so nothing of the round is lost. At LOAD_M the city
## is read and built on threads like a tile, and all of it wakes up as it
## was: no navigation mesh is baked again, a lamp shot out stays out.
## The round's robots left in it are not the map's: they go, and the
## Director sends others where the player is - but a heavy mech (a goal of
## the round) or a collector (people aboard) keeps the map in. One player
## only (the server's): with more, the map stays.
func _home_check(at: Vector3) -> void:
	if home.is_empty():
		home = {"state": "in", "streets": true, "asleep": []}
	var d := _distance(main.bounds, Vector2(at.x, at.z))
	if home["state"] == "in" and d > UNLOAD_M and _home_may_leave(at):
		_home_out()
	elif home["state"] == "out" and d < LOAD_M:
		home["state"] = "loading"
		home["t0"] = Time.get_ticks_usec()
		home["paths"] = [main._city(".glb")]
		if ResourceLoader.exists(main._city("_collision.glb")):
			home["paths"].append(main._city("_collision.glb"))
		for path in home["paths"]:
			ResourceLoader.load_threaded_request(path, "", true)


func _home_may_leave(at: Vector3) -> bool:
	if tiles.is_empty() or not multiplayer.is_server() or main.players_root.get_child_count() > 1:
		return false
	if not main._round_live or not main.nav_ready or main.design or main.studio_session:
		return false
	if not (main.road_graph as Dictionary).has("out") or not walkable(at):
		return false
	var area: Rect2 = (main.bounds as Rect2).grow(3.0)
	for e in main.enemies_root.get_children():
		if e.get("kind") in HOME_KEEPERS and area.has_point(Vector2((e as Node3D).global_position.x, (e as Node3D).global_position.z)):
			return false
	return true


func _home_out() -> void:
	var t0 := Time.get_ticks_usec()
	var area: Rect2 = (main.bounds as Rect2).grow(3.0)
	var inside := func(n: Node) -> bool:
		return n is Node3D and area.has_point(Vector2((n as Node3D).global_position.x, (n as Node3D).global_position.z))
	for e in main.enemies_root.get_children():
		if inside.call(e):
			e.queue_free()                       # a tile's patrol; or the round's, and the Director sends others
	# who and what is in it sleeps where it stands
	var asleep := _sleep(main.civilians_root.get_children() + main.traffic_root.get_children()
			+ main.pickups_root.get_children() + main._containers + main._antennas, area)
	home["asleep"] = asleep
	# its streets close
	var g: Dictionary = main.road_graph
	if _map_edges < 0:
		_map_edges = g["edges"].size()
	if not home.has("ways"):
		home["ways"] = []
		for node in g["out"]:
			for w in g["out"][node]:
				if int(w[0]) < _map_edges:
					home["ways"].append([node, w])
	_streets_out(home)
	# the city goes, what stays sleeps
	var region: NavigationRegion3D = main.nav_region
	region.enabled = false
	region.visible = false
	region.process_mode = Node.PROCESS_MODE_DISABLED
	for part in ["City", "SidewalkCollision"]:
		var n := region.get_node_or_null(part)
		if n:
			n.name = part + "Leaving"
			n.queue_free()
	_home_links(false)
	main.home_out = true
	home["state"] = "out"
	_note(HOME, "unload: %d asleep" % asleep.size(), t0)


## The links between the round's map and the tiles round it (the tiles' own
## and the map's) are off while the map is out: a link with one end on no
## mesh makes the path search report an error.
func _home_links(on: bool) -> void:
	var area: Rect2 = (main.bounds as Rect2).grow(LINK_REACH_M + 0.5)
	var roots := []
	for id in tiles:
		if is_instance_valid(tiles[id]["node"]):
			roots.append(tiles[id]["node"])
	if is_instance_valid(home.get("links")):
		roots.append(home["links"])
	for root in roots:
		for l in (root as Node).get_children():
			if l is NavigationLink3D:
				var a: Vector3 = (l as NavigationLink3D).get_global_start_position()
				var b: Vector3 = (l as NavigationLink3D).get_global_end_position()
				if area.has_point(Vector2(a.x, a.z)) and area.has_point(Vector2(b.x, b.z)):
					(l as NavigationLink3D).enabled = on


func _home_poll() -> void:
	if home.is_empty():
		return
	if home["state"] == "loading":
		for path in home["paths"]:
			var st := ResourceLoader.load_threaded_get_status(path)
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				return
			if st != ResourceLoader.THREAD_LOAD_LOADED:
				home["state"] = "failed"
				return
		home["scenes"] = (home["paths"] as Array).map(func(path: String) -> Resource: return ResourceLoader.load_threaded_get(path))
		_note(HOME, "read files (loader thread)", home["t0"])
		home["t0"] = Time.get_ticks_usec()
		home["state"] = "building"
		home["task"] = WorkerThreadPool.add_task(_build.bind(HOME))
	elif home["state"] == "building" and WorkerThreadPool.is_task_completed(home["task"]):
		WorkerThreadPool.wait_for_task_completion(home["task"])
		_note(HOME, "build (worker thread)", home["t0"])
		home["state"] = "entering"
		_home_in()


func _home_in() -> void:
	var t0 := Time.get_ticks_usec()
	var region: NavigationRegion3D = main.nav_region
	var built: Node3D = home["node"]
	home.erase("node")
	for part in built.get_children():
		built.remove_child(part)
		region.add_child(part)
	built.free()
	var city := region.get_node("City")
	main._water(city)
	main._matte_grass(city)
	main._add_grass_detail(city)
	main._kit_facades(city, true)
	region.visible = true
	region.process_mode = Node.PROCESS_MODE_PAUSABLE
	_note(HOME, "enter the tree (main thread)", t0)
	for k in 2:                                  # the ground is in the physics before anyone stands on it
		await get_tree().physics_frame
	if not is_instance_valid(region):
		return
	region.enabled = true
	_home_links(true)
	_wake(home["asleep"])
	home["asleep"] = []
	var g: Dictionary = main.road_graph
	for w in home["ways"]:
		(g["out"] as Dictionary).get_or_add(w[0], []).append(w[1])
	home["streets"] = true
	_entries()
	BusRoutes.invalidate(g)
	_bus_round()
	main.home_out = false
	home["state"] = "in"
	# the tiles that came in while it was out have no links to it
	t0 = Time.get_ticks_usec()
	var map: RID = main.get_world_3d().navigation_map
	var probe: Vector3 = main.spawn_point
	for k in 600:
		await get_tree().physics_frame
		if NavigationServer3D.map_get_closest_point(map, probe).distance_to(probe) < 3.0:
			break
	if not is_instance_valid(region) or home["state"] != "in":
		return
	if is_instance_valid(home.get("links")):
		(home["links"] as Node).queue_free()
	var links := Node3D.new()
	links.name = "HomeLinks"
	add_child(links)
	home["links"] = links
	_note(HOME, "%d links across the edge (main thread)" % _link(links, main.bounds), t0)


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
