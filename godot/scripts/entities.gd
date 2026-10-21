extends RefCounted
## Entity definitions (docs/ENTITIES.md): what an object is, read from data.
## types.json is the type tree; every `*.def.json` under res://assets is one
## object; `<collection>/roles.json` says which object plays each role.

const TYPES := "res://assets/types.json"
const ROOT := "res://assets"

static var _types := {}
static var _defs := {}          # id -> resolved definition
static var _roles := {}         # collection -> {role: id}
static var _loaded := false


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(TYPES):
		_types = JSON.parse_string(FileAccess.get_file_as_string(TYPES))
	var stack := [ROOT]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			stack.append(dir.path_join(sub))
		for f in DirAccess.get_files_at(dir):
			var path := dir.path_join(f.trim_suffix(".remap"))
			if path.ends_with(".def.json"):
				var d = JSON.parse_string(FileAccess.get_file_as_string(path))
				if d is Dictionary and d.has("id"):
					_defs[d["id"]] = _resolve(d)
			elif f == "roles.json" and dir.get_file() != "assets":
				_roles[dir.get_file()] = JSON.parse_string(FileAccess.get_file_as_string(path))


## The type chain's attributes, then the definition's own; tags add up.
static func _resolve(d: Dictionary) -> Dictionary:
	var chain := []
	var t: String = d.get("type", "")
	while t != "" and _types.has(t) and chain.size() < 16:
		chain.push_front(t)
		t = _types[t].get("extends", "")
	var out := {"types": chain.duplicate(), "tags": []}
	for name in chain:
		_merge(out, _types[name])
	_merge(out, d)
	return out


static func _merge(into: Dictionary, from: Dictionary) -> void:
	for k in from:
		if k == "extends":
			continue
		if k == "tags":
			for tag in from[k]:
				if not tag in into["tags"]:
					into["tags"].append(tag)
		elif from[k] is Dictionary and into.get(k) is Dictionary:
			var merged: Dictionary = into[k].duplicate()
			merged.merge(from[k], true)
			into[k] = merged
		else:
			into[k] = from[k]


static func get_def(id: String) -> Dictionary:
	_load()
	return _defs.get(id, {})


static func is_a(id: String, type: String) -> bool:
	return type in get_def(id).get("types", [])


static func by_category(category: String) -> Array:
	_load()
	return _defs.values().filter(func(d): return d.get("category", "") == category)


## The object id playing `role` in `collection`'s cities (common as fallback).
static func role(collection: String, role_name: String) -> String:
	_load()
	var r: String = _roles.get(collection, {}).get(role_name, "")
	return r if r != "" else _roles.get("common", {}).get(role_name, "")


## The definition whose model is `path` ({} when the model has none).
static func of_model(path: String) -> Dictionary:
	_load()
	for d in _defs.values():
		if d.get("model", "") == path:
			return d
	return {}


## Every definition, for the Studio's palette by type.
static func all() -> Array:
	_load()
	return _defs.values()


## The ids that can play a role (same category as the collection's choice).
const ROLE_CATEGORY := {"healing_big": "healing", "healing_small": "healing", "medicine": "healing",
		"booster": "booster", "armour": "armour", "ammo": "ammo"}


static func role_names() -> Array:
	return ROLE_CATEGORY.keys()


static func role_candidates(role_name: String) -> Array:
	return by_category(ROLE_CATEGORY.get(role_name, "")).map(func(d): return d["id"])
