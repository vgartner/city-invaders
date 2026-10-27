extends Node3D
## Street furniture from <city>.props.json (OSM nodes + generated lamps),
## built from simple procedural meshes. Poles and trunks get collision.
##
## Lamps, traffic signals and bins are destructible. They are built in the
## same order on every peer, so their index identifies them across the
## network; the server applies damage and broadcasts break_prop().

const HITS := {"lamp": 40, "traffic_signals": 40, "waste_basket": 20}   # health per kind
const PH := "res://assets/common/props/%s/%s.gltf"     # Poly Haven models (CC0)
## kind -> [model ids (one picked at random), solid?, visible up to metres]
const MODELS := {
	"lamp": [["street_lamp_01"], true, 90.0],
	"waste_basket": [["metal_trash_can", "res://assets/rio_grande_do_sul/street_furniture/lixeira_poste.glb"], true, 60.0],
	# Porto Alegre street furniture, at OSM's points (ids that are paths are used as they are)
	"bike_rack": [["res://assets/rio_grande_do_sul/street_furniture/bicicletario_cinco_bicicletas.glb"], true, 80.0],
	"orelhao": [["res://assets/rio_grande_do_sul/street_furniture/orelhao.glb"], true, 70.0],
	"clock": [["res://assets/rio_grande_do_sul/street_furniture/relogio_coluna.glb"], true, 90.0],
	"fountain": [["res://assets/rio_grande_do_sul/street_furniture/chafariz_imperial.glb"], true, 120.0],
	"container": [["res://assets/rio_grande_do_sul/street_furniture/conteiner_1000l_laranja.glb"], true, 70.0],
	"hydrant": [["fire_hydrant"], true, 45.0],
	"trashbag": [["trashbag"], false, 40.0],
	"car": [["covered_car"], true, 160.0],
	"manhole": [["water_manhole_cover"], false, 45.0],
	"barrier": [["concrete_road_barrier", "concrete_road_barrier_02"], true, 120.0],
	# modular_street_seating is an unassembled kit (parts laid flat): not used
	"bench": [["painted_wooden_bench"], true, 70.0],
	"planter": [["planter_box_01", "planter_box_02"], true, 60.0],
	"potted_plant": [["potted_plant_04"], true, 50.0],
	"crate": [["wooden_crate_01"], true, 60.0],
	"plastic_crate": [["plastic_crate_01"], true, 50.0],
	"barrel": [["Barrel_01"], true, 60.0],
	"shrub": [["shrub_sorrel_01"], false, 60.0],
	"shrub2": [["shrub_03"], false, 60.0],
	"fern": [["fern_02"], false, 45.0],
	"weed": [["weed_plant_02"], false, 35.0],
}
var _scene_cache := {}
var _covered_only := false
var _covered_n := 0             # cars under a tarp: a handful a map, not a car park of them
## kerbside parking spots ([position, yaw]) left for drivable parked cars
var parked_spots := []
## Poly Haven files that hold two variants side by side (offset on X):
## keep one at random and centre it.
const VARIANTS := {"hydrant": 0.3, "waste_basket": 0.5}

var _mats := {}
var destructibles := []     # [{root, body, kind, health, broken, light_mats}]
var crushables := []        # solid model props a vehicle can knock over: [{root, body, kind, start, down}]
## what a vehicle needs to knock a prop over: [mass (car = 1.3), speed m/s];
## twice as heavy halves the speed needed. Kinds not listed stop a vehicle.
const CRUSH := {"waste_basket": [0.25, 2.0], "crate": [0.25, 2.0], "plastic_crate": [0.25, 1.5],
		"potted_plant": [0.25, 2.0], "bench": [1.0, 3.0], "barrel": [1.0, 3.0], "planter": [1.0, 4.0],
		"hydrant": [1.0, 5.0], "lamp": [1.0, 7.0], "traffic_signals": [1.0, 7.0], "barrier": [10.0, 3.0],
		"container": [1.0, 3.0], "bike_rack": [1.0, 4.0], "orelhao": [1.0, 5.0]}


