extends RefCounted
## Your own photos on the city's walls, shown at once (no rebuild): a photo
## is a picture panel standing just in front of a wall. "Fit to wall" sizes
## it to the whole facade of the clicked building side; the inspector then
## moves it along the wall, up and down, resizes and turns it.
##
## Kept in the map's user edits (edits.gd) as "_photos":
##   {"id", "image": "photos/<file>", "pos": [x, y, z] (centre), "normal": [x, 0, z],
##    "w", "h", "roll" (degrees), "out" (m from the wall), "building"}
## and the image file copied into the edits folder, next to the json.

const Edits := preload("res://scripts/edits.gd")
const PICK_LAYER := 128            # design mode clicks find photos here; nothing else collides with it

static var _nodes := {}            # id -> MeshInstance3D


## Every photo of the map, built again (after loading the map).
static func apply_all(main: Node, map_id: String) -> void:
	for n in _nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	for p in Edits.read(map_id).get("_photos", []):
		_build(main, map_id, p)


## A new photo from `image_path` (any file on disk) on the wall at `at`
## facing `normal`; fitted to the building side when `wall` is given
## ({a: Vector2, b: Vector2, base: float, height: float, building: id}).
static func add(main: Node, map_id: String, image_path: String, at: Vector3, normal: Vector3, wall := {}) -> Dictionary:
	var img := Image.load_from_file(image_path)
	if img == null:
		return {}
	var id := "p%d" % Time.get_unix_time_from_system()
	var rel := "photos/%s.%s" % [id, "png"]
	var dst := Edits.dir(map_id).path_join(rel)
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	if img.get_width() > 2048 or img.get_height() > 2048:
		var k := 2048.0 / maxf(img.get_width(), img.get_height())
		img.resize(int(img.get_width() * k), int(img.get_height() * k), Image.INTERPOLATE_LANCZOS)
	img.save_png(dst)
	var n := Vector3(normal.x, 0, normal.z).normalized()
	if n.length() < 0.5:
		n = Vector3.BACK
	var aspect := float(img.get_height()) / float(img.get_width())
	var p := {"id": id, "image": rel, "pos": [at.x, at.y, at.z], "normal": [n.x, 0.0, n.z],
			"w": 6.0, "h": 6.0 * aspect, "roll": 0.0, "out": 0.06}
	if not wall.is_empty():
		_fit(p, wall)
	var user := Edits.read(map_id)
	var list: Array = user.get("_photos", [])
	list.append(p)
	user["_photos"] = list
	Edits.write(map_id, user)
	_build(main, map_id, p)
	return p


## Size and place a photo over a whole building side.
static func _fit(p: Dictionary, wall: Dictionary) -> void:
	var a: Vector2 = wall["a"]
	var b: Vector2 = wall["b"]
	var mid := (a + b) / 2.0
	p["w"] = a.distance_to(b)
	p["h"] = float(wall["height"])
	p["pos"] = [mid.x, float(wall["base"]) + p["h"] / 2.0, mid.y]
	# the outward side: the one the click came from
	var along := (b - a).normalized()
	var out := Vector2(-along.y, along.x)
	var n := Vector2(p["normal"][0], p["normal"][2])
	if out.dot(n) < 0:
		out = -out
	p["normal"] = [out.x, 0.0, out.y]
	p["building"] = wall.get("building", "")


## Change one photo (the inspector): fields merge into the entry; it moves at once.
static func update(main: Node, map_id: String, id: String, fields: Dictionary) -> Dictionary:
	var user := Edits.read(map_id)
	var list: Array = user.get("_photos", [])
	for p in list:
		if p["id"] == id:
			if fields.has("wall"):
				_fit(p, fields["wall"])
				fields.erase("wall")
			var new_image: bool = fields.has("image") and fields["image"] != p["image"]
			p.merge(fields, true)
			Edits.write(map_id, user)
			var n := node(id)
			if n and not new_image:
				_place(n, p)                 # moved in place: the selection stays on it
			else:
				if n:
					n.queue_free()
				_build(main, map_id, p)
			return p
	return {}


static func remove(map_id: String, id: String) -> void:
	var user := Edits.read(map_id)
	user["_photos"] = user.get("_photos", []).filter(func(p): return p["id"] != id)
	Edits.write(map_id, user)
	if _nodes.has(id) and is_instance_valid(_nodes[id]):
		_nodes[id].queue_free()
	_nodes.erase(id)


static func entry(map_id: String, id: String) -> Dictionary:
	for p in Edits.read(map_id).get("_photos", []):
		if p["id"] == id:
			return p
	return {}


static func node(id: String) -> Node3D:
	var n = _nodes.get(id)
	return n if is_instance_valid(n) else null


## The basis of a photo: facing out of the wall, upright, turned by its roll.
static func basis_of(p: Dictionary) -> Basis:
	var n := Vector3(p["normal"][0], 0, p["normal"][2]).normalized()
	var x := Vector3.UP.cross(n).normalized()
	return Basis(x, Vector3.UP, n).rotated(n, deg_to_rad(float(p.get("roll", 0.0))))


static func _build(main: Node, map_id: String, p: Dictionary) -> void:
	var path := Edits.dir(map_id).path_join(p["image"])
	var img := Image.load_from_file(path)
	if img == null:
		return
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(float(p["w"]), float(p["h"]))
	mi.mesh = q
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.85
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	img.generate_mipmaps()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	main.add_child(mi)
	mi.set_meta("photo", p["id"])
	# a thin pick box so the editor can click it
	var body := StaticBody3D.new()
	body.collision_layer = PICK_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	mi.add_child(body)
	_place(mi, p)
	_nodes[p["id"]] = mi


## Size, place and turn a photo's panel (and its pick box) from its entry.
static func _place(mi: MeshInstance3D, p: Dictionary) -> void:
	(mi.mesh as QuadMesh).size = Vector2(float(p["w"]), float(p["h"]))
	var b := basis_of(p)
	mi.global_transform = Transform3D(b, Vector3(p["pos"][0], p["pos"][1], p["pos"][2]) + b.z * float(p.get("out", 0.06)))
	for cs in mi.find_children("*", "CollisionShape3D", true, false):
		((cs as CollisionShape3D).shape as BoxShape3D).size = Vector3(float(p["w"]), float(p["h"]), 0.05)


## The image's height over its width (for "keep proportions").
static func aspect(map_id: String, p: Dictionary) -> float:
	var img := Image.load_from_file(Edits.dir(map_id).path_join(p["image"]))
	return float(img.get_height()) / float(img.get_width()) if img else 1.0


## A new image for a photo, copied into the edits folder.
static func copy_image(map_id: String, image_path: String, id: String) -> String:
	var img := Image.load_from_file(image_path)
	if img == null:
		return ""
	if img.get_width() > 2048 or img.get_height() > 2048:
		var k := 2048.0 / maxf(img.get_width(), img.get_height())
		img.resize(int(img.get_width() * k), int(img.get_height() * k), Image.INTERPOLATE_LANCZOS)
	var rel := "photos/%s_%d.png" % [id, Time.get_unix_time_from_system()]
	DirAccess.make_dir_recursive_absolute(Edits.dir(map_id).path_join("photos"))
	img.save_png(Edits.dir(map_id).path_join(rel))
	return rel
