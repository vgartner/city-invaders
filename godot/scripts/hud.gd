extends Control
## In-game HUD: a Doom-style status bar along the bottom (health, weapon,
## ammo, robots vs the phase goal, civilians, threat) and the phase objective
## as a banner at the top centre. player.gd feeds it with refresh().

const RED := Color(0.9, 0.22, 0.16)
const GREEN := Color(0.35, 0.95, 0.45)
const AMBER := Color(1.0, 0.72, 0.25)
const DIM := Color(0.62, 0.66, 0.72)

var _health: Label
var _health_bar: ProgressBar
var _armor: Label
var _armor_bar: ProgressBar
const ARMOR_COLOUR := Color(0.72, 0.55, 1.0)
var _weapon: Label
var _slots: Label
var _ammo: Label
var _reserve: Label
var _robots: Label
var _robots_bar: ProgressBar
var _mechs: Label
var _relay: Label
var _civ: Label
var _civ_lost: Label
var _threat: Label
var _banner: Label
var _center: Label
var _prompt: Label
var _score: Label
var _score_flash: Label
var _t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar := PanelContainer.new()
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -112
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.86)
	style.border_color = RED
	style.border_width_top = 3
	style.set_content_margin_all(10)
	bar.add_theme_stylebox_override("panel", style)
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	bar.add_child(row)

	var s := _section(row, "HEALTH", 260)
	_health = _big(s, 52)
	_health_bar = _bar(s, GREEN)
	# the pala (poncho) armour: takes a share of every hit until it is worn through
	s = _section(row, "ARMOR", 170)
	_armor = _big(s, 40)
	_armor_bar = _bar(s, ARMOR_COLOUR)
	_armor_bar.custom_minimum_size.x = 130
	s = _section(row, "WEAPON", 300)
	_weapon = _big(s, 34)
	_slots = _small(s, 18)
	s = _section(row, "AMMO", 220)
	var ammo_row := HBoxContainer.new()
	ammo_row.add_theme_constant_override("separation", 10)
	s.add_child(ammo_row)
	_ammo = _big(ammo_row, 52)
	_reserve = _small(ammo_row, 26)
	_reserve.size_flags_vertical = Control.SIZE_SHRINK_END
	s = _section(row, "ROBOTS", 320)
	var robots_row := HBoxContainer.new()             # robots and, beside them, the mechs still due
	robots_row.add_theme_constant_override("separation", 14)
	s.add_child(robots_row)
	_robots = _big(robots_row, 40)
	_mechs = _small(robots_row, 22)
	_mechs.size_flags_vertical = Control.SIZE_SHRINK_END
	_robots_bar = _bar(s, RED)
	_relay = _small(s, 14)
	s = _section(row, "CIVILIANS", 280)
	_civ = _big(s, 34)
	_civ_lost = _small(s, 20)
	s = _section(row, "THREAT", 220)
	_threat = _big(s, 34)
	s = _section(row, "SCORE", 220)
	_score = _big(s, 40)
	_score_flash = _small(s, 18)

	_banner = Label.new()
	_banner.anchor_left = 0.0
	_banner.anchor_right = 1.0
	_banner.offset_top = 14
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 30)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 8)
	add_child(_banner)
	_center = Label.new()
	_center.set_anchors_preset(Control.PRESET_CENTER)
	_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_center.grow_vertical = Control.GROW_DIRECTION_BOTH
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.add_theme_font_size_override("font_size", 56)
	_center.add_theme_color_override("font_color", RED)
	_center.add_theme_color_override("font_outline_color", Color.BLACK)
	_center.add_theme_constant_override("outline_size", 10)
	add_child(_center)
	_prompt = Label.new()
	_prompt.anchor_left = 0.0
	_prompt.anchor_right = 1.0
	_prompt.anchor_top = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_top = -170
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 28)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 8)
	add_child(_prompt)


func _section(row: HBoxContainer, title: String, width: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 0)
	row.add_child(box)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_color_override("font_color", DIM)
	box.add_child(t)
	if row.get_child_count() > 1:
		var sep := VSeparator.new()
		row.add_child(sep)
		row.move_child(sep, row.get_child_count() - 2)
	return box


