extends Node
## DevAgent: local JSON-RPC control channel for automated testing.
##
## Enabled only when the game is started with `--devagent` (after `--`).
## Listens on 127.0.0.1:24690; one JSON object per line in each direction:
##   -> {"id": 1, "method": "teleport", "params": {"x": 0, "y": 1, "z": 0}}
##   <- {"id": 1, "result": {...}}   or   {"id": 1, "error": "..."}
## tools/devagent/devagent.py (CLI) and tools/devagent/devagent_mcp.py (MCP server) are the
## clients. Never enabled in exported release builds unless asked for.

const PORT := 24690                   # DEVAGENT_PORT overrides it (a second instance for tests)
const SHOT_DIR := "user://devagent"

var _server := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _buffers := {}
var _shot_seq := 0


func _ready() -> void:
	if not "--devagent" in OS.get_cmdline_user_args():
		# off in a player's game: no frame work, and no F1 / F3 / F5 keys either
		set_process(false)
		set_process_input(false)
		set_process_unhandled_key_input(false)
		return
	var port := int(OS.get_environment("DEVAGENT_PORT")) if OS.has_environment("DEVAGENT_PORT") else PORT
	var err := _server.listen(port, "127.0.0.1")
	print("DevAgent listening on 127.0.0.1:%d (%s)" % [port, error_string(err)])
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_chat()


## Hitches: every frame longer than HITCH_MS, with what the world held then.
const HITCH_MS := 60.0
var _hitches: Array = []
var _hitch_total := 0          # hitches ever (the list keeps the last 200)
var _hitch_seen := 0
var _frame_t := 0


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _frame_t > 0:
		var ms := (now - _frame_t) / 1000.0
		if _rec_on:
			_rec_frame(ms)
		if _autoplay and _autoplay.done:
			_autoplay_finish()
		if ms > HITCH_MS and _main() and _main().map_id != "":
			_hitch_total += 1
			var m := _main()
			_hitches.append({"t": snappedf(Time.get_ticks_msec() / 1000.0, 0.1), "ms": snappedf(ms, 0.1),
					"physics_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.1),
					"robots": m.enemies_root.get_child_count(), "civilians": m.civilians_root.get_child_count(),
					"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
					"last_added": _last_added.slice(-6)})
			if _hitches.size() > 200:
				_hitches.pop_front()
	_frame_t = now
	if _recording:
		_frames.append(now)
	while _server.is_connection_available():
		var p := _server.take_connection()
		_peers.append(p)
		_buffers[p] = ""
	for p in _peers.duplicate():
		p.poll()
		if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(p)
			_buffers.erase(p)
			continue
		var n: int = p.get_available_bytes()
		if n > 0:
			_buffers[p] += p.get_utf8_string(n)
		while "\n" in _buffers[p]:
			var i: int = _buffers[p].find("\n")
			var line: String = _buffers[p].substr(0, i)
			_buffers[p] = _buffers[p].substr(i + 1)
			_handle(p, line)


func _handle(p: StreamPeerTCP, line: String) -> void:
	var msg = JSON.parse_string(line)
	if typeof(msg) != TYPE_DICTIONARY:
		_reply(p, null, null, "invalid JSON")
		return
	var method: String = msg.get("method", "")
	var params: Dictionary = msg.get("params", {})
	if not has_method("_m_" + method):
		_reply(p, msg.get("id"), null, "unknown method: " + method)
		return
	var result = await call("_m_" + method, params)
	if typeof(result) == TYPE_DICTIONARY and result.has("__error"):
		_reply(p, msg.get("id"), null, result["__error"])
	else:
		_reply(p, msg.get("id"), result, null)


func _reply(p: StreamPeerTCP, id, result, error) -> void:
	var out := {"id": id}
	if error != null:
		out["error"] = error
	else:
		out["result"] = result
	p.put_data((JSON.stringify(out) + "\n").to_utf8_buffer())


# ---- helpers -----------------------------------------------------------------

func _main() -> Node3D:
	return get_tree().current_scene


func _player() -> Node3D:
	var players := get_tree().get_nodes_in_group("players")
	for pl in players:
		if pl.is_multiplayer_authority():
			return pl
	return players[0] if players.size() > 0 else null


func _v(a) -> Array:
	return [snappedf(a.x, 0.01), snappedf(a.y, 0.01), snappedf(a.z, 0.01)]


func _err(text: String) -> Dictionary:
	return {"__error": text}


# ---- methods ---------------------------------------------------------------------

func _m_ping(_p: Dictionary):
	return {"pong": true, "fps": Engine.get_frames_per_second()}


func _m_start_solo(_p: Dictionary):
	if _player() == null:
		_main().driven = true
		await _main()._solo(str(_p.get("map", "")))
		await get_tree().process_frame
	return _m_get_state({})


