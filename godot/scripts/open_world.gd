extends Node
## The open world (docs/OPEN_WORLD.md): the city is made of tiles that come
## in and go out round the players. A tile is a map (res://city/<id>.glb,
## <id>_collision.glb, <id>.spawn.json with its bounds): its meshes, its
## collision and a navigation mesh of its own, baked on a thread once it is
## in (kept on disk after) and joined to the meshes round it by links across
## the edge, so people and robots walk over; its street furniture and its
## landmarks; its streets, joined to the round's road graph, so traffic
## drives in and out; and who and what it brings (_populate).
##
## Every round is played on tiles: a world's (tools/map/tiles.py,
## <name>.world.json) with the round's start tile in under the loading
## screen (load_now), or a map of its own as a world of one tile. More can
## be added: `main.open_world("<id or world>")` (DevAgent `eval`), or
## `-- --open-world=<id or world>`.
## Each step is timed (`report()`): reading the files on a loader thread,
## building the scene and its collision on a worker thread, and the frame
## that puts it into the tree - the one the player can feel.

const BusRoutes := preload("res://scripts/bus_routes.gd")
const Edits := preload("res://scripts/edits.gd")
const LOAD_M := 120.0       # a tile comes in when the player is this near its bounds
const UNLOAD_M := 220.0     # and goes out beyond this
const CHECK_S := 0.25
const LINK_STEP_M := 2.5    # a navigation link every so often along a tile's edge
const LINK_REACH_M := 1.2   # from this far outside the edge to this far inside
const TILE_PEOPLE := 14     # passers-by a tile brings
const TILE_ROBOTS := 4      # robots on patrol a tile brings
const TILE_TRAFFIC := 6     # vehicles a tile's streets bring
const TILE_POLICE := 1      # officers on patrol a tile brings
const TILE_PARKED := 5      # cars parked at its kerbs a player can drive, at most
const TILE_PICKUPS := 0.5   # of the scattered pickups of a tile a player is in (main.PICKUP_COUNTS)
const TILE_FLOCKS := 2      # pigeon flocks on its squares
const TILE_QUEROS := 2      # pairs of quero-queros on its lawns
const ROBOT_CLEAR_M := 60.0 # no robot is born nearer a player than this
const EVEN_S := 1.5         # traffic is evened out between the tiles this often,
const EVEN_GAP := 2.5       # when one has this many vehicles over its share and another under,
const EVEN_CLEAR_M := 100.0 # by moving one no player is this near to a street no player is this near
const FRAME_MS := 4.0       # street furniture: this much building a frame
const KEEPERS := ["mech", "collector"]   # robots of the round that keep their tile in: a goal of the round, people aboard

var main: Node
var threaded := true        # false: build on the main thread (to compare the hitch)
var extras := true         # false: a tile brings only passers-by and robots (to measure what the rest costs)
var tiles := {}             # id -> {rect, state, node, task, t0, ...}
var events: Array = []      # [{id, what, ms}, ...] in order
var _since := 0.0
var _even := 0.0
var _walls: StaticBody3D
var far := {}               # tile id -> its far model (tools/map/far_view.py)
var _jobs: Array[int] = []  # worker tasks after a bake, waited for when done (_reap) or when the world goes
var _leaving := false       # the world is going: worker tasks stop at their next step
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
		var path := "res://city/%s.glb" % (id if id == data.get("far", "") else id + "_far")
		if far.has(id) or not ResourceLoader.exists(path):
			continue
		var node: Node3D = (load(path) as PackedScene).instantiate()
		node.name = "Far_" + id
		for mi in node.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if mi is MeshInstance3D:
				_far_windows(mi as MeshInstance3D)
		add_child(node)
		far[id] = node
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


## A tile's far model shows while the tile itself is not in the tree. The
## promenade points people stroll to are those of what is in.
var _walks_of := ""
func _far_update() -> void:
	var here := ""
	for id in tiles:
		if tiles[id]["state"] == "in":
			here += id + " "
	if here != _walks_of:                       # what is in changed
		_walks_of = here
		var walks: Array = []
		for t in tiles.values():
			if t["state"] == "in":
				walks.append_array(t.get("crowd", []))
		main.promenades = walks
	for key in far:
		var node: Node3D = far[key]
		if tiles.has(key):
			node.visible = tiles[key]["state"] != "in"
		else:
			node.visible = true                  # the ring round the world


