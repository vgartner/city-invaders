extends RigidBody3D
## A thrown grenade of the resistance (definitions bergamota / porongo, type
## Grenade): it flies, bounces and rolls, its light blinking, until its fuse
## (the definition's effect.fuse_s) runs out. Every peer throws its own copy
## from the same start (main.grenade_thrown); only the server's bursts
## (main.grenade_burst: the blast or the EMP pulse).

const Entities := preload("res://scripts/entities.gd")

var kind := "bergamota"
var thrower_peer := 0
var _fuse := 2.0
var _t := 0.0
var _blink: OmniLight3D


func _ready() -> void:
	var d := Entities.get_def(kind)
	_fuse = float(d.get("effect", {}).get("fuse_s", 2.0))
	collision_layer = 0
	collision_mask = 1 | 64              # the world and the roofs; people and robots don't stop it
	mass = 0.45
	continuous_cd = true
	var mat := PhysicsMaterial.new()
	mat.bounce = 0.3
	mat.friction = 0.9
	physics_material_override = mat
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.1
	cs.shape = sph
	add_child(cs)
	var path: String = d.get("model", "")
	if ResourceLoader.exists(path):
		var m: Node3D = (load(path) as PackedScene).instantiate()
		m.scale = Vector3.ONE * float(d.get("scale", 2.0))
		m.position.y = -0.11                 # modelled standing on its base
		add_child(m)
	var glow: Array = d.get("glow", [1.0, 0.55, 0.15])
	_blink = OmniLight3D.new()
	_blink.light_color = Color(glow[0], glow[1], glow[2])
	_blink.omni_range = 2.5
	_blink.shadow_enabled = false
	add_child(_blink)
	angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))


func _physics_process(delta: float) -> void:
	_t += delta
	# blinks faster as the fuse runs down
	_blink.light_energy = 1.5 if fmod(_t * (3.0 + 6.0 * _t / _fuse), 1.0) < 0.5 else 0.0
	if _t >= _fuse:
		if multiplayer.is_server():
			get_tree().current_scene.grenade_burst(kind, global_position, thrower_peer)
		queue_free()
