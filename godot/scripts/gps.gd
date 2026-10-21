extends Control
## In-car GPS (local player, while driving): the streets around, turning
## with the vehicle (heading up), the car in the middle, robots as red dots,
## the phase exit in green, people containers in purple (red when full; with
## the repair shop's GPS upgrade) - and the name of the street you are on.

var SIZE := 260.0
var RANGE_M := 180.0            # metres from the centre to the panel's edge
var vehicle: Node3D
var _roads: Array = []          # [PackedVector2Array of street points (x, z)]
var _streets: Array = []        # [[name, PackedVector2Array]]
var _name := ""
var _name_cd := 0.0
var _font: Font
## The tablet's GPS app: a rectangular map of this size (0: the round in-car
## one), the markers drawn with the tablet's map pictograms when given
## ("robo", "coletor", "torre", "saida", "voce", "enxame").
var panel := Vector2.ZERO
var icons := {}
const ROAD_TABLET := Color(0.93, 0.89, 0.79, 0.55)


## On foot a smaller map of the nearer streets; driving, the bigger one.
func set_driving(on: bool) -> void:
	SIZE = 260.0 if on else 170.0
	RANGE_M = 180.0 if on else 90.0
	custom_minimum_size = Vector2(SIZE, SIZE + 34)
	size = custom_minimum_size


func _ready() -> void:
	set_driving(false)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	var main := get_tree().current_scene
	for e in main.road_graph.get("edges", []):
		var line := PackedVector2Array()
		for p in e.get("pts", []):
			line.append(Vector2(p[0], p[1]))
		_roads.append(line)
	for s in main.road_graph.get("streets", []):
		var line := PackedVector2Array()
		for p in s[1]:
			line.append(Vector2(p[0], p[1]))
		_streets.append([s[0], line])


func _process(delta: float) -> void:
	if not is_instance_valid(vehicle):
		return
	_name_cd -= delta
	if _name_cd <= 0:
		_name_cd = 0.4
		_name = _street_at(Vector2(vehicle.global_position.x, vehicle.global_position.z))
	queue_redraw()


## The named street nearest to `at` (within 18 m), "" off the streets.
func _street_at(at: Vector2) -> String:
	var best := 18.0
	var name := ""
	for s in _streets:
		var line: PackedVector2Array = s[1]
		for i in line.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(at, line[i], line[i + 1])
			var d := q.distance_to(at)
			if d < best:
				best = d
				name = s[0]
	return name


