extends StaticBody3D
## A people container: where the robots keep the people their Coletores
## catch. The mothership brings each one and sets it down far from the
## players (they have to go looking). A transport ship beams each captive down into it; once it holds
## `capacity` people the mothership comes for it and lifts it away (they are
## lost). Players free them with E at the hatch, even while it is being
## lifted, until it leaves the ground for good.
## Every peer builds the same ones (main places them); the server owns the
## contents and calls the rpcs, and its position while the mothership hauls it.

signal opened(by_peer: int, people: Array)

const Civilian := preload("res://scripts/civilian.gd")

const MODEL := "res://assets/common/enemies/people_container/people_container.glb"   # when it arrives
const RADIUS := 1.6
const HEIGHT := 3.4
const REACH := 3.2               # E opens it from this close (to the hatch side)

var capacity := 8
var people: Array = []           # model indices (Civilian.MODELS) of who is inside
var lifting := false             # the mothership's beam has it (bringing or taking it)
var ground_y := 0.0              # the height of the spot it stands (or will stand) on
var ground_spot := Vector3.ZERO
var _figures: Node3D
var _glass_mat: StandardMaterial3D
var _label: Label3D
var _t := 0.0


func _ready() -> void:
	add_to_group("people_containers")
	collision_layer = 1
	collision_mask = 0
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position.y = HEIGHT / 2.0
	add_child(cs)
	if ResourceLoader.exists(MODEL):
		add_child((load(MODEL) as PackedScene).instantiate())
	else:
		_build_placeholder()
	_figures = Node3D.new()
	add_child(_figures)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 64
	_label.pixel_size = 0.006
	_label.outline_size = 12
	_label.modulate = Color(1.0, 0.6, 0.2)
	_label.position = Vector3(0, HEIGHT + 1.0, 0)
	add_child(_label)
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:position"))
	sync.replication_config = cfg
	add_child(sync)
	_refresh()


## Metres above its spot (the mothership hauling it up).
func lift() -> float:
	return position.y - ground_y


func full() -> bool:
	return people.size() >= capacity


## The hatch: where a player stands to open it (front, -Z).
func hatch() -> Vector3:
	return global_transform * Vector3(0, 0, -RADIUS - 0.6)


@rpc("authority", "call_local", "reliable")
func add_person(model_idx: int) -> void:
	people.append(model_idx)
	_refresh()


@rpc("authority", "call_local", "reliable")
func emptied() -> void:
	people.clear()
	lifting = false
	_refresh()


## Server: a player opened it - everyone inside runs out (main spawns them).
func open_by(peer: int) -> void:
	if not multiplayer.is_server() or people.is_empty() or lift() > HEIGHT:
		return
	var out := people.duplicate()
	emptied.rpc()
	opened.emit(peer, out)


func _refresh() -> void:
	if _label == null:
		return
	_label.text = "%d / %d" % [people.size(), capacity]
	_label.modulate = Color(1.0, 0.25, 0.2) if full() else Color(1.0, 0.6, 0.2)
	# the people inside, shrunk to fit, in two rings behind the glass
	for c in _figures.get_children():
		c.queue_free()
	for i in people.size():
		var path: String = Civilian.MODELS[int(people[i]) % Civilian.MODELS.size()]
		var m: Node3D = (load(path) as PackedScene).instantiate()
		var ring := 0.55 if i % 2 == 0 else 1.0
		var a := i * 2.4
		m.position = Vector3(cos(a) * ring, 0.35, sin(a) * ring)
		m.rotation.y = -a + PI / 2
		m.scale = Vector3.ONE * 0.75
		_figures.add_child(m)
		grey(m)
		var ap: Array = m.find_children("*", "AnimationPlayer", true, false)
		if not ap.is_empty():
			var anim: AnimationPlayer = ap[0]
			for clip in ["idle", "idle_alert", "idle_selling"]:
				if anim.has_animation(clip):
					anim.play(clip)
					anim.seek(randf() * anim.current_animation_length, true)
					break


## A captive as a figure of one flat grey (no face, no clothes): the same
## silhouette for anyone in a capsule or a container.
static var _grey_mat: StandardMaterial3D
static func grey(fig: Node3D) -> void:
	if _grey_mat == null:
		_grey_mat = StandardMaterial3D.new()
		_grey_mat.albedo_color = Color(0.55, 0.57, 0.6)
		_grey_mat.roughness = 0.8
	for mi in fig.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = _grey_mat


func _process(delta: float) -> void:
	_t += delta
	if _glass_mat:
		var pulse := 0.5 + 0.5 * sin(_t * (4.0 if full() else 1.6))
		_glass_mat.emission_energy_multiplier = 0.4 + 0.6 * pulse


# ---- placeholder (until the modelled container arrives) ---------------------

func _build_placeholder() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.16, 0.17, 0.2)
	metal.metallic = 0.85
	metal.roughness = 0.35
	_glass_mat = StandardMaterial3D.new()
	_glass_mat.albedo_color = Color(0.35, 0.9, 1.0, 0.22)
	_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_glass_mat.emission_enabled = true
	_glass_mat.emission = Color(0.2, 0.8, 1.0)
	_glass_mat.metallic = 0.2
	_glass_mat.roughness = 0.05
	_part(_cyl(RADIUS + 0.25, RADIUS + 0.35, 0.35), Vector3(0, 0.17, 0), metal)        # base
	_part(_cyl(RADIUS, RADIUS, HEIGHT - 0.7), Vector3(0, 0.35 + (HEIGHT - 0.7) / 2.0, 0), _glass_mat)
	_part(_cyl(RADIUS + 0.2, RADIUS + 0.1, 0.35), Vector3(0, HEIGHT - 0.17, 0), metal)  # lid
	_part(_cyl(0.35, 0.5, 0.4), Vector3(0, HEIGHT + 0.2, 0), metal)                     # lifting eye
	for k in 4:                                   # ribs
		var a := k * TAU / 4 + PI / 4
		_part(_box(Vector3(0.18, HEIGHT - 0.4, 0.18)), Vector3(cos(a) * (RADIUS + 0.05), HEIGHT / 2.0, sin(a) * (RADIUS + 0.05)), metal)
	var hatch_mat := StandardMaterial3D.new()
	hatch_mat.albedo_color = Color(1.0, 0.55, 0.1)
	hatch_mat.emission_enabled = true
	hatch_mat.emission = Color(1.0, 0.45, 0.05)
	hatch_mat.emission_energy_multiplier = 1.5
	_part(_box(Vector3(0.5, 0.25, 0.12)), Vector3(0, 1.2, -RADIUS - 0.08), hatch_mat)   # the release handle
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 0.85, 1.0)
	light.light_energy = 1.2
	light.omni_range = 6.0
	light.position = Vector3(0, HEIGHT / 2.0, 0)
	add_child(light)


func _part(mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 24
	return c


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b
