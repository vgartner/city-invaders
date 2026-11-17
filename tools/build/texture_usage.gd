extends SceneTree
## Lists the textures the game's models draw with, and how each is used, into
## tools/build/texture_imports.json - what tools/map/texture_imports.py needs to
## make Godot import them compressed for the GPU (docs/PERFORMANCE.md).
## Run after adding or changing models, with the project imported:
##
##   godot --headless --path godot -s ../tools/build/texture_usage.gd
##
## Every model under res://assets is loaded and its materials read: a
## texture is "color" (albedo, emission), "normal" (a normal map: two
## channels, compressed as such) or "data" (roughness, metallic, occlusion).
## A texture used in two different ways, a height map (parallax shows every
## step of a compressed one) and anything a model does not draw with - the
## interface's images above all - are left out and stay lossless.

const OUT := "../tools/build/texture_imports.json"      # from the project folder
const ROOT := "res://assets"
const MATERIALS := "res://assets/materials"     # tiling PBR sets the game loads by path

var usage := {}       # path -> kind
var mixed := {}       # paths used in two ways


func _init() -> void:
	var models := []
	_find(ROOT, models)
	models.sort()
	var n := 0
	for path in models:
		var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res is PackedScene:
			var node: Node = (res as PackedScene).instantiate()
			_scan(node)
			node.free()
			n += 1
	var d := DirAccess.open(MATERIALS)
	if d:
		for set_name in d.get_directories():
			for f in DirAccess.get_files_at(MATERIALS.path_join(set_name)):
				var kind := ""
				match f.get_basename().to_lower():
					"color": kind = "color"
					"normalgl": kind = "normal"
					"roughness": kind = "data"
				if kind != "":
					_note(MATERIALS.path_join(set_name).path_join(f), kind)
	for path in mixed:
		usage.erase(path)
	var keys := usage.keys()
	keys.sort()
	var sorted := {}
	for k in keys:
		sorted[k] = usage[k]
	var file := FileAccess.open(ProjectSettings.globalize_path("res://").path_join(OUT).simplify_path(), FileAccess.WRITE)
	file.store_string(JSON.stringify(sorted, " ") + "\n")
	file.close()
	print("%d models, %d textures listed, %d used in two ways (left lossless)" % [n, usage.size(), mixed.size()])
	quit()


func _find(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in ["glb", "gltf", "tscn"]:
			out.append(dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		_find(dir.path_join(sub), out)


func _scan(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		_material(mi.material_override)
		if mi.mesh:
			for i in mi.mesh.get_surface_count():
				_material(mi.get_surface_override_material(i))
				_material(mi.mesh.surface_get_material(i))
	for c in node.get_children():
		_scan(c)


func _material(m: Material) -> void:
	var mat := m as BaseMaterial3D
	if mat == null:
		return
	_note_tex(mat.albedo_texture, "color")
	_note_tex(mat.emission_texture, "color")
	_note_tex(mat.detail_albedo, "color")
	_note_tex(mat.normal_texture, "normal")
	_note_tex(mat.detail_normal, "normal")
	_note_tex(mat.roughness_texture, "data")
	_note_tex(mat.metallic_texture, "data")
	_note_tex(mat.ao_texture, "data")
	_note_tex(mat.heightmap_texture, "height")
	if mat is ORMMaterial3D:
		_note_tex((mat as ORMMaterial3D).orm_texture, "data")
	_material(mat.next_pass)


func _note_tex(t: Texture2D, kind: String) -> void:
	if t is CompressedTexture2D and t.resource_path.begins_with(ROOT):
		_note(t.resource_path, kind)


func _note(path: String, kind: String) -> void:
	if kind == "height" or (usage.has(path) and usage[path] != kind):
		mixed[path] = true
	usage[path] = kind