func _draw() -> void:
	if not is_instance_valid(vehicle):
		return
	var c := Vector2(SIZE, SIZE) / 2.0 if panel == Vector2.ZERO else panel / 2.0
	var k := (SIZE / 2.0) / RANGE_M if panel == Vector2.ZERO else (panel.y / 2.0) / RANGE_M
	# off the map: pinned to its rim (a circle in the car, the frame on the tablet)
	var pin := func(q: Vector2) -> Vector2:
		if panel == Vector2.ZERO:
			return c + (q - c).limit_length(SIZE / 2.0 - 8.0)
		return q.clamp(Vector2(16, 16), panel - Vector2(16, 16))
	var here := Vector2(vehicle.global_position.x, vehicle.global_position.z)
	var yaw: float = vehicle.get_global_transform_interpolated().basis.get_euler().y
	var rot := Transform2D(yaw, Vector2.ZERO)        # world (x, z) -> heading up
	var to_panel := func(p: Vector2) -> Vector2: return c + (rot * (p - here)) * k
	if panel == Vector2.ZERO:
		draw_circle(c, SIZE / 2.0, Color(0.05, 0.07, 0.09, 0.78))
	else:
		draw_rect(Rect2(Vector2.ZERO, panel), Color(0.09, 0.17, 0.13))
	for line in _roads:
		var pts := PackedVector2Array()
		var near := false
		for p in line:
			pts.append(to_panel.call(p))
			near = near or p.distance_to(here) < RANGE_M * 1.6
		if near and pts.size() >= 2:
			draw_polyline(pts, Color(0.75, 0.8, 0.85, 0.85) if panel == Vector2.ZERO else ROAD_TABLET,
					3.0 if panel == Vector2.ZERO else 5.0, true)
	var main := get_tree().current_scene
	# the map's places (pharmacies, markets, fuel...) and the repair shops
	# (placed by hand too) by their pictograms; smaller on the round one
	var reach := RANGE_M * (1.0 if panel == Vector2.ZERO else panel.x / panel.y)
	var pic := 26.0 if panel != Vector2.ZERO else 18.0
	for pl in main.get("places") if main.get("places") != null else []:
		if pl["kind"] == "repair_shop":
			continue                  # drawn from the counters below: only those trade
		var icon: String = main.place_kinds.get(pl["kind"], {}).get("icon", "")
		var pp := Vector2(pl["at"][0], pl["at"][1])
		if icon != "" and pp.distance_to(here) < reach:
			_place(icon, to_panel.call(pp), pic, PLACE_TINT)
	for at in main.repair_shops() if main.has_method("repair_shops") else []:
		var sp := Vector2(at.x, at.z)
		if sp.distance_to(here) < reach and not _place("assistencia_tecnica", to_panel.call(sp), pic, SHOP_TINT):
			draw_rect(Rect2(to_panel.call(sp) - Vector2(5, 5), Vector2(10, 10)), Color(0.3, 0.85, 1.0))
	for e in main.enemies_root.get_children():
		var p := Vector2((e as Node3D).global_position.x, (e as Node3D).global_position.z)
		if e.get("variant") == "swarm" and e.positions.size() > 0:
			p = Vector2(e.positions[0].x, e.positions[0].z)
		var carrying: bool = is_instance_valid(e.get("_captive"))
		if carrying:
			# a Coletor with a civilian: always shown, pinned to the rim when far
			var cp: Vector2 = pin.call(to_panel.call(p))
			if not _icon("coletor", cp):
				draw_circle(cp, 6.0, Color(1.0, 0.6, 0.1))
		elif p.distance_to(here) < RANGE_M * (1.0 if panel == Vector2.ZERO else panel.x / panel.y) \
				and e.has_method("is_alive") and e.is_alive():
			var rp: Vector2 = to_panel.call(p)
			if not _icon("enxame" if e.get("variant") == "swarm" else "robo", rp, 22.0):
				draw_circle(rp, 3.5, Color(1.0, 0.2, 0.15))
	for a in get_tree().get_nodes_in_group("relay"):
		if a.spotted and a.is_alive():
			var ap: Vector2 = pin.call(to_panel.call(Vector2(a.global_position.x, a.global_position.z)))
			if _icon("torre", ap):
				continue
			draw_colored_polygon(PackedVector2Array([ap + Vector2(0, -8), ap + Vector2(7, 6), ap + Vector2(-7, 6)]),
					Color(1.0, 0.55, 0.1))
	# the route (tablet > GPS > Enter): the way there, then its end
	var me_p: Node3D = main._local_player() if main.has_method("_local_player") else null
	var route: PackedVector3Array = me_p.route_path if me_p else PackedVector3Array()
	if route.size() >= 2:
		var line := PackedVector2Array()
		for p3 in route:
			line.append(to_panel.call(Vector2(p3.x, p3.z)))
		draw_polyline(line, Color(1.0, 0.85, 0.15), 4.0 if panel != Vector2.ZERO else 3.0, true)
		var end: Vector2 = pin.call(line[line.size() - 1])
		draw_circle(end, 7.0, Color(1.0, 0.85, 0.15))
		draw_circle(end, 3.0, Color(0.1, 0.1, 0.1))
	# people containers - only with the GPS upgrade from a repair shop -
	# pinned to the rim when far, with how full
	var me: Node3D = main._local_player() if main.has_method("_local_player") else null
	for pc in get_tree().get_nodes_in_group("people_containers") if me and me.get("gps_containers") else []:
		if pc.lifting and pc.people.is_empty():
			continue                  # still on its way under the mothership
		var cp: Vector2 = pin.call(to_panel.call(Vector2(pc.global_position.x, pc.global_position.z)))
		if not _icon("container", cp):
			var col := Color(1.0, 0.3, 0.25) if pc.full() else Color(0.85, 0.45, 1.0)
			draw_rect(Rect2(cp - Vector2(8, 8), Vector2(16, 16)), col)
			draw_rect(Rect2(cp - Vector2(8, 8), Vector2(16, 16)), Color(0, 0, 0, 0.7), false, 2.0)
		if panel != Vector2.ZERO and pc.people.size() > 0:
			draw_string(_font, cp + Vector2(12, 6), "%d/%d" % [pc.people.size(), pc.capacity],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.85, 0.45, 1.0))
	if main.get("_exit") and is_instance_valid(main._exit):
		var ex := Vector2(main._exit.global_position.x, main._exit.global_position.z)
		var ep: Vector2 = pin.call(to_panel.call(ex))
		if not _icon("saida", ep):
			draw_circle(ep, 6.0, Color(0.2, 1.0, 0.35))
	# the car: an arrow pointing up
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -11), c + Vector2(8, 9), c + Vector2(0, 4), c + Vector2(-8, 9)]),
			Color(1.0, 0.85, 0.15) if panel == Vector2.ZERO else Color(0.94, 0.6, 0.32))
	if panel != Vector2.ZERO:
		if _name != "":
			var tw := _font.get_string_size(_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
			draw_rect(Rect2(12, panel.y - 44, tw + 24, 32), Color(0.08, 0.16, 0.12, 0.92))
			draw_string(_font, Vector2(24, panel.y - 21), _name, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.93, 0.89, 0.79))
		return
	draw_arc(c, SIZE / 2.0 - 1.0, 0, TAU, 64, Color(1, 1, 1, 0.35), 2.0)
	if _name != "":
		var w := _font.get_string_size(_name, HORIZONTAL_ALIGNMENT_CENTER, -1, 20).x
		draw_rect(Rect2(c.x - w / 2 - 10, SIZE + 4, w + 20, 28), Color(0.05, 0.07, 0.09, 0.85))
		draw_string(_font, Vector2(c.x - w / 2, SIZE + 25), _name, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1))