func _m_perf(_p: Dictionary):
	## Frame cost: where the time goes (ms per frame), what is drawn, how many agents.
	var m := _main()
	var P := Performance
	var vrid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vrid, true)
	return {"fps": Engine.get_frames_per_second(), "render_scale": snappedf(get_viewport().scaling_3d_scale, 0.01),
		"gpu_ms": snappedf(RenderingServer.viewport_get_measured_render_time_gpu(vrid), 0.01),
		"cpu_render_ms": snappedf(RenderingServer.viewport_get_measured_render_time_cpu(vrid), 0.01),
		"process_ms": snappedf(P.get_monitor(P.TIME_PROCESS) * 1000.0, 0.01),
		"physics_ms": snappedf(P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"navigation_ms": snappedf(P.get_monitor(P.TIME_NAVIGATION_PROCESS) * 1000.0, 0.01),
		"draw_calls": P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects_drawn": P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"primitives": P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"nodes": P.get_monitor(P.OBJECT_NODE_COUNT),
		"physics_bodies": P.get_monitor(P.PHYSICS_3D_ACTIVE_OBJECTS),
		"civilians": m.civilians_root.get_child_count() if m else 0,
		"civilians_near": _near_count(m, 120.0),
		"vehicles": m.traffic_root.get_child_count() if m else 0,
		"robots": m.enemies_root.get_child_count() if m else 0}


func _near_count(m: Node, r: float) -> int:
	var pl := _player()
	if m == null or pl == null:
		return 0
	var n := 0
	for c in m.civilians_root.get_children():
		if (c as Node3D).global_position.distance_to(pl.global_position) < r:
			n += 1
	return n


func _m_get_state(_p: Dictionary):
	var m := _main()
	var players := []
	for pl in get_tree().get_nodes_in_group("players"):
		players.append({"name": pl.display_name, "id": pl.name, "pos": _v(pl.global_position),
				"yaw_deg": snappedf(pl.rotation_degrees.y, 0.1), "pitch_deg": snappedf(rad_to_deg(pl.pitch), 0.1),
				"health": pl.health, "dead": pl.dead, "ammo": pl.ammo, "reserve": pl.reserve})
	var enemies := []
	for e in m.enemies_root.get_children():
		enemies.append({"id": e.name, "pos": _v(e.global_position), "health": e.health})
	var d = m.director
	return {"players": players, "enemies": enemies, "design": m.design,
			"director": {"phase": d.Phase.keys()[d.phase], "kills": d.kills,
					"intensity": d.intensity, "enabled": d.is_processing()},
			"fps": Engine.get_frames_per_second()}


## Look inside an NPC (robot, pedestrian/dog, vehicle): AI state, goal,
## navigation status and automatic diagnoses for "why is it stuck?".
## params: id ("E4", "C12", "V3") or none = the one closest to the
## player's crosshair within 80 m (else the nearest).
func _m_inspect(p: Dictionary):
	var m := _main()
	var node: Node3D = null
	var id := str(p.get("id", ""))
	for root in [m.enemies_root, m.civilians_root, m.traffic_root]:
		if id != "" and root.has_node(id):
			node = root.get_node(id)
	if node == null and id == "":
		node = _in_sight()
	if node == null:
		return _err("no such NPC" if id != "" else "no NPC near the crosshair")
	var map: RID = m.get_world_3d().navigation_map
	var space := m.get_world_3d().direct_space_state
	var out := {"id": str(node.name), "pos": _v(node.global_position)}
	var issues := []
	var player := _player()
	if player:
		out["distance_to_player"] = snappedf(node.global_position.distance_to(player.global_position), 0.1)
	var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			node.global_position + Vector3(0, 2.0, 0), node.global_position + Vector3(0, -8.0, 0), 1))
	if under:
		out["ground_below"] = snappedf(node.global_position.y - under.position.y, 0.01)
		out["ground_mesh"] = str(under.collider.get_parent().name)
		if abs(out["ground_below"]) > 0.6:
			issues.append("not on the ground (%.2f m off)" % out["ground_below"])
	else:
		issues.append("no ground under it")
	if node is AnimatableBody3D:
		out["kind"] = node.kind
		out["speed"] = snappedf(node.get("_speed"), 0.01)
		out["blocked_time"] = snappedf(node.get("_blocked_time"), 0.1)
		out["pitch_deg"] = snappedf(rad_to_deg(node.rotation.x), 0.1)
		if out["blocked_time"] > 2.0:
			issues.append("braking for something in front for %.1f s" % out["blocked_time"])
		return _with_issues(out, issues)
	if node.get("variant") == "drone":
		out["kind"] = "drone"
		out["health"] = node.health
		out["target"] = str(node.target.name) if is_instance_valid(node.target) else null
		out["velocity"] = _v(node.velocity)
		var g := space.intersect_ray(PhysicsRayQueryParameters3D.create(node.global_position, node.global_position + Vector3(0, -80, 0), 1))
		out["altitude"] = snappedf(node.global_position.y - g.position.y, 0.1) if g else null
		issues = []                    # flying: being off the ground is the point
		return _with_issues(out, issues)
	var agent: NavigationAgent3D = node.agent
	var on_mesh := NavigationServer3D.map_get_closest_point(map, node.global_position)
	out["navmesh_offset"] = snappedf(on_mesh.distance_to(node.global_position), 0.01)
	out["velocity"] = _v(node.velocity)
	out["on_floor"] = node.is_on_floor()
	out["nav_target"] = _v(agent.target_position)
	out["nav_next"] = _v(agent.get_next_path_position())
	out["nav_finished"] = agent.is_navigation_finished()
	out["target_reachable"] = agent.is_target_reachable()
	var path := NavigationServer3D.map_get_path(map, node.global_position, agent.target_position, true)
	out["path_points"] = path.size()
	if path.size() > 0:
		out["path_ends_from_target"] = snappedf(path[path.size() - 1].distance_to(agent.target_position), 0.01)
	if node.is_in_group("robots"):
		out["kind"] = "robot"
		out["state"] = node.State.keys()[node.state]
		out["health"] = node.health
		out["dropping"] = node.dropping
		out["patrol_goal"] = _v(node.get("_patrol_goal")) if node.get("_patrol_goal") != Vector3.INF else null
		out["target"] = str(node.target.name) if is_instance_valid(node.target) else null
		out["prey"] = str(node.get("_prey").name) if is_instance_valid(node.get("_prey")) else null
		out["wants_to_move"] = node.get("_wants_to_move")
		out["stuck_time"] = snappedf(node.get("_stuck_time"), 0.01)
	else:
		out["kind"] = "dog" if node.dog else ("skater" if node.skater else "pedestrian")
		out["state"] = node.State.keys()[node.state]
		out["health"] = node.health
		out["goal"] = _v(node.get("_goal")) if node.get("_goal") != Vector3.INF else null
		out["pause_left"] = snappedf(node.get("_pause"), 0.01)
	var horiz := Vector2(node.velocity.x, node.velocity.z).length()
	if out.get("path_ends_from_target", 0.0) > 1.5:
		issues.append("its goal is not reachable on the street network (path ends %.1f m short)" % out["path_ends_from_target"])
	if out["nav_finished"] and node.global_position.distance_to(agent.target_position) > 3.0:
		issues.append("navigation finished %.1f m away from its target" % node.global_position.distance_to(agent.target_position))
	if out["navmesh_offset"] > 1.5:
		issues.append("%.1f m off the navmesh" % out["navmesh_offset"])
	var nxt := agent.get_next_path_position()
	if horiz > 0.3 and Vector2(nxt.x - node.global_position.x, nxt.z - node.global_position.z).length() < 0.15:
		issues.append("moving although the next path point is where it stands (jitter)")
	return _with_issues(out, issues)


func _with_issues(out: Dictionary, issues: Array) -> Dictionary:
	out["issues"] = issues if not issues.is_empty() else ["none found"]
	return out


## The NPC nearest to the crosshair line (within 80 m and 8 degrees), else the nearest one.
func _in_sight() -> Node3D:
	var pl := _player()
	if pl == null:
		return null
	var cam: Camera3D = pl.camera
	var origin := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var m := _main()
	var best: Node3D = null
	var best_angle := deg_to_rad(8.0)
	var nearest: Node3D = null
	var nearest_d := INF
	for root in [m.enemies_root, m.civilians_root, m.traffic_root]:
		for n in root.get_children():
			var to: Vector3 = (n.global_position + Vector3(0, 1.0, 0)) - origin
			var d := to.length()
			if d < nearest_d:
				nearest_d = d
				nearest = n
			if d < 80.0 and fwd.angle_to(to) < best_angle:
				best_angle = fwd.angle_to(to)
				best = n
	return best if best else nearest


func _m_teleport(p: Dictionary):
	var pl := _player()
	if pl == null:
		return _err("no player; call start_solo first")
	pl.global_position = Vector3(float(p.get("x", pl.global_position.x)), float(p.get("y", pl.global_position.y)),
			float(p.get("z", pl.global_position.z)))      # the CLI may send ints
	pl.velocity = Vector3.ZERO
	if p.has("yaw"):
		pl.rotation_degrees.y = p["yaw"]
	if p.has("pitch"):
		pl.pitch = deg_to_rad(p["pitch"])
		pl.head.rotation.x = pl.pitch
	await get_tree().physics_frame
	return {"pos": _v(pl.global_position)}


func _m_look_at(p: Dictionary):
	## Turn the camera towards a world point.
	var pl := _player()
	if pl == null:
		return _err("no player")
	var target := Vector3(p["x"], p.get("y", 1.6), p["z"])
	var d: Vector3 = target - pl.camera.global_position
	pl.rotation.y = atan2(-d.x, -d.z)
	pl.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	pl.head.rotation.x = pl.pitch
	return {"yaw_deg": snappedf(pl.rotation_degrees.y, 0.1), "pitch_deg": snappedf(rad_to_deg(pl.pitch), 0.1)}


func _m_screenshot(p: Dictionary):
	## Saves the next rendered frame; returns the absolute PNG path.
	# Let physics/animation settle, then render synchronously: when the window
	# is covered or minimised macOS stops presenting frames and
	# frame_post_draw never fires.
	for i in int(p.get("settle_frames", 2)):
		await get_tree().process_frame
	# hud=false: hide the 2D layers for a clean view of the scene
	var hidden := []
	if not p.get("hud", true):
		for layer in _main().find_children("*", "CanvasLayer", true, false):
			if (layer as CanvasLayer).visible:
				(layer as CanvasLayer).visible = false
				hidden.append(layer)
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	var img := get_viewport().get_texture().get_image()
	for layer in hidden:
		(layer as CanvasLayer).visible = true
	# crop=[x0, y0, x1, y1] as fractions of the frame, then width=N to shrink
	if p.has("crop"):
		var c: Array = p["crop"]
		var W := img.get_width()
		var H := img.get_height()
		img = img.get_region(Rect2i(int(c[0] * W), int(c[1] * H), int((c[2] - c[0]) * W), int((c[3] - c[1]) * H)))
	if p.has("width"):
		var w: int = p["width"]
		img.resize(w, int(img.get_height() * w / float(img.get_width())))
	_shot_seq += 1
	# unique across launches (the counter alone restarted at 1 and overwrote)
	var path := ProjectSettings.globalize_path("%s/shot_%d_%04d.png" % [SHOT_DIR, Time.get_unix_time_from_system(), _shot_seq])
	img.save_png(path)
	return {"path": path, "size": [img.get_width(), img.get_height()]}