func add_tile(id: String) -> bool:
	var spawn := "res://city/%s.spawn.json" % id
	if tiles.has(id) or not FileAccess.file_exists(spawn) or not ResourceLoader.exists(_glb(id)):
		return false
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(spawn))
	var ev: Array = data.get("elev", [0.0, 0.0])
	var crowd := []                     # promenade points, stored [x, z, y]
	for c in data.get("crowd", []):
		crowd.append(Vector3(c[0], c[2] if c.size() > 2 else 0.0, c[1]))
	tiles[id] = {"rect": bounds_of(data), "state": "out", "node": null,
			"nav": false, "elev": Vector2(ev[0], ev[1]), "foreign": data.get("foreign", []), "crowd": crowd}
	_edge_walls()
	# a map of its own draws its far ground and towers where more tiles would be
	var horizon := main.get_node_or_null("Horizon") as Node3D
	if horizon and tiles.size() > 1:
		horizon.visible = false
	return true


## A map's rectangle from its <id>.spawn.json: "bounds" [min_x, max_x, min_z,
## max_z], or a square of "half" round the origin.
static func bounds_of(data: Dictionary) -> Rect2:
	if data.has("bounds"):
		var b: Array = data["bounds"]
		return Rect2(b[0], b[2], b[1] - b[0], b[3] - b[2])
	var half := float(data.get("half", 150.0))
	return Rect2(-half, -half, half * 2.0, half * 2.0)


func report() -> Dictionary:
	var states := {}
	for id in tiles:
		states[id] = tiles[id]["state"]
	return {"tiles": states, "events": events, "threaded": threaded}


## People, robots and vehicles in each tile now; "driving": the vehicles
## with their own driver aboard.
func census() -> Dictionary:
	var out := {}
	for id in tiles:
		var r: Rect2 = tiles[id]["rect"]
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
	_reap()
	_bring()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return                                  # (the start tile comes in before there is a player)
	_since += dt
	if _since < CHECK_S:
		return
	_since = 0.0
	_even += CHECK_S
	if _even >= EVEN_S:
		_even = 0.0
		_even_traffic()
	var p := Vector2(cam.global_position.x, cam.global_position.z)
	_looked = true
	main.home_out = tiles.get(main.map_id, {}).get("state", "") != "in"
	_far_update()
	var others := _others()
	for id in tiles:
		var t: Dictionary = tiles[id]
		var d := _distance(t["rect"], p)
		for q in others:
			d = minf(d, _distance(t["rect"], q))
		if t["state"] == "in" and not (t.get("full", false) and t.get("birds_full", true)) and _near(id):
			_fill(id, t)
		if t["state"] == "in" and not t.get("streets", false):
			_streets_in(id, t)
		if t["state"] == "in" and t.get("streets", false) and not t.get("cars", false):
			_traffic_in(t)
		if t["state"] == "out" and d < LOAD_M:
			t["state"] = "loading"
			t["t0"] = Time.get_ticks_usec()
			t["paths"] = _files(id)
			for path in t["paths"]:
				ResourceLoader.load_threaded_request(path)
		elif t["state"] == "in" and d > UNLOAD_M and tiles.size() > 1:     # (a map of its own stays)
			if not _vacate(t):
				continue                       # a robot of the round is in it: the tile stays
			var t0 := Time.get_ticks_usec()
			t["nav"] = false
			for lm in main._landmark_nodes.duplicate():      # its landmarks, the shops walked into, the wrecked ones
				if not is_instance_valid(lm) or (t["node"] as Node).is_ancestor_of(lm):
					main._landmark_nodes.erase(lm)
			t.erase("furnished")
			t.erase("full")
			t.erase("birds_full")
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
	var loaded: Array = paths.map(func(path: String) -> Resource:
		return ResourceLoader.load_threaded_get(path))
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
## thread may build it): every mesh of the city gets its triangle collision
## but what is only looked at (main.VISUAL_ONLY when the map has its own
## sidewalk collision, NO_COLLISION); roofs on their own layer.
func _build(id: String) -> void:
	var t: Dictionary = tiles[id]
	var scenes: Array = t["scenes"]
	var root := Node3D.new()
	root.name = "Tile_" + id
	var city: Node = (scenes[0] as PackedScene).instantiate()
	city.name = "City"
	root.add_child(city)
	var custom := scenes.size() > 1
	var top := 0.0
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		if _leaving:
			root.free()
			return
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
	for oi in main.occluders_of("res://city/%s.occluders.json" % id):
		root.add_child(oi)
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
	if not t.get("streets", false):
		_streets_in(id, t)                      # at once: the round's start tile comes in before there is a camera
	await _furnish(id, t, root)
	if is_instance_valid(root) and t["node"] == root:
		_bake(id, t)
		_wildlife(id, t, root)


