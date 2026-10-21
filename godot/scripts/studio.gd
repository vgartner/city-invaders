extends PanelContainer
## City Invaders Studio (from the title screen): work on cities rather than
## play them. Lists the cities and their phases; imports a new city
## (tools/map/new_city.py), rebuilds a phase map from its data and edits, and
## opens a phase for editing: the game starts there without robots, in
## design mode, so the in-game editor works on that phase.

const MapEditor := preload("res://scripts/map_editor.gd")
const Entities := preload("res://scripts/entities.gd")

signal closed
signal edit_phase(map_id: String)

var _cities: ItemList
var _phases: ItemList
var _info: Label
var _status: Label
var _city: LineEdit
var _title: LineEdit
var _size: SpinBox
var _phase_n: SpinBox
var _pid := -1
var _log_path := ""
var _log_cd := 0.0
var _then := ""                   # what the running job was ("import", "rebuild")
var _opts: AcceptDialog            # the import window: which objects the new city uses
var _opt_collection: OptionButton
var _opt_roles := {}               # role -> OptionButton
var _opt_film: OptionButton
var _opt_places := {}              # place kind -> CheckBox
var _opt_photos: CheckBox


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 1.0)
	style.set_content_margin_all(0)
	add_theme_stylebox_override("panel", style)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	# the menu bar: open a city, import one from OpenStreetMap, generate one
	var bar_panel := PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.04, 0.05, 0.07)
	bs.border_color = Color(0.3, 0.85, 1.0)
	bs.border_width_bottom = 2
	bs.content_margin_left = 16
	bs.content_margin_right = 16
	bar_panel.add_theme_stylebox_override("panel", bs)
	root.add_child(bar_panel)
	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 24)
	bar_panel.add_child(bar_row)
	var logo := _label("CITY INVADERS · STUDIO", 26)
	logo.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	bar_row.add_child(logo)
	var bar := MenuBar.new()
	bar.flat = true
	bar.prefer_global_menu = false
	bar.add_theme_font_size_override("font_size", 24)
	bar_row.add_child(bar)
	_file_menu = PopupMenu.new()
	_file_menu.name = "File"
	_file_menu.add_theme_font_size_override("font_size", 22)
	bar.add_child(_file_menu)
	_open_menu = PopupMenu.new()
	_open_menu.name = "open"
	_open_menu.add_theme_font_size_override("font_size", 22)
	_open_menu.index_pressed.connect(_open_city)
	_file_menu.add_child(_open_menu)
	_file_menu.add_submenu_node_item("Open city", _open_menu)
	_file_menu.add_separator()
	_file_menu.add_item("Import a city from OpenStreetMap...")
	_file_menu.add_item("Generate a city...")
	_file_menu.add_separator()
	_file_menu.add_item("Back to the title screen")
	_file_menu.index_pressed.connect(_file_pick)
	_city_title = _label("", 24)
	_city_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	bar_row.add_child(_city_title)
	_status = _label("", 22)
	_status.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.autowrap_mode = TextServer.AUTOWRAP_OFF
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar_row.add_child(_status)
	# the body: empty until a city is opened
	var body := MarginContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		body.add_theme_constant_override("margin_" + side, 28)
	root.add_child(body)
	_welcome = _label("Open a city from the File menu, import one from OpenStreetMap, or generate one.", 30)
	_welcome.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
	_welcome.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_welcome.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	body.add_child(_welcome)
	_city_view = HBoxContainer.new()
	_city_view.add_theme_constant_override("separation", 24)
	_city_view.visible = false
	body.add_child(_city_view)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(620, 0)
	left.add_child(_label("Phases", 35))
	_cities = ItemList.new()             # kept for the city list (hidden; the menu opens cities)
	_cities.visible = false
	left.add_child(_cities)
	_phases = ItemList.new()
	_phases.custom_minimum_size = Vector2(0, 420)
	_phases.add_theme_font_size_override("font_size", 30)
	_phases.item_selected.connect(func(_i): _show_info())
	left.add_child(_phases)
	_city_view.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	_info = _label("", 27)
	_info.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	right.add_child(_info)
	var row := HBoxContainer.new()
	_button("Edit this phase", _edit, row)
	_button("Rebuild this phase", _rebuild, row)
	_button("Open its folder", _open_folder, row)
	right.add_child(row)
	_city_view.add_child(right)
	# the import form lives in a dialog now (File > Import)
	_city = LineEdit.new()
	_title = LineEdit.new()
	_size = SpinBox.new()
	_phase_n = SpinBox.new()
	refresh()