func _m_hold_keys(p: Dictionary):
	## Hold game actions (Settings names: forward, left, right, back, run,
	## jump, use...) for `seconds`, through the same path as real keys.
	var acts: Array = p.get("actions", [])
	for a in acts:
		Settings.virtual[a] = true
	await get_tree().create_timer(float(p.get("seconds", 1.0))).timeout
	for a in acts:
		Settings.virtual.erase(a)
	return {"held": acts}


func _m_tap(p: Dictionary):
	## Press an action once (a key event: use, reload, weapon_N, design...).
	var ev := InputEventKey.new()
	ev.physical_keycode = Settings.key(p["action"])
	ev.keycode = ev.physical_keycode
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	return {"tapped": p["action"]}


func _m_audit_ground(p: Dictionary):
	## Things standing off the ground: vehicles, pedestrians, robots, parked
	## cars and pickups whose origin is more than `tolerance` m from the
	## surface under them (sunk or floating). Worst first.
	var tol: float = p.get("tolerance", 0.25)
	var m := _main()
	var space := m.get_world_3d().direct_space_state
	var items := []
	for root in [m.traffic_root, m.civilians_root, m.enemies_root]:       # pickups hover on purpose
		for n in root.get_children():
			items.append([String(root.name), n])
	for n in m.props.get_children():
		if n is Node3D and n.find_child("*", false, false) and String((n as Node3D).get_child(0).name).begins_with("car"):
			items.append(["parked", n])
	var out := []
	for it in items:
		var n: Node3D = it[1]
		if not is_instance_valid(n) or (n.get("dropping") == true):
			continue
		var at := n.global_position
		var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 3, 0), at - Vector3(0, 4, 0), 1)
		var ex := []
		for b in n.find_children("*", "CollisionObject3D", true, false):
			ex.append((b as CollisionObject3D).get_rid())
		if n is CollisionObject3D:
			ex.append((n as CollisionObject3D).get_rid())
		q.exclude = ex
		var hit := space.intersect_ray(q)
		# only the street itself counts (city ground meshes), not roofs or props above
		while not hit.is_empty() and not (hit.collider.get_parent() is MeshInstance3D):
			ex.append(hit.rid)
			q.exclude = ex
			hit = space.intersect_ray(q)
		if hit.is_empty():
			continue
		var off: float = at.y - hit.position.y
		if abs(off) > tol:
			out.append({"what": it[0], "name": String(n.name), "pos": _v(at), "off_m": snappedf(off, 0.01),
					"ground": str(hit.collider.name)})
	out.sort_custom(func(a, b): return abs(a["off_m"]) > abs(b["off_m"]))
	return {"checked": items.size(), "off_ground": out.slice(0, int(p.get("limit", 20)))}


func _m_audit_streets(p: Dictionary):
	## Drive every street of the traffic graph in thought: every `step` m along
	## each lane, rays down find the street surface and anything standing on it.
	## Reports, worst first: "step" (the surface jumps between two samples),
	## "dent" (a bump or a hollow against the line through its neighbours),
	## "steep" (grade over `grade`), "tilt" (the street leans across its lanes),
	## "hole" (no ground) and "blocked" (a building, a prop or a landmark on the
	## lane). Only `limit` findings come back; `totals` counts all of them.
	var m := _main()
	var g: Dictionary = m.road_graph
	if g.is_empty():
		return {"error": "no road graph on this map"}
	var step: float = float(p.get("step", 2.0))
	var max_step: float = float(p.get("max_step", 0.2))     # m between two samples, after the trend
	var max_dent: float = float(p.get("max_dent", 0.1))
	var max_grade: float = float(p.get("grade", 0.14))
	var max_tilt: float = float(p.get("tilt", 0.06))      # across the street
	var space := m.get_world_3d().direct_space_state
	var names := {}
	for st in g.get("streets", []):
		for q in st[1]:
			names[Vector2i(roundi(q[0]), roundi(q[1]))] = st[0]
	var found := []
	var totals := {}
	var metres := 0.0
	for ei in g["edges"].size():
		var e: Dictionary = g["edges"][ei]
		var pts: Array = e["pts"]
		var name := ""
		for q in pts:
			name = names.get(Vector2i(roundi(q[0]), roundi(q[1])), name)
		var lanes: Array = [0.0] if e["oneway"] else [-2.5, 2.5]
		var prev := {}
		for k in pts.size() - 1:
			var a := Vector3(pts[k][0], 0, pts[k][1])
			var b := Vector3(pts[k + 1][0], 0, pts[k + 1][1])
			var seg := a.distance_to(b)
			if seg < 0.01:
				continue
			var dir := (b - a) / seg
			var side := dir.cross(Vector3.UP)
			var expect_a: float = pts[k][2] if pts[k].size() > 2 else 0.0
			var expect_b: float = pts[k + 1][2] if pts[k + 1].size() > 2 else 0.0
			var t := 0.0
			while t < seg:
				var c := a + dir * t
				var y0: float = lerpf(expect_a, expect_b, t / seg)
				metres += step
				var hs := []
				for off in lanes + [lanes[0] - 2.0, lanes[-1] + 2.0]:
					var r := _street_ray(space, c + side * off, y0)
					hs.append(r)
					if off in lanes and r.has("blocked"):
						_finding(found, totals, "blocked", c + side * off, r["blocked_h"], name, ei, r["blocked"])
					elif off in lanes and r.is_empty():
						_finding(found, totals, "hole", c + side * off, 0.0, name, ei, "")
				var l: Dictionary = hs[hs.size() - 2]
				var rr: Dictionary = hs[hs.size() - 1]
				if l.has("y") and rr.has("y"):
					var w := absf(lanes[-1] - lanes[0]) + 4.0
					var tilt := absf(float(l["y"]) - float(rr["y"])) / w
					if tilt > max_tilt:
						_finding(found, totals, "tilt", c, tilt, name, ei, "")
				var mid: Dictionary = hs[0]
				if mid.has("y"):
					var y: float = mid["y"]
					if prev.has("y"):
						var dy: float = y - float(prev["y"])
						var trend: float = (expect_b - expect_a) / seg * step
						if absf(dy - trend) > max_step:
							_finding(found, totals, "step", c, dy, name, ei, "")
						elif absf(dy) / step > max_grade:
							_finding(found, totals, "steep", c, dy / step, name, ei, "")
						if prev.has("py"):
							var dent: float = float(prev["y"]) - 0.5 * (float(prev["py"]) + y)
							if absf(dent) > max_dent:
								_finding(found, totals, "dent", c - dir * step, dent, name, ei, "")
						prev = {"y": y, "py": prev["y"]}
					else:
						prev = {"y": y}
				t += step
	found.sort_custom(func(x, z): return x["size"] > z["size"])
	return {"metres": roundi(metres), "edges": g["edges"].size(), "totals": totals,
			"findings": found.slice(0, int(p.get("limit", 40)))}


## The street surface at a point (the city's ground mesh) and the first
## other thing above it on the way down (a wall, a prop, a landmark).
func _street_ray(space: PhysicsDirectSpaceState3D, at: Vector3, y0: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, y0 + 6.0, at.z), Vector3(at.x, y0 - 6.0, at.z), 1)
	var ex := []
	var out := {}
	for i in 6:
		q.exclude = ex
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		var col: Object = hit.collider
		var who := _owner_name(col)
		if col.get_parent() is MeshInstance3D and ("City/" in who or who.begins_with("City")) and not _is_building(who):
			out["y"] = hit.position.y
			if out.has("blocked") and float(out["blocked_at"]) - hit.position.y < 0.3:
				out.erase("blocked")          # only a kerb or a lip just above the street: not in the way
			if out.has("blocked"):
				out["blocked_h"] = float(out["blocked_at"]) - hit.position.y
			return out
		if col is CharacterBody3D or col is RigidBody3D or col is VehicleBody3D or col is Area3D:
			ex.append(hit.rid)                # cars, people, robots, pickups move on
			continue
		if not out.has("blocked"):
			out["blocked"] = who + _what_is(col as Node)
			out["blocked_at"] = hit.position.y
		ex.append(hit.rid)
	if out.has("blocked") and not out.has("y"):
		out["blocked_h"] = 6.0
	return out