## Every peer: the tile's pigeons on its squares, quero-queros on its lawns
## and birdsong in its greens (seeded by the tile's id: the same on every
## peer). Local and visual; they go with the tile.
func _wildlife(id: String, t: Dictionary, root: Node3D) -> void:
	if not extras:
		return
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var full := _near(id)                       # a player's tile: all its flocks and pairs
	t["birds_full"] = full                      # (decided here: _fill tops up only what came in light)
	var steps := [
		func(): main.pigeons_at(t.get("crowd", []), id, main.FLOCKS if full else TILE_FLOCKS, root),
		func(): main.queros_at(t["rect"], id, int(main.Pigeon.quero_def().get("pairs", 5)) if full else TILE_QUEROS, root),
		func(): main.bird_sounds("res://city/%s.props.json" % id, root),
		func():
			# its places: on the GPS while it is in, a green cross on a pharmacy's wall
			t["places"] = main.places_of("res://city/%s.places.json" % id, Edits.read(id))
			for pl in t["places"]:
				if main.place_kinds.get(pl["kind"], {}).get("sign", "") == "cross" and not pl.get("model"):
					main._cross_sign(pl, root),
	]
	for step in steps:
		await get_tree().process_frame
		while not main.models_warm and is_instance_valid(root):
			await get_tree().process_frame      # the birds' models are among those being read
		if not is_instance_valid(root) or t["node"] != root:
			return
		var t1 := Time.get_ticks_usec()
		step.call()
		worst = maxf(worst, (Time.get_ticks_usec() - t1) / 1000.0)
	_note(id, "pigeons, quero-queros and birdsong (main thread): worst frame %.1f ms" % worst, t0)


## The tile's street furniture (<id>.props.json: trees, lamps, signs, benches)
## and its landmarks and shops (<id>.landmarks.json, <id>.shells.json), a
## few per frame, then the map editor's edits (main.apply_edits).
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
	main.lay_down(id, props)                    # what was shot out or run over before the tile left
	_note(id, "street furniture, %d pieces, %d ms a frame (main thread)" % [props.get_child_count(), FRAME_MS], t0)
	var worst := 0.0
	var total := 0.0
	var slow := []
	var fixed := []                      # its landmarks' items (the server places them)
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
		main.trimesh_defer = true
		var n0: int = main.landmark_pickups.size()
		if item[0] == "landmarks":
			main._landmark(item[1])
		else:
			main._shell(item[1])
		main.landmark_into = null
		main.trimesh_defer = false
		# the list is the scene's: what this landmark added is the tile's (taken
		# at once - another tile may be adding its own between two frames)
		fixed.append_array(main.landmark_pickups.slice(n0))
		main.landmark_pickups.resize(n0)
		if not main.trimesh_later.is_empty():
			shaping.append(_shape_later(main.trimesh_later.duplicate()))
			main.trimesh_later.clear()
		var ms := (Time.get_ticks_usec() - t1) / 1000.0
		if ms > 20.0:
			slow.append("%s %.0f ms" % [String(item[1].get("model", item[1].get("kind", "?"))).get_file(), ms])
		worst = maxf(worst, ms)
		total += ms
	t["fixed_pickups"] = fixed
	main.apply_edits(id, root, props)           # its wall photos; in the released game its placed and removed objects
	t["furnished"] = true
	for b in (t.get("bursts", {}) as Dictionary).values():      # shops wrecked before the tile left
		main.wreck_shops(b[0], b[1])
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


## The round's start tile comes in at once (there is no player yet to be near
## it): main waits for ready_for_round under the loading screen.
func load_now(id: String) -> void:
	var t: Dictionary = tiles.get(id, {})
	if t.get("state", "") == "out":
		t["state"] = "loading"
		t["t0"] = Time.get_ticks_usec()
		t["paths"] = _files(id)
		for path in t["paths"]:
			ResourceLoader.load_threaded_request(path)


## The tile is in with its landmarks and its navigation mesh (or could not
## be loaded: the round does not wait for ever).
func ready_for_round(id: String) -> bool:
	var t: Dictionary = tiles.get(id, {})
	return t.is_empty() or t["state"] == "failed" or (t["state"] == "in" and t.get("nav", false) and t.get("furnished", false))


## DevAgent / Studio (main.reload_objects): the street furniture and the
## landmarks of every tile that is in, built again from their files (a model
## changed and imported again); on the server the vendors come back to their
## stalls. The ground and the navigation mesh stay. Returns the pieces of
## street furniture standing.
func refurnish() -> int:
	var n := 0
	for id in tiles.keys():
		var t: Dictionary = tiles[id]
		var root := t.get("node") as Node3D
		if t["state"] != "in" or not t.get("furnished", false) or not is_instance_valid(root):
			continue
		if is_instance_valid(t.get("props")):
			(t["props"] as Node).name = "PropsGoing"
			(t["props"] as Node).queue_free()
		for lm in main._landmark_nodes.duplicate():
			if not is_instance_valid(lm) or root.is_ancestor_of(lm):
				main._landmark_nodes.erase(lm)
				if is_instance_valid(lm):
					lm.queue_free()
		t.erase("furnished")
		await _furnish(id, t, root)
		if not is_instance_valid(root) or t.get("node") != root:
			continue
		n += (t["props"] as Node).get_child_count()
		if multiplayer.is_server():
			for data in main.vendor_spawns("res://city/%s.props.json" % id):
				_later(id, root, func(): main.spawn_civilian(data))
	return n


