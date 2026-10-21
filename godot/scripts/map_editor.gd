extends PanelContainer
## In-game map editor (design mode). Click a building: its OpenStreetMap
## identity, address and height appear here; change the height (a ghost of
## the new volume shows it in place), save it to maps/<map>/user/, send it to
## OpenStreetMap through JOSM, or rebuild the map with the pipeline.
##
## Buildings are found in <map>.buildings.json (written by osm2gltf.py):
## OSM id, name, height, base and footprint ring in game coordinates. Edits
## are keyed by OSM id, so a map rebuilt from fresh OSM data keeps them and
## they can go back to OSM as tags (height, building:levels).

const STOREY_M := 3.2
const Edits := preload("res://scripts/edits.gd")
const Photos := preload("res://scripts/photos.gd")

var _buildings: Array = []
var _map := ""
var _sel: Dictionary = {}
var _title: Label
var _info: Label
var _height: SpinBox
var _status: Label
var _ghost: MeshInstance3D
var _film: OptionButton           # cinemas: which of the city's films the screen plays


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.12
	offset_left = -430
	offset_right = -16
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.9)
	style.border_color = Color(1.0, 0.85, 0.1)
	style.border_width_left = 3
	style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_title)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 16)
	_info.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_info)
	var row := HBoxContainer.new()
	var hl := Label.new()
	hl.text = "Height (m)"
	hl.add_theme_font_size_override("font_size", 18)
	row.add_child(hl)
	_height = SpinBox.new()
	_height.min_value = 2.0
	_height.max_value = 300.0
	_height.step = 0.5
	_height.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height.value_changed.connect(func(_v): _update_ghost())
	row.add_child(_height)
	box.add_child(row)
	# the photo panel works everywhere; rectifying into the map, heights and
	# rebuilds need the map pipeline (playing from the sources)
	var specs := [["Put a photo on this wall...", _pick_wall_photo]]
	if Edits.has_sources():
		specs += [["Save height", _save], ["Rectify a photo into the map (pipeline)...", _pick_photo]]
	specs += [["Open in OpenStreetMap", _open_osm], ["Send to JOSM (remote control)", _send_josm]]
	if Edits.has_sources():
		specs.append(["Rebuild map and restart", _rebuild])
	for spec in specs:
		var b := Button.new()
		b.text = spec[0]
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(spec[1])
		box.add_child(b)
	_film = OptionButton.new()
	_film.visible = false
	_film.item_selected.connect(_choose_film)
	box.add_child(_film)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 15)
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status)


func repo_dir() -> String:
	return Edits.repo_dir()


## The map's edits folder (edits.gd: the repository's maps/<map>/user/, or
## user://maps/<map>/ in the released game).
func user_dir(map_id: String) -> String:
	return Edits.dir(map_id)


## The side of the selected building nearest to `at`: its two corners, base
## and height (for fitting a photo over the whole facade). {} if none.
func wall_at(map_id: String, at: Vector3) -> Dictionary:
	var b := building_at(map_id, at)
	if b.is_empty():
		return {}
	var ring: Array = b["ring"]
	var pt := Vector2(at.x, at.z)
	var best := INF
	var out := {}
	for i in ring.size():
		var a := Vector2(ring[i][0], ring[i][1])
		var c := Vector2(ring[(i + 1) % ring.size()][0], ring[(i + 1) % ring.size()][1])
		var d := Geometry2D.get_closest_point_to_segment(pt, a, c).distance_to(pt)
		if d < best:
			best = d
			out = {"a": a, "b": c}
	var h: float = Edits.read(map_id).get(b["id"], {}).get("height", b["height"])
	out["base"] = float(b.get("base", 0.0))
	out["height"] = h
	out["building"] = b["id"]
	return out


var _wall_normal := Vector3.BACK


## A photo of your own on the clicked wall, at once: it covers that side of
## the building; the Object Inspector then places it exactly.
func _pick_wall_photo() -> void:
	if _sel.is_empty():
		return
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = PackedStringArray(["*.jpg, *.jpeg, *.png, *.webp ; Photos"])
	dlg.file_selected.connect(func(path):
		var main := get_tree().current_scene
		var p: Dictionary = Photos.add(main, _map, path, _wall_at, _wall_normal, wall_at(_map, _wall_at))
		_status.text = ("Photo on the wall (%.0f × %.0f m) - click it to place it exactly" % [p["w"], p["h"]]) if not p.is_empty() \
				else "Could not read that image")
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _user_file() -> String:
	return Edits.file(_map)


func _load_index(map_id: String) -> void:
	if map_id == _map and not _buildings.is_empty():
		return
	_map = map_id
	_buildings = []
	var path := "res://city/%s.buildings.json" % map_id
	if FileAccess.file_exists(path):
		_buildings = JSON.parse_string(FileAccess.get_file_as_string(path))


