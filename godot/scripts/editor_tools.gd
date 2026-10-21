extends PanelContainer
## Design mode, left dock: the object palette, like Delphi's component
## palette - groups that open and close, a picture of each model (thumbs.gd),
## its name on mouse-over, a search box. Click a model, then click the world
## to place it (saved as "_props" in the map's user/buildings_user.json,
## rebuilt into the map); items become pickup spots ("_pickups").
## The rest of the editor: editor_menu.gd (menu bar), inspector.gd (right).

const MapEditor := preload("res://scripts/map_editor.gd")
const Entities := preload("res://scripts/entities.gd")
const Edits := preload("res://scripts/edits.gd")
const Thumbs := preload("res://scripts/thumbs.gd")
const Photos := preload("res://scripts/photos.gd")
const CYAN := Color(0.3, 0.85, 1.0)

signal status(text: String)

var placing := ""                 # model path (or "def:<id>") while placing
var bus_line := 1                 # the line a bus stop placed now belongs to (inspector)
var _yaw := 0.0
var _placed: Array = []           # [node, entry, map_id] this session (undo)
var _status: Label
var _editor: Node
var _sel: Dictionary = {}
var _sel_node: Node3D
var _sel_map := ""
var _by_type: CheckButton
var _search: LineEdit
var _groups: VBoxContainer
var _open := {}                   # group name -> open
var _buttons := {}                # model path -> Button (thumbnail)
var thumbs: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_bottom = 1.0
	offset_left = 0
	offset_right = 380
	offset_top = 40                # under the menu bar
	offset_bottom = -96            # above the HUD bar
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.92)
	style.border_color = CYAN
	style.border_width_right = 2
	style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", style)
	thumbs = Thumbs.new()
	add_child(thumbs)
	thumbs.ready_thumb.connect(_on_thumb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(_label("PALETTE", 20))
	_search = LineEdit.new()
	_search.placeholder_text = "Search objects..."
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _fill_palette())
	box.add_child(_search)
	_by_type = CheckButton.new()
	_by_type.text = "By type (all collections)"
	_by_type.button_pressed = true
	_by_type.toggled.connect(func(_on): _fill_palette())
	box.add_child(_by_type)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_groups = VBoxContainer.new()
	_groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_groups)
	_status = _label("Pick an object, then click the world to place it", 13)
	_status.add_theme_color_override("font_color", CYAN)
	_status.custom_minimum_size = Vector2(350, 0)
	box.add_child(_status)
	_fill_palette()


func _label(t: String, size: int) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	return l


func _say(t: String) -> void:
	_status.text = t
	status.emit(t)


## Display name of a palette entry.
func entry_name(m: String) -> String:
	if m.begins_with("def:"):
		var d := Entities.get_def(m.trim_prefix("def:"))
		return String(d.get("name", m.trim_prefix("def:")))
	if m.ends_with("layout.json"):
		return "Set: " + m.get_base_dir().get_file().capitalize()
	var d2 := Entities.of_model(m)
	if not d2.is_empty():
		return String(d2.get("name", d2["id"]))
	return m.get_file().get_basename().capitalize()


func _fill_palette() -> void:
	for c in _groups.get_children():
		c.queue_free()
	_buttons.clear()
	var q := _search.text.strip_edges().to_lower()
	var groups: Array = _type_groups() if _by_type.button_pressed else MapEditor.placeable_groups()
	for g in groups:
		var items: Array = []
		for m in g[1]:
			if q == "" or entry_name(String(m)).to_lower().contains(q) or String(m).to_lower().contains(q):
				items.append(String(m))
		if items.is_empty():
			continue
		var name: String = g[0]
		var open: bool = _open.get(name, false) or q != ""
		var head := Button.new()
		head.text = ("▾ " if open else "▸ ") + "%s  (%d)" % [name, items.size()]
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.flat = true
		head.add_theme_font_size_override("font_size", 15)
		head.pressed.connect(func():
			_open[name] = not _open.get(name, false)
			_fill_palette())
		_groups.add_child(head)
		if not open:
			continue
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		_groups.add_child(grid)
		for m in items:
			grid.add_child(_tile(m))