## The tile `at` (x, z) lies in, "" if none: also one that is not loaded.
func tile_at(at: Vector2) -> String:
	for id in tiles:
		if (tiles[id]["rect"] as Rect2).has_point(at):
			return id
	return ""


## A tile's node while it is in, else null.
func tile_node(id: String) -> Node:
	var t: Dictionary = tiles.get(id, {})
	return t["node"] if t.get("state", "") == "in" and is_instance_valid(t.get("node")) else null


## The street furniture of the tiles that are in (main.all_props).
func props_nodes() -> Array:
	var out := []
	for t in tiles.values():
		if t["state"] == "in" and is_instance_valid(t.get("props")):
			out.append(t["props"])
	return out


## Every peer: a blast at `at` (main.wreck_shops) wrecked shops of the tiles
## `into` (their nodes). The tile keeps the blast and wrecks them again when
## it comes back; a tile that is not in on this peer keeps every blast in it,
## for whatever shop it reaches.
func shop_burst(at: Vector3, r: float, into: Array) -> void:
	var key := Vector3i((at / 2.0).round())
	for t in tiles.values():
		if not (t["rect"] as Rect2).grow(r).has_point(Vector2(at.x, at.z)):
			continue
		if into.has(t["node"]) or not t.get("furnished", false):
			if not t.has("bursts"):
				t["bursts"] = {}
			t["bursts"][key] = [at, r]


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
		if _leaving:
			return
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
	if not _looked and not tiles.is_empty():
		return false                            # not yet looked round a player: nothing is on its way in *yet*
	for id in tiles:
		var t: Dictionary = tiles[id]
		if t["state"] in ["loading", "building"] or (t["state"] == "in" and not t["nav"]):
			return false
	return true


## The tiles people can walk in now, as rectangles.
func areas() -> Array:
	var out := []
	for id in tiles:
		if tiles[id]["nav"]:
			out.append(tiles[id]["rect"])
	return out


## Things of the round standing where a tile goes out (a people container,
## an antenna, the war machine, the round's own pickups) sleep in place -
## hidden, stopped, out of the physics - until it is back.
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
## A worker reading a mesh (its faces, its box) asks the rendering server and
## sleeps until the main thread serves it; a main thread that only waited for
## the worker would then wait for ever - the game hung on quit. So the wait
## keeps serving the rendering server, and a tile still being built is told
## to stop.
func _exit_tree() -> void:
	_leaving = true
	var t0 := Time.get_ticks_msec()
	for nm in _baking:
		while NavigationServer3D.is_baking_navigation_mesh(nm) and Time.get_ticks_msec() - t0 < 10000:
			OS.delay_msec(5)
	_baking.clear()
	for t in tiles.values():
		if t.get("state", "") == "building" and t.has("task"):
			_wait_out(t["task"])
			t["state"] = "out"
	for job in _jobs:
		_wait_out(job)
	_jobs.clear()
	_leaving = false


## Waits for a worker task while serving what it asks of the main thread. A
## task that does not end in 20 s is left to the engine.
func _wait_out(task: int) -> void:
	var t0 := Time.get_ticks_msec()
	while not WorkerThreadPool.is_task_completed(task):
		if Time.get_ticks_msec() - t0 > 20000:
			push_warning("open world: a worker task did not end, leaving it")
			return
		RenderingServer.force_sync()
		OS.delay_msec(2)
	WorkerThreadPool.wait_for_task_completion(task)


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
	if multiplayer.is_server():
		_populate(id, root, region)


