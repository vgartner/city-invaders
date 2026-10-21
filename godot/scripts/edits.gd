extends RefCounted
## Where a map's user edits live, and whether the map pipeline is there.
##
## Playing from the repository (the sources), edits go to
## maps/<map>/user/buildings_user.json and a rebuild bakes them into the city.
## The released game (executable + .pck) has no repository and no Python:
## edits go to user://maps/<map>/ and the game applies them at runtime -
## placed models, item spots, roles, bus lines, removed objects and wall
## photos. Building heights and paving need the pipeline (the sources).
## CITY_INVADERS_NO_SOURCES=1 plays as the released game does (for testing).

static func repo_dir() -> String:
	var res := ProjectSettings.globalize_path("res://").trim_suffix("/")
	return res.get_base_dir() if res != "" else ""


## The map pipeline (tools/ and the map sources) is next to the game.
static func has_sources() -> bool:
	if OS.get_environment("CITY_INVADERS_NO_SOURCES") == "1":
		return false
	var repo := repo_dir()
	return repo != "" and FileAccess.file_exists(repo.path_join("tools/map/osm2gltf.py"))


## Edits are applied by the game itself (no rebuild possible).
static func runtime() -> bool:
	return not has_sources()


## The folder of a map's edits. Maps cut from the same city share one
## ("user" in maps/<map>/build.json) when playing from the sources.
static func dir(map_id: String) -> String:
	if not has_sources():
		return "user://maps".path_join(map_id)
	var repo := repo_dir()
	var cfg := repo.path_join("maps/%s/build.json" % map_id)
	if FileAccess.file_exists(cfg):
		var c = JSON.parse_string(FileAccess.get_file_as_string(cfg))
		if c is Dictionary and c.has("user"):
			return repo.path_join(c["user"])
	return repo.path_join("maps/%s/user" % map_id)


static func file(map_id: String) -> String:
	return dir(map_id).path_join("buildings_user.json")


## Edits made in design mode stay here until File > Save (or the save
## question when leaving): nothing reaches the disk on its own.
static var _pending := {}         # map id -> its user edits, not saved yet


static func read(map_id: String) -> Dictionary:
	if _pending.has(map_id):
		return (_pending[map_id] as Dictionary).duplicate(true)
	return read_saved(map_id)


static func read_saved(map_id: String) -> Dictionary:
	var f := file(map_id)
	if FileAccess.file_exists(f):
		var d = JSON.parse_string(FileAccess.get_file_as_string(f))
		if d is Dictionary:
			return d
	return {}


static func write(map_id: String, user: Dictionary) -> void:
	_pending[map_id] = user.duplicate(true)


static func dirty(map_id: String) -> bool:
	return _pending.has(map_id)


static func save(map_id: String) -> void:
	if _pending.has(map_id):
		_write_file(map_id, _pending[map_id])
		_pending.erase(map_id)


static func discard(map_id: String) -> void:
	_pending.erase(map_id)


static func _write_file(map_id: String, user: Dictionary) -> void:
	var f := file(map_id)
	DirAccess.make_dir_recursive_absolute(f.get_base_dir())
	var fa := FileAccess.open(f, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(user, " "))
		fa.close()