## One palette tile: the model's picture (or its initials until it renders),
## the name as tooltip; pressed = placing it.
func _tile(m: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(82, 82)
	b.toggle_mode = true
	b.button_pressed = placing == m
	b.tooltip_text = entry_name(m) + "\n" + (m.trim_prefix("res://assets/") if not m.begins_with("def:") else "item: " + m.trim_prefix("def:"))
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var model := m
	if m.begins_with("def:"):
		model = String(Entities.get_def(m.trim_prefix("def:")).get("model", ""))
	var tex: Texture2D = thumbs.get_thumb(model) if model != "" else null
	if tex:
		b.icon = tex
	else:
		var initials := ""
		for w in entry_name(m).split(" ", false).slice(0, 2):
			initials += w.substr(0, 1).to_upper()
		b.text = initials if initials != "" else "?"
		b.add_theme_font_size_override("font_size", 22)
	b.toggled.connect(func(on): choose(m if on else ""))
	_buttons[model if model != "" else m] = b
	return b


func _on_thumb(path: String, tex: Texture2D) -> void:
	var b: Button = _buttons.get(path)
	if is_instance_valid(b):
		b.icon = tex
		b.text = ""


## Start (or stop, with "") placing an entry of the palette.
func choose(m: String) -> void:
	placing = m
	for k in _buttons:
		var b: Button = _buttons[k]
		if is_instance_valid(b):
			b.set_pressed_no_signal(b.tooltip_text.begins_with(entry_name(m) + "\n") and m != "")
	_say(("Placing %s - click the world  ·  Q / E turn it  ·  Esc stops" % entry_name(m)) if m != ""
			else "Pick an object, then click the world to place it")


## The palette by type: the items by category (placing one puts down a
## pickup spot), then the collections' model categories merged by name
## ("Furniture" and "Furniture (Porto Alegre)" are one list).
func _type_groups() -> Array:
	var out := []
	var cats := {}
	for d in Entities.all():
		if d.get("pickup", false):
			var c: String = d.get("category", "item")
			if not cats.has(c):
				cats[c] = []
			cats[c].append("def:" + d["id"])
	var names := cats.keys()
	names.sort()
	for c in names:
		out.append(["Items: " + c.capitalize(), cats[c]])
	var merged := {}
	var order := []
	for g in MapEditor.placeable_groups():
		var cat: String = String(g[0]).get_slice(" / ", 1).get_slice(" (", 0)
		if not merged.has(cat):
			merged[cat] = PackedStringArray()
			order.append(cat)
		for m in g[1]:
			if not merged[cat].has(m):
				merged[cat].append(m)
	for cat in order:
		out.append([cat, merged[cat]])
	return out


func _map_id() -> String:
	return get_tree().current_scene.get("map_id") if get_tree().current_scene else ""


func set_role(role_name: String, id: String) -> void:
	var map_id := _map_id()
	var user := _read_user(map_id)
	var roles: Dictionary = user.get("_roles", {})
	if id == "":
		roles.erase(role_name)
	else:
		roles[role_name] = id
	user["_roles"] = roles
	_write_user(map_id, user)
	_say("Saved: %s is %s on this map from the next round" % [role_name.replace("_", " "), id if id != "" else "the default"])


func map_roles() -> Dictionary:
	return _read_user(_map_id()).get("_roles", {})


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey and event.pressed):
		return
	if placing == "" and event.physical_keycode in [KEY_Q, KEY_E] and not get_viewport().gui_get_focus_owner() is LineEdit:
		if get_tree().current_scene.design_turn(15.0 if event.physical_keycode == KEY_Q else -15.0):
			get_viewport().set_input_as_handled()
			return
	if placing != "" and event.physical_keycode in [KEY_Q, KEY_E]:
		_yaw += 15.0 if event.physical_keycode == KEY_Q else -15.0
		if not _placed.is_empty():
			var last: Array = _placed[-1]
			(last[0] as Node3D).rotation.y = deg_to_rad(_yaw)
			last[1]["yaw"] = _yaw
			_save_props()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_Z and event.is_command_or_control_pressed():
		undo()
		get_viewport().set_input_as_handled()