## Server: who and what a tile brings - passers-by, an officer on patrol, the vendors at its stalls, the people
## at its pitches and playgrounds, someone waiting at each bus stop, cars
## parked at its kerbs that can be driven, its robots on patrol and its
## pickups. Each is one thing to make (_later): a character or a car costs
## 10-40 ms the first time its model is drawn, so they come one a frame, not
## all in the frame the tile's mesh is in. They leave with the tile (_vacate).
func _populate(id: String, root: Node3D, region: NavigationRegion3D, again := false) -> void:
	var t: Dictionary = tiles[id]
	var rid := region.get_rid()
	var full := _near(id)                       # a player's tile: the full numbers
	if full:
		t["full"] = true
	var walks: Array = t.get("crowd", []) if extras else []
	# (a tile a player is in has the round's own crowd and the Director's
	# robots: none of the tile's on top)
	for k in (0 if full else TILE_PEOPLE):
		_later(id, root, func():
			var at := NavigationServer3D.region_get_random_point(rid, 1, true)
			if not walks.is_empty() and randf() < 0.45:      # promenades are busier
				at = NavigationServer3D.region_get_closest_point(rid, walks.pick_random())
			if at != Vector3.ZERO:
				main.spawn_civilian({"pos": at + Vector3(0, 0.1, 0), "model": main.Civilian.pick()}))
	for k in (0 if full else TILE_ROBOTS):
		_later(id, root, func(): _robot_in(id, rid))
	if not extras:
		return
	var officers: Array = main.Civilian.models_where("spawn", "patrol")
	for k in ((int(round(4.0 * sqrt(main.density()))) if full else TILE_POLICE) if not officers.is_empty() else 0):
		_later(id, root, func():
			var at := NavigationServer3D.region_get_random_point(rid, 1, true)
			if at != Vector3.ZERO:
				main.spawn_civilian({"pos": at + Vector3(0, 0.1, 0), "model": officers.pick_random()}))
	for data in main.vendor_spawns("res://city/%s.props.json" % id) + main.leisure_spawns(root):
		_later(id, root, func(): main.spawn_civilian(data))
	for k in (main.WAITING_PER_STOP if full else 1):
		for n in (t.get("stops", {}).get("lines", {}) as Dictionary):
			for stop in t["stops"]["lines"][n]:
				_later(id, root, func(): main._spawn_waiting(Vector3(stop[1], 0, stop[2]), main.get_world_3d().navigation_map))
	var away := []                              # a car a player drove off is not made again
	for v in main.traffic_root.get_children():
		if v.get_meta("tile_parked", "") == id and not v.is_queued_for_deletion():
			away.append(v.get_meta("spot"))
	for data in main.parked_cars(t.get("props"), id, main.PARKED_MAX if full else TILE_PARKED, t.get("e0", -1)):
		if not away.has(data["spot"]):
			_later(id, root, func(): main.park_car(data).set_meta("tile_parked", id))
	if not again:                               # a new round leaves the pickups where they are
		_pickups_in(id, t, root, rid, 1.0 if full else TILE_PICKUPS)


## A player walked into a tile that came in with the lighter numbers: it is
## topped up to the full ones - more officers, parked cars (not where a player
## would see them appear), pickups; on every peer more pigeons and
## quero-queros. Once: it stays full until it leaves.
func _fill(id: String, t: Dictionary) -> void:
	var root: Node3D = t["node"]
	if extras and t.get("birds_full", true) == false:
		# (not before _wildlife brought the first: a client with a player
		# already in the tile had both the full flocks and the top-up)
		t["birds_full"] = true
		main.pigeons_at(t.get("crowd", []), id + "+", main.FLOCKS - TILE_FLOCKS, root)
		main.queros_at(t["rect"], id + "+", int(main.Pigeon.quero_def().get("pairs", 5)) - TILE_QUEROS, root)
	var region := root.get_node_or_null("Navigation") as NavigationRegion3D
	if not extras or not multiplayer.is_server() or region == null or t.get("full", false) or not t.has("pickups"):
		return                                  # (not yet populated: it comes full then, or is filled after)
	t["full"] = true
	_note(id, "topped up: a player is in it", Time.get_ticks_usec())
	var rid := region.get_rid()
	var players: Array = main.players_root.get_children()
	var far_from_all := func(at: Vector3) -> bool:
		return players.all(func(pl): return (pl as Node3D).global_position.distance_to(at) > 50.0)
	var officers: Array = main.Civilian.models_where("spawn", "patrol")
	for k in ((int(round(4.0 * sqrt(main.density()))) - TILE_POLICE) if not officers.is_empty() else 0):
		_later(id, root, func():
			var at := NavigationServer3D.region_get_random_point(rid, 1, true)
			if at != Vector3.ZERO and far_from_all.call(at):
				main.spawn_civilian({"pos": at + Vector3(0, 0.1, 0), "model": officers.pick_random()}))
	var have := []
	for v in main.traffic_root.get_children():
		if v.get_meta("tile_parked", "") == id:
			have.append(v.get_meta("spot"))
	for data in main.parked_cars(t.get("props"), id, main.PARKED_MAX, t.get("e0", -1)):
		if not have.has(data["spot"]) and far_from_all.call(data["parked"]):
			_later(id, root, func(): main.park_car(data).set_meta("tile_parked", id))
	_more_pickups(id, t, root, rid)


