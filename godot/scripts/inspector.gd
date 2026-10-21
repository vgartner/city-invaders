extends PanelContainer
## Design mode, right dock: the Object Inspector (after Delphi's). Nothing
## selected: the map itself - which item plays each role here, the bus line
## for new stops, what the map's user edits hold. One object: its
## properties (kind, model, definition, position, turn, size); a model placed
## by hand can be renamed, moved, raised and turned here, saved to the map's
## user edits. Several objects (Shift+click): the list, remove them together;
## F1 sends them all to Claude as references.

const Entities := preload("res://scripts/entities.gd")
const Photos := preload("res://scripts/photos.gd")
const Edits := preload("res://scripts/edits.gd")
const YELLOW := Color(1.0, 0.85, 0.1)
const DIM := Color(0.72, 0.75, 0.8)

var tools: Node                    # editor_tools.gd (saving, removing)
var _box: VBoxContainer
var _sels: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -400
	offset_right = 0
	offset_top = 40
	offset_bottom = -96
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.92)
	style.border_color = YELLOW
	style.border_width_left = 2
	style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 5)
	scroll.add_child(_box)
	show_selection([])


func _main() -> Node:
	return get_tree().current_scene


## Main: the selection changed. Each entry: {what, name, detail, pos, node}.
func show_selection(sels: Array) -> void:
	_sels = sels
	for c in _box.get_children():
		c.queue_free()
	_heading("OBJECT INSPECTOR")
	if sels.is_empty():
		_map_page()
	elif sels.size() == 1 and sels[0]["what"] == "photo":
		_photo_page(sels[0])
	elif sels.size() == 1:
		_object_page(sels[0])
	else:
		_many_page(sels)


# ---- pages ------------------------------------------------------------------

func _map_page() -> void:
	var main := _main()
	var map_id: String = main.get("map_id")
	var label := map_id
	for m in main.all_maps():
		if m[0] == map_id:
			label = m[1]
	_section("Map")
	_row("Name", label)
	_row("Id", map_id)
	_row("Collection", str(main.get("collection")))
	var user: Dictionary = tools._read_user(map_id) if tools else {}
	_row("Placed models", str(user.get("_props", []).size()))
	_row("Item spots", str(user.get("_pickups", []).size()))
	_row("Removed objects", str(user.get("_remove", []).size()))
	_section("Items on this map")
	var chosen: Dictionary = user.get("_roles", {})
	for r in Entities.role_names():
		var ob := OptionButton.new()
		ob.add_item("default (%s)" % Entities.role(main.get("collection"), r))
		ob.set_item_metadata(0, "")
		for id in Entities.role_candidates(r):
			ob.add_item(id)
			ob.set_item_metadata(ob.item_count - 1, id)
			if id == chosen.get(r, ""):
				ob.select(ob.item_count - 1)
		ob.item_selected.connect(func(i): tools.set_role(r, ob.get_item_metadata(i)))
		_row_control(r.replace("_", " ").capitalize(), ob)
	_section("Bus lines")
	var sb := SpinBox.new()
	sb.min_value = 1
	sb.max_value = 9
	sb.value = tools.bus_line if tools else 1
	sb.value_changed.connect(func(v): tools.bus_line = int(v))
	_row_control("Line for new stops", sb)
	var lines: Array = main.get("road_graph").get("lines", [])
	_row("Designed lines", str(lines.size()) if not lines.is_empty() else "none (one round of all stops)")
	if Edits.runtime():
		_hint("Edits are kept in your game folder and applied by the game. Building heights and paving need the map pipeline (the source version).")
	_hint("Click an object to inspect it  ·  Shift+click adds more  ·  F1 sends the selection to Claude")