## Main: the design-mode selection changed (the last one picked).
func on_selection(map_id: String, sel: Dictionary, node: Node3D) -> void:
	_sel = sel
	_sel_node = node
	_sel_map = map_id


func _read_user(map_id: String) -> Dictionary:
	return Edits.read(map_id)


func _write_user(map_id: String, user: Dictionary) -> void:
	Edits.write(map_id, user)          # kept until File > Save


## A placed model leaves the map's _props, a placed item its _pickups; a
## generated one (OSM tree, lamp, bench...) gets a "_remove" point. Either
## way it is gone now and after a rebuild. False if it cannot be removed.
func remove_node(map_id: String, node: Node3D, what: String) -> bool:
	if what == "photo" and node and is_instance_valid(node):
		Photos.remove(map_id, String(node.get_meta("photo")))
		return true
	if node == null or not is_instance_valid(node) or not what in ["prop", "object", "pickup"]:
		return false
	var user := _read_user(map_id)
	var at: Vector3 = node.global_position
	if what == "pickup":
		var spots: Array = user.get("_pickups", [])
		var left := spots.filter(func(p): return not (p.get("id", "") == str(node.get("kind"))
				and Vector2(p["x"], p["z"]).distance_to(Vector2(at.x, at.z)) < 1.5))
		if left.size() == spots.size():
			return false                   # a random pickup of the round, not a placed spot
		user["_pickups"] = left
		node.queue_free()
	elif node.has_meta("landmark") and String(node.get_meta("landmark").get("id", "")) == "prop":
		var model: String = node.get_meta("landmark").get("model", "")
		user["_props"] = user.get("_props", []).filter(func(p): return not (p.get("model", "") == model
				and Vector2(p["x"], p["z"]).distance_to(Vector2(at.x, at.z)) < 1.5))
	else:
		var gone: Array = user.get("_remove", [])
		gone.append([snappedf(at.x, 0.01), snappedf(at.z, 0.01)])
		user["_remove"] = gone
		# gone now as well (a tree's batched picture too), not only after a rebuild
		var main := get_tree().current_scene
		if main.get("props"):
			main.props.remove_near(Vector2(at.x, at.z))
	_write_user(map_id, user)
	if is_instance_valid(node) and not node.is_queued_for_deletion():
		node.visible = false
		for b in node.find_children("*", "CollisionObject3D", true, false):
			(b as CollisionObject3D).collision_layer = 0
	return true


## The inspector changed a placed model (name, position, height, turn): the
## node moves and its "_props" entry is rewritten. Only hand-placed models.
func update_prop(map_id: String, node: Node3D, fields: Dictionary, from := Vector3.INF) -> bool:
	if node == null or not node.has_meta("landmark") or String(node.get_meta("landmark").get("id", "")) != "prop":
		return false
	var user := _read_user(map_id)
	var model: String = node.get_meta("landmark").get("model", "")
	var at: Vector3 = node.global_position if from == Vector3.INF else from      # a drag: where it was
	var found := false
	var old_offset := 0.0
	for p in user.get("_props", []):
		if p.get("model", "") == model and Vector2(p["x"], p["z"]).distance_to(Vector2(at.x, at.z)) < 1.5:
			old_offset = float(p.get("y_offset", 0.0))
			for k in fields:
				if k == "label" and String(fields[k]) == "":
					p.erase("label")
				else:
					p[k] = fields[k]
			found = true
			break
	if not found:
		return false
	_write_user(map_id, user)
	if fields.has("x") or fields.has("z"):
		node.global_position.x = float(fields.get("x", at.x))
		node.global_position.z = float(fields.get("z", at.z))
	if fields.has("y_offset"):
		node.global_position.y += float(fields["y_offset"]) - old_offset
	if fields.has("yaw"):
		node.rotation.y = deg_to_rad(float(fields["yaw"]))
	if fields.has("label"):
		var l: Dictionary = node.get_meta("landmark")
		l["label"] = fields["label"]
	_say("Saved %s - part of the map on the next rebuild" % model.get_file())
	return true