func _big(parent: Control, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	parent.add_child(l)
	return l


func _small(parent: Control, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", DIM)
	parent.add_child(l)
	return l


func _bar(parent: Control, colour: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(200, 12)
	b.show_percentage = false
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.16, 0.2)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = colour
	fill.set_corner_radius_all(4)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fill)
	parent.add_child(b)
	return b


## Reapplying an identical override still notifies the theme/layout machinery.
## Check the effective value so transitions and the exit pulse stay unchanged.
func _font_color(label: Label, color: Color) -> void:
	if not label.has_theme_color_override("font_color") or label.get_theme_color("font_color") != color:
		label.add_theme_color_override("font_color", color)


## d: health, weapon, slots, ammo, reserve, reloading, kills, goal (0 = none),
## goal_extra, civ_alive, civ_lost, threat, objective, exit_open, dead
func refresh(d: Dictionary, delta: float) -> void:
	_t += delta
	var hp: int = d["health"]
	_health.text = str(hp)
	_font_color(_health, GREEN if hp > 60 else (AMBER if hp > 30 else RED))
	_health_bar.value = hp
	var ar: int = d.get("armor", 0)
	_armor.text = str(ar)
	_font_color(_armor, ARMOR_COLOUR if ar > 0 else DIM)
	_armor_bar.value = ar
	(_health_bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = GREEN if hp > 60 else (AMBER if hp > 30 else RED)
	_weapon.text = d["weapon"].to_upper()
	_slots.text = d["slots"]
	_ammo.text = str(d["ammo"])
	_font_color(_ammo, RED if d["ammo"] == 0 else Color.WHITE)
	_reserve.text = ("RELOADING" if d["reloading"] else "/ %d" % d["reserve"])
	var goal: int = d["goal"]
	if goal > 0:
		_robots.text = "%d / %d" % [min(d["kills"], goal), goal]
		_robots_bar.visible = true
		_robots_bar.max_value = goal
		_robots_bar.value = d["kills"]
	else:
		_robots.text = "%d destroyed" % d["kills"]
		_robots_bar.visible = false
	var mg: int = d.get("mech_goal", 0)
	_mechs.visible = mg > 0
	_mechs.text = "MECHS %d / %d" % [d.get("mechs", 0), mg]
	var code: int = d.get("antenna", 0)
	var relay: int = code % 10
	_relay.visible = relay > 0
	var down: int = (code / 10) % 10
	var total: int = code / 100
	_relay.text = ["", "ANTENNAS %d/%d down · find them with a drone" % [down, total],
			"ANTENNAS %d/%d down · one spotted (GPS)" % [down, total], "ANTENNAS all down"][relay]
	_font_color(_relay, [DIM, AMBER, RED, GREEN][relay])
	_font_color(_mechs, GREEN if d.get("mechs", 0) >= mg else AMBER)
	_civ.text = "%d alive" % d["civ_alive"]
	_civ_lost.text = "%d lost" % d["civ_lost"] + ("  (+%d robots to the goal)" % d["goal_extra"] if d["goal_extra"] > 0 else "")
	_font_color(_civ_lost, RED if d["civ_lost"] > 0 else DIM)
	var threat: Array = {"RELAX": ["CALM", GREEN], "BUILD_UP": ["ALERT", AMBER], "PEAK": ["ATTACK", RED]}.get(d["threat"], [d["threat"], DIM])
	_threat.text = threat[0]
	_font_color(_threat, threat[1])
	var blink := 0.55 + 0.45 * sin(_t * 6.0)
	_banner.offset_top = 52 if d.get("design", false) else 14     # under the editor's menu bar
	var banner_size := 20 if d.get("design", false) else 30
	if _banner.get_theme_font_size("font_size") != banner_size:
		_banner.add_theme_font_size_override("font_size", banner_size)
	if d.get("design", false):
		_banner.text = d["design_hint"]
		_font_color(_banner, AMBER)
	else:
		_banner.text = d["objective"]
		_font_color(_banner, Color(GREEN, blink) if d["exit_open"] else Color(1, 1, 1, 0.92))
	_center.text = "YOU DIED\nrespawning..." if d["dead"] else ""
	_prompt.text = d.get("prompt", "")
	_score.text = str(d.get("score", 0))
	_score_flash.text = d.get("score_flash", "")
	_font_color(_score_flash, GREEN if d.get("score_up", true) else RED)
