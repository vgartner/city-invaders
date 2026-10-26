extends Area3D
const Entities := preload("res://scripts/entities.gd")
## Pickup on the street: espeto de churrasco (big heal), chimarrão (small
## heal), pala (armour), ammo box or machine gun, resting on the
## ground with a softly pulsing ring of light. The server decides who gets
## it and hides it for RESPAWN_SECONDS; clients only mirror `active`.

const MODELS := {
	"medkit": "res://assets/common/pickups/medkit/medkit.glb",
	"churrasco": "res://assets/rio_grande_do_sul/pickups/churrasco/churrasco.glb",
	"chimarrao": "res://assets/rio_grande_do_sul/pickups/chimarrao/chimarrao.glb",
	"pala": "res://assets/rio_grande_do_sul/pickups/pala/pala.glb",
	"remedio": "res://assets/common/pickups/medkit/medkit.glb",
	"fruki": "res://assets/rio_grande_do_sul/pickups/fruki/fruki.glb",
	"ammo": "res://assets/common/pickups/ammo/ammo.glb",
	"machinegun": "res://assets/common/weapons/machinegun/carbine_556_pickup.glb",
	"revolver": "res://assets/common/weapons/revolver/revolver_38_pickup.glb",
	"shotgun": "res://assets/common/weapons/shotgun/shotgun_12g_pickup.glb",
	"laco": "res://assets/rio_grande_do_sul/pickups/laco/laco.glb",
	"pistol": "res://assets/common/weapons/pistol/pistol_9mm_pickup.glb",
	"espeto": "res://assets/rio_grande_do_sul/weapons/espeto/espeto_com_carne_pickup.glb",
}
const RESPAWN_SECONDS := 25.0
## parts robots drop (traded at repair shops): kind -> glow
const PARTS := {"circuit": Color(0.2, 1.0, 0.4), "core": Color(0.3, 0.6, 1.0), "lens": Color(0.4, 1.0, 1.0),
		"module": Color(1.0, 0.6, 0.15)}
const MEDKIT_HEAL := 35
## models smaller than a medkit are shown larger so they read from afar
const SCALE := {"remedio": 0.6, "fruki": 3.0, "chimarrao": 2.2, "churrasco": 1.0, "pala": 1.0, "laco": 1.5}
const GLOW := {"medkit": Color(0.3, 1.0, 0.45), "churrasco": Color(1.0, 0.45, 0.2),
		"chimarrao": Color(0.45, 1.0, 0.3), "pala": Color(0.85, 0.65, 1.0), "laco": Color(0.95, 0.7, 0.35), "remedio": Color(0.3, 1.0, 0.45), "fruki": Color(1.0, 0.85, 0.1), "ammo": Color(1.0, 0.75, 0.25), "machinegun": Color(0.3, 0.85, 1.0),
		"revolver": Color(0.3, 0.85, 1.0), "shotgun": Color(0.3, 0.85, 1.0), "pistol": Color(0.3, 0.85, 1.0)}
## a definition's "lie": modelled upright (origin at its centre), it lies on its
## side this high; "stand": it stands upright with its lowest point on the street
const LIE := {}

@export var active := true
var kind := "medkit"
var respawns := true
var fixed := false              # placed by a building (the pharmacy's remedy): comes back in the same spot
var _visual: Node3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _t := 0.0


## Include definition-driven drops/gadgets as well as legacy fallback models.
## Retain these scenes during map loading, even after their last pickup is gone.
static func model_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for path in MODELS.values():
		if not path in paths and ResourceLoader.exists(path):
			paths.append(path)
	for definition in Entities.all():
		var path: String = definition.get("model", "")
		if definition.get("pickup", false) and not path.is_empty() \
				and not path in paths and ResourceLoader.exists(path):
			paths.append(path)
	return paths


func _ready() -> void:
	collision_layer = 0
	collision_mask = 4          # players
	monitoring = true
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.9
	cs.shape = sph
	cs.position.y = 0.6
	add_child(cs)
	_visual = _build_visual()
	# rest at a varied angle, the same on every peer (derived from the name)
	_visual.rotation.y = fmod(float(hash(str(name))) * 0.001, TAU)
	add_child(_visual)
	_t = fmod(float(hash(str(name))) * 0.01, TAU)
	_build_ring()
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:active"))
	cfg.add_property(NodePath(".:position"))
	sync.replication_config = cfg
	add_child(sync)
	if multiplayer.is_server():
		body_entered.connect(_on_body)