## The city's own meshes that are walls, not ground.
func _is_building(who: String) -> bool:
	for w in ["facade", "roof", "plaster", "brick", "glass", "bands", "fins", "wall", "shop"]:
		if w in who.to_lower():
			return true
	return false


## What a prop or landmark is: its model file or its meshes' names.
func _what_is(n: Node) -> String:
	while n and n.get_parent() and n.get_parent() != _main() and String(n.get_parent().name) not in ["Props", "Landmarks", "City"]:
		n = n.get_parent()
	if n == null:
		return ""
	for k in ["landmark", "prop", "model"]:
		if n.has_meta(k):
			var v = n.get_meta(k)
			return " = " + (str(v.get("model", v)) if v is Dictionary else str(v))
	if n.scene_file_path != "":
		return " = " + n.scene_file_path
	var meshes := n.find_children("*", "MeshInstance3D", true, false)
	return " = " + (String(meshes[0].name) if meshes.size() > 0 else String(n.name))


func _owner_name(col: Object) -> String:
	var n := col as Node
	var names := []
	while n and n != _main() and names.size() < 4:
		names.push_front(String(n.name))
		n = n.get_parent()
	return "/".join(names)


## One finding per kind and place: a run of samples a few metres apart is one.
func _finding(found: Array, totals: Dictionary, kind: String, at: Vector3, size: float, street: String, edge: int, what: String) -> void:
	totals[kind] = int(totals.get(kind, 0)) + 1
	for f in found:
		if f["kind"] == kind and Vector2(f["pos"][0], f["pos"][2]).distance_to(Vector2(at.x, at.z)) < 6.0:
			f["size"] = maxf(f["size"], absf(size))
			return
	found.append({"kind": kind, "pos": _v(at), "size": snappedf(absf(size), 0.01), "signed": snappedf(size, 0.01),
			"street": street, "edge": edge, "what": what})


func _m_show_only(p: Dictionary):
	## Performance: show or hide a whole kind of thing to see what it costs
	## (perf before and after). `what`: storefronts, landmarks, props, city,
	## civilians, traffic, robots, shadows; `on` true / false.
	var m := _main()
	var on: bool = p.get("on", false)
	var n := 0
	match String(p.get("what", "")):
		"storefronts", "landmarks":
			for lm in m._landmark_nodes:
				if is_instance_valid(lm):
					var sf := String(lm.get_meta("landmark", {}).get("model", "")).contains("/storefronts/")
					if sf == (p["what"] == "storefronts"):
						lm.visible = on
						n += 1
		"props":
			m.props.visible = on
			n = m.props.get_child_count()
		"city":
			m.get_node("Navigation/City").visible = on
			n = 1
		"civilians":
			m.civilians_root.visible = on
			n = m.civilians_root.get_child_count()
		"traffic":
			m.traffic_root.visible = on
			n = m.traffic_root.get_child_count()
		"robots":
			m.enemies_root.visible = on
			n = m.enemies_root.get_child_count()
		"shadows":
			for l in m.find_children("*", "DirectionalLight3D", true, false):
				(l as DirectionalLight3D).shadow_enabled = on
				n += 1
	return {"what": p.get("what"), "on": on, "nodes": n}


func _m_lights(p: Dictionary):
	## Performance: the omni and spot lights by where they hang (the node
	## under Main / Navigation they belong to), with how many cast shadows.
	var m := _main()
	var by := {}
	for l in m.find_children("*", "Light3D", true, false):
		if l is DirectionalLight3D:
			continue
		var n: Node = l
		var trail := []
		while n and n != m:
			trail.push_front(String(n.name))
			n = n.get_parent()
		var key := "/".join(trail.slice(0, 2 if trail.size() > 1 and trail[0] == "Navigation" else 1))
		if trail.size() > 2 and trail[0] == "Navigation":
			key += "/" + String(trail[2]).get_slice("@", 0).left(24)
		var e: Array = by.get(key, [0, 0, 0])
		e[0] += 1
		e[1] += 1 if (l as Light3D).shadow_enabled else 0
		e[2] += 1 if (l as Light3D).visible else 0
		by[key] = e
	var rows := []
	for k in by:
		rows.append([k, by[k][0], by[k][1], by[k][2]])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	return {"total": rows.reduce(func(acc, r): return acc + r[1], 0), "by": rows.slice(0, int(p.get("limit", 20)))}


func _m_uncap(p: Dictionary):
	## Benchmarks: no frame cap and no vsync (`on` false puts them back), so
	## a frame's real cost shows above the screen's refresh rate.
	var on: bool = p.get("on", true)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if on else DisplayServer.VSYNC_ENABLED)
	return {"uncapped": on}


## What entered the tree lately (by name / class), for the hitch log.
var _last_added: Array = []
func _on_node_added(n: Node) -> void:
	if n is Node3D and n.get_parent() and (n.get_parent() == _main() or n.get_parent().get_parent() == _main()):
		var what := String(n.name).get_slice("@", 0).left(24)
		if what == "" and n is MeshInstance3D and (n as MeshInstance3D).mesh:
			what = (n as MeshInstance3D).mesh.get_class()
		_last_added.append("%s:%s@%.1f" % [n.get_class(), what, Time.get_ticks_msec() / 1000.0])
		if _last_added.size() > 30:
			_last_added.pop_front()


func _m_hitches(p: Dictionary):
	## The frames longer than 60 ms since the last call (cleared), with what
	## the world held and what had just been added to it.
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	var out := _hitches.duplicate()
	if p.get("clear", true):
		_hitches.clear()
	return {"count": out.size(), "hitches": out.slice(-int(p.get("limit", 40)))}


func _m_scene_count(_p: Dictionary):
	## What the scene holds by kind (to find what piles up during a match).
	var m := _main()
	var out := {}
	for k in ["MeshInstance3D", "MultiMeshInstance3D", "OmniLight3D", "SpotLight3D", "Decal", "GPUParticles3D",
			"CPUParticles3D", "RigidBody3D", "StaticBody3D", "CollisionShape3D", "AudioStreamPlayer3D", "Label3D"]:
		out[k] = m.find_children("*", k, true, false).size()
	var by_parent := {}
	for c in m.get_children():
		by_parent[String(c.name).get_slice("@", 0)] = int(by_parent.get(String(c.name).get_slice("@", 0), 0)) + 1 + c.get_child_count()
	out["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	out["top_level"] = by_parent
	return out


## Frame times for benchmarks: `frames on=true` starts recording every frame,
## `frames` (on missing) returns the distribution since then and goes on.
var _recording := false
var _frames: PackedInt64Array = []
func _m_frames(p: Dictionary):
	if p.has("on"):
		_recording = bool(p["on"])
		_frames.clear()
		return {"recording": _recording}
	var ms: Array = []
	for i in range(1, _frames.size()):
		ms.append((_frames[i] - _frames[i - 1]) / 1000.0)
	_frames = _frames.slice(_frames.size() - 1) if _frames.size() > 0 else _frames
	if ms.is_empty():
		return {"frames": 0}
	ms.sort()
	var total := 0.0
	for v in ms:
		total += v
	var q := func(f: float) -> float: return snappedf(ms[mini(ms.size() - 1, int(ms.size() * f))], 0.1)
	return {"frames": ms.size(), "seconds": snappedf(total / 1000.0, 0.1), "avg_fps": snappedf(ms.size() / (total / 1000.0), 0.1),
			"median_ms": q.call(0.5), "p95_ms": q.call(0.95), "p99_ms": q.call(0.99), "max_ms": snappedf(ms[-1], 0.1),
			"over_33ms": ms.filter(func(v): return v > 33.4).size(), "over_100ms": ms.filter(func(v): return v > 100.0).size()}


## Give the player a weapon with full ammunition (automated play tests).
func _m_arm(p: Dictionary):
	var pl := _player()
	var w: String = p.get("weapon", "machinegun")
	pl.give(w)
	pl._reserves[w] = pl.WEAPONS[w]["reserve_max"]
	return {"weapon": pl.weapon, "mag": pl._mags.get(w), "reserve": pl._reserves.get(w)}


func _m_census(_p: Dictionary):
	## Performance: who is doing what - people wandering / fleeing / at a far
	## LOD, robots by state.
	var m := _main()
	var civ := {"wander": 0, "flee": 0, "far": 0, "police": 0}
	for c in m.civilians_root.get_children():
		civ["flee" if c.state == 1 else "wander"] += 1
		civ["far"] += 1 if c.get("_far") else 0
		civ["police"] += 1 if c.get("police") else 0
	var rob := {}
	for e in m.enemies_root.get_children():
		var k := str(e.get("state"))
		rob[k] = int(rob.get(k, 0)) + 1
	return {"civilians": civ, "robots": rob}


func _m_errors(p: Dictionary):
	## The latest SCRIPT ERROR / ERROR lines from the game log.
	var path := ProjectSettings.globalize_path("user://logs/godot.log")
	if not FileAccess.file_exists(path):
		return {"errors": []}
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var out := []
	for i in lines.size():
		var l := lines[i]
		if l.begins_with("SCRIPT ERROR") or (l.begins_with("ERROR") and not "leaked" in l):
			out.append(l + (" | " + lines[i + 1].strip_edges() if i + 1 < lines.size() else ""))
	return {"errors": out.slice(max(0, out.size() - int(p.get("limit", 15))))}


func _m_raycast(p: Dictionary):
	var a := Vector3(p["from"][0], p["from"][1], p["from"][2])
	var b := Vector3(p["to"][0], p["to"][1], p["to"][2])
	var q := PhysicsRayQueryParameters3D.create(a, b, int(p.get("mask", 1)))
	var hit: Dictionary = _main().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"hit": false}
	return {"hit": true, "pos": _v(hit.position), "normal": _v(hit.normal),
			"collider": str(hit.collider.get_parent().name if hit.collider.get_parent() else hit.collider.name)}


