extends Node
const Tablet = preload("res://scripts/tablet.gd")

func _ready() -> void:
	var tablet := Tablet.new()
	var path := "user://tablet_title_cache_test.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"known_clip": "Título original"}))
	file.close()
	tablet._load_video_titles(path)
	assert(tablet._video_title("res://known_clip.ogv") == "Título original")
	assert(tablet._video_title("res://unknown_clip.ogv") == "Unknown Clip")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"known_clip": "Título atualizado"}))
	file.close()
	# Drawing keeps the snapshot; re-entering the list refreshes it.
	assert(tablet._video_title("res://known_clip.ogv") == "Título original")
	tablet._load_video_titles(path)
	assert(tablet._video_title("res://known_clip.ogv") == "Título atualizado")
	DirAccess.remove_absolute(path)
	tablet._load_video_titles(path)
	assert(tablet._video_title("res://known_clip.ogv") == "Known Clip")
	tablet.free()
	print("Tablet title lookup, fallback and refresh tests passed")
	get_tree().quit()
