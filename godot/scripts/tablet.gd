extends Node3D
## The field tablet (T): held up in first person, its screen shows a real
## interface rendered in a SubViewport, drawn with the tablet's own art
## (gadgets/tablet/ui: pampa wallpaper, app screens, pictograms). Apps: GPS
## (the street map, robots, Coletores, spotted antennas, the exit), Radio
## (the stations, on foot too), Bah, the assistant (questions and answers
## about the game, from bah_faq.json), Peças (the parts carried); the rest
## are still to come. Keys while it is up: 1-8 or the arrows + Enter open an
## app, Backspace back to the home screen, T puts it away.

const MODEL := "res://assets/rio_grande_do_sul/gadgets/tablet/tablet_campo_viewmodel.glb"
const FAQ := "res://assets/rio_grande_do_sul/gadgets/tablet/bah_faq.json"
const SCREEN := Vector2i(1110, 690)
const BG := Color(0.07, 0.11, 0.09)
const CREAM := Color(0.96, 0.92, 0.82)
const ORANGE := Color(0.94, 0.6, 0.32)
const PANEL := Color8(36, 62, 49)       # bah_molde.png's chat panel, its bubbles and the question's
const BUBBLE := Color8(53, 79, 62)
const QUESTION := Color8(98, 78, 53)
const UI := "res://assets/rio_grande_do_sul/gadgets/tablet/ui/"
## the home screen's apps, in the order of its grid (UI_REGIONS.json)
## (the TchêTube video app takes the Camera's place on the home grid for now)
const APPS := ["gps", "radio", "bah", "tchetube", "rastreador", "pecas", "mensagens_defesa_civil", "configuracoes"]
const READY := ["gps", "radio", "bah", "tchetube", "pecas"]
const VIDEOS := "res://assets/rio_grande_do_sul/video/tchetube/"
const RED := Color(0.85, 0.16, 0.14)
const PART_NAMES := {"circuit": "Circuitos", "core": "Núcleos", "lens": "Lentes", "module": "Módulos"}

var player: Node                   # the local player (radio, position)
var _vp: SubViewport
var _ui: Control
var _anim: AnimationPlayer
var _app := "home"
var routes: Array = []             # GPS: the destinations list while it is open ([label, position])
var chat_q := ""                   # Bah: the player's own question, its answer
var chat_reply := ""
var chat_wait := false
var _sel := 0
var _faq: Dictionary = {}
var _answer := -1
var _gps: Control
var _tex := {}                     # loaded art by name
var _regions := {}
var _note := ""                    # a line at the bottom of the home screen ("em breve")
var _note_t := 0.0
var _videos: Array = []            # TchêTube: res:// paths of the .ogv files
var _player: VideoStreamPlayer      # the video playing on the tablet's screen


func _ready() -> void:
	var packed := load(MODEL) as PackedScene
	if packed:
		var m := packed.instantiate()
		add_child(m)
		for mi in m.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var aps := m.find_children("*", "AnimationPlayer", true, false)
		if aps.size() > 0:
			_anim = aps[0]
			if _anim.has_animation("idle"):
				_anim.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
			_anim.animation_finished.connect(func(n): if n != "idle" and _anim.has_animation("idle"): _anim.play("idle"))
		_vp = SubViewport.new()
		_vp.size = SCREEN
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED     # redrawn only while open
		_vp.disable_3d = true                  # a 2D screen: no 3D pass of its own
		_vp.transparent_bg = false
		add_child(_vp)
		_ui = Control.new()
		_ui.size = Vector2(SCREEN)
		_ui.draw.connect(_draw_ui)
		_vp.add_child(_ui)
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = _vp.get_texture()
		mat.emission_enabled = true
		mat.emission_texture = _vp.get_texture()
		mat.emission_energy_multiplier = 0.9
		mat.roughness = 0.35
		for mi in m.find_children("*", "MeshInstance3D", true, false):
			if String(mi.name).to_lower().contains("screen"):
				(mi as MeshInstance3D).material_override = mat
	if FileAccess.file_exists(FAQ):
		_faq = JSON.parse_string(FileAccess.get_file_as_string(FAQ))
	if FileAccess.file_exists(UI + "UI_REGIONS.json"):
		_regions = JSON.parse_string(FileAccess.get_file_as_string(UI + "UI_REGIONS.json"))
	for n in ["papel_parede_pampa", "inicial_overlay", "gps_molde", "radio_molde", "bah_molde",
			"controls/pause", "controls/play"]:
		if ResourceLoader.exists(UI + n + ".png"):
			_tex[n] = load(UI + n + ".png")
	visible = false


