extends Control
## Key binding screen (main menu and pause menu): one row per action; click a
## key, then press the new one (Esc cancels). Bindings live in Settings.

signal closed

var _rows := {}           # action -> Button
var _waiting := ""
var _hint: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.7)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.92)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(30)
	style.border_color = Color(0.85, 0.2, 0.15, 0.9)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Controls"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(1.0, 0.32, 0.22))
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	for a in Settings.ACTIONS:
		var l := Label.new()
		l.text = Settings.ACTIONS[a][0]
		l.add_theme_font_size_override("font_size", 24)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
		var b := Button.new()
		b.custom_minimum_size = Vector2(220, 44)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(_listen.bind(a))
		grid.add_child(b)
		_rows[a] = b
	var fixed := Label.new()
	fixed.text = "Mouse: look · Left click: shoot · Wheel: switch weapon · Esc: pause"
	fixed.add_theme_font_size_override("font_size", 18)
	fixed.add_theme_color_override("font_color", Color(0.7, 0.73, 0.78))
	fixed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(fixed)
	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	box.add_child(_hint)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)
	for spec in [["Reset to defaults", Settings.reset_keys], ["Back", _close]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(240, 52)
		b.add_theme_font_size_override("font_size", 24)
		b.pressed.connect(spec[1])
		buttons.add_child(b)
	Settings.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	for a in _rows:
		_rows[a].text = "press a key..." if a == _waiting else Settings.key_label(a)
	_hint.text = "" if _waiting == "" else "Press the new key for \"%s\" (Esc cancels)" % Settings.ACTIONS[_waiting][0]


func _listen(action: String) -> void:
	_waiting = action
	_refresh()


func _input(event: InputEvent) -> void:
	if not visible or _waiting == "" or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	var k := (event as InputEventKey).physical_keycode
	var action := _waiting
	_waiting = ""
	if k != KEY_ESCAPE:
		Settings.bind(action, k)
	_refresh()


func _close() -> void:
	_waiting = ""
	visible = false
	closed.emit()