func _m_design(p: Dictionary):
	## Turn design mode on/off (enabled omitted: toggle).
	var m := _main()
	if not p.has("enabled") or bool(p["enabled"]) != m.design:
		m.toggle_design()
	return {"design": m.design}


# ---- the message channel: the player writes to the assistant (F1), the
# assistant reads with `inbox` (or tools/devagent/devagent_wait.py, which blocks until
# something arrives) and answers with `say` -------------------------------------
const INBOX := "user://devagent/inbox.jsonl"
var _inbox: Array = []
var _chat_layer: CanvasLayer
var _chat_edit: LineEdit


func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.layer = 61
	_chat_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_chat_layer.visible = false
	add_child(_chat_layer)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.2
	panel.anchor_right = 0.8
	panel.anchor_top = 0.8
	panel.anchor_bottom = 0.8
	panel.offset_top = -40
	panel.offset_bottom = 40
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.1, 0.16, 0.95)
	st.border_color = Color(0.85, 0.55, 1.0)
	st.set_border_width_all(2)
	st.set_content_margin_all(10)
	st.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", st)
	_chat_layer.add_child(panel)
	_chat_edit = LineEdit.new()
	_chat_edit.placeholder_text = "Message to Claude (Enter sends, Esc closes) - what you selected in design mode goes with it"
	_chat_edit.add_theme_font_size_override("font_size", 22)
	_chat_edit.text_submitted.connect(_send_chat)
	panel.add_child(_chat_edit)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	if _chat_layer.visible:
		return
	if event.physical_keycode == KEY_F3:
		_toggle_god()
		get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_F5:
		_toggle_rec()
		get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_F1:
		_view = _view_snapshot()            # what the player looks at, before the panel covers it
		_chat_layer.visible = true
		_chat_mouse = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_chat_edit.grab_focus.call_deferred()
		get_viewport().set_input_as_handled()


var _chat_mouse := Input.MOUSE_MODE_CAPTURED
func _input(event: InputEvent) -> void:
	if _chat_layer and _chat_layer.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_chat()
		get_viewport().set_input_as_handled()


func _close_chat() -> void:
	_chat_layer.visible = false
	_chat_edit.text = ""
	Input.mouse_mode = _chat_mouse