func open() -> void:
	visible = true
	if _vp:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_app = "home"
	_sel = 0
	if _anim and _anim.has_animation("raise"):
		_anim.play("raise")
	Sfx.play("pickup", -12.0)


func close() -> void:
	visible = false
	if _vp:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_stop_video()
	if is_instance_valid(_gps):
		_gps.queue_free()


func tap() -> void:
	if _anim and _anim.has_animation("tap"):
		_anim.play("tap")


## Keys while the tablet is up (player.gd forwards them). True = used.
func key(event: InputEventKey) -> bool:
	var k := event.keycode
	if k == KEY_BACKSPACE or k == KEY_ESCAPE:
		if _app == "gps" and not routes.is_empty():
			routes = []                    # close the destinations list
			return true
		if _answer != -1:
			_answer = -1
		elif is_instance_valid(_player):
			_stop_video()              # back to the list
		else:
			_open_app("home")
		return true
	if _app == "home":
		if k >= KEY_1 and k <= KEY_8:
			_launch(k - KEY_1)
			return true
		var moves := {KEY_RIGHT: 1, KEY_LEFT: -1, KEY_DOWN: 4, KEY_UP: -4}
		if moves.has(k):
			_sel = (_sel + moves[k] + APPS.size()) % APPS.size()
			return true
		if k == KEY_ENTER or k == KEY_KP_ENTER:
			_launch(_sel)
			return true
		return false
	# Tab: straight to what you type or press - Bah's question line; the
	# radio's on / off (Space too)
	if k == KEY_TAB and _app == "bah":
		tap()
		player.ask_bah()
		return true
	if k in [KEY_TAB, KEY_SPACE] and _app == "radio":
		tap()
		if player._radio != null and player._radio.playing:
			player.radio_stop()
		else:
			_tune()
		return true
	var n := _list_size()
	if k in [KEY_DOWN, KEY_RIGHT] and n > 0:
		_sel = (_sel + 1) % n
		if _app == "radio":
			_tune()
		return true
	if k in [KEY_UP, KEY_LEFT] and n > 0:
		_sel = (_sel - 1 + n) % n
		if _app == "radio":
			_tune()
		return true
	if k == KEY_ENTER or k == KEY_KP_ENTER:
		tap()
		match _app:
			"radio":
				if player._radio != null and player._radio.playing:
					player.radio_stop()
				else:
					_tune()
			"gps":
				if routes.is_empty():
					var main := player.get_tree().current_scene
					routes = main.route_destinations(player.global_position, player.gps_containers)
					if player.route_to != Vector3.INF:
						routes.push_front(["Cancelar a rota (" + player.route_name + ")", Vector3.INF])
					_sel = 0
				elif _sel < routes.size():
					if routes[_sel][1] == Vector3.INF:
						player.clear_route()
					else:
						player.set_route(routes[_sel][1], routes[_sel][0])
					routes = []
			"bah":
				if _sel == 0:
					player.ask_bah()            # a question of your own, to the AI
				else:
					_answer = _sel - 1
			"tchetube":
				if is_instance_valid(_player):
					_player.paused = not _player.paused
				elif _sel < _videos.size():
					_play_video(_videos[_sel])
		return true
	return false


