extends RefCounted
## Mods: a map's own edits (what the map editor saves - placed models, item
## spots, roles, bus lines, removed objects, wall photos) packed in a zip with
## a mod.json, shared through the City Invaders server and installed by
## other players (docs/MODDING.md).
##
## A mod holds data only: mod.json, buildings_user.json and photos/<image>.
## Anything else in a zip is refused. Installing writes into the released
## game's edits folder (user://maps/<map>/), keeping what was there in
## user://mods/backup/<map>/ so Remove puts it back.

const Edits := preload("res://scripts/edits.gd")
const ROOT := "user://mods"
const INSTALLED := "user://mods/installed.json"
const IMAGES := ["png", "jpg", "jpeg", "webp"]


## The zip of a map's edits as they are now (unsaved ones included).
static func pack(map_id: String, info: Dictionary) -> PackedByteArray:
	DirAccess.make_dir_recursive_absolute(ROOT)
	var path := ROOT.path_join("outgoing.zip")
	var zip := ZIPPacker.new()
	if zip.open(path) != OK:
		return PackedByteArray()
	var manifest := {"format": 1, "map": map_id, "name": info.get("name", ""), "author": info.get("author", ""),
			"description": info.get("description", ""), "version": info.get("version", "1.0")}
	_put(zip, "mod.json", JSON.stringify(manifest, " ").to_utf8_buffer())
	var user := Edits.read(map_id)
	_put(zip, "buildings_user.json", JSON.stringify(user, " ").to_utf8_buffer())
	for p in user.get("_photos", []):
		var rel := String(p.get("image", ""))
		var src := Edits.dir(map_id).path_join(rel)
		if rel.begins_with("photos/") and FileAccess.file_exists(src):
			_put(zip, rel, FileAccess.get_file_as_bytes(src))
	zip.close()
	return FileAccess.get_file_as_bytes(path)


static func _put(zip: ZIPPacker, name: String, data: PackedByteArray) -> void:
	zip.start_file(name)
	zip.write_file(data)
	zip.close_file()


## Install a downloaded mod: "" when done, else why not.
static func install(id: String, bytes: PackedByteArray, sha256: String, maps: Array) -> String:
	if sha256 != "":
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(bytes)
		if h.finish().hex_encode() != sha256.to_lower():
			return "The download is damaged (checksum)."
	DirAccess.make_dir_recursive_absolute(ROOT)
	var tmp := ROOT.path_join("incoming.zip")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "Cannot write the download."
	f.store_buffer(bytes)
	f.close()
	var zip := ZIPReader.new()
	if zip.open(tmp) != OK:
		return "Not a zip."
	var files := zip.get_files()
	for name in files:
		var ok: bool = name in ["mod.json", "buildings_user.json"] or (name.begins_with("photos/")
				and not name.contains("..") and name.get_extension().to_lower() in IMAGES and name.count("/") == 1)
		if not ok and not name.ends_with("/"):
			zip.close()
			return "The mod holds a file a mod may not have (%s)." % name
	var manifest = JSON.parse_string(zip.read_file("mod.json").get_string_from_utf8()) if "mod.json" in files else null
	var edits = JSON.parse_string(zip.read_file("buildings_user.json").get_string_from_utf8()) if "buildings_user.json" in files else null
	if not (manifest is Dictionary) or not (edits is Dictionary):
		zip.close()
		return "The mod has no mod.json / buildings_user.json."
	var map_id := String(manifest.get("map", ""))
	if not map_id in maps:
		zip.close()
		return "The mod is for a map this game does not have (%s)." % map_id
	var dest := "user://maps".path_join(map_id)
	var backup := ROOT.path_join("backup").path_join(map_id)
	var installed := installed_mods()
	if not installed.has(map_id):
		# the first mod on this map: keep the player's own edits
		_copy_dir(dest, backup)
	_clear_dir(dest)
	DirAccess.make_dir_recursive_absolute(dest.path_join("photos"))
	for name in files:
		if name.ends_with("/") or name == "mod.json":
			continue
		var out := FileAccess.open(dest.path_join(name), FileAccess.WRITE)
		if out:
			out.store_buffer(zip.read_file(name))
			out.close()
	zip.close()
	installed[map_id] = {"id": id, "name": manifest.get("name", ""), "version": manifest.get("version", "")}
	_save_installed(installed)
	return ""


## Take a map's mod off: its edits back as they were before.
static func remove(map_id: String) -> void:
	var dest := "user://maps".path_join(map_id)
	_clear_dir(dest)
	_copy_dir(ROOT.path_join("backup").path_join(map_id), dest)
	_clear_dir(ROOT.path_join("backup").path_join(map_id))
	var installed := installed_mods()
	installed.erase(map_id)
	_save_installed(installed)


static func installed_mods() -> Dictionary:
	if FileAccess.file_exists(INSTALLED):
		var d = JSON.parse_string(FileAccess.get_file_as_string(INSTALLED))
		if d is Dictionary:
			return d
	return {}


static func _save_installed(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT)
	var f := FileAccess.open(INSTALLED, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, " "))


static func _copy_dir(from: String, to: String) -> void:
	if not DirAccess.dir_exists_absolute(from):
		return
	DirAccess.make_dir_recursive_absolute(to)
	for name in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(name), to.path_join(name))
	for sub in DirAccess.get_directories_at(from):
		_copy_dir(from.path_join(sub), to.path_join(sub))


static func _clear_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub in DirAccess.get_directories_at(path):
		_clear_dir(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
	for name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