func _object_page(s: Dictionary) -> void:
	var node: Node3D = s.get("node")
	var what: String = s["what"]
	var main := _main()
	var map_id: String = main.get("map_id")
	_section(what.capitalize())
	var lm: Dictionary = node.get_meta("landmark", {}) if node else {}
	var placed := not lm.is_empty() and String(lm.get("id", "")) == "prop"
	var entry: Dictionary = tools.prop_entry(map_id, node) if placed else {}
	var model: String = lm.get("model", "")
	if what == "pickup" and node:
		model = String(Entities.get_def(str(node.get("kind"))).get("model", ""))
	var def: Dictionary = Entities.of_model(model) if model != "" else {}
	if what == "pickup" and node:
		def = Entities.get_def(str(node.get("kind")))
	# name: placed models take a name of their own
	if placed:
		var le := LineEdit.new()
		le.text = String(entry.get("label", ""))
		le.placeholder_text = String(def.get("name", model.get_file().get_basename()))
		le.text_changed.connect(func(t): tools.update_prop(map_id, node, {"label": t}))
		_row_control("Name", le)
	else:
		_row("Name", s["name"] if s["name"] != "" else "-")
	if s.get("detail", "") != "":
		_row("Detail", s["detail"])
	if model != "":
		_row("Model", model.trim_prefix("res://assets/"))
	if not def.is_empty():
		_section("Definition")
		_row("Id", def.get("id", ""))
		if def.has("name"):
			_row("Called", def["name"])
		_row("Type", " > ".join(def.get("types", [])))
		if def.has("category"):
			_row("Category", def["category"])
		if not def.get("tags", []).is_empty():
			_row("Tags", ", ".join(def["tags"]))
		if def.has("effect"):
			_row("Effect", JSON.stringify(def["effect"]))
		if def.has("sound"):
			_row("Sound", JSON.stringify(def["sound"]))
	if node and what in ["robot", "pedestrian", "vehicle"]:
		_section("State")
		for k in ["variant", "health", "state", "kind"]:
			var v = node.get(k)
			if v != null:
				_row(k.capitalize(), str(v))
	_section("Transform")
	var p: Vector3 = node.global_position if node else s["pos"]
	if placed:
		_spin("X (east)", p.x, func(v): tools.update_prop(map_id, node, {"x": snappedf(v, 0.01)}))
		_spin("Z (south)", p.z, func(v): tools.update_prop(map_id, node, {"z": snappedf(v, 0.01)}))
		_spin("Height offset", float(entry.get("y_offset", 0.0)), func(v): tools.update_prop(map_id, node, {"y_offset": snappedf(v, 0.01)}), 0.05)
		_spin("Turn (°)", float(entry.get("yaw", rad_to_deg(node.rotation.y))), func(v): tools.update_prop(map_id, node, {"yaw": v}), 5.0)
		if entry.has("line"):
			_spin("Bus line", float(entry["line"]), func(v):
				tools.update_prop(map_id, node, {"line": int(v)})
				main.refresh_bus_stops(), 1.0)
	else:
		_row("Position", "%.2f, %.2f, %.2f" % [p.x, p.y, p.z])
		if node:
			_row("Turn (°)", "%.0f" % rad_to_deg(node.global_rotation.y))
	if node:
		var box := AABB()
		var first := true
		for mi in node.find_children("*", "MeshInstance3D", true, false):
			var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
		if not first:
			_row("Size (m)", "%.1f × %.1f × %.1f" % [box.size.x, box.size.y, box.size.z])
	_section("Actions")
	if node:
		_action("Fly to it", func(): _fly_to(node.global_position))
	if what in ["prop", "object", "pickup"]:
		_action("Remove this object", func(): _remove([s]))
	if what == "ground" and (String(s["name"]).begins_with("paving") or String(s["name"]).begins_with("plaza")):
		_action("Make this paving asphalt", func(): tools.asphalt_selected())
	if not placed and what in ["prop", "object"]:
		_hint("Generated from OpenStreetMap: it can be removed; to move it, remove it and place a model by hand.")


## A photo on a wall: slide it along the wall and up, size it, turn it,
## fit it over the whole side of the building, or change its picture.
func _photo_page(s: Dictionary) -> void:
	var main := _main()
	var map_id: String = main.get("map_id")
	var id: String = s["detail"]
	var p := Photos.entry(map_id, id)
	if p.is_empty():
		_hint("This photo is gone.")
		return
	_section("Photo on a wall")
	_row("Picture", String(p["image"]).get_file())
	if p.get("building", "") != "":
		_row("Building", p["building"])
	var keep := CheckBox.new()
	keep.text = "keep the picture's proportions"
	keep.button_pressed = true
	_box.add_child(keep)
	var aspect := Photos.aspect(map_id, p)
	var set_fields := func(f: Dictionary): Photos.update(main, map_id, id, f)
	_section("Place")
	var slide := [0.0]                          # how far it was slid along the wall so far
	_spin("Along the wall (m)", 0.0, func(v):
		var e := Photos.entry(map_id, id)
		var b := Photos.basis_of(e)
		var c: Vector3 = Vector3(e["pos"][0], e["pos"][1], e["pos"][2]) + b.x * (float(v) - float(slide[0]))
		slide[0] = v
		set_fields.call({"pos": [c.x, c.y, c.z]}), 0.1)
	_spin("Centre height (m)", float(p["pos"][1]), func(v):
		var e := Photos.entry(map_id, id)
		set_fields.call({"pos": [e["pos"][0], v, e["pos"][2]]}), 0.1)
	_spin("Out from the wall (m)", float(p.get("out", 0.06)), func(v): set_fields.call({"out": clampf(v, 0.01, 2.0)}), 0.01)
	_section("Size and turn")
	var hs := [null]
	_spin("Width (m)", float(p["w"]), func(v):
		var f := {"w": maxf(v, 0.2)}
		if keep.button_pressed:
			f["h"] = maxf(v, 0.2) * aspect
			if hs[0]:
				hs[0].set_value_no_signal(f["h"])
		set_fields.call(f), 0.1)
	hs[0] = _spin("Height (m)", float(p["h"]), func(v): set_fields.call({"h": maxf(v, 0.2)}), 0.1)
	_spin("Turn on the wall (°)", float(p.get("roll", 0.0)), func(v): set_fields.call({"roll": v}), 1.0)
	_section("Actions")
	_action("Fit over this side of the building", func():
		var e := Photos.entry(map_id, id)
		var wall: Dictionary = main.map_editor.wall_at(map_id, Vector3(e["pos"][0], e["pos"][1], e["pos"][2]) - Photos.basis_of(e).z * 0.5)
		if wall.is_empty():
			tools._say("No building side found behind this photo")
			return
		set_fields.call({"wall": wall})
		show_selection(_sels))
	_action("Use the picture's proportions", func():
		var e := Photos.entry(map_id, id)
		set_fields.call({"h": float(e["w"]) * aspect})
		show_selection(_sels))
	_action("Change the picture...", func(): _replace_photo(map_id, id))
	_action("Fly to it", func(): _fly_to(Photos.node(id).global_position if Photos.node(id) else s["pos"]))
	_action("Remove this photo", func():
		Photos.remove(map_id, id)
		main.design_deselect())
	_hint("The photo shows at once and stays (in the map's edits). Several photos can cover one facade, side by side.")