func _build_visual() -> Node3D:
	var root := Node3D.new()
	# what it looks like comes from its entity definition (docs/ENTITIES.md)
	var d: Dictionary = Entities.get_def(kind)
	var model: String = d.get("model", MODELS.get(kind, ""))
	if ResourceLoader.exists(model):
		root.add_child((load(model) as PackedScene).instantiate())
		root.position.y = 0.01 + float(d.get("lift", 0.0))
		root.scale = Vector3.ONE * float(d.get("scale", SCALE.get(kind, 1.0)))
		var lie: float = d.get("lie", LIE.get(kind, -1.0))
		if lie >= 0.0:
			root.rotation.z = PI / 2
			root.position.y = lie
		elif d.get("stand", false):
			var low := INF
			for mi in root.find_children("*", "MeshInstance3D", true, false):
				var xf := Transform3D.IDENTITY
				var n: Node = mi
				while n != root:
					xf = (n as Node3D).transform * xf
					n = n.get_parent()
				low = minf(low, (xf * (mi as MeshInstance3D).get_aabb()).position.y)
			if low < INF:
				root.position.y = 0.01 + float(d.get("lift", 0.0)) - low * root.scale.y
		return root
	# placeholder until the generated models arrive
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	if PARTS.has(kind):
		# robot parts: small glowing pieces
		var c: Color = PARTS[kind]
		var m: Mesh = BoxMesh.new() if kind in ["circuit", "module"] else SphereMesh.new()
		if m is BoxMesh:
			(m as BoxMesh).size = Vector3(0.28, 0.05, 0.2) if kind == "circuit" else Vector3(0.3, 0.3, 0.3)
		else:
			(m as SphereMesh).radius = 0.14
			(m as SphereMesh).height = 0.28
		mi.mesh = m
		mat.albedo_color = c * 0.6
		mat.emission_enabled = true
		mat.emission = c
		mat.emission_energy_multiplier = 1.5
		mat.metallic = 0.6
		mi.material_override = mat
		root.add_child(mi)
		root.position.y = 0.2
		return root
	match kind:
		"medkit":
			var box := BoxMesh.new()
			box.size = Vector3(0.5, 0.3, 0.35)
			mi.mesh = box
			mat.albedo_color = Color(0.95, 0.95, 0.95)
			var cross := MeshInstance3D.new()
			var cb := BoxMesh.new()
			cb.size = Vector3(0.3, 0.32, 0.08)
			cross.mesh = cb
			var cm := StandardMaterial3D.new()
			cm.albedo_color = Color(0.9, 0.05, 0.05)
			cm.emission_enabled = true
			cm.emission = Color(0.9, 0.05, 0.05)
			cross.material_override = cm
			root.add_child(cross)
			var cross2 := cross.duplicate()
			cross2.rotation.y = PI / 2
			root.add_child(cross2)
		"ammo":
			var box := BoxMesh.new()
			box.size = Vector3(0.45, 0.28, 0.3)
			mi.mesh = box
			mat.albedo_color = Color(0.3, 0.38, 0.22)
		"machinegun":
			var box := BoxMesh.new()
			box.size = Vector3(0.15, 0.2, 0.9)
			mi.mesh = box
			mat.albedo_color = Color(0.15, 0.15, 0.16)
			mat.metallic = 0.8
	mi.material_override = mat
	root.add_child(mi)
	root.position.y = 0.15
	return root


func _build_ring() -> void:
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.48
	torus.outer_radius = 0.56
	_ring.mesh = torus
	_ring.scale = Vector3(1, 0.05, 1)
	_ring.position.y = 0.03
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var g = Entities.get_def(kind).get("glow")
	_ring_mat.albedo_color = Color(g[0], g[1], g[2]) if g is Array else GLOW.get(kind, Color.WHITE)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)


func _process(delta: float) -> void:
	_visual.visible = active
	_ring.visible = active
	_t += delta
	var pulse := 0.5 + 0.5 * sin(_t * 2.2)
	_ring_mat.albedo_color.a = 0.25 + 0.55 * pulse
	_ring.scale = Vector3.ONE * (1.0 + 0.06 * pulse) * Vector3(1, 0.05, 1)


func _on_body(body: Node) -> void:
	if not active or not body.is_in_group("players") or body.dead:
		return
	if not body.can_take(kind):
		body.refused.rpc_id(body.get_multiplayer_authority(), kind)   # says why (pockets full...)
		return
	body.give.rpc_id(body.get_multiplayer_authority(), kind)
	if respawns:
		active = false
		get_tree().create_timer(RESPAWN_SECONDS).timeout.connect(_respawn_elsewhere)
	else:
		queue_free()


## Server: reappear at a new street point, away from where it was taken.
func _respawn_elsewhere() -> void:
	if not fixed:
		global_position = get_tree().current_scene.random_pickup_point(global_position)
	active = true