func _file_pick(i: int) -> void:
	var t := _file_menu.get_item_text(i)
	if t.begins_with("Import"):
		_import_dialog()
	elif t.begins_with("Generate"):
		_generate_dialog()
	elif t.begins_with("Back"):
		closed.emit()


var _file_menu: PopupMenu
var _open_menu: PopupMenu
var _welcome: Label
var _city_view: HBoxContainer
var _city_title: Label
var _form: AcceptDialog
var _gen_mode := false


func _open_city(i: int) -> void:
	_cities.select(i)
	_fill_phases()
	_welcome.visible = false
	_city_view.visible = true
	_city_title.text = "·  " + _cities.get_item_text(i)


## File > Import: where, the menu name, map size and phases; then the
## window with what the new city uses (collection, items, film...).
func _import_dialog() -> void:
	_gen_mode = false
	_form_dialog("Import a city from OpenStreetMap", [
		["Place", "e.g. \"Pelotas, Centro\" or \"Altstadt, Bielefeld\"", _city],
		["Name in the menu", "optional, e.g. Pelotas", _title]])


## File > Generate: a made-up town (tools/map/gen_city.py) - streets, a square,
## a park, buildings, shops and a fuel station - built like an import.
func _generate_dialog() -> void:
	_gen_mode = true
	_form_dialog("Generate a city", [["Name", "e.g. Vila Querência", _title]])


func _form_dialog(title: String, fields: Array) -> void:
	if _form:
		_form.queue_free()
	_form = AcceptDialog.new()
	_form.title = title
	_form.ok_button_text = "Next"
	_form.add_cancel_button("Cancel")
	add_child(_form)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_form.add_child(box)
	for f in fields:
		box.add_child(_label(f[0], 22))
		var le: LineEdit = f[2]
		if le.get_parent():
			le.get_parent().remove_child(le)
		le.placeholder_text = f[1]
		le.custom_minimum_size = Vector2(620, 0)
		le.add_theme_font_size_override("font_size", 22)
		box.add_child(le)
	var r := HBoxContainer.new()
	r.add_child(_label("map size (m)", 22))
	if _size.get_parent():
		_size.get_parent().remove_child(_size)
	_size.min_value = 200
	_size.max_value = 800
	_size.step = 50
	_size.value = 400
	r.add_child(_size)
	r.add_child(_label("   phases", 22))
	if _phase_n.get_parent():
		_phase_n.get_parent().remove_child(_phase_n)
	_phase_n.min_value = 1
	_phase_n.max_value = 4
	_phase_n.value = 1 if _gen_mode else 2
	r.add_child(_phase_n)
	box.add_child(r)
	_form.confirmed.connect(func():
		if _gen_mode:
			if _title.text.strip_edges() == "":
				_title.text = "Vila Nova"
			_city.text = _title.text
		_import())
	_form.popup_centered()


func _label(t: String, size: int) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	if t.length() > 30 or t == "":
		l.autowrap_mode = TextServer.AUTOWRAP_WORD     # short labels stay on one line
	return l


func _button(t: String, cb: Callable, parent: Node) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 28)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func refresh() -> void:
	_cities.clear()
	_open_menu.clear()
	for c in get_tree().current_scene.available_cities():
		_cities.add_item(c[0])
		_open_menu.add_item(c[0])
	if _city_view.visible and _cities.item_count > 0:
		var keep := _city_title.text.trim_prefix("·  ")
		for i in _cities.item_count:
			if _cities.get_item_text(i) == keep:
				_cities.select(i)
		_fill_phases()


func _city_phases() -> Array:
	var cs: Array = get_tree().current_scene.available_cities()
	var sel := _cities.get_selected_items()
	return cs[sel[0]][1] if not sel.is_empty() and sel[0] < cs.size() else []


func _fill_phases() -> void:
	_phases.clear()
	for p in _city_phases():
		_phases.add_item(String(p[1]))
	if _phases.item_count > 0:
		_phases.select(0)
	_show_info()


func _selected_phase() -> String:
	var ph := _city_phases()
	var sel := _phases.get_selected_items()
	return ph[sel[0]][0] if not sel.is_empty() and sel[0] < ph.size() else ""