func _send_chat(text: String) -> void:
	text = text.strip_edges()
	_close_chat()
	if text == "":
		return
	var m := _main()
	var msg := {"text": text, "time": Time.get_datetime_string_from_system(), "map": m.map_id if m else "",
			"design": m.design if m else false}
	var p := _player()
	if p:
		msg["player"] = _v(p.global_position)
	if m and not m.design_selection.is_empty():
		var s: Dictionary = m.design_selection
		msg["selection"] = {"what": s["what"], "name": s["name"], "detail": s["detail"], "pos": _v(s["pos"])}
		if m.map_editor and s["what"] == "building":
			msg["selection"]["osm"] = m.map_editor._sel.get("id", "")
	if m and m.design_selections.size() > 1:
		# several objects picked (Shift+click): all of them, as references
		msg["selections"] = m.design_selections.map(func(e): return _sel_ref(e))
	if not _view.is_empty():
		msg["view"] = _view
		_view = {}
	_inbox.append(msg)
	var f := FileAccess.open(INBOX, FileAccess.READ_WRITE if FileAccess.file_exists(INBOX) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(JSON.stringify(msg))
	f.close()
	_m_say({"text": "(sent) " + text, "seconds": 5})


## F1: where the player is looking when the message is started - the view's
## heading on the compass (0 north = -Z, 90 east = +X), its pitch, what the
## crosshair is on (a building with its OSM id, a robot, a person, a
## vehicle, the ground) and a picture of the screen, so "this building here"
## needs no guessing.
var _view := {}
const VIEW_DIR := "user://devagent/f1"
func _view_snapshot() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var fwd := -cam.global_transform.basis.z
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var out := {"camera": _v(cam.global_position), "heading_deg": snappedf(heading, 1.0),
			"compass": names[int(round(heading / 45.0)) % 8], "pitch_deg": snappedf(rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0))), 1.0)}
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + fwd * 400.0, 1 | 2 | 16 | 32 | 64)
	var pl := _player()
	if pl:
		q.exclude = [pl.get_rid()]
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		var aim := {"pos": _v(hit.position), "distance": snappedf(cam.global_position.distance_to(hit.position), 0.1),
				"collider": String(hit.collider.name)}
		var n: Node = hit.collider
		while n and n != _main():
			if n.is_in_group("robots"):
				aim["robot"] = "%s %s" % [n.name, n.get("variant")]
				break
			if n.is_in_group("civilians"):
				aim["person"] = String(n.name)
				break
			if n.get("kind") != null and n.has_method("shove"):
				aim["vehicle"] = "%s %s" % [n.name, n.kind]
				break
			if n.has_meta("landmark"):
				aim["landmark"] = String(n.get_meta("landmark").get("model", n.get_meta("landmark").get("id", "")))
				break
			n = n.get_parent()
		var m := _main()
		if not aim.has("robot") and not aim.has("person") and not aim.has("vehicle") and m:
			var b := _building_near(m.map_id, hit.position)
			if not b.is_empty():
				aim["building"] = {"osm": b.get("id", ""), "name": b.get("name", ""), "height": b.get("height", 0),
						"link": "https://www.openstreetmap.org/" + str(b.get("id", ""))}
		out["aim"] = aim
	var img := get_viewport().get_texture().get_image()
	if img:
		img.resize(1280, int(1280.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		DirAccess.make_dir_recursive_absolute(VIEW_DIR)
		var path := VIEW_DIR.path_join("f1_%d.jpg" % Time.get_unix_time_from_system())
		img.save_jpg(path, 0.85)
		out["screenshot"] = ProjectSettings.globalize_path(path)
	return out


## The generated building at (or within 2.5 m of) a point - from the map's
## <city>.buildings.json, so it works in play too (the map editor's index only
## exists in design mode).
var _bld_map := ""
var _bld: Array = []
func _building_near(map_id: String, p: Vector3) -> Dictionary:
	if map_id != _bld_map:
		_bld_map = map_id
		var path := "res://city/%s.buildings.json" % map_id
		_bld = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else []
	var pt := Vector2(p.x, p.z)
	var best := {}
	var best_d := 2.5
	for b in _bld:
		var poly := PackedVector2Array()
		for q in b["ring"]:
			poly.append(Vector2(q[0], q[1]))
		if Geometry2D.is_point_in_polygon(pt, poly):
			return b
		for i in poly.size():
			var d := Geometry2D.get_closest_point_to_segment(pt, poly[i], poly[(i + 1) % poly.size()]).distance_to(pt)
			if d < best_d:
				best_d = d
				best = b
	return best


## F3: god mode on and off (no damage) - for playing while developing.
func _toggle_god() -> void:
	var pl := _player()
	if pl == null:
		return
	var on := not bool(pl.get_meta("god", false))
	pl.set_meta("god", on)
	if on:
		pl.health = maxi(pl.health, 100)
	_m_say({"text": "God mode %s (F3)" % ("ON - no damage" if on else "OFF"), "seconds": 4})


## F5: record what every frame costs until F5 again - frame time, script and
## physics time, what is drawn, people and robots, where the player is and
## looks, and every hitch with what had just come in. The file goes to
## user://devagent/perf/ and a message to the F1 channel says where, with a
## summary (tools/devagent/perf_report.py reads it).
var _rec_on := false
var _rec_rows: Array = []
var _rec_start := 0
var _rec_hitch0 := 0
var _rec_label: Label
const PERF_DIR := "user://devagent/perf"
func _toggle_rec() -> void:
	if not _rec_on:
		_rec_on = true
		_rec_rows = []
		_rec_start = Time.get_ticks_msec()
		_rec_hitch0 = _hitches.size()
		_hitch_seen = _hitch_total
		if _rec_label == null:
			var layer := CanvasLayer.new()
			layer.layer = 62
			add_child(layer)
			_rec_label = Label.new()
			_rec_label.text = "● REC performance (F5 stops)"
			_rec_label.position = Vector2(20, 40)
			_rec_label.add_theme_font_size_override("font_size", 20)
			_rec_label.add_theme_color_override("font_color", Color(1, 0.25, 0.2))
			_rec_label.add_theme_constant_override("outline_size", 6)
			_rec_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			layer.add_child(_rec_label)
		_rec_label.visible = true
		return
	_rec_on = false
	_rec_label.visible = false
	var ms: Array = _rec_rows.map(func(r): return r[1])
	if ms.size() < 2:
		return
	ms.sort()
	var total := 0.0
	for v in ms:
		total += v
	var qf := func(f: float) -> float: return snappedf(ms[mini(ms.size() - 1, int(ms.size() * f))], 0.1)
	var hitches: Array = _hitches.slice(maxi(0, _hitches.size() - (_hitch_total - _hitch_seen)))
	var summary := {"seconds": snappedf(total / 1000.0, 0.1), "frames": ms.size(), "avg_fps": snappedf(ms.size() / (total / 1000.0), 0.1),
			"median_ms": qf.call(0.5), "p95_ms": qf.call(0.95), "p99_ms": qf.call(0.99), "max_ms": snappedf(ms[-1], 0.1),
			"over_33ms": ms.filter(func(v): return v > 33.4).size(), "over_100ms": ms.filter(func(v): return v > 100.0).size(),
			"hitches": hitches.size(), "map": _main().map_id if _main() else ""}
	DirAccess.make_dir_recursive_absolute(PERF_DIR)
	var path := PERF_DIR.path_join("rec_%d.json" % Time.get_unix_time_from_system())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"summary": summary, "hitches": hitches,
			"columns": ["t", "frame_ms", "process_ms", "physics_ms", "draw_calls", "objects", "primitives",
					"civilians", "robots", "vehicles", "x", "z", "heading_deg", "fps_setting_scale", "activity"],
			"rows": _rec_rows}))
	f.close()
	var line := "%.0f s, %.0f fps avg, median %.1f ms, p99 %.1f ms, worst %.0f ms, %d frames over 100 ms" % [
			summary["seconds"], summary["avg_fps"], summary["median_ms"], summary["p99_ms"], summary["max_ms"], summary["over_100ms"]]
	_m_say({"text": "Performance recorded (%s) - sent to Claude" % line, "seconds": 8})
	var msg := {"text": "(F5 performance recording) " + line, "time": Time.get_datetime_string_from_system(),
			"map": summary["map"], "perf_log": ProjectSettings.globalize_path(path), "summary": summary}
	var pl := _player()
	if pl:
		msg["player"] = _v(pl.global_position)
	_inbox.append(msg)
	var fi := FileAccess.open(INBOX, FileAccess.READ_WRITE if FileAccess.file_exists(INBOX) else FileAccess.WRITE)
	fi.seek_end()
	fi.store_line(JSON.stringify(msg))
	fi.close()


func _rec_frame(ms: float) -> void:
	var m := _main()
	var P := Performance
	var cam := get_viewport().get_camera_3d()
	var pos := cam.global_position if cam else Vector3.ZERO
	var fwd := -cam.global_transform.basis.z if cam else Vector3.FORWARD
	_rec_rows.append([snappedf((Time.get_ticks_msec() - _rec_start) / 1000.0, 0.001), snappedf(ms, 0.01),
			snappedf(P.get_monitor(P.TIME_PROCESS) * 1000.0, 0.01), snappedf(P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
			int(P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), int(P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME)),
			int(P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			m.civilians_root.get_child_count() if m else 0, m.enemies_root.get_child_count() if m else 0,
			m.traffic_root.get_child_count() if m else 0, snappedf(pos.x, 0.1), snappedf(pos.z, 0.1),
			snappedf(fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0), 1.0), snappedf(get_viewport().scaling_3d_scale, 0.01),
			_autoplay.activity if _autoplay else ""])


## Autoplay (autoplay.gd): the local player plays by itself for `minutes`,
## with the F5 recording on and every frame tagged with what it was doing;
## at the end the run (counts, stuck spots, unreachable pickups, falls, the
## recording's path) goes to user://devagent/autoplay/ and a message to the
## F1 channel says where. tools/bench/autoplay_report.py reads both.
const Autoplay := preload("res://scripts/autoplay.gd")
var _autoplay: Node
var _auto_errors0 := 0
func _m_autoplay(p: Dictionary):
	var pl := _player()
	if pl == null:
		return {"error": "no round"}
	if not bool(p.get("on", true)):
		if _autoplay:
			_autoplay.stop()
		return {"autoplay": false}
	if _autoplay and not _autoplay.done:
		return {"autoplay": "already on", "activity": _autoplay.activity, "t": _autoplay._t}
	_autoplay = Autoplay.new()
	_autoplay.process_mode = Node.PROCESS_MODE_PAUSABLE
	_autoplay.player = pl
	_autoplay.seconds = float(p.get("minutes", 10)) * 60.0
	_autoplay.rng.seed = int(p.get("seed", 7))
	if p.has("drive_every"):            # a driving test: drive_every=5 takes cars almost all the time
		_autoplay.drive_every = float(p["drive_every"])
		_autoplay._drive_cd = minf(_autoplay._drive_cd, _autoplay.drive_every)
	if bool(p.get("god", true)):
		pl.set_meta("god", true)
	if bool(p.get("armed", true)):
		for w in ["pistol", "machinegun"]:
			pl.give(w)
		for g in ["bergamota", "porongo"]:
			pl.grenades[g] = 2          # so it throws some
	_auto_errors0 = _errors_seen()
	_main().add_child(_autoplay)
	if not _rec_on:
		_toggle_rec()
	return {"autoplay": true, "seconds": _autoplay.seconds}


func _errors_seen() -> int:
	var r: Dictionary = _m_errors({})
	return r.get("errors", []).size()


