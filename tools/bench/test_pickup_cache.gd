extends Node3D
const Main := preload("res://scripts/main.gd")
const Pickup := preload("res://scripts/pickup.gd")
const Entities := preload("res://scripts/entities.gd")
var failures := 0
func expect(value: bool, reason: String) -> void:
	if not value:
		failures += 1
		push_error(reason)

func _ready() -> void:
	var paths := Pickup.model_paths()
	var unique := {}
	for path in paths:
		expect(not unique.has(path), "Pickup warm paths must not contain duplicates")
		unique[path] = true
	for kind in ["circuit", "core", "lens", "module", "canhao", "bateria", "detector", "oculos"]:
		expect(Entities.get_def(kind).get("model", "") in paths, "Missing definition-driven pickup: " + kind)
	# Limit this fixture to pickup requests; full rendered loading separately
	# checks that _warm_people_request includes every one of these paths.
	var main := Main.new()
	for path in paths:
		if ResourceLoader.load_threaded_request(path, "", false) == OK:
			main._warm_people.append(path)
	main._warm_models() # Actual map-loading retention, without unrelated view-model worker jobs.
	for kind in ["core", "canhao", "bateria"]:
		var path: String = Entities.get_def(kind)["model"]
		expect(main._warm.has(path), "Pickup scene must stay in the map's retained cache")
		for repeat in 3:
			var item := Pickup.new()
			item.kind = kind
			var visual := item._build_visual()
			expect(visual.get_child_count() > 0, "Keep the original pickup model")
			visual.free()
			item.free()
			expect(ResourceLoader.has_cached(path), "Removing the last pickup must not evict its scene")
			expect(load(path) == main._warm[path], "The next drop must reuse the retained scene")
	main.free()
	print("Pickup cache regression failures: ", failures, "; retained pickup paths: ", paths.size())
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if failures else 0)