## The user edits entry of a placed model (for the inspector), {} if none.
func prop_entry(map_id: String, node: Node3D) -> Dictionary:
	if node == null or not node.has_meta("landmark"):
		return {}
	var model: String = node.get_meta("landmark").get("model", "")
	var at: Vector3 = node.global_position
	for p in _read_user(map_id).get("_props", []):
		if p.get("model", "") == model and Vector2(p["x"], p["z"]).distance_to(Vector2(at.x, at.z)) < 1.5:
			return p
	return {}


## A model with a front (`faces` in its definition): the yaw in degrees that
## turns that front towards the nearest street of the traffic graph; NAN when
## the model has no front or no street is near.
func face_yaw(model: String, at: Vector3) -> float:
	var rule: Dictionary = Entities.of_model(model).get("faces", {})
	var graph: Dictionary = get_tree().current_scene.road_graph
	if rule.is_empty() or graph.is_empty():
		return NAN
	var p := Vector2(at.x, at.z)
	var best := Vector2.INF
	for e in graph["edges"]:
		var pts: Array = e["pts"]
		for k in pts.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(p, Vector2(pts[k][0], pts[k][1]), Vector2(pts[k + 1][0], pts[k + 1][1]))
			if q.distance_to(p) < best.distance_to(p):
				best = q
	if best == Vector2.INF or best.distance_to(p) > 40.0 or best.distance_to(p) < 0.05:
		return NAN
	var d := best - p                   # x, z
	var yaw: float
	match String(rule.get("front", "+z")):
		"-z": yaw = atan2(-d.x, -d.y)
		"+x": yaw = atan2(-d.y, d.x)
		"-x": yaw = atan2(d.y, -d.x)
		_: yaw = atan2(d.x, d.y)
	return rad_to_deg(yaw)


## The paved square under the click becomes asphalt (osm2gltf "_asphalt").
func asphalt_selected() -> void:
	if _sel.is_empty():
		return
	var user := _read_user(_sel_map)
	var p: Vector3 = _sel["pos"]
	var pts: Array = user.get("_asphalt", [])
	pts.append([snappedf(p.x, 0.01), snappedf(p.z, 0.01)])
	user["_asphalt"] = pts
	_write_user(_sel_map, user)
	_say("Saved: this paving becomes asphalt on the next rebuild (Studio, or Rebuild in a building's panel)")


## Main calls this for a design-mode click while placing.
func place_at(map_id: String, at: Vector3) -> void:
	if placing.ends_with("layout.json"):
		_place_set(map_id, at)
		return
	if placing.begins_with("def:"):
		_place_item(map_id, at)
		return
	var m: Node3D = (load(placing) as PackedScene).instantiate()
	get_tree().current_scene.add_child(m)
	m.global_position = at
	var faced := face_yaw(placing, at)
	if not is_nan(faced):
		_yaw = snappedf(faced, 1.0)          # its front to the street (Q / E still turn it)
	m.rotation.y = deg_to_rad(_yaw)
	var entry := {"model": placing, "x": snappedf(at.x, 0.01), "z": snappedf(at.z, 0.01), "yaw": _yaw, "solid": "box",
			"placed_in_game": Time.get_datetime_string_from_system()}
	_selectable(m, placing)
	if placing.contains("bus_shelter") or Entities.of_model(placing).get("tags", []).has("bus_stop"):
		entry["line"] = bus_line
	_placed.append([m, entry, map_id])
	_save_props()
	if placing.contains("bus_shelter"):
		get_tree().current_scene.refresh_bus_stops()     # the buses' route, in placing order
	_say("Placed %s - saved; it becomes part of the map on the next rebuild" % placing.get_file())