func _show_info() -> void:
	var id := _selected_phase()
	if id == "":
		_info.text = ""
		return
	var repo: String = MapEditor.new().repo_dir()
	var cfg := repo.path_join("maps/%s/build.json" % id)
	var c = JSON.parse_string(FileAccess.get_file_as_string(cfg)) if FileAccess.file_exists(cfg) else {}
	var n_bld := 0
	if FileAccess.file_exists("res://city/%s.buildings.json" % id):
		n_bld = JSON.parse_string(FileAccess.get_file_as_string("res://city/%s.buildings.json" % id)).size()
	var films: PackedStringArray = get_tree().current_scene.city_films(id)
	var b: Array = c.get("bounds", []) if c is Dictionary else []
	_info.text = "Map: %s\nArea: %s\nBuildings: %d\nFilms: %s\nEdits: %s" % [id,
			("%d x %d m" % [b[2] - b[0], b[3] - b[1]]) if b.size() == 4 else "-", n_bld,
			", ".join(Array(films).map(func(f): return f.get_file())) if films.size() > 0 else "none",
			c.get("user", "maps/%s/user" % id) if c is Dictionary else "-"]


func _edit() -> void:
	var id := _selected_phase()
	if id != "":
		edit_phase.emit(id)


func _open_folder() -> void:
	var id := _selected_phase()
	if id != "":
		OS.shell_open(MapEditor.new().repo_dir().path_join("maps/" + id))


func _run(job: String, args: String) -> void:
	if _pid > 0:
		return
	var repo: String = MapEditor.new().repo_dir()
	_log_path = repo.path_join("maps/%s_%d.log" % [job, Time.get_unix_time_from_system()])
	var cmd := "cd '%s' && %s > '%s' 2>&1" % [repo, args, _log_path]
	_pid = OS.create_process("/bin/sh", ["-c", cmd])
	_then = job


## Import: first a window with what the new city will use - its collection,
## the item for each role, the opening film, the kinds of places that get
## their models, facade photos - the defaults already chosen.
func _import() -> void:
	var place := _city.text.strip_edges()
	if place == "":
		return
	_build_options(place)
	_opts.popup_centered(Vector2i(900, 760))


func _start_import() -> void:
	var place := _city.text.strip_edges().replace("'", "")
	var title := _title.text.strip_edges().replace("'", "")
	var setup := {"_collection": _opt_collection.get_item_metadata(_opt_collection.selected), "_roles": {},
			"_place_kinds_off": [], "intro": _opt_film.get_item_metadata(_opt_film.selected)}
	for r in _opt_roles:
		var ob: OptionButton = _opt_roles[r]
		var id: String = ob.get_item_metadata(ob.selected)
		if id != "":
			setup["_roles"][r] = id
	for k in _opt_places:
		if not (_opt_places[k] as CheckBox).button_pressed:
			setup["_place_kinds_off"].append(k)
	var repo: String = MapEditor.new().repo_dir()
	var setup_path := repo.path_join("maps/import_setup_%d.json" % Time.get_unix_time_from_system())
	var f := FileAccess.open(setup_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(setup, " "))
	f.close()
	if _gen_mode:
		var gen := repo.path_join("maps/generated_%d.json" % Time.get_unix_time_from_system())
		var total := int(_size.value) * int(_phase_n.value)
		_run("import", "tools/.venv/bin/python tools/map/gen_city.py '%s' --size %d --seed %d && tools/.venv/bin/python tools/map/new_city.py '%s' --size %d --phases %d --title '%s' --osm-file '%s' --setup '%s'" % [
				gen, total, randi() % 100000, place, int(_size.value), int(_phase_n.value), place, gen, setup_path])
		_status.text = "Generating %s ..." % place
		return
	_run("import", "tools/.venv/bin/python tools/map/new_city.py '%s' --size %d --phases %d%s%s --setup '%s'" % [
			place, int(_size.value), int(_phase_n.value), (" --title '%s'" % title) if title != "" else "",
			"" if _opt_photos.button_pressed else " --no-photos", setup_path])
	_status.text = "Importing %s ..." % place


