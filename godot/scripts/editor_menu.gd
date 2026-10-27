extends PanelContainer
## Design mode, top: the editor's menu bar - File (open another phase,
## rebuild this map, leave), Edit (undo, remove, select none), View (the
## palette and the inspector), Help (the editor's keys) - with the map's name
## and the last thing the editor did on the right.

const MapEditor := preload("res://scripts/map_editor.gd")
const Edits := preload("res://scripts/edits.gd")

var _status: Label
var _title: Label
var _help: AcceptDialog


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_right = 1.0
	offset_bottom = 40
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	style.border_color = Color(0.3, 0.85, 1.0)
	style.border_width_bottom = 2
	style.content_margin_left = 10
	style.content_margin_right = 14
	add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	add_child(row)
	var logo := Label.new()
	logo.text = "CITY INVADERS · EDITOR"
	logo.add_theme_font_size_override("font_size", 16)
	logo.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	row.add_child(logo)
	var bar := MenuBar.new()
	bar.flat = true
	bar.prefer_global_menu = false       # macOS would move it into the system menu bar
	row.add_child(bar)
	var file_items := [["Open phase", null], ["Save  (Ctrl+S)", save], ["Discard unsaved changes", _discard],
			["Share these edits as a mod...", func(): _main().share_mod()]]
	if Edits.has_sources():
		file_items.append(["Rebuild this map and restart", _rebuild])   # the map pipeline is here
	file_items += [["-", null], ["Leave design mode", func(): _main().toggle_design()]]
	_menu(bar, "File", file_items)
	_menu(bar, "Edit", [["Undo  (Ctrl+Z)", func(): _tools().undo()], ["Remove selected  (Del)", _remove_selected],
			["Select none  (Esc)", func(): _main().design_deselect()], ["Stop placing", func(): _tools().choose("")]])
	_menu(bar, "View", [["Palette", func(): _toggle(_tools())], ["Object Inspector", func(): _toggle(_main().inspector)]])
	_menu(bar, "Help", [["Editor keys and mouse", _show_help]])
	var file: PopupMenu = bar.get_child(0)
	var phases := PopupMenu.new()
	phases.name = "phases"
	for m in _main().available_maps():
		phases.add_item(m[1])
		phases.set_item_metadata(phases.item_count - 1, m[0])
	phases.id_pressed.connect(func(id): _main().edit_phase(phases.get_item_metadata(phases.get_item_index(id))))
	file.add_child(phases)
	file.set_item_submenu_node(0, phases)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 16)
	row.add_child(_title)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color(0.72, 0.75, 0.8))
	row.add_child(_status)
	visibility_changed.connect(_refresh_title)


func _main() -> Node:
	return get_tree().current_scene


func _tools() -> Node:
	return _main().editor_tools


func _menu(bar: MenuBar, title: String, items: Array) -> void:
	var pm := PopupMenu.new()
	pm.name = title
	pm.add_theme_font_size_override("font_size", 16)
	var actions := []
	for it in items:
		if it[0] == "-":
			pm.add_separator()
		else:
			pm.add_item(it[0])
		actions.append(it[1])
	pm.index_pressed.connect(func(i):
		if actions[i] is Callable:
			actions[i].call())
	bar.add_child(pm)


func _refresh_title() -> void:
	var id: String = _main().get("map_id")
	for m in _main().all_maps():
		if m[0] == id:
			_title.text = "·  " + m[1] + ("  *unsaved" if Edits.dirty(id) else "")


func _process(_delta: float) -> void:
	if visible and _title and Engine.get_process_frames() % 20 == 0:
		_refresh_title()


## File > Save: the map's edits go to its user/buildings_user.json.
func save() -> void:
	Edits.save(_main().map_id)
	set_status("Saved")
	_refresh_title()


## File > Discard: back to the saved edits (the phase reloads in design mode).
func _discard() -> void:
	var id: String = _main().map_id
	if not Edits.dirty(id):
		set_status("Nothing to discard")
		return
	Edits.discard(id)
	_main().edit_phase(id)


func set_status(t: String) -> void:
	_status.text = t


func _toggle(c: Control) -> void:
	if c:
		c.visible = not c.visible


func _remove_selected() -> void:
	var main := _main()
	var n := 0
	for s in main.design_selections:
		if _tools().remove_node(main.map_id, s.get("node"), s["what"]):
			n += 1
	set_status("Removed %d object(s)" % n)
	main.design_deselect()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S \
			and (event.ctrl_pressed or event.meta_pressed):
		save()
		get_viewport().set_input_as_handled()
		return
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode in [KEY_DELETE, KEY_BACKSPACE] and not get_viewport().gui_get_focus_owner() is LineEdit:
		_remove_selected()
		get_viewport().set_input_as_handled()


func _rebuild() -> void:
	var me: Node = _main().map_editor
	me.set("_map", _main().map_id)
	me.set("_sel", {})
	set_status("Rebuilding the map... (this takes a minute)")
	me._rebuild()


func _show_help() -> void:
	if _help == null:
		_help = AcceptDialog.new()
		_help.title = "Editor keys and mouse"
		_help.process_mode = Node.PROCESS_MODE_ALWAYS
		_help.dialog_text = "\n".join([
			"Fly: W A S D, Space up, Ctrl down, Shift faster",
			"The mouse moves a free crosshair; right drag or the arrow keys turn the view",
			"Mouse wheel: fly forward / back (Shift: faster)",
			"Click: pick what the crosshair is on  ·  Shift+click: add it to the selection (or take it out)",
			"Hold the click on the selected object and move the mouse: it slides over the ground (not onto the street, walls or roofs)",
			"Q / E: turn the selected object (or the one being placed)",
			"Palette: click a model, then click the world to place it; Q / E turn it; Esc stops",
			"Object Inspector: rename, move, raise and turn models placed by hand",
			"Del: remove the selection  ·  Ctrl+Z: undo the last placing  ·  Esc: stop, deselect, leave",
			"F1: talk to the AI assistant - everything selected goes along as reference",
			"Tab: lock the mouse to look around as in the game (and back)"])
		add_child(_help)
	_help.popup_centered()