## The map pictograms (gadgets/tablet/ui/map/): robots, Coletor, antenna,
## exit, swarm, people container, repair shop, and every place kind's icon.
const MAP_UI := "res://assets/rio_grande_do_sul/gadgets/tablet/ui/map/"
func load_icons(place_kinds: Dictionary) -> void:
	var pics := {"robo": "robo", "coletor": "coletor", "torre": "torre_comunicacao", "saida": "saida_fase",
			"enxame": "enxame", "container": "container_pessoas", "assistencia_tecnica": "assistencia_tecnica"}
	for k in place_kinds.values():
		if k is Dictionary and k.has("icon"):
			pics[k["icon"]] = k["icon"]             # places: farmacia, mercado, posto_gasolina...
	for id in pics:
		if ResourceLoader.exists(MAP_UI + "%s.png" % pics[id]):
			icons[id] = load(MAP_UI + "%s.png" % pics[id])


## A tablet map pictogram centred on `at`; false when there is none.
func _icon(id: String, at: Vector2, size := 30.0, tint := Color.WHITE) -> bool:
	var t: Texture2D = icons.get(id)
	if t == null:
		return false
	draw_texture_rect(t, Rect2(at - Vector2(size, size) / 2.0, Vector2(size, size)), false, tint)
	return true


## A place's pictogram on a dark disc with a coloured rim, so shops read
## apart from the robots.
const PLACE_TINT := Color(0.55, 0.9, 1.0)
const SHOP_TINT := Color(1.0, 0.7, 0.3)
func _place(id: String, at: Vector2, size: float, tint: Color) -> bool:
	if not icons.has(id):
		return false
	draw_circle(at, size * 0.62, Color(0.04, 0.08, 0.07, 0.9))
	draw_arc(at, size * 0.62, 0, TAU, 24, tint, 2.0, true)
	return _icon(id, at, size * 0.85, tint)
