extends RefCounted
## Music tracks live in res://assets/<collection>/music/<station>/ (mp3 or
## ogg). Each station folder is a car-radio station; "gaita" is also what the
## gaiteiro plays, "colheitadeira" what the harvester's radio starts on,
## "menu" what plays on the title screen and "loading" on the loading screen -
## "loading_<city>" for one city's maps (loading_porto_alegre), see main.gd.

const COLLECTIONS := ["res://assets/common/music", "res://assets/rio_grande_do_sul/music"]
## the radio's name for a station folder
const LABELS := {"gaita": "Rádio Gaita", "gaita_solo": "Rádio Gaita Solo", "colheitadeira": "Rádio do Interior",
		"violao": "Rádio Violão", "radio_campeira": "Rádio Campeira", "rock_gaucho": "Rádio Rock Gaúcho"}
## song titles as written (file names are kept plain ASCII); a trailing _2 is a take
const TITLES := {"gaitaco": "Gaitaço", "colheitadeira": "Colheitadeira", "poeira_da_colheita": "Poeira da Colheita",
		"chamame_de_um_so_fole": "Chamamé de um Só Fole", "amanhecer_gaucho": "Amanhecer Gaúcho",
		"baile_no_ctg": "Baile no CTG", "chuva_de_acordeao": "Chuva de Acordeão", "chuva_de_chao": "Chuva de Chão",
		"guaiba": "Guaíba", "fogo_de_chao": "Fogo de Chão", "invasao_chamame": "Invasão Chamamé",
		"humanitys_resolve": "Humanity's Resolve"}


static func tracks(station: String) -> PackedStringArray:
	var out := PackedStringArray()
	for root in COLLECTIONS:
		var dir: String = String(root).path_join(station)
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in DirAccess.get_files_at(dir):
			var name := f.trim_suffix(".remap").trim_suffix(".import")
			if (name.ends_with(".mp3") or name.ends_with(".ogg")) and not out.has(dir.path_join(name)):
				out.append(dir.path_join(name))
	out.sort()
	return out


## Radio stations: every station folder with tracks, except the menu and loading music.
static func stations() -> PackedStringArray:
	var out := PackedStringArray()
	for root in COLLECTIONS:
		if not DirAccess.dir_exists_absolute(root):
			continue
		for d in DirAccess.get_directories_at(root):
			if not d.begins_with("loading") and d != "menu" and not out.has(d) and not tracks(d).is_empty():
				out.append(d)
	out.sort()
	return out


static func label(station: String) -> String:
	return LABELS.get(station, "Rádio " + station.capitalize())


static func title(path: String) -> String:
	var base := path.get_file().get_basename()
	var take := ""
	var parts := base.rsplit("_", true, 1)
	if parts.size() == 2 and parts[1].is_valid_int():
		base = parts[0]
		take = " " + parts[1]
	return TITLES.get(base, base.replace("_", " ").capitalize()) + take


## A player that keeps going through a station's tracks (shuffled start).
static func playlist(player: Node, station: String) -> void:
	var list := tracks(station)
	if list.is_empty():
		return
	var i := randi() % list.size()
	player.set_meta("station", station)
	player.set_meta("track", i)
	player.stream = load(list[i])
	player.play()
	if not player.finished.is_connected(_next.bind(player)):
		player.finished.connect(_next.bind(player))


static func _next(player: Node) -> void:
	var list := tracks(player.get_meta("station", ""))
	if list.is_empty():
		return
	var i: int = (int(player.get_meta("track", 0)) + 1) % list.size()
	player.set_meta("track", i)
	player.stream = load(list[i])
	player.play()
