extends Node
## Open-world prototype (docs/OPEN_WORLD.md): neighbouring map tiles come in
## and go out round the player while the round's own map stays as it is.
## A tile is another map of the same source and frame (res://city/<id>.glb,
## <id>_collision.glb, <id>.spawn.json with its bounds): its meshes, its
## collision and a navigation mesh of its own, baked on a thread once it is
## in and joined to the meshes round it by links across the edge, so people
## and robots walk over. No traffic, props or landmarks of its own yet.
##
## Started by `main.open_world("owb")` (DevAgent `eval`) or `-- --open-world=owb`.
## Each step is timed (`report()`): reading the files on a loader thread,
## building the scene and its collision on a worker thread, and the frame
## that puts it into the tree - the one the player can feel.

const LOAD_M := 120.0       # a tile comes in when the player is this near its bounds
const UNLOAD_M := 220.0     # and goes out beyond this
const CHECK_S := 0.25
const LINK_STEP_M := 2.5    # a navigation link every so often along a tile's edge
const LINK_REACH_M := 1.2   # from this far outside the edge to this far inside
const TILE_PEOPLE := 14     # passers-by a tile brings

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
		var n := [0, 0]
		for k in 2:
			for c in ([main.civilians_root, main.enemies_root][k] as Node).get_children():
				var p: Vector3 = (c as Node3D).global_position
				if r.has_point(Vector2(p.x, p.z)):
					n[k] += 1
		out[id] = {"people": n[0], "robots": n[1]}
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
		if t["state"] == "out" and d < LOAD_M:
			t["state"] = "loading"
			t["t0"] = Time.get_ticks_usec()
			ResourceLoader.load_threaded_request(_glb(id), "", true)
			if ResourceLoader.exists(_col(id)):
				ResourceLoader.load_threaded_request(_col(id), "", true)
		elif t["state"] == "in" and d > UNLOAD_M:
			if not _vacate(t["rect"]):
				continue                       # a robot is in it: the tile stays
			var t0 := Time.get_ticks_usec()
			t["nav"] = false
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
	_bake(id, t)


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
	var before := NavigationServer3D.map_get_iteration_id(map)
	for k in 600:
		await get_tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(map) != before and k > 2:
			break
	if not is_instance_valid(root):
		return
	var n := _link(root, tiles[id]["rect"])
	tiles[id]["nav"] = true
	_note(id, "navigation region and %d links across the edge (main thread)" % n, t0)
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


## Before a tile leaves: passers-by in it leave the streets; a robot in it
## keeps the tile (false).
func _vacate(r: Rect2) -> bool:
	var area := r.grow(3.0)
	for e in main.enemies_root.get_children():
		if area.has_point(Vector2((e as Node3D).global_position.x, (e as Node3D).global_position.z)):
			return false
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