func _autoplay_finish() -> void:
	var ap := _autoplay
	_autoplay = null
	if _rec_on:
		_toggle_rec()                      # writes the recording and its message
	var rec_path := ""
	for i in range(_inbox.size() - 1, -1, -1):
		if _inbox[i].has("perf_log"):
			rec_path = _inbox[i]["perf_log"]
			break
	var errs: Array = _m_errors({}).get("errors", [])
	var out := {"map": _main().map_id if _main() else "", "seconds": snappedf(ap._t, 0.1), "counts": ap.counts,
			"events": ap.events, "recording": rec_path, "script_errors": errs.slice(_auto_errors0).filter(
				# Metal fence timeouts and a tester's own eval errors are not the game's
				func(e): return not "timeout waiting for fence" in str(e) and not "core/math/expression.cpp" in str(e))}
	DirAccess.make_dir_recursive_absolute("user://devagent/autoplay")
	var path := "user://devagent/autoplay/run_%d.json" % Time.get_unix_time_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	var stuck: int = ap.events.filter(func(e): return e["kind"] == "stuck").size()
	var msg := {"text": "(autoplay finished) %.0f s: %d robots, %d pickups, %d drives, %d grenades, %d containers, %d trades, %d stuck, %d unreachable" % [
			ap._t, ap.counts["robots_shot"], ap.counts["pickups"], ap.counts["drives"], ap.counts["grenades"],
			ap.counts["containers"], ap.counts["trades"], stuck,
			ap.events.filter(func(e): return e["kind"] == "unreachable").size()],
			"time": Time.get_datetime_string_from_system(), "map": out["map"],
			"autoplay_log": ProjectSettings.globalize_path(path), "perf_log": rec_path}
	_inbox.append(msg)
	var fi := FileAccess.open(INBOX, FileAccess.READ_WRITE if FileAccess.file_exists(INBOX) else FileAccess.WRITE)
	fi.seek_end()
	fi.store_line(JSON.stringify(msg))
	fi.close()
	ap.queue_free()


func _m_inbox(p: Dictionary):
	## Messages the player wrote with F1 since the last call (cleared unless keep=true).
	var out := _inbox.duplicate()
	if not p.get("keep", false):
		_inbox.clear()
	return {"messages": out}


var _say_layer: CanvasLayer
var _say_box: VBoxContainer


func _m_say(p: Dictionary):
	## A message to the player on screen (top right, stays `seconds`, default 12):
	## the assistant talking to the person playing.
	if _say_layer == null:
		_say_layer = CanvasLayer.new()
		_say_layer.layer = 60
		_say_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_say_layer)
		_say_box = VBoxContainer.new()
		_say_box.anchor_left = 1.0
		_say_box.anchor_right = 1.0
		_say_box.offset_left = -560
		_say_box.offset_right = -20
		_say_box.offset_top = 70
		_say_box.add_theme_constant_override("separation", 8)
		_say_layer.add_child(_say_box)
	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.1, 0.16, 0.92)
	st.border_color = Color(0.85, 0.55, 1.0)
	st.border_width_left = 4
	st.set_content_margin_all(12)
	st.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", st)
	var l := Label.new()
	var t := str(p.get("text", ""))
	l.text = t if t.begins_with("(sent)") else "Claude: " + t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.add_theme_font_size_override("font_size", 20)
	panel.add_child(l)
	_say_box.add_child(panel)
	Sfx.play("pickup", -14.0)
	get_tree().create_timer(float(p.get("seconds", 12.0)), true, false, true).timeout.connect(panel.queue_free)
	return {"shown": true}


func _m_tune(p: Dictionary):
	## Live tuning: tune name=value ... sets res://scripts/tune.gd values in the
	## running game; no arguments lists them. Keep a good value by writing it
	## into tune.gd.
	for k in p:
		if k in Tune.values():
			Tune.set(k, float(p[k]))
		else:
			return _err("unknown tuning value %s (see tune.gd)" % k)
	return Tune.values()


func _find(name: String) -> Node3D:
	var m := _main()
	for n in m._landmark_nodes:
		if is_instance_valid(n) and (String(n.name) == name or String(n.name).begins_with(name)):
			return n
	for root in [m.traffic_root, m.civilians_root, m.enemies_root, m.pickups_root]:
		var n: Node3D = root.get_node_or_null(name)
		if n:
			return n
	return null


func _m_move(p: Dictionary):
	## Move / turn something live: move name=posto_charrua [x z | dx dz] [yaw | dyaw] (degrees),
	## kept on the ground. save=true writes a placed model's new spot into the
	## map's user edits (it stays after a rebuild); otherwise it is a preview.
	var n := _find(str(p["name"]))
	if n == null:
		return _err("nothing called %s (landmark model name, or V12 / C50 / E3 / P8)" % p["name"])
	var at := n.global_position
	if p.has("x"):
		at.x = float(p["x"])
	if p.has("z"):
		at.z = float(p["z"])
	at += Vector3(float(p.get("dx", 0)), 0, float(p.get("dz", 0)))
	if p.has("y"):
		at.y = float(p["y"])
	else:
		var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 30, 0), at - Vector3(0, 30, 0), 1)
		var ex := []
		for b in n.find_children("*", "CollisionObject3D", true, false):
			ex.append((b as CollisionObject3D).get_rid())
		q.exclude = ex
		var hit := _main().get_world_3d().direct_space_state.intersect_ray(q)
		if hit:
			at.y = hit.position.y
	n.global_position = at
	if p.has("yaw"):
		n.rotation.y = deg_to_rad(float(p["yaw"]))
	n.rotation.y += deg_to_rad(float(p.get("dyaw", 0)))
	var out := {"name": String(n.name), "pos": _v(at), "yaw_deg": snappedf(rad_to_deg(n.rotation.y), 0.1), "saved": false}
	if p.get("save", false):
		out["saved"] = _save_move(n)
	return out


func _save_move(n: Node3D) -> bool:
	var l: Dictionary = n.get_meta("landmark", {})
	if l.get("id", "") != "prop":
		return false                  # a building's model stands on its OSM footprint
	var m := _main()
	var path: String = m.MapEditor.new().user_dir(m.map_id).path_join("buildings_user.json")
	var user = JSON.parse_string(FileAccess.get_file_as_string(path))
	var orig: Array = l["pos"]
	var best: Dictionary = {}
	var bd := 3.0
	for e in user.get("_props", []):
		var d := Vector2(e["x"] - orig[0], e["z"] - orig[2]).length()
		if e["model"] == l["model"] and d < bd:
			bd = d
			best = e
	if best.is_empty():
		return false
	best["x"] = snappedf(n.global_position.x, 0.01)
	best["z"] = snappedf(n.global_position.z, 0.01)
	best["yaw"] = snappedf(rad_to_deg(n.rotation.y), 0.1)
	l["pos"] = [n.global_position.x, n.global_position.y, n.global_position.z]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(user, " "))
	f.close()
	return true


func _m_reload(p: Dictionary):
	## Hot reload without restarting: re-read the given resource files from disk
	## (after re-importing them: `godot --headless --path godot --import`), then
	## rebuild the map's props, stalls, landmarks and vendors.
	var paths: Array = p.get("paths", [])
	for path in paths:
		if ResourceLoader.exists(path):
			# a fresh copy, sub-resources and all, put in the cache's place:
			# REPLACE(_DEEP) matched a re-exported model's materials by their old
			# ids (the logo texture on the posto's fascia, lamps on the pumps)
			var fresh := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
			if fresh:
				fresh.take_over_path(path)
	var r: Dictionary = await _main().reload_objects()
	r["reloaded"] = paths.size()
	return r


func _m_civilians(_p: Dictionary):
	## Every pedestrian: position, AI state, kind and pending crossing waypoints.
	var out := []
	for c in _main().civilians_root.get_children():
		out.append({"name": String(c.name), "pos": _v(c.global_position), "state": c.state,
				"dog": c.dog, "police": c.police, "route": c._route.size(), "health": c.health})
	return {"civilians": out}


func _m_selection(_p: Dictionary):
	## What the player clicked in design mode (the last pick, and all of them).
	var s: Dictionary = _main().design_selection
	if s.is_empty():
		return {"selected": false}
	var b: Dictionary = _main().map_editor._sel if _main().map_editor and s["what"] == "building" else {}
	return {"selected": true, "what": s["what"], "name": s["name"], "detail": s["detail"], "osm": b.get("id", ""),
			"pos": _v(s["pos"]), "normal": _v(s["normal"]), "map": _main().map_id,
			"all": _main().design_selections.map(func(e): return _sel_ref(e))}


