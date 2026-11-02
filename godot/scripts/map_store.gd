extends Node
## The Maps screen of a released game: lists the maps of this version's
## release (catalog.json, made by tools/build/map_packs.py), downloads the
## ones the player picks into user://map_packs/, checks each file's SHA-256
## and loads it at once (Packs.load_map_pack) - no restart. The macOS and
## Linux packages carry only the first phase; on Windows it adds maps the
## installer left out. Playing from the sources every map is already there.
##
## CITY_INVADERS_CATALOG=<url> reads another catalog (a local server, for
## testing); the files sit next to it.

signal changed

const RELEASES := "https://github.com/vgartner/city-invaders/releases/download/v%s/catalog.json"

var catalog: Array = []           # [{id, name, file, size, sha256}, ...]
var status := ""
var _base := ""
var _http: HTTPRequest
var _job := {}                    # the download in progress: {id, file, size, sha256}
var _panel: Control
var _list: VBoxContainer
var _status: Label


func catalog_url() -> String:
	var env := OS.get_environment("CITY_INVADERS_CATALOG")
	if env != "":
		return env
	return RELEASES % str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


static func installed(id: String) -> bool:
	return ResourceLoader.exists("res://city/%s.glb" % id)


## Fetch the catalog; `changed` fires when it is in (or failed).
func refresh() -> void:
	if _http != null:
		return
	var url := catalog_url()
	_base = url.substr(0, url.rfind("/") + 1)
	status = "Loading the list of maps..."
	changed.emit()
	_http = _request()
	_http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		_done_http()
		var data = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and code == 200 else null
		if data is Dictionary and data.get("maps") is Array:
			catalog = data["maps"]
			status = ""
		else:
			status = "No list of maps for this version (%s)." % ("HTTP %d" % code if code else "no connection")
		changed.emit())
	_http.request(url)


## Download, check and load one map; `changed` fires as it goes.
func download(id: String) -> void:
	if _http != null:
		return
	var entry: Dictionary = {}
	for m in catalog:
		if m.get("id") == id:
			entry = m
	if entry.is_empty() or installed(id):
		return
	DirAccess.make_dir_recursive_absolute(Packs.USER_DIR)
	_job = entry
	_http = _request()
	_http.download_file = Packs.USER_DIR.path_join(String(entry["file"]) + ".part")
	_http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray):
		var part: String = _http.download_file
		_done_http()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			DirAccess.remove_absolute(part)
			_finish("Download failed (%s)." % ("HTTP %d" % code if code else "no connection"))
			return
		status = "Checking %s..." % entry["name"]
		changed.emit()
		await get_tree().process_frame
		if _sha256(part) != String(entry["sha256"]):
			DirAccess.remove_absolute(part)
			_finish("%s arrived damaged - try again." % entry["name"])
			return
		var path := part.trim_suffix(".part")
		DirAccess.rename_absolute(part, path)
		if Packs.load_map_pack(path):
			_finish("%s installed." % entry["name"])
		else:
			DirAccess.remove_absolute(path)
			_finish("%s could not be loaded." % entry["name"]))
	_http.request(_base + String(entry["file"]))
	changed.emit()


## 0..1 of the download in progress, or -1.
func progress() -> float:
	if _http == null or _job.is_empty():
		return -1.0
	return clampf(float(_http.get_downloaded_bytes()) / maxf(1.0, float(_job["size"])), 0.0, 1.0)


func busy_id() -> String:
	return String(_job.get("id", ""))


func _finish(text: String) -> void:
	_job = {}
	status = text
	changed.emit()


func _request() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.use_threads = true
	h.max_redirects = 8          # release files redirect to GitHub's storage
	h.timeout = 0.0
	add_child(h)
	return h


func _done_http() -> void:
	_http.queue_free()
	_http = null


static func _sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()


func _process(_dt: float) -> void:
	if _panel and _panel.visible and not _job.is_empty():
		_update_rows()


# ---- the screen ----------------------------------------------------------

## Show the Maps screen over `parent` (the menu); `on_installed` runs after a
## map is added, so the menu lists it.
func show_screen(parent: Control, on_installed: Callable) -> void:
	if _panel == null:
		_build(parent, on_installed)
	_panel.visible = true
	if FileAccess.file_exists("res://project.godot"):
		status = "Playing from the sources: every map is already here."
		_fill()
	elif catalog.is_empty():
		refresh()
	else:
		_fill()


func _build(parent: Control, on_installed: Callable) -> void:
	_panel = CenterContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(_panel)
	var pc := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.04, 0.05, 0.07, 0.97)
	st.set_corner_radius_all(12)
	st.set_content_margin_all(22)
	st.border_color = Color(0.85, 0.2, 0.15, 0.9)
	st.set_border_width_all(2)
	pc.add_theme_stylebox_override("panel", st)
	_panel.add_child(pc)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(760, 420)
	box.add_theme_constant_override("separation", 12)
	pc.add_child(box)
	var title := Label.new()
	title.text = "Maps"
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	var how := Label.new()
	how.text = "Each map is a download of its own; it is checked and ready to play at once."
	how.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(how)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
	box.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(140, 44)
	close.pressed.connect(func(): _panel.visible = false)
	row.add_child(close)
	changed.connect(func():
		if status.ends_with(" installed."):
			on_installed.call()
		_fill())


func _fill() -> void:
	_status.text = status
	for c in _list.get_children():
		c.queue_free()
	for m in catalog:
		var line := HBoxContainer.new()
		line.set_meta("id", m["id"])
		line.add_theme_constant_override("separation", 12)
		var lbl := Label.new()
		lbl.text = "%s   (%d MB)" % [m["name"], roundi(float(m["size"]) / 1048576.0)]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 22)
		line.add_child(lbl)
		var bar := ProgressBar.new()
		bar.name = "Bar"
		bar.custom_minimum_size = Vector2(180, 0)
		bar.max_value = 1.0
		bar.visible = false
		line.add_child(bar)
		var b := Button.new()
		b.name = "Get"
		b.custom_minimum_size = Vector2(150, 40)
		var id: String = m["id"]
		b.pressed.connect(func(): download(id))
		line.add_child(b)
		_list.add_child(line)
	_update_rows()


func _update_rows() -> void:
	for line in _list.get_children():
		var id: String = line.get_meta("id", "")
		var b: Button = line.get_node("Get")
		var bar: ProgressBar = line.get_node("Bar")
		var here := installed(id)
		var mine := busy_id() == id
		bar.visible = mine
		if mine:
			bar.value = progress()
		b.text = "Installed" if here else ("Downloading" if mine else "Download")
		b.disabled = here or _http != null
