extends Node
## A released game ships in two packages: CityInvaders.pck (the game) and
## CityInvaders-maps.pck (res://city/, the generated maps). One package would
## be over 2 GB, more than a GitHub release file may hold. This autoload comes
## first, so the maps are there before anything looks for them. Playing from
## the sources (the editor, ./run-godot.sh) the maps are already there.
##
## The maps package is looked for next to the executable, or where
## `-- --maps-pack=<path>` says (checking an export with the editor binary,
## docs/BUILDING.md).

const MAPS_PACK := "CityInvaders-maps.pck"


func _init() -> void:
	if FileAccess.file_exists("res://city/maps.json"):
		return
	var paths := [OS.get_executable_path().get_base_dir().path_join(MAPS_PACK)]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--maps-pack="):
			paths.push_front(a.trim_prefix("--maps-pack="))
	for path in paths:
		if FileAccess.file_exists(path):
			if not ProjectSettings.load_resource_pack(path, false):
				push_error("could not load %s" % path)
			_register_uids("res://city")
			return
	push_error("%s not found next to the game: the maps are missing" % MAPS_PACK)


## The game package's UID table doesn't know the maps' files, and the map
## scenes refer to their textures by UID: take them from the .import files.
static func _register_uids(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".import"):
			continue
		var cfg := ConfigFile.new()
		if cfg.load(dir.path_join(f)) != OK:
			continue
		var id := ResourceUID.text_to_id(str(cfg.get_value("remap", "uid", "")))
		if id != ResourceUID.INVALID_ID and not ResourceUID.has_id(id):
			ResourceUID.add_id(id, dir.path_join(f.trim_suffix(".import")))
