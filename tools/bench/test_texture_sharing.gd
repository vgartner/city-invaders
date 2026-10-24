extends SceneTree
const Sharing = preload("res://scripts/texture_sharing.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := "--packed" in OS.get_cmdline_user_args()
	var source: CompressedTexture2D
	var other: CompressedTexture2D
	if packed:
		source = CompressedTexture2D.new()
		other = CompressedTexture2D.new()
		assert(source.load("res://test/bark.ctex") == OK)
		assert(other.load("res://test/leaves.ctex") == OK)
	else:
		source = load("res://city/bark.png")
		other = load("res://city/leaves.png")
	var copy := CompressedTexture2D.new()
	assert(copy.load(source.get_load_path()) == OK)
	assert(copy != source)
	var a := StandardMaterial3D.new()
	var b := StandardMaterial3D.new()
	a.albedo_texture = source
	b.albedo_texture = copy
	b.normal_texture = other
	var sphere := SphereMesh.new()
	sphere.material = b
	var instance := MeshInstance3D.new()
	instance.mesh = sphere
	var sharing := Sharing.new()
	sharing.resource(a)
	sharing.tree(instance)
	assert(a.albedo_texture == b.albedo_texture, "Identical imported payloads must share")
	assert(b.normal_texture == other, "Different pixels/import formats must remain distinct")
	assert(sphere.radius == 0.5 and instance.mesh == sphere, "Geometry must remain unchanged")
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var dynamic := ImageTexture.create_from_image(image)
	b.albedo_texture = dynamic
	sharing = Sharing.new()
	sharing.resource(b)
	assert(b.albedo_texture == dynamic, "Procedural textures must not be read back")
	# Strong cache entries would keep every visited map's textures alive.
	sharing.resource(a)
	var ref := _visit_duplicate(sharing, source.get_load_path())
	assert(ref.get_ref() == null, "Sharing cache must not retain duplicate texture objects")
	instance.free()
	print("Texture sharing tests passed (packed=%s)" % packed)
	quit()

func _visit_duplicate(sharing: RefCounted, path: String) -> WeakRef:
	var probe := CompressedTexture2D.new()
	assert(probe.load(path) == OK)
	var ref: WeakRef = weakref(probe)
	var canonical: Texture2D = sharing._texture(probe)
	assert(canonical != probe)
	return ref
