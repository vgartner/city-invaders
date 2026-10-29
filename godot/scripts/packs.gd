extends Node
## A released game is CityInvaders.pck (the game) plus one package per map,
## maps/<id>.pck (res://city/<id>*), so a map can be installed or added on
## its own. This autoload comes first and loads every map package it finds,
## before anything looks for the maps. Playing from the sources (the editor,
## ./run-godot.sh) the maps are already there and nothing is loaded.
##
## Map packages are looked for in maps/ next to the executable, in
## user://map_packs/ (maps added later) and where `-- --maps-dir=<path>` says
## (checking an export with the editor binary, docs/BUILDING.md).

const USER_DIR := "user://map_packs"

## map packages loaded, by file name
var loaded: Array[String] = []


func _init() -> void:
	if FileAccess.file_exists("res://project.godot"):   # the sources, not a package
		return
	var dirs := [OS.get_executable_path().get_base_dir().path_join("maps"), USER_DIR]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--maps-dir="):
			dirs.push_front(a.trim_prefix("--maps-dir="))
	for dir in dirs:
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".pck") and not loaded.has(f):
				load_map_pack(dir.path_join(f))
	if loaded.is_empty():
		push_error("no map packages found (maps/*.pck next to the game)")


## Loads one map package; it may hold nothing but map files (res://city/
## and their imported data), so a map can't replace or add game code.
func load_map_pack(path: String) -> bool:
	var files := pack_files(path)
	if files.is_empty():
		push_error("%s is not a map package" % path)
		return false
	for f in files:
		var ok: bool = f.begins_with("res://city/") or f.begins_with("res://.godot/imported/") \
				or f in ["res://project.binary", "res://.godot/uid_cache.bin", "res://.godot/global_script_class_cache.cfg"]
		if not ok or f.get_extension() in ["gd", "gdc", "gde", "cs", "gdextension", "dll", "so", "dylib"]:
			push_error("%s is refused: %s is not a map file" % [path, f])
			return false
	if not ProjectSettings.load_resource_pack(path, false):
		push_error("could not load %s" % path)
		return false
	loaded.append(path.get_file())
	_register_uids("res://city")
	return true


## The paths in a Godot package's directory (the .pck format, version 2 or 3).
static func pack_files(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_buffer(4).get_string_from_ascii() != "GDPC":
		return out
	var version := f.get_32()
	f.get_32()                    # engine major, minor, patch
	f.get_32()
	f.get_32()
	var flags := f.get_32()
	f.get_64()                    # file base
	if flags & 1:                 # encrypted directory
		return out
	if version >= 3:
		f.seek(f.get_64())
	else:
		f.seek(f.get_position() + 64)
	var count := f.get_32()
	for i in count:
		var name := f.get_buffer(f.get_32()).get_string_from_utf8()
		f.seek(f.get_position() + 8 + 8 + 16 + 4)   # offset, size, md5, flags
		out.append(name if name.begins_with("res://") else "res://" + name)
	return out


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