func _replace_photo(map_id: String, id: String) -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = PackedStringArray(["*.jpg, *.jpeg, *.png, *.webp ; Photos"])
	dlg.file_selected.connect(func(path):
		var rel := Photos.copy_image(map_id, path, id)
		if rel != "":
			Photos.update(_main(), map_id, id, {"image": rel})
			for e in _main().design_selections:
				if e["what"] == "photo" and e["detail"] == id:
					e["node"] = Photos.node(id)
			_main()._show_selection())
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _many_page(sels: Array) -> void:
	_section("%d objects selected" % sels.size())
	for s in sels:
		var p: Vector3 = s["pos"]
		_row(String(s["what"]).capitalize(), "%s  (%.0f, %.0f, %.0f)" % [s["detail"] if s["detail"] != "" else s["name"], p.x, p.y, p.z])
	var removable := sels.filter(func(s): return s["what"] in ["prop", "object", "pickup", "photo"])
	_section("Actions")
	if not removable.is_empty():
		_action("Remove %d objects" % removable.size(), func(): _remove(removable))
	_action("Clear the selection", func(): _main().design_deselect())
	_hint("F1: talk to Claude about these %d objects" % sels.size())


func _remove(sels: Array) -> void:
	var n := 0
	for s in sels:
		if tools.remove_node(_main().get("map_id"), s.get("node"), s["what"]):
			n += 1
	tools._say("Removed %d object(s) - kept out of the map from the next rebuild" % n)
	_main().design_deselect()


func _fly_to(at: Vector3) -> void:
	var p: Node3D = _main()._local_player()
	if p == null:
		return
	var back := (p.global_position - at)
	back.y = 0
	back = back.normalized() * 6.0 if back.length() > 0.1 else Vector3(0, 0, 6)
	p.global_position = at + back + Vector3(0, 3, 0)
	p.look_at(Vector3(at.x, p.global_position.y, at.z), Vector3.UP)
	p.pitch = -0.4
	p.head.rotation.x = p.pitch


# ---- building blocks --------------------------------------------------------

func _heading(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 20)
	_box.add_child(l)


func _section(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", YELLOW)
	_box.add_child(HSeparator.new())
	_box.add_child(l)


func _row(key: String, value: String) -> void:
	var v := Label.new()
	v.text = value
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_theme_font_size_override("font_size", 14)
	_row_control(key, v)


func _row_control(key: String, c: Control) -> void:
	var row := HBoxContainer.new()
	var k := Label.new()
	k.text = key
	k.custom_minimum_size = Vector2(130, 0)
	k.add_theme_font_size_override("font_size", 14)
	k.add_theme_color_override("font_color", DIM)
	row.add_child(k)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(c)
	_box.add_child(row)


func _spin(key: String, value: float, cb: Callable, step := 0.1) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = -5000
	sb.max_value = 5000
	sb.step = step
	sb.value = value
	sb.value_changed.connect(cb)
	_row_control(key, sb)
	return sb


func _action(t: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = t
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(cb)
	_box.add_child(b)


func _hint(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", DIM)
	_box.add_child(l)