func build(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var props: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	_covered_n = 0
	for p in props:
		var pos := Vector3(p["pos"][0], p["pos"][1], p["pos"][2])
		var yaw: float = p.get("yaw", 0.0)
		match p["type"]:
			"tree": _tree(pos)
			"lamp": _lamp(pos)
			"bus_stop": _bus_stop(pos, yaw)
			"waste_basket": _bin(pos)
			"traffic_signals": _signal(pos)
			"repair_shop": _repair_shop(pos, yaw)
			"street_sign": _street_sign(pos, p.get("plates", []))
			"stall": _static_model("res://assets/rio_grande_do_sul/stalls/prop_%s.glb" % p.get("stall", "popcorn_cart"), pos, yaw)
			"tram": _static_model("res://assets/rio_grande_do_sul/tram/historic_open_tram_centro.glb", pos, yaw)
			_:
				if p["type"] == "car":
					# a few under a tarp stay as street furniture; the other
					# spots are for parked cars you can drive (main.gd)
					# walled in (no way out over the asphalt to a street): a car under a tarp
					if p.get("no_way_out", false) or (randf() < 0.05 and _covered_n < 5):
						_covered_n += 1
						_covered_only = true
						var r := _model_prop("car", pos, yaw)
						_covered_only = false
						if r:
							_parked.append(r)
					else:
						# [where, yaw, way out to a street (car parks), the street it joins]
						parked_spots.append([pos, yaw, p.get("out", []), int(p.get("edge", -1))])
				elif MODELS.has(p["type"]):
					_model_prop(p["type"], pos, yaw)
	_batch.build(self)
	_settle_parked.call_deferred()
	_settle_long.call_deferred()


## Parked cars come with the smoothed terrain height, but on slopes the
## street surface (flat triangles between its vertices) runs above it and
## they sank in: once the city's collision is in the physics space, drop
## each onto the asphalt under its axles and tilt it to the slope.
var _parked: Array = []
func _settle_parked() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	for r in _parked:
		var root := r as Node3D
		if not is_instance_valid(root):
			continue
		var fwd := Vector3(-sin(root.rotation.y), 0, -cos(root.rotation.y))
		var ys := []
		for k in [-1.3, 1.3]:
			var p: Vector3 = root.global_position + fwd * float(k)
			var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2.0, 0), p - Vector3(0, 2.0, 0), 1)
			q.exclude = _parked_bodies(root)
			var hit := space.intersect_ray(q)
			if hit:
				ys.append(hit.position.y)
		if ys.size() == 2:
			root.global_position.y = (ys[0] + ys[1]) / 2.0
			root.rotation.x = clamp(atan2(ys[1] - ys[0], 2.6), -0.2, 0.2)   # nose up when the street climbs ahead
			# and bank with a sideways slope
			var right := Vector3(cos(root.rotation.y), 0, -sin(root.rotation.y))
			var side := []
			for k in [-0.8, 0.8]:
				var p2: Vector3 = root.global_position + right * float(k)
				var q2 := PhysicsRayQueryParameters3D.create(p2 + Vector3(0, 2.0, 0), p2 - Vector3(0, 2.0, 0), 1)
				q2.exclude = _parked_bodies(root)
				var h2 := space.intersect_ray(q2)
				if h2:
					side.append(h2.position.y)
			if side.size() == 2:
				root.rotation.z = clamp(atan2(side[1] - side[0], 1.6), -0.2, 0.2)
	_parked.clear()


func _parked_bodies(root: Node3D) -> Array:
	var out := []
	for b in root.find_children("*", "StaticBody3D", true, false):
		out.append((b as StaticBody3D).get_rid())
	return out


func _mat(c: Color, emit := false) -> StandardMaterial3D:
	var key := c.to_html() + str(emit)
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.8
		if emit:
			m.emission_enabled = true
			m.emission = c
			m.emission_energy_multiplier = 2.0
		_mats[key] = m
	return _mats[key]