## A model placed this session can be picked and edited at once, like the
## map's own placed models (main finds them near a click).
func _selectable(m: Node3D, model: String) -> void:
	m.set_meta("landmark", {"id": "prop", "model": model})
	var lms: Array = get_tree().current_scene.get("_landmark_nodes")
	if lms != null:
		lms.append(m)


## An item from the palette by type: a pickup spot (it respawns there every
## round), saved as "_pickups" in the map's user edits; it shows at once.
func _place_item(map_id: String, at: Vector3) -> void:
	var id := placing.trim_prefix("def:")
	var user := _read_user(map_id)
	var spots: Array = user.get("_pickups", [])
	spots.append({"id": id, "x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01)})
	user["_pickups"] = spots
	_write_user(map_id, user)
	var main := get_tree().current_scene
	if main.multiplayer.is_server() and main.has_method("_spawn_pickup"):
		main._spawn_pickup(id, at, true, true)
	_say("Placed a %s pickup - saved; it is there every round" % id)


## An interior set (layout.json: room modules, furniture, at their spots):
## every piece is placed around `at`, turned by the current yaw, and saved
## as its own map edit. Room pieces get their real collision (you walk in).
func _place_set(map_id: String, at: Vector3) -> void:
	var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(placing))
	var base := placing.get_base_dir()
	var turn := Basis(Vector3.UP, deg_to_rad(_yaw))
	var n := 0
	for inst in lay.get("instances", []):
		var path := base.path_join(inst["model"]).simplify_path()
		if not ResourceLoader.exists(path):
			continue
		var p: Array = inst["position"]
		var w: Vector3 = at + turn * Vector3(p[0], 0, p[2])
		# the layout turns clockwise seen from above; Godot's yaw the other way
		var yaw: float = _yaw - float(inst.get("rotation_degrees", [0, 0, 0])[1])
		var m: Node3D = (load(path) as PackedScene).instantiate()
		get_tree().current_scene.add_child(m)
		m.global_position = w + Vector3(0, float(p[1]), 0)
		m.rotation.y = deg_to_rad(yaw)
		var room: bool = inst.get("category", "") in ["room", "ceiling", "wall", "facade"]
		_selectable(m, path)
		var entry := {"model": path, "x": snappedf(w.x, 0.01), "z": snappedf(w.z, 0.01), "yaw": yaw,
				"y_offset": float(p[1]), "solid": true if room else "box",
				"placed_in_game": Time.get_datetime_string_from_system()}
		_placed.append([m, entry, map_id])
		n += 1
	_save_props()
	_say("Placed the %s set (%d pieces) - saved; part of the map on the next rebuild" % [base.get_file(), n])


func _props_file(map_id: String) -> String:
	if _editor == null:
		_editor = MapEditor.new()
	return _editor.user_dir(map_id).path_join("buildings_user.json")


func _save_props() -> void:
	if _placed.is_empty():
		return
	var map_id: String = _placed[-1][2]
	var path := _props_file(map_id)
	var user := {}
	if FileAccess.file_exists(path):
		var d = JSON.parse_string(FileAccess.get_file_as_string(path))
		user = d if d is Dictionary else {}
	var props: Array = user.get("_props", [])
	# drop this session's entries, then write them as they are now
	var mine := _placed.filter(func(p): return p[2] == map_id).map(func(p): return p[1])
	props = props.filter(func(p): return not p.has("placed_in_game") or not mine.any(func(m): return m["placed_in_game"] == p["placed_in_game"] and m["model"] == p["model"]))
	props.append_array(mine)
	user["_props"] = props
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(user, " "))
	f.close()


func undo() -> void:
	if _placed.is_empty():
		return
	var last: Array = _placed.pop_back()
	(last[0] as Node3D).queue_free()
	var path := _props_file(last[2])
	var user = JSON.parse_string(FileAccess.get_file_as_string(path))
	if user is Dictionary:
		user["_props"] = user.get("_props", []).filter(func(p): return p.get("placed_in_game", "") != last[1]["placed_in_game"])
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(user, " "))
		f.close()
	_say("Removed")