## TchêTube: the game's own videos (video/tchetube/*.ogv) in a list.
func _scan_videos() -> void:
	_videos = []
	for f in DirAccess.get_files_at(VIDEOS):
		var n := f.trim_suffix(".remap").trim_suffix(".import")
		if n.ends_with(".ogv") and not _videos.has(VIDEOS + n):
			_videos.append(VIDEOS + n)
	_videos.sort()


## Titles from video/tchetube/titles.json (file name -> title), else the file name.
func _video_title(path: String) -> String:
	var key := path.get_file().get_basename()
	if FileAccess.file_exists(VIDEOS + "titles.json"):
		var t = JSON.parse_string(FileAccess.get_file_as_string(VIDEOS + "titles.json"))
		if t is Dictionary and t.has(key):
			return t[key]
	return key.replace("_", " ").capitalize()


## Plays on the tablet's screen; the radio goes quiet meanwhile.
func _play_video(path: String) -> void:
	_stop_video()
	if not ResourceLoader.exists(path):
		return
	if player._radio != null and player._radio.playing:
		player.radio_stop()
	_player = VideoStreamPlayer.new()
	_player.stream = load(path)
	_player.expand = true
	_player.volume_db = -4.0
	_vp.add_child(_player)
	_player.finished.connect(_stop_video)
	_player.play()
	# the player takes the video's own size when it starts: fit it after
	var h := float(SCREEN.y) - 130.0 - 70.0          # between the header and the caption line
	var fit := func():
		if is_instance_valid(_player):
			_player.size = Vector2(h * 16.0 / 9.0, h)
			_player.position = Vector2((SCREEN.x - h * 16.0 / 9.0) / 2.0, 120.0)
	fit.call()
	await get_tree().process_frame
	fit.call()


func _stop_video() -> void:
	if is_instance_valid(_player):
		_player.queue_free()
	_player = null


func _launch(i: int) -> void:
	tap()
	if APPS[i] in READY:
		_open_app(APPS[i])
	else:
		_sel = i
		_note = "Em breve: este app chega numa próxima versão do tablet."
		_note_t = 3.0


func _tune() -> void:
	var st: PackedStringArray = player.Music.stations()
	if _sel < st.size():
		player._radio_tune(_sel)


func _open_app(app: String) -> void:
	_app = app
	_sel = maxi(0, APPS.find(app)) if app == "home" else 0
	_answer = -1
	tap()
	if app == "radio" and player._radio != null and player._radio.playing:
		_sel = maxi(0, player._radio_station)
	if is_instance_valid(_gps):
		_gps.queue_free()
	_stop_video()
	if app == "tchetube":
		_scan_videos()
	if app == "gps":
		var r: Array = _regions.get("gps", {}).get("map_rect", [33, 119, 757, 491])
		_gps = preload("res://scripts/gps.gd").new()
		_gps.vehicle = player
		_vp.add_child(_gps)
		_gps.set_driving(true)
		_gps.RANGE_M = 200.0
		_gps.panel = Vector2(r[2], r[3])
		_gps.position = Vector2(r[0], r[1])
		_gps.size = _gps.panel
		_gps.clip_contents = true
		_gps.load_icons(player.get_tree().current_scene.get("place_kinds"))


func _list_size() -> int:
	match _app:
		"radio":
			return player.Music.stations().size()
		"gps":
			return routes.size()
		"bah":
			return _faq.get("faq", []).size() + 1
		"tchetube":
			return _videos.size()
	return 0


func _process(delta: float) -> void:
	_note_t -= delta
	if visible and _ui:
		_ui.queue_redraw()


