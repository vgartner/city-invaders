extends Node
## Palette thumbnails: each model is rendered once in a small offscreen
## studio (its own world, a key light, a 3/4 view framed on its bounds) and
## the picture is kept in user://thumbs/, so the next session shows it at once.
## Requests queue up; a few render per frame so the editor never stalls.

const SIZE := 96
const DIR := "user://thumbs"

signal ready_thumb(path: String, tex: Texture2D)

var _queue: Array = []
var _cache := {}                  # model path -> Texture2D
var _vp: SubViewport
var _cam: Camera3D
var _slot: Node3D
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS       # the world is paused in design mode
	DirAccess.make_dir_recursive_absolute(DIR)
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.environment.ambient_light_energy = 0.8
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0)
	sun.light_energy = 1.3
	_vp.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	_vp.add_child(_cam)
	_slot = Node3D.new()
	_vp.add_child(_slot)


## The thumbnail of `path` (a .glb / layout.json), or null while it renders;
## `ready_thumb` fires when it is there.
func get_thumb(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var file := _file(path)
	if FileAccess.file_exists(file):
		var img := Image.load_from_file(file)
		if img:
			_cache[path] = ImageTexture.create_from_image(img)
			return _cache[path]
	if not path in _queue:
		_queue.append(path)
	return null


func _file(path: String) -> String:
	return DIR.path_join("%s.png" % path.md5_text())


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	await _render(_queue.pop_front())
	_busy = false


func _render(path: String) -> void:
	for c in _slot.get_children():
		c.free()
	var model := path
	if path.ends_with("layout.json"):
		# an interior set: its first room piece stands for it
		var lay = JSON.parse_string(FileAccess.get_file_as_string(path))
		if lay is Dictionary and not lay.get("instances", []).is_empty():
			model = path.get_base_dir().path_join(lay["instances"][0]["model"]).simplify_path()
	if not ResourceLoader.exists(model):
		return
	var packed := load(model) as PackedScene
	if packed == null:
		return
	var m := packed.instantiate()
	_slot.add_child(m)
	for ap in m.find_children("*", "AnimationPlayer", true, false):
		(ap as AnimationPlayer).stop()
	var box := AABB()
	var first := true
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		return
	var radius := maxf(box.size.length() / 2.0, 0.05)
	var dist := radius / sin(deg_to_rad(_cam.fov / 2.0)) * 1.05
	var centre := box.get_center()
	_cam.position = centre + Vector3(1.0, 0.75, 1.2).normalized() * dist
	_cam.look_at(centre, Vector3.UP)
	_cam.near = maxf(dist - radius * 2.0, 0.01)
	_cam.far = dist + radius * 2.0
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	if img:
		img.save_png(_file(path))
		var tex := ImageTexture.create_from_image(img)
		_cache[path] = tex
		ready_thumb.emit(path, tex)
