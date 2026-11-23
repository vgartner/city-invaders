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
## question when leaving): nothing reaches the disk on its own. Kept by
## file: maps cut from one city (an open world's tiles) share theirs, so an
## edit made on one is the others' at once.
static var _pending := {}         # edits file -> its user edits, not saved yet
static var touched := {}          # map id -> true: edited this session (the rebuild takes each)


static func read(map_id: String) -> Dictionary:
	var f := file(map_id)
	if _pending.has(f):
		return (_pending[f] as Dictionary).duplicate(true)
	return read_saved(map_id)


static func read_saved(map_id: String) -> Dictionary:
	var f := file(map_id)
	if FileAccess.file_exists(f):
		var d = JSON.parse_string(FileAccess.get_file_as_string(f))
		if d is Dictionary:
			return d
	return {}


static func write(map_id: String, user: Dictionary) -> void:
	_pending[file(map_id)] = user.duplicate(true)
	touched[map_id] = true


static func dirty(map_id: String) -> bool:
	return _pending.has(file(map_id))


## Unsaved edits on any map (design mode edits every area round the camera).
static func any_dirty() -> bool:
	return not _pending.is_empty()


static func save(map_id: String) -> void:
	var f := file(map_id)
	if _pending.has(f):
		_write_path(f, _pending[f])
		_pending.erase(f)


static func save_all() -> void:
	for f in _pending:
		_write_path(f, _pending[f])
	_pending.clear()


static func discard(map_id: String) -> void:
	_pending.erase(file(map_id))


static func discard_all() -> void:
	_pending.clear()


## What was written straight to a map's file (the editor's placed models)
## also goes into its unsaved edits, or File > Save would write it away.
static func mirror(map_id: String, key: String, value) -> void:
	var f := file(map_id)
	touched[map_id] = true
	if _pending.has(f):
		_pending[f][key] = value


static func _write_path(f: String, user: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(f.get_base_dir())
	var fa := FileAccess.open(f, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(user, " "))
		fa.close()
