extends RefCounted
## Lists the .glb models dropped into a folder. Generated characters/cars go
## to res://assets/<collection>/people and .../cars; the Kenney sets are the
## fallback while those folders are empty. Exported builds keep only
## ".glb.import"/".remap" entries, so those suffixes are stripped.

static func models(dir: String, fallback_dir: String) -> PackedStringArray:
	var out := _list(dir)
	return out if out.size() > 0 else _list(fallback_dir)


static func _list(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		var name := f.trim_suffix(".remap").trim_suffix(".import")
		if name.ends_with(".glb") and not out.has(dir.path_join(name)):
			out.append(dir.path_join(name))
	out.sort()
	return out