## Server: the rest of the scattered pickups for a tile topped up (_fill).
func _more_pickups(id: String, t: Dictionary, root: Node3D, rid: RID) -> void:
	if t.get("pickups_full", false):
		return                                  # it has them all already (this round: also after it left and came back)
	t["pickups_full"] = true
	var reach := func(at: Vector3, _max_m: float) -> Vector3: return at     # a point of the tile's own mesh
	var more: Array = await main.pickups_for(main.get_world_3d().navigation_map, id, t["rect"], 1.0 - TILE_PICKUPS, [], [], {},
			func(): return NavigationServer3D.region_get_random_point(rid, 1, true), reach, BRING_MS)
	if not is_instance_valid(root) or t["node"] != root:
		return
	var n0: int = t["pickups"].size()
	t["pickups"].append_array(more)
	for k in range(n0, t["pickups"].size()):
		_later(id, root, func():
			var pk: Array = t["pickups"][k]
			var node: Node = main._spawn_pickup(pk[0], pk[1], true, pk[2])
			node.set_meta("tile", id)
			node.set_meta("spot", k))


## One thing a tile still brings, made when its turn comes (_bring): while
## the tile `id` is in as `root`.
var _looked := false                    # the tiles round a player's camera were looked at once (settled)
var _coming: Array = []                 # [tile id, the tile node's instance id, Callable, Callable]
var _cars_coming := 0                   # vehicles among them (the traffic count allows for these)
func _later(id: String, root: Node3D, make: Callable, dropped := Callable()) -> void:
	_coming.append([id, root.get_instance_id(), make, dropped])     # `dropped` is called instead if the tile left


## Every frame: the next things the tiles bring - two at most, one when the
## first took BRING_MS (what a new model costs comes after, when it is drawn).
const BRING_MS := 2.0
func _bring() -> void:
	if not main.models_warm:
		return                                  # the round is still reading its models (main.models_warm)
	var t0 := Time.get_ticks_usec()
	var made := 0
	while not _coming.is_empty() and made < 2:
		var job: Array = _coming.pop_front()
		var t: Dictionary = tiles.get(job[0], {})
		if t.get("state", "") != "in" or not is_instance_valid(t.get("node")) or (t["node"] as Node).get_instance_id() != job[1]:
			if (job[3] as Callable).is_valid():
				(job[3] as Callable).call()
			continue                            # its tile left meanwhile
		(job[2] as Callable).call()
		made += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 > BRING_MS:
			break


## Server: the tile's pickups (main.pickups_for): worked out the first time it comes in a round and
## kept, so each comes back where it was; they leave with the tile. A spot
## can be walked to when the tile's own mesh reaches it - what nobody can
## reach was dropped from it (drop_islands) - whichever neighbours are in.
## A few milliseconds a frame; each then comes in its turn (_later).
func _pickups_in(id: String, t: Dictionary, root: Node3D, rid: RID, share: float) -> void:
	if not t.has("pickups"):
		var map: RID = main.get_world_3d().navigation_map
		if not t.has("places"):
			t["places"] = main.places_of("res://city/%s.places.json" % id, Edits.read(id))
		var reach := func(at: Vector3, max_m: float) -> Vector3:
			var q := NavigationServer3D.region_get_closest_point(rid, at)
			if q.distance_to(at) < 1.2:
				return at
			return q if Vector2(q.x - at.x, q.z - at.z).length() <= max_m and absf(q.y - at.y) <= 3.0 else Vector3.INF
		var t0 := Time.get_ticks_usec()
		var found: Array = await main.pickups_for(map, id, t["rect"], share, t.get("fixed_pickups", []), t["places"],
				Edits.read(id), func(): return NavigationServer3D.region_get_random_point(rid, 1, true), reach, BRING_MS)
		if not is_instance_valid(root) or t["node"] != root:
			return
		t["pickups"] = found
		if share >= 1.0:
			t["pickups_full"] = true
		_note(id, "%d pickups worked out, %d ms a frame (main thread)" % [found.size(), BRING_MS], t0)
	for k in t["pickups"].size():
		_later(id, root, func():
			var pk: Array = t["pickups"][k]
			var node: Node = main._spawn_pickup(pk[0], pk[1], true, pk[2])
			node.set_meta("tile", id)
			node.set_meta("spot", k))


## Server: a tile's pickup taken comes back at another street point of its
## tile (main.random_pickup_point); the tile keeps where.
func pickup_point(pk: Node, avoid: Vector3) -> Vector3:
	var id: String = pk.get_meta("tile")
	var t: Dictionary = tiles.get(id, {})
	var region := (t["node"] as Node).get_node_or_null("Navigation") as NavigationRegion3D if t.get("state", "") == "in" and is_instance_valid(t.get("node")) else null
	if region == null:
		return avoid
	for attempt in 60:
		var pos := NavigationServer3D.region_get_random_point(region.get_rid(), 1, true)
		if not (t["rect"] as Rect2).grow(-10.0).has_point(Vector2(pos.x, pos.z)) or pos.distance_to(avoid) < 25.0:
			continue
		if main.pickups_root.get_children().any(func(o): return (o as Node3D).global_position.distance_to(pos) < 15.0):
			continue
		t["pickups"][int(pk.get_meta("spot"))][1] = pos
		return pos
	return avoid


