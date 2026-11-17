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

const LOAD_M := 120.0       # a tile comes in when the player is this near its bounds
const UNLOAD_M := 220.0     # and goes out beyond this
const CHECK_S := 0.25
const LINK_STEP_M := 2.5    # a navigation link every so often along a tile's edge
const LINK_REACH_M := 1.2   # from this far outside the edge to this far inside
const TILE_PEOPLE := 14     # passers-by a tile brings
const FRAME_MS := 4.0       # street furniture: this much building a frame

var main: Node
var threaded := true        # false: build on the main thread (to compare the hitch)
var tiles := {}             # id -> {rect, state, node, task, t0, ...}
var events: Array = []      # [{id, what, ms}, ...] in order
var _since := 0.0
var _walls: StaticBody3D


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
	return {"tiles": states, "events": events, "threaded": threaded}


## People and robots standing in each tile now.
func census() -> Dictionary:
	var out := {}
	for id in tiles:
		var r: Rect2 = tiles[id]["rect"]
		var n := [0, 0, 0]
		for k in 3:
			for c in ([main.civilians_root, main.enemies_root, main.traffic_root][k] as Node).get_children():
				var p: Vector3 = (c as Node3D).global_position
				if r.has_point(Vector2(p.x, p.z)):
					n[k] += 1
		out[id] = {"people": n[0], "robots": n[1], "vehicles": n[2]}
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
	_since += dt
	if _since < CHECK_S:
		return
	_since = 0.0
	var p := Vector2(cam.global_position.x, cam.global_position.z)
	for id in tiles:
		var t: Dictionary = tiles[id]
		var d := _distance(t["rect"], p)
		if t["state"] == "in" and not t.get("streets", false):
			_streets_in(id, t)
		if t["state"] == "out" and d < LOAD_M:
			t["state"] = "loading"
			t["t0"] = Time.get_ticks_usec()
			t["paths"] = _files(id)
			for path in t["paths"]:
				ResourceLoader.load_threaded_request(path, "", true)
		elif t["state"] == "in" and d > UNLOAD_M:
			if not _vacate(t["rect"]):
				continue                       # a robot is in it: the tile stays
			var t0 := Time.get_ticks_usec()
			t["nav"] = false
			for lm in t.get("landmarks", []):
				main._landmark_nodes.erase(lm)
			t.erase("landmarks")
			t.erase("held")
			_streets_out(t)
			(t["node"] as Node).queue_free()
			t["node"] = null
			t["state"] = "out"
			_note(id, "unload", t0)


## What a tile reads on the loader thread: its city, its collision, and the
## models of its landmarks (a shop closed until someone walks in: its light
## version; a set laid out from pieces: the pieces).
func _files(id: String) -> Array:
	var out := [_glb(id)]
	if ResourceLoader.exists(_col(id)):
		out.append(_col(id))
	var path := "res://city/%s.landmarks.json" % id
	if not FileAccess.file_exists(path):
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
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
	root.add_child(props)
	await props.call("build", "res://city/%s.props.json" % id, FRAME_MS)
	if not is_instance_valid(root) or t["node"] != root:
		return
	for body in props.find_children("*", "CollisionObject3D", true, false):
		for key in ["prop_index", "crush"]:      # indices into the map's own props
			if body.has_meta(key):
				body.remove_meta(key)
	_note(id, "street furniture, %d pieces, %d ms a frame (main thread)" % [props.get_child_count(), FRAME_MS], t0)
	var worst := 0.0
	var total := 0.0
	var slow := []
	var n0: int = main._landmark_nodes.size()
	var pickups: int = main.landmark_pickups.size()
	var todo := []
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
		var ms := (Time.get_ticks_usec() - t1) / 1000.0
		if ms > 20.0:
			slow.append("%s %.0f ms" % [String(item[1].get("model", item[1].get("kind", "?"))).get_file(), ms])
		worst = maxf(worst, ms)
		total += ms
	t["landmarks"] = main._landmark_nodes.slice(n0)
	main.landmark_pickups.resize(pickups)        # the round's pickups are already out
	events.append({"id": id, "what": "%d landmarks and shops, one a frame (main thread): worst %.1f ms %s" % [todo.size(), worst, ", ".join(slow)],
			"ms": snappedf(total, 0.1)})
	# their collision is merged a frame later: the navmesh bake reads it
	for k in 2:
		await get_tree().physics_frame


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


## The tile's own navigation mesh: its colliders are read here, the mesh is
## baked on a thread, and when it is in, links join it to what is round it.
func _bake(id: String, t: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var root: Node3D = t["node"]
	obstacles(root, t["foreign"])
	var nm: NavigationMesh = (main.nav_region as NavigationRegion3D).navigation_mesh.duplicate()
	nm.clear()
	var r: Rect2 = t["rect"]
	var elev: Vector2 = t["elev"]
	nm.filter_baking_aabb = AABB(Vector3(r.position.x, elev.x - 2, r.position.y), Vector3(r.size.x, elev.y - elev.x + 6, r.size.y))
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, source, root)
	_note(id, "read colliders for the navmesh (main thread)", t0)
	var t1 := Time.get_ticks_usec()
	NavigationServer3D.bake_from_source_geometry_data_async(nm, source, func() -> void:
		_baked.call_deferred(id, root, nm, t1))


func _baked(id: String, root: Node3D, nm: NavigationMesh, t1: int) -> void:
	if not is_instance_valid(root) or not tiles.has(id) or tiles[id]["node"] != root:
		return                                  # the tile left while its mesh was baking
	_note(id, "bake the navmesh (thread), %d polygons" % nm.get_polygon_count(), t1)
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
		_note(id, "streets: %d edges joined to the road graph at %d nodes" % [tg["edges"].size(), joined], t0)
	for w in t["ways"]:
		(g["out"] as Dictionary).get_or_add(w[0], []).append(w[1])


## The tile leaves: the ways into its streets close (the edges stay in the
## graph, unreachable, for when it comes back).
func _streets_out(t: Dictionary) -> void:
	t["streets"] = false
	var g: Dictionary = main.road_graph
	if not g.has("out"):
		return
	for w in t.get("ways", []):
		var ways: Array = (g["out"] as Dictionary).get(w[0], [])
		for k in ways.size():
			if ways[k][0] == w[1][0] and ways[k][1] == w[1][1]:
				ways.remove_at(k)
				break


## Before a tile leaves: passers-by in it leave the streets and traffic in it
## comes back in at a border street of the map; a robot in it, or a vehicle
## someone left there, keeps the tile (false).
func _vacate(r: Rect2) -> bool:
	var area := r.grow(3.0)
	for e in main.enemies_root.get_children():
		if area.has_point(Vector2((e as Node3D).global_position.x, (e as Node3D).global_position.z)):
			return false
	var traffic := []
	for v in main.traffic_root.get_children():
		if area.has_point(Vector2((v as Node3D).global_position.x, (v as Node3D).global_position.z)):
			if v.get("driver_peer") != 0 or not v.get("occupied"):
				return false
			traffic.append(v)
	if multiplayer.is_server():
		for v in traffic:
			v.call("_enter_from_edge")
	if multiplayer.is_server():
		for c in main.civilians_root.get_children():
			if area.has_point(Vector2((c as Node3D).global_position.x, (c as Node3D).global_position.z)):
				c.queue_free()
	return true


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