func _cyl(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	return m


func _part(pos: Vector3, mesh: Mesh, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	mi.visibility_range_end = 150.0        # small street pieces fade out with distance
	return mi


func _pole_collider(pos: Vector3, r: float, h: float, parent: Node3D = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = r
	shape.height = h
	cs.shape = shape
	body.position = pos + Vector3(0, h / 2, 0)
	body.add_child(cs)
	(parent if parent else self).add_child(body)
	return body


## Root for a destructible prop; the topple direction is derived from the
## index so every peer animates the same fall.
func _destructible(pos: Vector3, kind: String) -> Dictionary:
	var root := Node3D.new()
	root.set_meta("kind", kind)          # the editor's name for it
	root.position = pos
	root.rotation.y = fmod(destructibles.size() * 2.399, TAU)
	add_child(root)
	var d := {"root": root, "body": null, "kind": kind, "health": HITS[kind], "broken": false, "lights": []}
	destructibles.append(d)
	return d


func _register_body(d: Dictionary, body: StaticBody3D) -> void:
	d["body"] = body
	body.set_meta("prop_index", destructibles.size() - 1)


var _leaf_mat: StandardMaterial3D
var _bark_mat: StandardMaterial3D
var _falling_leaf: QuadMesh
## tree crowns: an area on their own layer that only shots look for (it blocks
## nothing); a shot through it or into the trunk shakes leaves loose
const FOLIAGE_LAYER := 128
var crowns := []                 # [batch id, crown centre]


func _tree_mats() -> void:
	if _leaf_mat:
		return
	_leaf_mat = StandardMaterial3D.new()
	_leaf_mat.albedo_texture = load("res://city/leaves.png")
	_leaf_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_leaf_mat.alpha_scissor_threshold = 0.4
	_leaf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_leaf_mat.roughness = 0.9
	_leaf_mat.backlight_enabled = true
	_leaf_mat.backlight = Color(0.25, 0.35, 0.1)
	_bark_mat = StandardMaterial3D.new()
	_bark_mat.albedo_texture = load("res://city/bark.png")
	_bark_mat.uv1_scale = Vector3(2, 3, 1)
	_bark_mat.roughness = 1.0


## Foliage-card tree: textured trunk plus crossed alpha-cut leaf planes at a
## few heights. TREE_TEMPLATES shapes are built once; each street tree is one
## of them, turned and scaled, drawn in batches (one draw call per template
## and map cell instead of 13 per tree).
const TREE_TEMPLATES := 8
var _tree_meshes: Array = []      # [[ArrayMesh, trunk height, crown radius], ...]
var _batch := preload("res://scripts/batcher.gd").new()


func _tree_template() -> Array:
	var h := randf_range(5.5, 8.5)
	var trunk_h := h * 0.55
	var crown_r := randf_range(2.2, 3.2)
	var bark := SurfaceTool.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.1
	trunk.bottom_radius = 0.16
	trunk.height = trunk_h
	trunk.radial_segments = 8
	trunk.rings = 1
	bark.append_from(trunk, 0, Transform3D(Basis(), Vector3(0, trunk_h / 2, 0)))
	var leaves := SurfaceTool.new()
	for layer in 3:
		var y := trunk_h + layer * crown_r * 0.45
		var size := crown_r * 2.0 * (1.0 - layer * 0.18)
		for k in 3:
			var q := QuadMesh.new()
			q.size = Vector2(size, size * 0.85)
			var b := Basis.from_euler(Vector3(randf_range(-0.15, 0.15), k * PI / 3 + layer * 0.5, 0))
			leaves.append_from(q, 0, Transform3D(b, Vector3(randf_range(-0.3, 0.3), y, randf_range(-0.3, 0.3))))
		var tq := QuadMesh.new()
		tq.size = Vector2(size * 0.9, size * 0.9)
		leaves.append_from(tq, 0, Transform3D(Basis.from_euler(Vector3(-PI / 2, randf() * TAU, 0)), Vector3(0, y + size * 0.15, 0)))
	var mesh: ArrayMesh = bark.commit()
	mesh.surface_set_material(0, _bark_mat)
	leaves.commit(mesh)
	mesh.surface_set_material(1, _leaf_mat)
	return [mesh, trunk_h, crown_r]


func _tree(pos: Vector3) -> void:
	_tree_mats()
	if _tree_meshes.is_empty():
		for t in TREE_TEMPLATES:
			_tree_meshes.append(_tree_template())
	var tpl: Array = _tree_meshes[randi() % TREE_TEMPLATES]
	var s := randf_range(0.85, 1.15)
	var trunk_h: float = tpl[1] * s
	var crown_r: float = tpl[2] * s
	var id := crowns.size()
	_batch.add(tpl[0], Transform3D(Basis(Vector3.UP, randf() * TAU).scaled(Vector3.ONE * s), pos), null, 0.0,
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "tree%d" % id)
	var trunk_body := _pole_collider(pos, 0.25, trunk_h)
	var centre := pos + Vector3(0, trunk_h + crown_r * 0.5, 0)
	trunk_body.set_meta("tree_crown", centre)
	var area := Area3D.new()
	area.collision_layer = FOLIAGE_LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	var acs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = crown_r
	acs.shape = sph
	area.add_child(acs)
	area.position = centre
	area.set_meta("tree_crown", centre)
	add_child(area)
	crowns.append(["tree%d" % id, centre])


## Every peer: leaves shaken loose at `at` (a shot through a crown); the
## nearest crown gives a little shudder.
func leaves(at: Vector3, count := 22) -> void:
	_tree_mats()
	if _falling_leaf == null:
		# a single drawn leaf: pointed oval with a midrib
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		for y in 32:
			for x in 32:
				var u := (x - 15.5) / 15.5
				var v := (y - 15.5) / 15.5
				var w := 0.55 * (1.0 - v * v)            # narrows to a point at both ends
				if abs(u) < w:
					var shade: float = 0.85 + 0.15 * (1.0 - abs(u) / max(w, 0.01))
					var rib := 0.8 if abs(u) < 0.06 else 1.0
					img.set_pixel(x, y, Color(0.55 * shade * rib, 0.68 * shade * rib, 0.2 * shade, 1.0))
		var m := StandardMaterial3D.new()
		m.albedo_texture = ImageTexture.create_from_image(img)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.9
		_falling_leaf = QuadMesh.new()
		_falling_leaf.size = Vector2(0.2, 0.25)
		_falling_leaf.material = m
	var parts := CPUParticles3D.new()
	parts.mesh = _falling_leaf
	parts.amount = count
	parts.one_shot = true
	parts.explosiveness = 0.7
	parts.lifetime = 4.0
	parts.direction = Vector3.DOWN
	parts.spread = 120.0
	parts.initial_velocity_min = 0.4
	parts.initial_velocity_max = 1.6
	parts.gravity = Vector3(0, -1.3, 0)
	parts.damping_min = 0.6
	parts.damping_max = 1.2
	parts.angle_min = -180.0
	parts.angle_max = 180.0
	parts.angular_velocity_min = -220.0
	parts.angular_velocity_max = 220.0
	parts.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	parts.emission_sphere_radius = 0.6
	parts.scale_amount_min = 0.7
	parts.scale_amount_max = 1.3
	parts.color = Color(1, 1, 1)
	parts.hue_variation_min = -0.08
	parts.hue_variation_max = 0.06
	parts.position = at
	add_child(parts)
	parts.emitting = true
	get_tree().create_timer(4.5).timeout.connect(parts.queue_free)
	var best: Array = []
	var bd := 5.0
	for c in crowns:
		var d: float = (c[1] as Vector3).distance_to(at)
		if d < bd:
			bd = d
			best = c
	if not best.is_empty():
		# the batched tree instance gives a little shudder
		for r in _batch.ref(best[0]):
			var mm: MultiMesh = r[0]
			var i: int = r[1]
			var base: Transform3D = r[2]
			var tilt := Vector3(randf_range(-0.03, 0.03), 0, randf_range(-0.03, 0.03))
			var tw := create_tween()
			var sway := func(t: float): mm.set_instance_transform(i, Transform3D(Basis.from_euler(tilt * t) * base.basis, base.origin))
			tw.tween_method(sway, 0.0, 1.0, 0.08)
			tw.tween_method(sway, 1.0, 0.0, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _lamp(pos: Vector3) -> void:
	var d := _destructible(pos, "lamp")
	var r: Node3D = d["root"]
	# cheap pole for far away, the scanned lamp model up close
	var pole := _part(Vector3(0, 3.0, 0), _cyl(0.07, 6.0), _mat(Color(0.25, 0.27, 0.3)), r)
	var model := _instance("lamp", r)
	if model:
		model.scale = Vector3.ONE * 1.5        # scanned post is 3.9 m; city lamps are ~6 m
		pole.visibility_range_begin = MODELS["lamp"][2]
		pole.visibility_range_end = 200.0       # a thin pole is not worth drawing further off
		pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		var head := BoxMesh.new()
		head.size = Vector3(0.6, 0.15, 0.25)
		var lamp_mat := _mat(Color(1.0, 0.95, 0.8), true).duplicate()
		_part(Vector3(0, 6.0, 0), head, lamp_mat, r)
		d["lights"].append(lamp_mat)
	_register_body(d, _pole_collider(Vector3.ZERO, 0.12, 6.0, r))


## Electronics repair shop (assistência técnica): a counter under a sign;
## players trade robot parts here for gadgets (player.gd shop menu). A
## placeholder until its model arrives.
var shops: Array = []                 # [position]
func _repair_shop(pos: Vector3, yaw: float) -> void:
	var root := Node3D.new()
	root.set_meta("kind", "repair_shop")
	root.position = pos
	root.rotation.y = yaw
	add_child(root)
	var counter := BoxMesh.new()
	counter.size = Vector3(2.4, 1.05, 0.7)
	_part(Vector3(0, 0.52, 0), counter, _mat(Color(0.18, 0.2, 0.24)), root)
	var top := BoxMesh.new()
	top.size = Vector3(2.5, 0.06, 0.8)
	_part(Vector3(0, 1.08, 0), top, _mat(Color(0.75, 0.78, 0.8)), root)
	var post := _part(Vector3(1.4, 1.5, 0), _cyl(0.05, 3.0), _mat(Color(0.3, 0.3, 0.32)), root)
	post.visibility_range_end = 0.0
	var board := BoxMesh.new()
	board.size = Vector3(2.6, 0.7, 0.08)
	var sign := _part(Vector3(0, 2.7, 0), board, _mat(Color(0.05, 0.45, 0.3), true), root)
	sign.visibility_range_end = 0.0
	var text := Label3D.new()
	text.text = "ASSISTÊNCIA TÉCNICA"
	text.font_size = 64
	text.pixel_size = 0.0042
	text.position = Vector3(0, 2.7, 0.05)
	text.modulate = Color(1, 1, 1)
	root.add_child(text)
	var back := text.duplicate() as Label3D
	back.position.z = -0.05
	back.rotation.y = PI
	root.add_child(back)
	var cs := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(2.4, 1.1, 0.7)
	shape.shape = b
	shape.position.y = 0.55
	cs.add_child(shape)
	root.add_child(cs)
	shops.append(pos)


## A generated model standing as authored (front -Z) at `yaw`, with a box
## collider: vendor stalls and the parked historic tram.
func _static_model(path: String, pos: Vector3, yaw: float) -> void:
	if not ResourceLoader.exists(path):
		return
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	add_child(root)
	var model: Node3D = (load(path) as PackedScene).instantiate()
	root.add_child(model)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = 150.0
	if path.contains("kiosk"):
		# the kiosk is open in front with a side door: collide with its real walls
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			if not String(mi.name).begins_with("covers"):
				(mi as MeshInstance3D).create_trimesh_collision()
		return
	var box := _aabb(model)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	cs.shape = shape
	cs.position = box.get_center()
	body.add_child(cs)
	root.add_child(body)


## Corner pole with one blue name plate per street (Porto Alegre style),
## each plate parallel to its street, lettering on both faces.
const SIGN_ABBREV := {"Rua ": "R. ", "Avenida ": "Av. ", "Travessa ": "Tv. ", "Praça ": "Pça. ",
		"Largo ": "Lgo. ", "General ": "Gen. ", "Senador ": "Sen. "}


func _street_sign(pos: Vector3, plates: Array) -> void:
	var root := Node3D.new()
	root.set_meta("kind", "street_sign")
	root.position = pos
	add_child(root)
	_part(Vector3(0, 1.5, 0), _cyl(0.035, 3.0), _mat(Color(0.32, 0.34, 0.36)), root)
	_pole_collider(Vector3.ZERO, 0.06, 3.0, root)
	var blue := _mat(Color(0.05, 0.22, 0.55))
	for i in plates.size():
		var text: String = plates[i]["name"]
		for k in SIGN_ABBREV:
			text = text.replace(k, SIGN_ABBREV[k])
		text = text.to_upper()
		var plate := Node3D.new()
		plate.position.y = 2.75 - i * 0.3
		plate.rotation.y = plates[i]["yaw"]
		root.add_child(plate)
		var width: float = clamp(0.3 + text.length() * 0.075, 0.8, 2.2)
		var box := BoxMesh.new()
		box.size = Vector3(width, 0.24, 0.02)
		# hang the plate off the pole so it doesn't intersect the other one
		_part(Vector3(width / 2 + 0.04, 0, 0), box, blue, plate)
		for side in [1.0, -1.0]:
			var lbl := Label3D.new()
			lbl.text = text
			lbl.font_size = 48
			lbl.pixel_size = 0.0028
			lbl.outline_size = 0
			lbl.modulate = Color(0.95, 0.95, 0.95)
			lbl.shaded = true
			lbl.double_sided = false
			lbl.width = (width - 0.08) / lbl.pixel_size
			lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			lbl.position = Vector3(width / 2 + 0.04, 0, 0.0115 * side)
			lbl.rotation.y = 0.0 if side > 0 else PI
			lbl.visibility_range_end = 60.0
			plate.add_child(lbl)


const SHELTER := "res://assets/common/props/bus_shelter/bus_shelter_porto_alegre.glb"
func _bus_stop(pos: Vector3, yaw: float) -> void:
	# open side (+Z) faces the street (the exporter sets the yaw)
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	root.set_meta("kind", "bus_stop")
	add_child(root)
	if ResourceLoader.exists(SHELTER):
		# the Porto Alegre shelter: origin on its kerb-side edge, roofed area
		# behind it (z -1.6..0), open towards its +Z - the street, as the
		# exporter turns the root; centred on the OSM point like the old one
		var m: Node3D = (load(SHELTER) as PackedScene).instantiate()
		m.position = Vector3(0, 0, 0.8)
		root.add_child(m)
		var body := StaticBody3D.new()
		for spec in [[Vector3(3.5, 2.5, 0.12), Vector3(0, 1.25, -0.75)], [Vector3(0.1, 2.5, 1.6), Vector3(-1.7, 1.25, 0.0)],
				[Vector3(0.1, 2.5, 1.6), Vector3(1.7, 1.25, 0.0)], [Vector3(2.4, 0.5, 0.45), Vector3(0, 0.25, -0.45)]]:
			var cs := CollisionShape3D.new()      # back wall, the two ends, the bench
			var bx := BoxShape3D.new()
			bx.size = spec[0]
			cs.shape = bx
			cs.position = spec[1]
			body.add_child(cs)
		root.add_child(body)
		return
	var roof := BoxMesh.new()
	roof.size = Vector3(3.0, 0.1, 1.4)
	_part(Vector3(0, 2.4, 0), roof, _mat(Color(0.75, 0.78, 0.8)), root)
	for x in [-1.4, 1.4]:
		_part(Vector3(x, 1.2, -0.6), _cyl(0.05, 2.4), _mat(Color(0.3, 0.3, 0.32)), root)
	var bench := BoxMesh.new()
	bench.size = Vector3(2.4, 0.08, 0.4)
	_part(Vector3(0, 0.5, -0.4), bench, _mat(Color(0.4, 0.3, 0.2)), root)


func _signal(pos: Vector3) -> void:
	var d := _destructible(pos, "traffic_signals")
	var r: Node3D = d["root"]
	_part(Vector3(0, 1.8, 0), _cyl(0.08, 3.6), _mat(Color(0.15, 0.15, 0.15)), r)
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.9, 0.3)
	_part(Vector3(0, 3.9, 0), box, _mat(Color(0.1, 0.1, 0.1)), r)
	for k in 3:
		var c: Color = [Color(1, 0.1, 0.1), Color(1, 0.75, 0.1), Color(0.1, 1, 0.3)][k]
		var m := _mat(c, true).duplicate()
		var bulb := _part(Vector3(0, 4.15 - k * 0.25, 0.16), SphereMesh.new(), m, r)
		bulb.scale = Vector3.ONE * 0.12
		d["lights"].append(m)
	_register_body(d, _pole_collider(Vector3.ZERO, 0.12, 4.2, r))


func _bin(pos: Vector3) -> void:
	var d := _destructible(pos, "waste_basket")
	if _instance("waste_basket", d["root"]) == null:
		_part(Vector3(0, 0.45, 0), _cyl(0.25, 0.9), _mat(Color(0.2, 0.35, 0.25)), d["root"])
	_register_body(d, _pole_collider(Vector3.ZERO, 0.3, 0.95, d["root"]))


## Instance a scanned model for `kind` under `parent`; null if missing.
## Parked cars mix in the generated car models (assets/common/cars) when present.
func _instance(kind: String, parent: Node3D) -> Node3D:
	var spec: Array = MODELS[kind]
	var id: String = spec[0][randi() % spec[0].size()]
	var path := id if id.begins_with("res://") else PH % [id, id]
	if kind == "car" and not _covered_only:
		var cars := preload("res://scripts/model_library.gd")._list("res://assets/common/cars")
		if cars.size() > 0 and randf() < 0.75:
			path = cars[randi() % cars.size()]
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path) if ResourceLoader.exists(path) else null
	if _scene_cache[path] == null:
		return null
	var node: Node3D = _scene_cache[path].instantiate()
	parent.add_child(node)
	if VARIANTS.has(kind) and not id.begins_with("res://"):
		_keep_one_variant(node, VARIANTS[kind])     # (Poly Haven files with two variants side by side)
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = spec[2]
		(mi as MeshInstance3D).visibility_range_end_margin = 5.0
	return node


## Static furniture: model, yaw (long axis along the curb), box collider.
func _model_prop(kind: String, pos: Vector3, yaw: float) -> Node3D:
	var root := Node3D.new()
	root.set_meta("kind", kind)
	root.position = pos
	add_child(root)
	var node := _instance(kind, root)
	if node == null:
		root.queue_free()
		return null
	var box := node.transform * _aabb(node)     # model space -> root space (variant shifts)
	# exporter yaw aligns local -Z/+Z with the curb; turn X-long models
	root.rotation.y = yaw - (PI / 2 if box.size.x > box.size.z else 0.0)
	if MODELS[kind][1] and box.size.length() > 0.2:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = box.size
		cs.shape = shape
		cs.position = box.get_center()
		body.add_child(cs)
		root.add_child(body)
		if CRUSH.has(kind):
			body.set_meta("crush", crushables.size())
			crushables.append({"root": root, "body": body, "kind": kind, "start": root.transform, "down": false,
					"lift": min(box.size.x, box.size.z) / 2.0})
	elif not MODELS[kind][1]:
		# nothing touches it (shrubs, ferns, manholes): into the draw batches
		_batch.absorb(root)
	if kind in SETTLE:
		_settle.append([root, box])
	return root


## Long pieces on a sloping street (a bike rack, a container, a bench): the
## ground is probed at both ends once the city's collision is in, and the
## piece stands at the higher one so no end is buried.
const SETTLE := ["bike_rack", "container", "bench", "planter", "barrier"]
var _settle: Array = []
func _settle_long() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	for e in _settle:
		var root: Node3D = e[0]
		if not is_instance_valid(root):
			continue
		var box: AABB = e[1]
		var top := -INF
		# not the piece itself (its own collision would lift it onto its seat)
		var own: Array[RID] = []
		for b in root.find_children("*", "CollisionObject3D", true, false):
			own.append((b as CollisionObject3D).get_rid())
		if root is CollisionObject3D:
			own.append((root as CollisionObject3D).get_rid())
		for corner in [Vector2(0, 0), Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var local := box.get_center() + Vector3(corner.x * box.size.x * 0.45, 0, corner.y * box.size.z * 0.45)
			local.y = 0
			var at: Vector3 = root.global_transform * local
			var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 2.0, 0), at - Vector3(0, 2.0, 0), 1)
			q.exclude = own
			var hit := space.intersect_ray(q)
			if hit:
				top = max(top, hit.position.y)
		# a slope lifts one end a little; more than that is something else under it
		if top > -INF and top > root.global_position.y and top - root.global_position.y < 0.6:
			root.global_position.y = top
			for c in crushables:
				if c["root"] == root:
					c["start"] = root.transform      # a new round puts it back here


func _aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var t := node.global_transform.affine_inverse() * m.global_transform if node.is_inside_tree() else m.transform
		var b := t * m.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


# ---- destruction ------------------------------------------------------------

## Server: apply damage to a prop hit by a shot (player or robot).
func damage_prop(index: int, amount: int) -> void:
	if not multiplayer.is_server() or index < 0 or index >= destructibles.size():
		return
	var d: Dictionary = destructibles[index]
	if d["broken"]:
		return
	d["health"] -= amount
	if d["health"] <= 0:
		break_prop.rpc(index)


func find_target(from: Vector3, radius: float, eye := Vector3.INF) -> int:
	## Index of an intact destructible within `radius` (closest first), or -1.
	## With `eye`: only one in plain sight from there (no shooting through walls).
	var best := -1
	var bd := radius
	var space := get_world_3d().direct_space_state
	for i in destructibles.size():
		var d: Dictionary = destructibles[i]
		if d["broken"]:
			continue
		var dist: float = (d["root"] as Node3D).global_position.distance_to(from)
		if dist >= bd:
			continue
		if eye != Vector3.INF:
			var q := PhysicsRayQueryParameters3D.create(eye, (d["root"] as Node3D).global_position + Vector3(0, 1.0, 0), 1)
			q.exclude = [(d["body"] as StaticBody3D).get_rid()]
			if not space.intersect_ray(q).is_empty():
				continue
		bd = dist
		best = i
	return best


func prop_position(index: int) -> Vector3:
	return (destructibles[index]["root"] as Node3D).global_position


@rpc("authority", "call_local", "reliable")
func break_prop(index: int) -> void:
	var d: Dictionary = destructibles[index]
	if d["broken"]:
		return
	d["broken"] = true
	var root: Node3D = d["root"]
	var body: StaticBody3D = d["body"]
	body.collision_layer = 0
	d["y"] = root.position.y
	for m in d["lights"]:
		(m as StandardMaterial3D).emission_enabled = false
		(m as StandardMaterial3D).albedo_color = Color(0.15, 0.15, 0.15)
	var tw := create_tween()
	tw.tween_property(root, "rotation:x", deg_to_rad(84 if d["kind"] != "waste_basket" else 90), 0.9) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	if d["kind"] == "waste_basket":
		# it pivots on its base: lying down, it rests on its side, a radius up
		tw.parallel().tween_property(root, "position:y", root.position.y + 0.28, 0.9) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_sparks(root.global_position + Vector3(0, 0.3 if d["kind"] == "waste_basket" else 1.0, 0))
	Sfx.play_at("prop_break", root.global_position + Vector3(0, 1.0, 0), 0.0)
	if d["kind"] != "waste_basket":
		Sfx.play_at("glass", root.global_position + Vector3(0, 4.0, 0), -4.0)


@rpc("authority", "call_local", "reliable")
func restore_all() -> void:
	for c in crushables:
		c["down"] = false
		(c["root"] as Node3D).transform = c["start"]
		(c["body"] as StaticBody3D).collision_layer = 1
	for d in destructibles:
		if d.get("removed", false):
			continue
		d["broken"] = false
		d["health"] = HITS[d["kind"]]
		(d["root"] as Node3D).rotation.x = 0.0
		(d["root"] as Node3D).position.y = d.get("y", (d["root"] as Node3D).position.y)
		(d["body"] as StaticBody3D).collision_layer = 1
		for m in d["lights"]:
			(m as StandardMaterial3D).emission_enabled = true


## Lamps and bins standing on a landmark's forecourt or shop floor (its
## *_ground_pad meshes) are taken away.
func clear_under(pad: MeshInstance3D) -> int:
	var box := pad.get_aabb()
	var inv := pad.global_transform.affine_inverse()
	var n := 0
	for d in destructibles:
		var lp: Vector3 = inv * (d["root"] as Node3D).global_position
		if d.get("removed", false) or lp.x < box.position.x or lp.x > box.end.x \
				or lp.z < box.position.z or lp.z > box.end.z:
			continue
		d["removed"] = true
		d["broken"] = true
		(d["root"] as Node3D).visible = false
		(d["body"] as StaticBody3D).collision_layer = 0
		n += 1
	return n


## The released game's "_remove" edits (no rebuild there): what stands within
## `r` m of `at` (x, z) goes - knockable props, trees (their batched picture
## too), modelled furniture. Shrubs and ferns drawn in the batches stay.
func remove_near(at: Vector2, r := 1.0) -> int:
	var n := 0
	for d in destructibles:
		var p: Vector3 = (d["root"] as Node3D).global_position
		if d.get("removed", false) or Vector2(p.x, p.z).distance_to(at) > r:
			continue
		d["removed"] = true
		d["broken"] = true
		(d["root"] as Node3D).visible = false
		(d["body"] as StaticBody3D).collision_layer = 0
		n += 1
	for c in crowns:
		var cp: Vector3 = c[1]
		if Vector2(cp.x, cp.z).distance_to(at) > r:
			continue
		for ref in _batch.ref(c[0]):
			(ref[0] as MultiMesh).set_instance_transform(ref[1], Transform3D(Basis.from_scale(Vector3.ZERO), ref[2].origin))
		for b in get_children():
			if b is CollisionObject3D and b.has_meta("tree_crown") and Vector2(b.global_position.x, b.global_position.z).distance_to(at) < r + 0.5:
				(b as CollisionObject3D).collision_layer = 0
		n += 1
	for root in get_children():
		if root is Node3D and root.has_meta("kind") and not root is CollisionObject3D \
				and Vector2(root.global_position.x, root.global_position.z).distance_to(at) <= r:
			root.visible = false
			for b in root.find_children("*", "CollisionObject3D", true, false):
				(b as CollisionObject3D).collision_layer = 0
			n += 1
	return n


## Server: a vehicle of `mass` drove into a prop body at `speed` along `dir`.
## True when it went over (the vehicle drives on), false when it holds.
func crush(body: Node, mass: float, speed: float, dir: Vector3) -> bool:
	var kind := ""
	if body.has_meta("prop_index"):
		var d: Dictionary = destructibles[body.get_meta("prop_index")]
		kind = d["kind"]
		if d["broken"]:
			return true
	elif body.has_meta("crush"):
		var c: Dictionary = crushables[body.get_meta("crush")]
		kind = c["kind"]
		if c["down"]:
			return true
	if not CRUSH.has(kind):
		return false
	var need: Array = CRUSH[kind]
	if mass < need[0] or speed < need[1] * clamp(need[0] * 2.0 / mass, 0.4, 1.0):
		return false
	if body.has_meta("prop_index"):
		break_prop.rpc(body.get_meta("prop_index"))
	else:
		knock_over.rpc(body.get_meta("crush"), dir)
	return true


## Every peer: a bench, bin or planter run over falls away from the vehicle.
@rpc("authority", "call_local", "reliable")
func knock_over(index: int, dir: Vector3) -> void:
	var c: Dictionary = crushables[index]
	if c["down"]:
		return
	c["down"] = true
	(c["body"] as StaticBody3D).collision_layer = 0
	var root: Node3D = c["root"]
	var start: Transform3D = root.transform
	dir.y = 0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	var axis := Vector3.UP.cross(dir).normalized()       # the top falls along dir
	var lift: float = c.get("lift", 0.2)                 # lying down it rests on its side, not in the street
	create_tween().tween_method(func(t: float):
		root.transform = Transform3D(Basis(axis, t * 1.45) * start.basis,
				start.origin + dir * t * 0.9 + Vector3.UP * lift * t),
		0.0, 1.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	Sfx.play_at("prop_break", root.global_position + Vector3(0, 0.5, 0), -4.0)


func _sparks(at: Vector3) -> void:
	var flash := OmniLight3D.new()
	flash.light_color = Color(1, 0.7, 0.3)
	flash.light_energy = 5.0
	flash.omni_range = 6.0
	flash.position = at
	add_child(flash)
	var parts := CPUParticles3D.new()
	parts.position = at
	parts.amount = 40
	parts.one_shot = true
	parts.explosiveness = 0.95
	parts.lifetime = 0.8
	parts.direction = Vector3.UP
	parts.spread = 70.0
	parts.initial_velocity_min = 3.0
	parts.initial_velocity_max = 7.0
	parts.gravity = Vector3(0, -9.8, 0)
	var pm := SphereMesh.new()
	pm.radius = 0.03
	pm.height = 0.06
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_color = Color(1, 0.8, 0.3)
	pm.material = pmat
	parts.mesh = pm
	add_child(parts)
	parts.emitting = true
	var tw := create_tween()
	tw.tween_property(flash, "light_energy", 0.0, 0.4)
	tw.tween_callback(flash.queue_free)
	get_tree().create_timer(1.5).timeout.connect(parts.queue_free)


func _keep_one_variant(model: Node3D, offset: float) -> void:
	var sign := 1.0 if randf() < 0.5 else -1.0
	var holder: Node = model
	if model.get_child_count() == 1 and model.get_child(0).get_child_count() > 1:
		holder = model.get_child(0)
	for c in holder.get_children():
		if c is Node3D and (c as Node3D).position.x * sign < -0.01:
			c.free()     # now, not deferred: the collider is sized right after this
	model.position.x -= sign * offset
