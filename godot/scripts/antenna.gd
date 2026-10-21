extends StaticBody3D
## The robots' relay antenna: hidden on a rooftop, it coordinates the
## invasion - while it stands the dropships come faster. It can only be
## found from the air (a drone you fly, see player.gd); once spotted a red
## beacon marks it for everyone. Shots, cobs and blasts bring it down
## (it sits on the robots' layer, so every weapon that hits robots hits it).
## The server owns its health; every peer builds the same one (main places it).

signal destroyed

const HEALTH := 400
var health := HEALTH
var spotted := false
var _light: OmniLight3D
var _lamp_mat: StandardMaterial3D
var _beacon: MeshInstance3D
var _t := 0.0


func _ready() -> void:
	add_to_group("relay")
	collision_layer = 2
	collision_mask = 0
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.22, 0.23, 0.26)
	metal.metallic = 0.8
	metal.roughness = 0.35
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.7, 0.08, 0.06)
	red.metallic = 0.5
	# a lattice mast with a dish and a ring of emitters, robot-made
	_part(_cyl(0.9, 0.9, 0.5), Vector3(0, 0.25, 0), metal)
	for k in 4:
		var a := k * TAU / 4 + 0.4
		for seg in 3:                     # in three lengths, so it breaks up when it falls
			var leg := _part(_cyl(0.06, 0.06, 2.4), Vector3(cos(a) * 0.45, 1.2 + 2.4 * seg, sin(a) * 0.45), metal)
			leg.rotation = Vector3(sin(a) * 0.06, 0, -cos(a) * 0.06)
	for h in [1.8, 3.6, 5.4]:
		_part(_torus(0.42, 0.5), Vector3(0, h, 0), metal)
	var dish := _part(_cyl(1.1, 0.15, 0.35), Vector3(0, 6.3, 0.55), red)
	dish.rotation.x = -1.1
	_part(_cyl(0.08, 0.08, 2.2), Vector3(0, 8.2, 0), metal)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(1, 0.1, 0.05)
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(1, 0.1, 0.05)
	_lamp_mat.emission_energy_multiplier = 4.0
	var bulb := SphereMesh.new()
	bulb.radius = 0.22
	bulb.height = 0.44
	_part(bulb, Vector3(0, 9.4, 0), _lamp_mat)
	_light = OmniLight3D.new()
	_light.light_color = Color(1, 0.15, 0.1)
	_light.omni_range = 12.0
	_light.position = Vector3(0, 9.4, 0)
	add_child(_light)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 9.5, 2.0)
	cs.shape = box
	cs.position = Vector3(0, 4.75, 0)
	add_child(cs)


func _part(mesh: Mesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	add_child(mi)
	return mi


func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	return c


func _torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	return t


func is_alive() -> bool:
	return health > 0


func _process(delta: float) -> void:
	_t += delta
	var on := fmod(_t, 1.2) < 0.5 and health > 0           # the warning lamp blinks
	_light.light_energy = 3.0 if on else 0.2
	_lamp_mat.emission_energy_multiplier = 5.0 if on else 0.3


## Server: hit by a shot / cob / blast.
func apply_damage(amount: int, attacker: Node3D = null) -> void:
	if not multiplayer.is_server() or health <= 0:
		return
	set_health.rpc(max(0, health - amount), attacker.get_multiplayer_authority() if attacker and attacker.is_in_group("players") else 0)


@rpc("authority", "call_local", "reliable")
func set_health(h: int, by_peer: int) -> void:
	var was := health
	health = h
	if was > 0 and h <= 0:
		_fall(by_peer)


func _fall(by_peer: int) -> void:
	collision_layer = 0
	if _beacon:
		_beacon.queue_free()
	Sfx.play_at("robot_death", global_position + Vector3(0, 6, 0), 6.0, 160.0)
	_light.light_energy = 0.0
	_burst()
	_shatter()
	destroyed.emit()
	if multiplayer.is_server() and by_peer != 0:
		get_tree().current_scene.award(by_peer, 800, "relay antenna destroyed")


## Every peer: the mast blows apart - each part flies off as a loose piece,
## tumbles onto the roof (or down to the street) and is cleared away later.
func _shatter() -> void:
	var centre := global_position + Vector3(0, 4.5, 0)
	for mi in get_children():
		if not mi is MeshInstance3D:
			continue
		var piece := RigidBody3D.new()
		piece.collision_layer = 0
		piece.collision_mask = 1 | 64          # the world and the roofs
		piece.mass = 3.0
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = (mi as MeshInstance3D).get_aabb().size.max(Vector3.ONE * 0.12)
		cs.shape = box
		piece.add_child(cs)
		var at: Transform3D = mi.global_transform
		remove_child(mi)
		piece.add_child(mi)
		mi.transform = Transform3D.IDENTITY
		get_tree().current_scene.add_child(piece)
		piece.global_transform = at
		var out := (at.origin - centre)
		out.y = 0
		piece.linear_velocity = out.normalized() * randf_range(3, 7) + Vector3(randf_range(-2, 2), randf_range(4, 9), randf_range(-2, 2))
		piece.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
		get_tree().create_timer(14.0 + randf() * 4.0).timeout.connect(piece.queue_free)


## Every peer: sparks and smoke where the mast stood.
func _burst() -> void:
	var at := global_position + Vector3(0, 5, 0)
	for smoke in [false, true]:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.explosiveness = 0.9
		p.amount = 40 if smoke else 70
		p.lifetime = 2.5 if smoke else 1.2
		p.direction = Vector3.UP
		p.spread = 180.0
		p.initial_velocity_min = 2.0 if smoke else 6.0
		p.initial_velocity_max = 5.0 if smoke else 16.0
		p.gravity = Vector3(0, 1.5, 0) if smoke else Vector3(0, -9.8, 0)
		var m := SphereMesh.new()
		m.radius = 0.6 if smoke else 0.06
		m.height = m.radius * 2
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if smoke:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(0.2, 0.2, 0.2, 0.5)
		else:
			mat.albedo_color = Color(1.0, 0.7, 0.25)
		m.material = mat
		p.mesh = m
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.6
		get_tree().current_scene.add_child(p)
		p.global_position = at
		p.emitting = true
		get_tree().create_timer(4.0).timeout.connect(p.queue_free)
	var flash := OmniLight3D.new()
	flash.light_color = Color(1, 0.6, 0.25)
	flash.light_energy = 12.0
	flash.omni_range = 30.0
	get_tree().current_scene.add_child(flash)
	flash.global_position = at
	flash.create_tween().tween_property(flash, "light_energy", 0.0, 0.6)
	get_tree().create_timer(0.7).timeout.connect(flash.queue_free)


## Every peer: someone's drone found it - it shows on the GPS from now on.
@rpc("any_peer", "call_local", "reliable")
func mark_spotted() -> void:
	if spotted or health <= 0:
		return
	spotted = true                      # shown on the GPS and the HUD, no beacon in the sky
	Sfx.play("pickup", 0.0)