## The building whose footprint contains game point (x, z), or {}.
func building_at(map_id: String, p: Vector3) -> Dictionary:
	_load_index(map_id)
	var best := {}
	var best_d := 2.5                  # a click on a wall lands just outside the eroded footprint
	for b in _buildings:
		var poly := PackedVector2Array()
		for q in b["ring"]:
			poly.append(Vector2(q[0], q[1]))
		var pt := Vector2(p.x, p.z)
		if Geometry2D.is_point_in_polygon(pt, poly):
			return b
		for i in poly.size():
			var c := Geometry2D.get_closest_point_to_segment(pt, poly[i], poly[(i + 1) % poly.size()])
			if c.distance_to(pt) < best_d:
				best_d = c.distance_to(pt)
				best = b
	return best


## Design mode picked something: show the panel for buildings.
func select(map_id: String, what: String, at: Vector3) -> Dictionary:
	_clear_ghost()
	if what != "building":
		visible = false
		return {}
	_wall_at = at
	_sel = building_at(map_id, at)
	visible = not _sel.is_empty()
	if _sel.is_empty():
		return {}
	var user := _read_user()
	var h: float = user.get(_sel["id"], {}).get("height", _sel["height"])
	_title.text = _sel["name"] if _sel["name"] != "" else "Building"
	var addr: String = ("%s %s" % [_sel["street"], _sel["number"]]).strip_edges()
	_info.text = "%s\n%s\nOSM: height %s, levels %s" % [_sel["id"], addr if addr != "" else "(no address)",
			_sel["osm_height"] if _sel["osm_height"] != "" else "-", _sel["levels"] if _sel["levels"] != "" else "-"]
	# what OSM says it is (place_kinds.json): a pharmacy, a market...
	var scene := get_tree().current_scene
	var pl: Dictionary = scene.place_of(_sel["id"]) if scene.has_method("place_of") else {}
	if not pl.is_empty():
		_info.text += "\nPlace: %s%s" % [scene.place_kinds.get(pl["kind"], {}).get("label", pl["kind"]),
				("  ·  " + pl["name"]) if pl["name"] != "" else ""]
	_height.set_value_no_signal(h)
	_status.text = "Edited (not yet rebuilt)" if user.has(_sel["id"]) else ""
	_update_ghost()
	# a cinema: offer the city's films (res://assets/rio_grande_do_sul/video/cities/<city>/)
	var main := get_tree().current_scene
	var is_cinema: bool = String(user.get(_sel["id"], {}).get("model", "")).contains("cine")
	_film.visible = is_cinema
	if is_cinema:
		_film.clear()
		for f in main.city_films(map_id):
			_film.add_item("Film: " + f.get_file().get_basename())
			_film.set_item_metadata(_film.item_count - 1, f)
		var current: String = user.get(_sel["id"], {}).get("film", "")
		for i in _film.item_count:
			if _film.get_item_metadata(i) == current:
				_film.select(i)
	return _sel


func _choose_film(i: int) -> void:
	var film: String = _film.get_item_metadata(i)
	var user := _read_user()
	var entry: Dictionary = user.get(_sel["id"], {})
	entry["film"] = film
	user[_sel["id"]] = entry
	Edits.write(_map, user)
	get_tree().current_scene.set_screen_film(film)
	_status.text = "Now showing %s (saved for this cinema)" % film.get_file()


func _read_user() -> Dictionary:
	return Edits.read(_map)


func _save() -> void:
	if _sel.is_empty():
		return
	var user := _read_user()
	var entry: Dictionary = user.get(_sel["id"], {})
	entry["height"] = _height.value
	entry["edited_in_game"] = Time.get_datetime_string_from_system()
	user[_sel["id"]] = entry
	Edits.write(_map, user)
	_status.text = "Changed (File > Save keeps it) - rebuild to see it in the city"


var _wall_at := Vector3.ZERO


## Your own photo on the clicked wall: tools/map/building_photo.py finds the wall
## (pick) and rectifies the whole image onto it (photo).
func _pick_photo() -> void:
	if _sel.is_empty():
		return
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = PackedStringArray(["*.jpg, *.jpeg, *.png, *.webp ; Photos"])
	dlg.file_selected.connect(_apply_photo)
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _apply_photo(path: String) -> void:
	var repo := repo_dir()
	var py := repo.path_join("tools/.venv/bin/python")
	var out := []
	OS.execute(py, [repo.path_join("tools/map/building_photo.py"), "pick", _map, str(_wall_at.x), str(_wall_at.z)], out, true)
	var info = JSON.parse_string("\n".join(out))
	if not info is Dictionary or not info.has("wall"):
		_status.text = "Could not find the wall"
		return
	out = []
	var code := OS.execute(py, [repo.path_join("tools/map/building_photo.py"), "photo", _map, info["wall"], path,
			"--height", str(_height.value)], out, true)
	_status.text = ("Photo applied to the wall (%.0f m wide) - rebuild to see it" % info["wall_length_m"]) if code == 0 \
			else "Photo failed:\n" + "\n".join(out).right(300)


func _open_osm() -> void:
	if not _sel.is_empty():
		OS.shell_open("https://www.openstreetmap.org/" + _sel["id"])