## The TchêTube app on the home grid, over the Camera's tile of the art:
## the wallpaper is drawn back over that tile (hiding the camera icon and its
## label), then the TchêTube icon and its name in the art's own style.
var _tt_icon: Texture2D
func _tchetube_icon(f: Font) -> void:
	var apps: Array = _regions.get("home", {}).get("apps", [])
	var r: Array = apps[3]["rect"] if apps.size() > 3 else [860, 184, 140, 174]
	var tile := Rect2(r[0] - 6, r[1] - 6, r[2] + 12, r[3] + 12)
	var wall: Texture2D = _tex.get("papel_parede_pampa")
	if wall:
		var k := Vector2(wall.get_size()) / Vector2(SCREEN)
		_ui.draw_texture_rect_region(wall, tile, Rect2(tile.position * k, tile.size * k))
	if _tt_icon == null and ResourceLoader.exists(UI + "apps/tchetube.png"):
		# as an ImageTexture: the imported texture drew blank on this canvas
		_tt_icon = ImageTexture.create_from_image((load(UI + "apps/tchetube.png") as Texture2D).get_image())
	var icon := Rect2(r[0] + 4, r[1] + 1, r[2] - 8, r[2] - 8)
	if _tt_icon:
		_ui.draw_texture_rect(_tt_icon, icon, false)
	else:
		var c := icon.get_center()
		_ui.draw_rect(Rect2(c - Vector2(38, 26), Vector2(76, 52)), RED)
		_ui.draw_colored_polygon(PackedVector2Array([c + Vector2(-12, -16), c + Vector2(18, 0), c + Vector2(-12, 16)]), CREAM)
	_ui.draw_string(f, Vector2(r[0], r[1] + r[3] - 14), "TchêTube", HORIZONTAL_ALIGNMENT_CENTER, r[2], 17, Color(0.96, 0.93, 0.86))