## One design-mode selection as a reference for Claude.
func _sel_ref(e: Dictionary) -> Dictionary:
	var r := {"what": e["what"], "name": e["name"], "detail": e["detail"], "pos": _v(e["pos"])}
	var n = e.get("node")
	if n is Node3D and is_instance_valid(n) and n.has_meta("landmark"):
		r["model"] = String(n.get_meta("landmark").get("model", ""))
		if n.get_meta("landmark").has("label"):
			r["label"] = n.get_meta("landmark")["label"]
	return r


func _m_aim(_p: Dictionary):
	## What the crosshair is on: the first world hit straight ahead of the camera.
	var cam := _player().camera as Camera3D
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * 250.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 64)
	q.exclude = [_player().get_rid()]
	var hit: Dictionary = _main().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"hit": false, "map": _main().map_id}
	return {"hit": true, "map": _main().map_id, "pos": _v(hit.position), "normal": _v(hit.normal),
			"distance": snapped(from.distance_to(hit.position), 0.01),
			"collider": str(hit.collider.get_parent().name if hit.collider.get_parent() else hit.collider.name)}


func _m_mark(p: Dictionary):
	## Outline a wall (from/to = [x, z], base/top = y) with a glowing frame
	## until the next mark; clear=true just removes it.
	var old := _main().get_node_or_null("DevMark")
	if old:
		old.free()
	if p.get("clear", false):
		return {"marked": false}
	var a := Vector3(p["from"][0], 0, p["from"][1])
	var b := Vector3(p["to"][0], 0, p["to"][1])
	var base: float = p["base"]
	var top: float = p["top"]
	var root := Node3D.new()
	root.name = "DevMark"
	_main().add_child(root)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.1)
	mat.no_depth_test = true
	var fill := mat.duplicate() as StandardMaterial3D
	fill.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill.albedo_color = Color(1.0, 0.85, 0.1, 0.18)
	var along := b - a
	var out := Vector3(along.z, 0, -along.x).normalized() * 0.08    # street side of the wall
	var corners := [a + Vector3(0, base, 0), b + Vector3(0, base, 0), b + Vector3(0, top, 0), a + Vector3(0, top, 0)]
	for i in 4:
		var c0: Vector3 = corners[i] + out
		var c1: Vector3 = corners[(i + 1) % 4] + out
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.15, 0.15, c0.distance_to(c1))
		bar.mesh = bm
		bar.material_override = mat
		root.add_child(bar)
		bar.global_position = (c0 + c1) / 2
		bar.look_at(c1, Vector3.UP if abs((c1 - c0).normalized().y) < 0.99 else Vector3.RIGHT)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(along.length(), top - base)
	quad.mesh = qm
	quad.material_override = fill
	fill.cull_mode = BaseMaterial3D.CULL_DISABLED
	root.add_child(quad)
	quad.global_position = (a + b) / 2 + Vector3(0, (base + top) / 2, 0) + out
	quad.look_at(quad.global_position + out, Vector3.UP)
	return {"marked": true}


func _m_scan_gaps(p: Dictionary):
	## Find see-through slits in building blocks. A sample point at eye height
	## is a slit if it is open to the sky but walls on two opposite sides are
	## closer than `max_width` metres. Returns clusters (centre, count, width).
	var space: PhysicsDirectSpaceState3D = _main().get_world_3d().direct_space_state
	var cx: float = p.get("x", 0.0)
	var cz: float = p.get("z", 0.0)
	var r: float = p.get("radius", 150.0)
	var step: float = p.get("step", 0.5)
	var max_w: float = p.get("max_width", 2.5)
	var y: float = p.get("y", 1.5)
	var dirs := [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0.7071, 0, 0.7071), Vector3(0.7071, 0, -0.7071)]
	var found := []
	var checked := 0
	var x := cx - r
	while x <= cx + r:
		var z := cz - r
		while z <= cz + r:
			var o := Vector3(x, y, z)
			checked += 1
			# must be outdoors (sky above, ground below)
			var up := PhysicsRayQueryParameters3D.create(o, o + Vector3(0, 200, 0), 1)
			# a probe that starts on a wall plane slides along it: nudge sideways too
			var up2 := PhysicsRayQueryParameters3D.create(o + Vector3(0.03, 0, 0.03), o + Vector3(0.03, 200, 0.03), 1)
			if space.intersect_ray(up).is_empty() and space.intersect_ray(up2).is_empty():
				for d in dirs:
					var ha: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(o, o + d * max_w, 1))
					if ha.is_empty() or ha.position.distance_to(o) < 0.05:
						continue    # no wall, or the sample sits on a wall plane (false positive)
					var hb: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(o, o - d * max_w, 1))
					if hb.is_empty() or hb.position.distance_to(o) < 0.05:
						continue
					var w: float = ha.position.distance_to(hb.position)
					if w < max_w:
						found.append([x, z, w])
						break
			z += step
		x += step
		if int(x / step) % 40 == 0:
			await get_tree().process_frame
	# cluster neighbouring samples
	var clusters := []
	for f in found:
		var placed := false
		for c in clusters:
			if Vector2(c["x"], c["z"]).distance_to(Vector2(f[0], f[1])) < 4.0:
				c["n"] += 1
				c["min_width"] = min(c["min_width"], f[2])
				placed = true
				break
		if not placed:
			clusters.append({"x": f[0], "z": f[1], "n": 1, "min_width": f[2]})
	clusters.sort_custom(func(a, b): return a["n"] > b["n"])
	for c in clusters:
		c["min_width"] = snappedf(c["min_width"], 0.01)
	return {"checked": checked, "slit_samples": found.size(), "clusters": clusters.slice(0, int(p.get("limit", 50)))}


func _m_spawn_enemy(p: Dictionary):
	var m := _main()
	m.enemy_spawner.spawn({"id": m._next_enemy_id(), "pos": Vector3(p["x"], p.get("y", 0.5), p["z"]),
			"variant": p.get("variant", "trooper"),
			"n": int(p.get("n", randi_range(m.Difficulty.get_value("swarm_n")[0], m.Difficulty.get_value("swarm_n")[1])))})
	return {"enemies": m.enemies_root.get_child_count()}


func _m_kill_enemies(_p: Dictionary):
	var n := 0
	for e in _main().enemies_root.get_children():
		e.queue_free()
		n += 1
	return {"killed": n}


func _m_set_director(p: Dictionary):
	var d = _main().director
	if p.has("enabled"):
		d.set_process(bool(p["enabled"]))
	if p.has("phase"):
		d._set_phase(d.Phase[p["phase"]])
	return _m_get_state({})["director"]


func _m_set_god(p: Dictionary):
	var pl := _player()
	pl.set_meta("god", bool(p.get("enabled", true)))
	pl.health = 100
	return {"god": pl.get_meta("god")}


func _m_set_sun(p: Dictionary):
	var sun: DirectionalLight3D = _main().get_node("Sun")
	sun.rotation_degrees = Vector3(-float(p.get("elevation", 58)), float(p.get("azimuth", 160)), 0)
	if p.has("energy"):
		sun.light_energy = p["energy"]
	return {"rotation": _v(sun.rotation_degrees)}


func _m_eval(p: Dictionary):
	## Evaluate a GDScript expression with `main`, `player`, `tree`, `nav`
	## (NavigationServer3D) and `map` (the navigation map RID) bound.
	var e := Expression.new()
	var err := e.parse(p["expr"], ["main", "player", "tree", "nav", "map"])
	if err != OK:
		return _err(e.get_error_text())
	var r = e.execute([_main(), _player(), get_tree(), NavigationServer3D,
			_main().get_world_3d().navigation_map], self)
	if e.has_execute_failed():
		return _err(e.get_error_text())
	return {"value": var_to_str(r)}


func _m_quit(_p: Dictionary):
	get_tree().quit.call_deferred()
	return {"quitting": true}