## The fixed items of the landmarks of the tiles that are in, [kind,
## position] (DevAgent nav_probe).
func fixed_pickups() -> Array:
	var out := []
	for t in tiles.values():
		if t["state"] == "in":
			out.append_array(t.get("fixed_pickups", []))
	return out


## The places of the tiles that are in (main.all_places).
func places_in() -> Array:
	var out := []
	for t in tiles.values():
		if t["state"] == "in":
			out.append_array(t.get("places", []))
	return out


## Server, a new round (every passer-by and robot was removed): the tiles
## that are in bring theirs again.
func repopulate() -> void:
	for id in tiles:
		var t: Dictionary = tiles[id]
		var region := (t["node"] as Node).get_node_or_null("Navigation") as NavigationRegion3D if t["state"] == "in" and is_instance_valid(t["node"]) else null
		if t.get("nav", false) and region != null:
			for v in main.traffic_root.get_children():
				if v.get_meta("tile_parked", "") == id and not v.has_meta("taken"):
					v.queue_free()
			_populate(id, t["node"], region, true)


## Server: one of the tile's own robots on patrol, away from the players. They carry
## the tile's id (meta "tile") and leave with whatever tile they are in when
## it goes; those of the tile still alive elsewhere are not made again.
func _robot_in(id: String, rid: RID) -> void:
	var have := 0
	for e in main.enemies_root.get_children():
		if e.get_meta("tile", "") == id and e.has_method("is_alive") and e.is_alive():
			have += 1
	if have >= TILE_ROBOTS:
		return
	var players: Array = main.players_root.get_children()
	for attempt in 12:
		var at := NavigationServer3D.region_get_random_point(rid, 1, true)
		if at == Vector3.ZERO or not (tiles[id]["rect"] as Rect2).grow(-8.0).has_point(Vector2(at.x, at.z)):
			continue
		if players.any(func(pl): return (pl as Node3D).global_position.distance_to(at) < ROBOT_CLEAR_M):
			continue
		var e: Node = main.enemy_spawner.spawn({"id": main._next_enemy_id(), "pos": at + Vector3(0, 0.2, 0)})
		e.set_meta("tile", id)
		return


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
		var e0: int = g["edges"].size()
		t["e0"] = e0
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
		# its bus stops (main.area_stops), its zebra crossings and street names
		t["e1"] = g["edges"].size()
		t["stops"] = main.area_stops(Edits.read(id), "res://city/%s.props.json" % id, e0, t["e1"], t["rect"])
		var stops := 0
		for n in t["stops"]["lines"]:
			stops += t["stops"]["lines"][n].size()
		for key in ["crossings", "streets"]:
			if not g.has(key):
				g[key] = []
			(g[key] as Array).append_array(tg.get(key, []))
		g["rev"] = int(g.get("rev", 0)) + 1          # the GPS draws the streets again
		_note(id, "streets: %d edges joined to the road graph at %d nodes, %d bus stops, %d crossings" % [tg["edges"].size(), joined, stops, tg.get("crossings", []).size()], t0)
	for w in t["ways"]:
		(g["out"] as Dictionary).get_or_add(w[0], []).append(w[1])
	_entries()
	BusRoutes.invalidate(g)
	_bus_round()


## Map editor: a bus shelter was placed or moved - every tile's stops again.
func refresh_stops() -> void:
	for id in tiles:
		var t: Dictionary = tiles[id]
		if t.has("e1"):
			t["stops"] = main.area_stops(Edits.read(id), "res://city/%s.props.json" % id, t["e0"], t["e1"], t["rect"])
	_bus_round()


## The buses' round (main.set_bus_round): the stops of the tiles whose
## streets are open.
func _bus_round() -> void:
	var g: Dictionary = main.road_graph
	if not g.has("edges"):
		return
	var sets := []
	for t in tiles.values():
		if t.get("streets", false) and t.has("stops"):
			sets.append(t["stops"])
	main.set_bus_round(sets)


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
## of what is loaded.
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


## In a tile whose streets are open, `margin` from the edge of their union (a point on the seam between two of them is inside).
func _inside(p: Vector2, margin: float) -> bool:
	for d in [Vector2(margin, 0), Vector2(-margin, 0), Vector2(0, margin), Vector2(0, -margin)]:
		var q: Vector2 = p + d
		var found := false
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