func _bubble(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(12)
	return sb


func _tx(n: String) -> void:
	if _tex.has(n):
		_ui.draw_texture_rect(_tex[n], Rect2(Vector2.ZERO, Vector2(SCREEN)), false)


func _r(app: String, key: String, fallback: Array) -> Rect2:
	var a: Array = _regions.get(app, {}).get(key, fallback)
	return Rect2(a[0], a[1], a[2], a[3])


func _draw_ui() -> void:
	var f := ThemeDB.fallback_font
	# the screens' status bar is see-through in the art: a dark strip under it
	_ui.draw_rect(Rect2(Vector2.ZERO, Vector2(SCREEN)), BG)
	match _app:
		"home":
			_tx("papel_parede_pampa")
			_tx("inicial_overlay")
			_tchetube_icon(f)
			var apps: Array = _regions.get("home", {}).get("apps", [])
			if _sel < apps.size():
				var a: Array = apps[_sel]["rect"]
				_ui.draw_rect(Rect2(a[0] - 8, a[1] - 8, a[2] + 16, a[3] + 16), ORANGE, false, 4.0)
			if _note_t > 0:
				_ui.draw_string(f, Vector2(300, 612), _note, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, ORANGE)
		"gps":
			_tx("gps_molde")
			if not routes.is_empty():
				# the destinations: ↑ ↓ and Enter, Backspace closes
				_ui.draw_rect(Rect2(40, 126, 744, 478), Color(0.06, 0.12, 0.09, 0.96))
				_ui.draw_string(f, Vector2(60, 162), "PARA ONDE?", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, ORANGE)
				var top: int = clampi(_sel - 4, 0, maxi(0, routes.size() - 9))
				for i in range(top, mini(routes.size(), top + 9)):
					var y := 204 + (i - top) * 44
					if i == _sel:
						_ui.draw_rect(Rect2(52, y - 30, 720, 40), ORANGE, false, 3.0)
					_ui.draw_string(f, Vector2(70, y), routes[i][0], HORIZONTAL_ALIGNMENT_LEFT, 690, 21, CREAM)
				_ui.draw_string(f, Vector2(60, 596), "↑ ↓ escolhe  ·  Enter traça a rota  ·  Backspace fecha",
						HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(CREAM, 0.7))

			# our own legend over the art's example one
			var lg := Rect2(818, 112, 258, 395)
			_ui.draw_rect(lg, Color(0.14, 0.24, 0.19))
			_ui.draw_string(f, Vector2(832, 146), "NO MAPA", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, ORANGE)
			if is_instance_valid(_gps):
				_gps.visible = routes.is_empty()         # the destinations list takes the map's place
			if player.route_to != Vector3.INF:
				_ui.draw_string(f, Vector2(832, 578), "Rota: " + player.route_name, HORIZONTAL_ALIGNMENT_LEFT, 240, 18, ORANGE)
				_ui.draw_string(f, Vector2(832, 600), "Enter muda ou cancela", HORIZONTAL_ALIGNMENT_LEFT, 240, 15, Color(CREAM, 0.8))
			else:
				_ui.draw_string(f, Vector2(832, 578), "ao vivo", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, CREAM)
				_ui.draw_string(f, Vector2(832, 600), "Enter: traçar uma rota", HORIZONTAL_ALIGNMENT_LEFT, 240, 15, ORANGE)
			var rows := [["Você (seta)", ""], ["Robôs", "robo"], ["Coletor com alguém", "coletor"],
					["Torre avistada", "torre_comunicacao"], ["Enxame", "enxame"], ["Saída da fase", "saida_fase"],
					["Container de pessoas", "container"], ["Assistência técnica", "assistencia_tecnica"]]
			for i in rows.size():
				var y := 186 + i * 44
				var icon: String = rows[i][1]
				var pic: Texture2D = _gps.icons.get({"robo": "robo", "coletor": "coletor", "torre_comunicacao": "torre",
						"enxame": "enxame", "saida_fase": "saida", "container": "container",
						"assistencia_tecnica": "assistencia_tecnica"}.get(icon, ""), null) if is_instance_valid(_gps) else null
				if pic:
					_ui.draw_texture_rect(pic, Rect2(830, y - 26, 36, 36), false)
				elif icon == "container":
					_ui.draw_rect(Rect2(838, y - 18, 20, 20), Color(0.85, 0.45, 1.0))
				else:
					_ui.draw_colored_polygon(PackedVector2Array([Vector2(848, y - 22), Vector2(860, y + 6), Vector2(848, y - 1), Vector2(836, y + 6)]), ORANGE)
				_ui.draw_string(f, Vector2(876, y), rows[i][0], HORIZONTAL_ALIGNMENT_LEFT, 196, 18, CREAM)
		"radio":
			_tx("radio_molde")
			var st: PackedStringArray = player.Music.stations()
			var playing: bool = player._radio != null and player._radio.playing
			var label: String = player.Music.label(st[_sel]) if _sel < st.size() else "-"
			var sr := _r("radio", "station_rect", [62, 168, 720, 49])
			_ui.draw_string(f, sr.position + Vector2(0, 40), label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, sr.size.x, 40, CREAM)
			var sub := _r("radio", "subtitle_rect", [63, 222, 720, 29])
			var title: String = player.Music.title(player._radio.stream.resource_path) if playing and player._radio.stream else "Desligado - Enter liga"
			_ui.draw_string(f, sub.position + Vector2(0, 24), title, HORIZONTAL_ALIGNMENT_LEFT, sub.size.x, 22, Color(CREAM, 0.75))
			var band := _r("radio", "band_rect", [62, 304, 720, 29])
			_ui.draw_string(f, band.position + Vector2(0, 24), "ESTAÇÃO %d DE %d  ·  ◀ ▶ troca  ·  Enter ou Espaço liga / desliga" % [_sel + 1, st.size()],
					HORIZONTAL_ALIGNMENT_LEFT, band.size.x, 22, CREAM)
			_ui.draw_string(f, Vector2(160, 431), "AO VIVO" if playing else "DESLIGADO", HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
					ORANGE if playing else Color(CREAM, 0.6))
			if playing and _tex.has("controls/pause"):
				var pb := _r("radio", "play_button", [510, 462, 90, 90])
				_ui.draw_circle(pb.get_center(), pb.size.x / 2.0, ORANGE)
				_ui.draw_texture_rect(_tex["controls/pause"], Rect2(pb.get_center() - Vector2(28, 28), Vector2(56, 56)), false)
		"bah":
			_tx("bah_molde")
			var faq: Array = _faq.get("faq", [])
			var q := ""
			var a := ""
			if _answer == -2:
				q = chat_q                         # a conversation with the AI (Online.chat)
				a = "Bah está pensando..." if chat_wait else chat_reply
			elif _answer >= 0 and _answer < faq.size():
				q = faq[_answer][0]
				a = faq[_answer][1]
			if q == "":
				_ui.draw_multiline_string(f, Vector2(80, 248), _faq.get("greeting", ""), HORIZONTAL_ALIGNMENT_LEFT, 460, 18, 2, CREAM)
			else:
				# a question and its answer: the greeting gives way, the answer
				# gets the whole chat panel below the question
				_ui.draw_rect(Rect2(40, 200, 720, 360), PANEL)
				_ui.draw_style_box(_bubble(QUESTION), Rect2(302, 212, 429, 58))
				_ui.draw_multiline_string(f, Vector2(318, 236), q, HORIZONTAL_ALIGNMENT_LEFT, 400, 19, 2, CREAM)
				_ui.draw_style_box(_bubble(BUBBLE), Rect2(65, 286, 666, 266))
				_ui.draw_multiline_string(f, Vector2(82, 312), a, HORIZONTAL_ALIGNMENT_LEFT, 632, 18, 11, Color(CREAM, 0.95))
			# the quick questions: four at a time around the chosen one
			var boxes := [187, 273, 359, 444]
			var rows: Array = [["✦ Pergunte o que quiser à Bah"]] + faq
			var top: int = clampi(_sel - 1, 0, maxi(0, rows.size() - 4))
			for i in range(top, mini(rows.size(), top + 4)):
				var y: int = boxes[i - top]
				if i == _sel:
					_ui.draw_rect(Rect2(801, y, 258, 69), ORANGE, false, 3.0)
				_ui.draw_multiline_string(f, Vector2(814, y + 28), rows[i][0], HORIZONTAL_ALIGNMENT_LEFT, 232, 18, 2,
						ORANGE if i == 0 else CREAM)
			var typing: LineEdit = player._ask if is_instance_valid(player) and is_instance_valid(player._ask) else null
			if typing:
				# what the player types (the line itself is invisible, it only takes the keys)
				var shown := typing.text
				while shown.length() > 1 and f.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, 21).x > 700:
					shown = shown.substr(1)          # the end of a long question stays in view
				var caret := "|" if int(Time.get_ticks_msec() / 500) % 2 == 0 else " "
				_ui.draw_string(f, Vector2(236, 628), (shown if shown != "" else "") + caret, HORIZONTAL_ALIGNMENT_LEFT, 740, 21, CREAM)
				if shown == "":
					_ui.draw_string(f, Vector2(250, 628), "Escreve tua pergunta  ·  Enter envia  ·  Esc cancela",
							HORIZONTAL_ALIGNMENT_LEFT, 720, 19, Color(CREAM, 0.5))
			else:
				_ui.draw_string(f, Vector2(236, 626), "Tab: escrever tua pergunta  ·  ↑ ↓ escolhe  ·  Enter pergunta  ·  Backspace volta",
						HORIZONTAL_ALIGNMENT_LEFT, 760, 19, Color(CREAM, 0.7))
		"tchetube":
			_tx("papel_parede_pampa")
			_ui.draw_rect(Rect2(Vector2.ZERO, Vector2(SCREEN)), Color(0.04, 0.06, 0.05, 0.82))
			_ui.draw_rect(Rect2(0, 0, SCREEN.x, 42), Color(0, 0, 0, 0.35))
			_ui.draw_rect(Rect2(0, 48, SCREEN.x, 62), Color(0.08, 0.14, 0.11))
			if ResourceLoader.exists(UI + "map/tchetube.png"):
				_ui.draw_texture_rect(load(UI + "map/tchetube.png"), Rect2(36, 54, 52, 52), false)
			else:
				_ui.draw_rect(Rect2(40, 60, 52, 38), RED)
				_ui.draw_colored_polygon(PackedVector2Array([Vector2(58, 68), Vector2(80, 79), Vector2(58, 90)]), CREAM)
			_ui.draw_string(f, Vector2(106, 92), "TchêTube", HORIZONTAL_ALIGNMENT_LEFT, -1, 32, CREAM)
			if is_instance_valid(_player):
				var title := _video_title(_player.stream.resource_path) if _player.stream else ""
				_ui.draw_string(f, Vector2(60, SCREEN.y - 34), title, HORIZONTAL_ALIGNMENT_LEFT, 600, 24, CREAM)
				_ui.draw_string(f, Vector2(SCREEN.x - 470, SCREEN.y - 34),
						("Enter continua" if _player.paused else "Enter pausa") + "  ·  Backspace volta",
						HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(CREAM, 0.7))
			elif _videos.is_empty():
				_ui.draw_string(f, Vector2(60, 140), "Nenhum vídeo por aqui ainda.", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, CREAM)
			else:
				for i in _videos.size():
					var y := 134 + i * 76
					_ui.draw_rect(Rect2(60, y, SCREEN.x - 120, 64), Color(0.35, 0.22, 0.12) if i == _sel else Color(0.12, 0.18, 0.14))
					_ui.draw_rect(Rect2(76, y + 14, 50, 36), RED)
					_ui.draw_colored_polygon(PackedVector2Array([Vector2(93, y + 22), Vector2(112, y + 32), Vector2(93, y + 42)]), CREAM)
					_ui.draw_string(f, Vector2(146, y + 42), _video_title(_videos[i]), HORIZONTAL_ALIGNMENT_LEFT, SCREEN.x - 240, 26, CREAM)
				_ui.draw_string(f, Vector2(60, SCREEN.y - 34), "↑ ↓ escolhe  ·  Enter assiste  ·  Backspace volta",
						HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(CREAM, 0.7))
		"pecas":
			_tx("papel_parede_pampa")
			_ui.draw_rect(Rect2(60, 90, SCREEN.x - 120, SCREEN.y - 160), Color(0.08, 0.16, 0.12, 0.9))
			_ui.draw_string(f, Vector2(90, 150), "PEÇAS NA MOCHILA", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, ORANGE)
			var parts: Dictionary = player.get("parts")
			var i := 0
			for k in PART_NAMES:
				_ui.draw_string(f, Vector2(110, 230 + i * 70), "%s:  %d" % [PART_NAMES[k], parts.get(k, 0)], HORIZONTAL_ALIGNMENT_LEFT, -1, 32, CREAM)
				i += 1
			_ui.draw_string(f, Vector2(560, 230), "Carregando %d de %d" % [player.parts_total(), player.parts_cap()],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 30, ORANGE)
			_ui.draw_string(f, Vector2(560, 280), "Mala de garupa: sim" if player.has_bag else "Sem mala: só os bolsos",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 24, CREAM)
			_ui.draw_string(f, Vector2(90, SCREEN.y - 100), "Troca na assistência técnica (E no balcão).", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(CREAM, 0.7))
	# the clock in the status bar (all screens)
	var t := Time.get_time_dict_from_system()
	var cr := _r("home", "clock_rect", [42, 30, 78, 24])
	_ui.draw_string(f, cr.position + Vector2(0, 20), "%02d:%02d" % [t["hour"], t["minute"]], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, CREAM)