## JOSM's remote control (Preferences > Remote Control, port 8111): loads the
## object and sets the tags; you review and upload from JOSM.
func _send_josm() -> void:
	if _sel.is_empty():
		return
	var parts: PackedStringArray = _sel["id"].split("/")
	var obj: String = {"way": "w", "relation": "r", "node": "n"}.get(parts[0], "w") + parts[1]
	var h := snappedf(_height.value, 0.5)
	var tags := "height=%s|building:levels=%d" % [str(h), maxi(1, roundi((h - 0.6) / STOREY_M))]
	var url := "http://127.0.0.1:8111/load_object?objects=%s&addtags=%s" % [obj, tags.uri_encode()]
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result, code, _h, _b):
		_status.text = "JOSM: object loaded with the new tags - review and upload there" if code == 200 \
				else "JOSM did not answer (is it running with Remote Control on?)"
		http.queue_free())
	if http.request(url) != OK:
		_status.text = "Could not reach JOSM"


func _rebuild() -> void:
	if not _sel.is_empty():
		_save()
	Edits.save(_map)                   # the pipeline reads the saved edits
	_status.text = "Rebuilding the map... (this takes a minute)"
	await get_tree().process_frame
	await get_tree().process_frame
	var repo := repo_dir()
	var out := []
	var code := OS.execute(repo.path_join("tools/.venv/bin/python"),
			[repo.path_join("tools/map/building_photo.py"), "rebuild", _map], out, true)
	if code != 0:
		_status.text = "Rebuild failed:\n" + "\n".join(out).right(400)
		return
	OS.execute(OS.get_executable_path(), ["--headless", "--path", repo.path_join("godot"), "--import"], [], true)
	# start again with the same arguments (keeps --devagent), the new map loads
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


func _clear_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null


## A see-through volume of the building at the height in the box.
func _update_ghost() -> void:
	_clear_ghost()
	if _sel.is_empty():
		return
	var ring: Array = _sel["ring"]
	var base: float = _sel["base"]
	var top: float = base + _height.value
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in ring.size():
		var a: Array = ring[i]
		var b: Array = ring[(i + 1) % ring.size()]
		var p := [Vector3(a[0], base, a[1]), Vector3(b[0], base, b[1]), Vector3(b[0], top, b[1]), Vector3(a[0], top, a[1])]
		for k in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(p[k])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.25)
	_ghost = MeshInstance3D.new()
	_ghost.mesh = st.commit()
	_ghost.material_override = mat
	get_tree().current_scene.add_child(_ghost)


func close() -> void:
	visible = false
	_clear_ghost()



# ---- the tools panel: place objects, import a new city -----------------------

const PLACEABLE_DIRS := ["res://assets/rio_grande_do_sul/gaucho", "res://assets/rio_grande_do_sul/stalls", "res://assets/rio_grande_do_sul/landmarks", "res://assets/rio_grande_do_sul/tram",
		"res://assets/common/props"]


## The picker's groups from res://assets/collections.json:
## [["Rio Grande do Sul / Gaúcho culture", [model paths]], ...] - only the
## kinds that can stand in a street (no people, weapons, films).
const PLACEABLE_CATEGORIES := ["Furniture", "Furniture (Porto Alegre)", "Landmarks (Porto Alegre)", "Gaúcho culture", "Street stalls",
		"Transport", "Waterfront", "Wildlife", "Musicians", "Interiors"]
static func placeable_groups() -> Array:
	var out := []
	if not FileAccess.file_exists("res://assets/collections.json"):
		return [["Objects", placeable_models()]]
	var cols: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/collections.json"))
	for key in cols:
		if key.begins_with("_"):
			continue
		for cat in cols[key]["categories"]:
			if not cat in PLACEABLE_CATEGORIES:
				continue
			var models := PackedStringArray()
			for pattern in cols[key]["categories"][cat]:
				var parts: PackedStringArray = String(pattern).split("/")
				var dir: String = "res://assets/" + "/".join(parts.slice(0, parts.size() - 1)) if String(pattern).contains("*") \
						else "res://assets/" + pattern
				var glob: String = parts[-1] if String(pattern).contains("*") else "*"
				if not DirAccess.dir_exists_absolute(dir):
					continue
				var stack := [dir]
				while not stack.is_empty():
					var d: String = stack.pop_back()
					for sub_dir in DirAccess.get_directories_at(d):
						stack.append(d.path_join(sub_dir))
					for f in DirAccess.get_files_at(d):
						var n := f.trim_suffix(".remap").trim_suffix(".import")
						if (n.ends_with(".glb") or n.ends_with(".gltf") or n == "layout.json") and n.match(glob + "*") and not models.has(d.path_join(n)):
							models.append(d.path_join(n))
			if models.size() > 0:
				out.append(["%s / %s" % [cols[key]["label"], cat], models])
	return out


static func placeable_models() -> PackedStringArray:
	var out := PackedStringArray()
	for d in PLACEABLE_DIRS:
		for f in DirAccess.get_files_at(d):
			var n := f.trim_suffix(".remap").trim_suffix(".import")
			if (n.ends_with(".glb") or n.ends_with(".gltf")) and not out.has(d.path_join(n)):
				out.append(d.path_join(n))
	return out