## A tile a player stands in (or the round starts in) is full - its
## traffic, officers, parked cars, pickups, birds by the numbers in main,
## which grow with the start tile's size (main.density); the tiles round it
## bring the lighter TILE_* numbers.
func _near(id: String) -> bool:
	var r: Rect2 = tiles[id]["rect"]
	var players: Array = main.players_root.get_children()
	if players.is_empty():
		return r.has_point(Vector2(main.spawn_point.x, main.spawn_point.z))
	return players.any(func(pl): return r.has_point(Vector2((pl as Node3D).global_position.x, (pl as Node3D).global_position.z)))


## The moving traffic a tile should hold: main.TRAFFIC where a player is, else TILE_TRAFFIC.
func _share(id: String) -> int:
	return int(round(main.TRAFFIC * main.density())) if _near(id) else TILE_TRAFFIC


## Traffic the loaded world should hold: each open tile's.
func _traffic_wanted() -> int:
	var n := 0
	for id in tiles:
		if tiles[id].get("streets", false):
			n += _share(id)
	return n


## Server: traffic left to itself gathers where the one-way streets lead and
## thins out elsewhere. Each tile with its streets open has its share of the
## moving traffic (16 where a player is, 6 elsewhere); when one is EVEN_GAP
## over it and another as much under, a vehicle of the first that no player
## is near starts again on a street of the second that no player is near.
func _even_traffic() -> void:
	if not multiplayer.is_server() or not main._round_live:
		return
	var areas := []
	for id in tiles:
		if tiles[id].get("streets", false) and not (tiles[id]["ways"] as Array).is_empty():
			areas.append({"rect": tiles[id]["rect"], "want": float(_share(id)), "ways": tiles[id]["ways"], "have": []})
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
			var way: Array = (least["ways"] as Array).pick_random()[1]
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
	# vehicles their drivers ran from stay where they are and count, or every
	# tile coming in after a fight would add to them without end; the parked
	# cars and the war machine are not traffic
	var have := 0
	for v in main.traffic_root.get_children():
		if not v.has_meta("tile_parked") and v.get("kind") != "harvester":
			have += 1
	var room: int = _traffic_wanted() - have - _cars_coming     # (those other tiles are still bringing)
	var id: String = tiles.find_key(t)
	var full: bool = _share(id) > TILE_TRAFFIC     # a player's tile: the full traffic, buses too
	for k in mini(_share(id), room):
		var way: Array = ways.pick_random()[1]
		var model: int = main.Car.pick()
		while (main.Car.kind_of(main.Car.MODELS[model]) == "bus" and not full) \
				or (main.Car.MODELS[model].contains("trailer") and g["len"][way[0]] < 150.0):
			model = main.Car.pick()
		# in its turn (_later): six vehicles in one frame were a hitch of 170-190 ms
		_cars_coming += 1
		_later(id, t["node"], func():
			_cars_coming -= 1
			main._car_seq += 1
			main.car_spawner.spawn({"id": main._car_seq, "model": model, "driver": main.Civilian.pick_walker(),
					"edge": way[0], "forward": way[1]}),
			func(): _cars_coming -= 1)


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
			# a goal of the round or people aboard keeps the tile; another
			# robot of the round goes and the Director sends others
			if not e.has_meta("tile") and e.get("kind") in KEEPERS:
				return false
			robots.append(e)
	var traffic := []
	for v in main.traffic_root.get_children():
		if area.has_point(Vector2((v as Node3D).global_position.x, (v as Node3D).global_position.z)):
			if v.get("driver_peer") != 0 or v.has_meta("taken"):
				return false
			traffic.append(v)
	_streets_out(t)
	# what is the round's sleeps where it stands until the tile is back: a
	# container, an antenna, the war machine, the pickups no tile brought
	var kept := traffic.filter(func(v): return v.get("kind") == "harvester")
	traffic = traffic.filter(func(v): return not kept.has(v))
	t["asleep"] = _sleep(main._containers + main._antennas + kept
			+ main.pickups_root.get_children().filter(func(pk): return not pk.has_meta("tile") and pk.get("respawns")), area)
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
	# its pickups (it brings them again), and what a robot dropped in it
	for pk in main.pickups_root.get_children():
		var mine: bool = pk.has_meta("tile") and tiles.get(pk.get_meta("tile")) == t
		if mine or (not pk.has_meta("tile") and not pk.get("respawns") \
				and area.has_point(Vector2((pk as Node3D).global_position.x, (pk as Node3D).global_position.z))):
			pk.queue_free()
	return true


func _note(id: String, what: String, t0: int) -> void:
	events.append({"id": id, "what": what, "ms": snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1)})


## Invisible walls round all the tiles: players cannot leave the world (what
## lies beyond is scenery).
func _edge_walls() -> void:
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