func _build_options(place: String) -> void:
	if _opts == null:
		_opts = AcceptDialog.new()
		_opts.title = "Import a new city: what it uses"
		_opts.ok_button_text = "Import"
		_opts.add_cancel_button("Cancel")
		_opts.confirmed.connect(_start_import)
		add_child(_opts)
	for c in _opts.get_children():
		if c is ScrollContainer:
			c.queue_free()
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(860, 640)
	_opts.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	box.add_child(_label("%s" % place, 28))
	# the collection: Rio Grande do Sul's for a town there, the common one elsewhere
	box.add_child(_label("Collection (models, items, music)", 24))
	_opt_collection = OptionButton.new()
	var gaucho: bool = place.to_lower().contains("rs") or place.to_lower().contains("rio grande do sul")
	for c in DirAccess.get_directories_at("res://assets"):
		if FileAccess.file_exists("res://assets/%s/roles.json" % c):
			_opt_collection.add_item(c.replace("_", " ").capitalize())
			_opt_collection.set_item_metadata(_opt_collection.item_count - 1, c)
			if (c == "rio_grande_do_sul") == gaucho:
				_opt_collection.select(_opt_collection.item_count - 1)
	_opt_collection.item_selected.connect(func(_i): _fill_roles())
	box.add_child(_opt_collection)
	box.add_child(_label("Items for each role", 24))
	_opt_roles = {}
	for r in Entities.role_names():
		var row := HBoxContainer.new()
		var l := _label(r.replace("_", " ").capitalize(), 20)
		l.custom_minimum_size = Vector2(220, 0)
		row.add_child(l)
		var ob := OptionButton.new()
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ob)
		_opt_roles[r] = ob
		box.add_child(row)
	_fill_roles()
	box.add_child(_label("Opening film (cutscene)", 24))
	_opt_film = OptionButton.new()
	_opt_film.add_item("None (the city opens straight away)")
	_opt_film.set_item_metadata(0, "")
	var stack := ["res://assets/rio_grande_do_sul/video"]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(d):
			stack.append(d.path_join(sub))
		for fn in DirAccess.get_files_at(d):
			var n := fn.trim_suffix(".remap").trim_suffix(".import")
			if n.ends_with(".ogv"):
				_opt_film.add_item(d.trim_prefix("res://assets/rio_grande_do_sul/video/").path_join(n))
				_opt_film.set_item_metadata(_opt_film.item_count - 1, d.path_join(n))
	box.add_child(_opt_film)
	box.add_child(_label("Places that get their models and items (place_kinds.json)", 24))
	_opt_places = {}
	var kinds: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/place_kinds.json")) \
			if FileAccess.file_exists("res://assets/place_kinds.json") else {}
	var grid := GridContainer.new()
	grid.columns = 3
	for k in kinds:
		if String(k).begins_with("_"):
			continue
		var cb := CheckBox.new()
		cb.text = kinds[k].get("label", k)
		cb.button_pressed = true
		cb.add_theme_font_size_override("font_size", 20)
		grid.add_child(cb)
		_opt_places[k] = cb
	box.add_child(grid)
	_opt_photos = CheckBox.new()
	_opt_photos.text = "Facade photos from Mapillary (slower; procedural painted facades without)"
	_opt_photos.button_pressed = true
	_opt_photos.add_theme_font_size_override("font_size", 20)
	_opt_photos.visible = not _gen_mode        # a generated town has no photos
	box.add_child(_opt_photos)


## The role choices follow the chosen collection: its roles.json is the default.
func _fill_roles() -> void:
	var col: String = _opt_collection.get_item_metadata(_opt_collection.selected) if _opt_collection.item_count > 0 else "common"
	for r in _opt_roles:
		var ob: OptionButton = _opt_roles[r]
		ob.clear()
		ob.add_item("default: %s" % Entities.role(col, r))
		ob.set_item_metadata(0, "")
		for id in Entities.role_candidates(r):
			var d := Entities.get_def(id)
			ob.add_item("%s (%s)" % [d.get("name", id), id])
			ob.set_item_metadata(ob.item_count - 1, id)


func _rebuild() -> void:
	var id := _selected_phase()
	if id == "":
		return
	_run("rebuild", "tools/.venv/bin/python tools/map/building_photo.py rebuild %s && godot --headless --path godot --import" % id)
	_status.text = "Rebuilding %s ..." % id


func _process(delta: float) -> void:
	if _pid <= 0:
		return
	_log_cd -= delta
	if _log_cd > 0:
		return
	_log_cd = 1.0
	var text := FileAccess.get_file_as_string(_log_path) if FileAccess.file_exists(_log_path) else ""
	var lines := Array(text.split("\n")).filter(func(l): return l.strip_edges() != "")
	if OS.is_process_running(_pid):
		_status.text = "%s...\n%s" % [_then.capitalize(), String(lines[-1]).trim_prefix("[new_city] ").left(160) if lines.size() > 0 else "starting"]
		return
	_pid = -1
	var ok := text.contains("done:") if _then == "import" else text.contains(".glb:")
	_status.text = ("%s finished. Restart the game to load the new maps." % _then.capitalize()) if ok \
			else "%s failed - see %s" % [_then.capitalize(), _log_path.get_file()]
	refresh()
