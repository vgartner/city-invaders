extends AnimatableBody3D
## Traffic vehicle: car, bus, motorcycle courier or cyclist. The server
## drives it along the road graph (right-hand lane, one-way streets
## respected), picks a random continuation at every junction and brakes for
## anything in front of it. Clients mirror position/rotation.

const Library := preload("res://scripts/model_library.gd")
## kind -> folder, share of the traffic, cruise speed (m/s), extra offset to
## the right of the lane, riding clip and the ground speed it was animated at
const KINDS := {
	"car": {"dir": "res://assets/common/cars", "dirs": ["res://assets/rio_grande_do_sul/cars"], "share": 0.41, "speed": 8.5, "kerb": 0.0},
	"bus": {"dir": "res://assets/common/buses", "dirs": ["res://assets/rio_grande_do_sul/buses"], "share": 0.12, "speed": 7.0, "kerb": 0.2},
	# the armoured combine harvester (never in the traffic: parked by main)
	"harvester": {"dir": "res://assets/rio_grande_do_sul/war", "share": 0.0, "speed": 0.0, "kerb": 0.0},
	# delivery lorries (Fruki box truck, Fruki tractor-trailer on long avenues)
	"lorry": {"dir": "res://assets/rio_grande_do_sul/lorries", "dirs": ["res://assets/rio_grande_do_sul/service"], "share": 0.04, "speed": 7.5, "kerb": 0.3},
	# fuel tanker: explodes when shot to pieces
	"truck": {"dir": "res://assets/rio_grande_do_sul/trucks", "share": 0.04, "speed": 7.0, "kerb": 0.3},
	"motoboy": {"dir": "res://assets/common/motoboys", "share": 0.18, "speed": 8.44, "kerb": 0.6,
			"clip": "ride", "stop_clip": "idle_stopped", "clip_speed": 8.44},
	"cyclist": {"dir": "res://assets/common/cyclists", "share": 0.15, "speed": 4.976, "kerb": 1.5,
			"clip": "ride", "stop_clip": "idle_on_bike", "clip_speed": 4.976},
	# a gaúcho on horseback trotting through town; walk / canter by speed
	"horse": {"dir": "res://assets/rio_grande_do_sul/horses", "share": 0.06, "speed": 2.3, "kerb": 1.2,
			"clip": "trot", "stop_clip": "idle", "clip_speed": 2.1},
}
static var MODELS: PackedStringArray = _all_models()
const CRUISE := 8.5            # m/s (~30 km/h downtown)
const LANE_TWO_WAY := 1.7      # offset to the right of the centre line
const LANE_ONE_WAY := 0.9
const LENGTH := 4.4

@export var model_idx := 0
var kind := "car"
var _cruise := CRUISE
var _anim: AnimationPlayer
var graph: Dictionary          # {"nodes": [...], "edges": [...], "out": {node: [[edge, forward], ...]}}
var _path: PackedVector3Array = PackedVector3Array()
var _i := 0
var _speed := 0.0
var _node := -1
var _box: BoxShape3D
var _length := LENGTH
var _wheels: Array = []
var _wheel_radius := 0.3
var _last_pos := Vector3.ZERO
var _blocked_time := 0.0
## someone at the wheel / on the saddle. Shot at, they get out and run; the
## vehicle stays where it stopped (players can take it later)
@export var driver_idx := -1          # car/bus driver's pedestrian model, set by the server
var occupied := true
var _driver: Node3D
var _rider: Node3D                    # cyclists / motoboys: the rider mesh in the model
var _fall_tween: Tween                # the bike falling over when its rider bails
var _rider_parts: Array = []          # horseman: rider mesh, hat and scarf
var _box_centre := Vector3.ZERO
var _cs: CollisionShape3D
var _reel: Node3D                     # harvester: the spinning shredder
var _engine: AudioStreamPlayer3D
var _engine_base := 1.0
var _engine_db := -12.0              # this kind's base level (Tune.engine_* on top)
## a player at the controls (peer id; 0 = AI traffic or parked)
var driver_peer := 0
var _input := Vector3.ZERO            # throttle, steer, handbrake from the driver
## kind -> top speed m/s, acceleration m/s2, max steering angle (rad)
const DRIVE := {"car": [24.0, 7.0, 0.55], "bus": [15.0, 3.5, 0.5],
		"motoboy": [22.0, 8.0, 0.6], "cyclist": [9.0, 3.0, 0.6], "horse": [7.5, 4.0, 0.7],     # horse: the canter clip at 2.2x
		"truck": [17.0, 3.0, 0.45], "harvester": [12.0, 3.5, 0.5], "lorry": [18.0, 3.2, 0.48]}


func _ready() -> void:
	# drawn between physics steps, so driving looks smooth at any frame rate
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	reset_physics_interpolation.call_deferred()
	collision_layer = 16
	collision_mask = 0
	sync_to_physics = false
	_build_visual()
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:position"))
	cfg.add_property(NodePath(".:rotation"))
	cfg.add_property(NodePath(".:_hp"))          # the driver's HUD shows the vehicle's state
	sync.replication_config = cfg
	add_child(sync)
	set_physics_process(multiplayer.is_server())


## A kind's folders: its main one plus the collections' ("dirs").
static func _dirs(k: String) -> Array:
	return [KINDS[k]["dir"]] + KINDS[k].get("dirs", [])


static func _all_models() -> PackedStringArray:
	var out := PackedStringArray()
	for k in KINDS:
		out.append_array(Library.models(KINDS[k]["dir"], "res://assets/kenney/cars" if k == "car" else ""))
		for d in KINDS[k].get("dirs", []):
			out.append_array(Library._list(d))
	return out


static func kind_of(path: String) -> String:
	for k in KINDS:
		for d in _dirs(k):
			if path.begins_with(d + "/"):
				return k
	return "car"


## A model index for a new vehicle: the kind by its share, then any model of it.
static func pick() -> int:
	var r := randf()
	for k in KINDS:
		r -= KINDS[k]["share"]
		var of_kind := []
		for i in MODELS.size():
			if kind_of(MODELS[i]) == k:
				of_kind.append(i)
		if r <= 0.0 and not of_kind.is_empty():
			return of_kind.pick_random()
	return randi() % MODELS.size()


func _build_visual() -> void:
	var path: String = MODELS[model_idx % MODELS.size()]
	kind = kind_of(path)
	_cruise = KINDS[kind]["speed"]
	var model: Node3D = (load(path) as PackedScene).instantiate()
	add_child(model)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = 160.0      # far traffic isn't drawn
		(mi as MeshInstance3D).visibility_range_end_margin = 10.0
	var kenney := path.begins_with("res://assets/kenney/")
	if kenney:
		# fallback set: toy-scale, facing +Z
		var raw := _bounds(model)
		var long: float = max(raw.size.x, raw.size.z)
		if long > 0.01:
			model.scale = Vector3.ONE * (LENGTH / long)
		if raw.size.x > raw.size.z:
			model.rotation.y = PI / 2
		model.rotation.y += PI
	# generated fleet: real size, front -Z, ground at y=0 - used as authored
	var box := _bounds(model)
	var cs := CollisionShape3D.new()
	_cs = cs
	_box = BoxShape3D.new()
	_box.size = Vector3(box.size.x, box.size.y, box.size.z) if not kenney \
			else Vector3(min(box.size.x, box.size.z), box.size.y, max(box.size.x, box.size.z))
	cs.shape = _box
	cs.position = box.get_center()
	add_child(cs)
	_length = _box.size.z
	_box_centre = box.get_center()
	if kind in ["car", "bus", "truck", "motoboy", "harvester", "lorry"]:
		# engine note: low idle, rising with speed; only heard close by
		_engine = AudioStreamPlayer3D.new()
		# a recorded car engine loop (qubodup, CC-BY 3.0), pitched per vehicle:
		# it was recorded revving, so idle sits well below 1.0
		var st: AudioStreamWAV = (load("res://assets/audio/engine_recorded.wav") as AudioStreamWAV).duplicate()
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_end = st.data.size() / 2
		_engine.stream = st
		_engine_db = {"bus": -6.0, "truck": -5.0, "harvester": -3.0, "motoboy": -10.0}.get(kind, -12.0)
		_engine.volume_db = _engine_db + Tune.engine_db
		_engine.unit_size = 6.0
		_engine.max_distance = 60.0
		_engine.autoplay = true
		_engine_base = {"bus": 0.3, "truck": 0.27, "lorry": 0.29, "harvester": 0.24, "motoboy": 0.62}.get(kind, 0.42)
		_engine.pitch_scale = _engine_base
		add_child(_engine)
	if kind in ["car", "bus", "truck", "lorry"]:
		_seat_driver(box)
	if KINDS[kind].has("clip"):
		# riders: the clip pedals / steers and turns the wheels itself
		var players := model.find_children("*", "AnimationPlayer", true, false)
		if players.size() > 0:
			_anim = players[0]
			for c in [KINDS[kind]["clip"], KINDS[kind]["stop_clip"], "walk", "canter"]:
				if _anim.has_animation(c):
					_anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
			_anim.play(KINDS[kind]["clip"])
		var r := model.find_child("rider_mesh", true, false)
		if r:
			_rider = r
		if kind == "horse":
			# the rider: the pedestrian mesh with hat and scarf; the horse stays
			for mi in model.find_children("*", "MeshInstance3D", true, false):
				if not String(mi.name).begins_with("cavalo") and not String(mi.name).begins_with("horse"):
					_rider_parts.append(mi)
			if randf() < 0.5:
				_saddlebag(model)
		return
	_reel = model.find_child("reel", true, false) as Node3D
	for w in model.find_children("wheel_*", "Node3D", true, false):
		_wheels.append(w)
		var wb := _bounds(w)
		_wheel_radius = max(_wheel_radius, wb.size.y / 2.0)


## Half the horses carry a mala de garupa behind the saddle: modelled in the
## horse's own coordinates (rio_grande_do_sul/gaucho/mala_garupa), it rides
## on the Pelvis bone so it follows the trot.
const SADDLEBAG := "res://assets/rio_grande_do_sul/gaucho/mala_garupa/mala_garupa_cavalo.glb"
func _saddlebag(model: Node3D) -> void:
	if not ResourceLoader.exists(SADDLEBAG):
		return
	var sk := model.find_children("*", "Skeleton3D", true, false)
	if sk.is_empty():
		return
	var skel: Skeleton3D = sk[0]
	var bone := skel.find_bone("Pelvis")
	if bone < 0:
		return
	var att := BoneAttachment3D.new()
	att.bone_name = "Pelvis"
	skel.add_child(att)
	var bag: Node3D = (load(SADDLEBAG) as PackedScene).instantiate()
	att.add_child(bag)
	# in the bone's frame, the bag sits where it was modelled on the horse
	var bone_in_model: Transform3D = (model.global_transform.affine_inverse() * skel.global_transform) * skel.get_bone_global_rest(bone)
	bag.transform = bone_in_model.affine_inverse()


## A pedestrian sitting at the wheel (left seat; the bus driver up front):
## the walker's skeleton bent at hips and knees, hands forward on the wheel.
func _seat_driver(box: AABB) -> void:
	const Civ := preload("res://scripts/civilian.gd")
	var models: PackedStringArray = Civ.MODELS
	var idx: int = driver_idx if driver_idx >= 0 else (abs(hash(str(name))) % models.size())
	var path: String = models[idx % models.size()]
	if not path.begins_with("res://assets/common/people/"):
		for m in models:
			if m.begins_with("res://assets/common/people/"):
				path = m
				break
	var d: Node3D = (load(path) as PackedScene).instantiate()
	add_child(d)
	for mi in d.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visibility_range_end = 60.0
	var skels := d.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		d.queue_free()
		return
	var sk: Skeleton3D = skels[0]
	# bend: deltas in skeleton space applied over the rest pose, parents first
	# thighs forward and knees bent back down: the shins went straight through the floor and out
	var bend := {"LeftUpLeg": Basis(Vector3.RIGHT, deg_to_rad(85)), "RightUpLeg": Basis(Vector3.RIGHT, deg_to_rad(85)),
			"LeftLeg": Basis(Vector3.RIGHT, deg_to_rad(-80)), "RightLeg": Basis(Vector3.RIGHT, deg_to_rad(-80)),
			"LeftArm": Basis(Vector3.RIGHT, deg_to_rad(55)), "RightArm": Basis(Vector3.RIGHT, deg_to_rad(55)),
			"LeftForeArm": Basis(Vector3.RIGHT, deg_to_rad(80)), "RightForeArm": Basis(Vector3.RIGHT, deg_to_rad(80)),
			"LeftHand": Basis(Vector3.RIGHT, deg_to_rad(80)), "RightHand": Basis(Vector3.RIGHT, deg_to_rad(80))}
	var glob := {}
	for b in sk.get_bone_count():
		var parent := sk.get_bone_parent(b)
		var rest := sk.get_bone_global_rest(b)
		var key := sk.get_bone_name(b).trim_prefix("mixamorig:").trim_prefix("mixamorig_")
		var g := Transform3D((bend[key] if bend.has(key) else Basis()) * rest.basis, rest.origin)
		if parent >= 0:
			# keep the joint where the (moved) parent puts it
			var pg: Transform3D = glob[parent]
			g.origin = pg * (sk.get_bone_global_rest(parent).affine_inverse() * rest.origin)
			var local := pg.affine_inverse() * g
			sk.set_bone_pose_rotation(b, local.basis.get_rotation_quaternion())
		glob[b] = g
	var hips := sk.find_bone("mixamorig:Hips")
	if hips < 0:
		hips = sk.find_bone("mixamorig_Hips")
	var hip_y: float = (sk.global_transform * sk.get_bone_global_rest(max(hips, 0)).origin).y - global_position.y if is_inside_tree() \
			else sk.get_bone_global_rest(max(hips, 0)).origin.y * 1.0
	var seat_y: float = box.position.y + {"bus": 1.15, "truck": 1.55, "lorry": 1.45}.get(kind, 0.48)
	var x := box.position.x + box.size.x * (0.3 if kind == "car" else 0.25)
	var z: float = box.position.z + {"bus": 1.0, "truck": 0.95, "lorry": 0.9}.get(kind, box.size.z * 0.5)
	d.position = Vector3(x, seat_y - hip_y, z)
	_driver = d


## motor vehicles have hit points: shot to pieces they explode (the tanker
## sooner, the armoured harvester much later); bikes and horses don't
const HP := {"car": 150, "bus": 300, "truck": 100, "motoboy": 60, "harvester": 900, "lorry": 250}
var _hp := 0
var _wrecked := false


## Server: a shot hit this vehicle. Whoever is aboard gets out and runs;
## a fuel tanker shot to pieces explodes.
func apply_damage(_amount: int, attacker: Node3D = null) -> void:
	if not multiplayer.is_server():
		return
	if HP.has(kind) and not _wrecked:
		if _hp == 0:
			_hp = HP[kind]
		_hp -= _amount
		if _hp <= 0:
			_explode(attacker)
			return
	if not occupied:
		return
	occupied = false
	_cruise = 0.0
	_speed = 0.0
	var threat: Vector3 = attacker.global_position if attacker else global_position
	bail.rpc()
	# the person comes out on the kerb side, away from the shooter
	var side := global_transform.basis.x * (_box.size.x / 2 + 0.6) * (-1.0 if kind in ["car", "bus"] else 1.0)
	var main := get_tree().current_scene
	if main.has_method("spawn_fleeing"):
		main.spawn_fleeing(global_position + side, threat, driver_idx if kind in ["car", "bus"] else -1)


## Server: the tanker blows up - everyone and everything within 12 m is hurt,
## robots most of all; the wreck stays, burnt out.
func _explode(by: Node3D) -> void:
	_wrecked = true
	_cruise = 0.0
	_speed = 0.0
	var burnt_peer := driver_peer
	if driver_peer != 0:
		var drv: Node = get_tree().current_scene.players_root.get_node_or_null(str(driver_peer))
		if drv:
			drv.burned.rpc_id(driver_peer)      # trapped inside: burnt to death
		driver_peer = 0
		set_driven.rpc(0)
	var at := global_position + Vector3(0, 1.5, 0)
	var big := kind in ["truck", "harvester"]     # a tank of fuel / diesel: the big blast
	for group in ["robots", "civilians", "players"]:
		for n in get_tree().get_nodes_in_group(group):
			var d: float = (n as Node3D).global_position.distance_to(at)
			var radius := 12.0 if big else 6.0
			if d > radius:
				continue
			var dmg := int(lerp(140.0 if big else 90.0, 20.0, d / radius))
			if group == "players":
				n.hurt.rpc_id(n.get_multiplayer_authority(), int(dmg * 0.6), at)
			elif n.has_method("apply_damage"):
				n.apply_damage(dmg, by)
	explode_fx.rpc(burnt_peer != 0)
	get_tree().create_timer(WRECK_KEEP_S).timeout.connect(_clear_wreck)


## Server: a burnt-out wreck is towed away once no player is looking at it.
const WRECK_KEEP_S := 30.0
func _clear_wreck() -> void:
	if not is_inside_tree():
		return
	for pl in get_tree().get_nodes_in_group("players"):
		if _seen_by(pl):
			get_tree().create_timer(3.0).timeout.connect(_clear_wreck)
			return
	queue_free()


func _seen_by(pl: Node3D) -> bool:
	var eye: Vector3 = pl.camera.global_position if "camera" in pl and pl.camera else pl.global_position + Vector3(0, 1.6, 0)
	var to := global_position + Vector3(0, 1.0, 0) - eye
	if to.length() > 160.0:
		return false
	var fwd: Vector3 = -pl.global_transform.basis.z
	fwd.y = 0
	var flat := Vector3(to.x, 0, to.z)
	if flat.length() > 4.0 and fwd.normalized().angle_to(flat.normalized()) > deg_to_rad(70):
		return false                 # outside the view (the camera shows about 55 degrees either side)
	var q := PhysicsRayQueryParameters3D.create(eye, global_position + Vector3(0, 1.0, 0), 1 | 64)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Harvester grain gun: corn and soy blasted out of the unloading auger.
const GRAIN_DAMAGE := 22             # one corn cob
@rpc("any_peer", "call_local", "unreliable")
func grain_fire(dir: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or kind != "harvester" or (sender if sender != 0 else 1) != driver_peer:
		return
	var tip := find_child("muzzle_auger", true, false) as Node3D
	var from: Vector3 = tip.global_position if tip else global_position + Vector3(0, 4.5, 0)
	var driver := get_tree().current_scene.players_root.get_node_or_null(str(driver_peer)) as Node3D
	var ends := []
	for k in 1:
		var d := (dir + Vector3(randf_range(-1, 1), randf_range(-0.5, 1), randf_range(-1, 1)) * 0.01).normalized()
		var q := PhysicsRayQueryParameters3D.create(from, from + d * 90.0, 1 | 2 | 16 | (32 if Settings.friendly_fire else 0))
		q.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		var to: Vector3 = hit.position if hit else from + d * 90.0
		if hit and hit.collider.has_method("apply_damage") and hit.collider != self:
			hit.collider.apply_damage(GRAIN_DAMAGE, driver)
		ends.append(to)
	for e in get_tree().get_nodes_in_group("robots"):
		e.heard(from)
	grain_fx.rpc(from, ends)


@rpc("authority", "call_local", "unreliable")
func grain_fx(from: Vector3, ends: Array) -> void:
	Sfx.play_at("machinegun", from, -10.0, 60.0)
	for to in ends:
		# a corn cob, tumbling as it flies (tools/blender/corn_cob.py)
		var g: Node3D = COB.instantiate()
		g.scale = Vector3.ONE * 2.5             # a big cob, so it reads from the chase camera
		get_tree().current_scene.add_child(g)
		g.global_position = from
		if from.distance_to(to) > 0.1:
			g.look_at(to, Vector3.UP)
		var tw := g.create_tween().set_parallel()
		var t: float = from.distance_to(to) / 55.0
		tw.tween_property(g, "global_position", to, t)
		tw.tween_property(g, "rotation:z", g.rotation.z + TAU * 2.0, t)
		tw.chain().tween_callback(g.queue_free)
		tw.chain().tween_callback(_cob_burst.bind(to))


## Where a cob lands: kernels and bits of cob bounce off and scatter.
func _cob_burst(at: Vector3) -> void:
	var bits: Node3D = GRAINS.instantiate()
	get_tree().current_scene.add_child(bits)
	bits.global_position = at
	bits.scale = Vector3.ONE * 2.0
	for piece in bits.get_children():
		if not piece is Node3D:
			continue
		var p := piece as Node3D
		p.position = Vector3.ZERO
		var out := Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized() * randf_range(0.4, 1.2)
		var tw := p.create_tween().set_parallel()
		tw.tween_property(p, "position", out + Vector3(0, 0.6, 0), 0.25).set_ease(Tween.EASE_OUT)
		tw.tween_property(p, "rotation", Vector3(randf() * TAU, randf() * TAU, 0), 0.6)
		tw.chain().tween_property(p, "position:y", -0.45, 0.35).set_ease(Tween.EASE_IN)
	get_tree().create_timer(4.0).timeout.connect(bits.queue_free)


const COB := preload("res://assets/rio_grande_do_sul/war/corn/espiga_milho.glb")
const GRAINS := preload("res://assets/rio_grande_do_sul/war/corn/graos_milho.glb")


## Server: a shot meant for the player at the wheel hits the vehicle instead.
@rpc("any_peer", "call_local", "reliable")
func vehicle_hit(amount: int) -> void:
	if multiplayer.is_server():
		apply_damage(amount, null)


@rpc("authority", "call_local", "reliable")
func explode_fx(burnt_driver := false) -> void:
	_wrecked = true
	occupied = false
	if _driver:
		_driver.visible = false
	var at := global_position + Vector3(0, 2.0, 0)
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.6, 0.2)
	flash.light_energy = 16.0
	flash.omni_range = 30.0
	get_tree().current_scene.add_child(flash)
	flash.global_position = at
	var tw := flash.create_tween()
	tw.tween_property(flash, "light_energy", 0.0, 1.6)
	tw.tween_callback(flash.queue_free)
	for spec in [[90, 1.4, Color(1.0, 0.55, 0.1), 0.6, 9.0], [60, 4.0, Color(0.12, 0.11, 0.1), 1.6, 3.0]]:
		var parts := CPUParticles3D.new()        # fireball, then a column of black smoke
		parts.amount = spec[0]
		parts.lifetime = spec[1]
		parts.one_shot = true
		parts.explosiveness = 0.9
		parts.direction = Vector3.UP
		parts.spread = 80.0
		parts.initial_velocity_min = spec[4] * 0.5
		parts.initial_velocity_max = spec[4]
		parts.gravity = Vector3(0, 1.5, 0)
		parts.scale_amount_min = spec[3]
		parts.scale_amount_max = spec[3] * 2.5
		var m := SphereMesh.new()
		m.radius = 0.5
		m.height = 1.0
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = spec[2]
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.material = mat
		parts.mesh = m
		get_tree().current_scene.add_child(parts)
		parts.global_position = at
		parts.emitting = true
		get_tree().create_timer(spec[1] + 1.0).timeout.connect(parts.queue_free)
	Sfx.play_at("robot_death", at, 10.0, 160.0)
	Sfx.play_at("prop_break", at, 6.0, 120.0)
	# the burnt-out wreck
	var burnt := StandardMaterial3D.new()
	burnt.albedo_color = Color(0.07, 0.06, 0.055)
	burnt.roughness = 1.0
	for mi in find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = burnt
	if burnt_driver:
		# the driver's charred body, lying beside the wreck
		const Civ := preload("res://scripts/civilian.gd")
		for m in Civ.MODELS:
			if m.begins_with("res://assets/common/people/"):
				var body: Node3D = (load(m) as PackedScene).instantiate()
				get_tree().current_scene.add_child(body)
				var side := global_transform.basis.x * -(_box.size.x / 2 + 1.0) if _box else Vector3.LEFT * 2.0
				body.global_position = global_position + side + Vector3(0, 0.12, 0)
				body.rotation = Vector3(-PI / 2, rotation.y + PI / 2, 0)
				var char_mat := StandardMaterial3D.new()
				char_mat.albedo_color = Color(0.05, 0.04, 0.035)
				char_mat.roughness = 1.0
				for mi in body.find_children("*", "MeshInstance3D", true, false):
					(mi as MeshInstance3D).material_override = char_mat
				var smoke := CPUParticles3D.new()
				smoke.amount = 16
				smoke.lifetime = 3.0
				smoke.direction = Vector3.UP
				smoke.spread = 15.0
				smoke.initial_velocity_min = 0.3
				smoke.initial_velocity_max = 0.8
				smoke.gravity = Vector3(0, 0.4, 0)
				var sm := SphereMesh.new()
				sm.radius = 0.25
				sm.height = 0.5
				var smat := StandardMaterial3D.new()
				smat.albedo_color = Color(0.15, 0.14, 0.13, 0.5)
				smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sm.material = smat
				smoke.mesh = sm
				body.add_child(smoke)
				get_tree().create_timer(40.0).timeout.connect(body.queue_free)
				break


## Every peer: the driver / rider is gone; a bike or motorbike falls over.
@rpc("authority", "call_local", "reliable")
func bail() -> void:
	occupied = false
	if _driver:
		_driver.visible = false
	for part in _rider_parts:
		(part as Node3D).visible = false
	if _rider:
		_rider.visible = false
		var model := get_child(0) as Node3D
		# it tips over on its base line: lift it by half its width so the
		# handlebar side lies on the street instead of under it, and lay the
		# collision box down with it (design mode clicks, shots)
		var fall := deg_to_rad(78)
		var lift: float = max(_box.size.x / 2.0, 0.25) if _box else 0.3
		_fall_tween = create_tween().set_parallel()
		_fall_tween.tween_property(model, "rotation:z", fall, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_fall_tween.tween_property(model, "position:y", lift, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		if _cs:
			var c := _box_centre
			_fall_tween.tween_property(_cs, "rotation:z", fall, 0.6)
			_fall_tween.tween_property(_cs, "position", Vector3(c.x * cos(fall) - c.y * sin(fall),
					c.x * sin(fall) + c.y * cos(fall) + lift, c.z), 0.6)
		if _anim:
			_anim.pause()


## Bounds of all meshes under `node`, in this car's space.
func _bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var inv := global_transform.affine_inverse()
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = (inv * (mi as MeshInstance3D).global_transform) * (mi as MeshInstance3D).get_aabb()
		out = b if first else out.merge(b)
		first = false
	if node is MeshInstance3D:
		var b2: AABB = (inv * (node as MeshInstance3D).global_transform) * (node as MeshInstance3D).get_aabb()
		out = b2 if first else out.merge(b2)
	return out


## Every peer: roll the wheels by the distance actually travelled.
func _process(delta: float) -> void:
	var moved := global_position - _last_pos
	_last_pos = global_position
	moved.y = 0
	if _anim:
		var v: float = moved.length() / max(delta, 1e-4)
		var clip: String = KINDS[kind]["clip"] if v > 0.4 else KINDS[kind]["stop_clip"]
		if kind == "horse" and v > 0.4:
			# hysteresis: the per-frame speed wobbles, don't flicker between gaits
			var cantering := _anim.current_animation == "canter"
			clip = "canter" if v > (2.6 if cantering else 3.0) else ("walk" if v < 1.4 else "trot")
		if _anim.current_animation != clip and _anim.has_animation(clip):
			_anim.play(clip, 0.3)
		# ground speed of each gait at playback 1.0 (the hooves' backward sweep,
		# the Criollo pack's nominal speeds: walk 1.0, trot 2.1, canter 3.4 m/s)
		var gait: float = {"walk": 1.0, "canter": 3.4}.get(clip, KINDS[kind]["clip_speed"])
		var top := 2.2 if kind == "horse" else 1.5      # a ridden horse at full tilt: a fast canter
		_anim.speed_scale = clamp(v / gait, 0.3, top) if clip != KINDS[kind]["stop_clip"] else 1.0
		return
	if _engine:
		var v: float = moved.length() / max(delta, 1e-4)
		_engine.pitch_scale = lerp(_engine.pitch_scale, _engine_base * (1.0 + clamp(v / 20.0, 0.0, 1.2)), min(1.0, delta * 3.0))
		# louder as it revs; the one you drive is heard close up, not from the chase camera's distance
		var mine := driver_peer != 0 and driver_peer == multiplayer.get_unique_id()
		var want_db: float = _engine_db + Tune.engine_db + clamp(v / 20.0, 0.0, 1.0) * Tune.engine_rev_db \
				+ (Tune.engine_driving_db if mine else 0.0) - (RADIO_DUCK_DB if mine and radio_on else 0.0)
		_engine.volume_db = lerp(_engine.volume_db, want_db, min(1.0, delta * 4.0))
		_engine.unit_size = 14.0 if mine else 6.0
		if _wrecked and _engine.playing:
			_engine.stop()
	if _reel and driver_peer != 0:
		_reel.rotate_object_local(Vector3.RIGHT, -delta * 9.0)
	if _wheels.is_empty() or moved.length() < 0.0005 or moved.length() > 5.0:
		return
	var sign := 1.0 if moved.dot(-global_transform.basis.z) >= 0 else -1.0
	for w in _wheels:
		(w as Node3D).rotate_object_local(Vector3.RIGHT, -sign * moved.length() / max(_wheel_radius, 0.1))


## Server: place on an edge and start driving.
func start(on_edge: int, forward: bool) -> void:
	_follow(on_edge, forward)
	if _path.size() > 1:
		# start part-way along the edge, not on the shared junction node
		_i = clamp(_path.size() / 2, 1, _path.size() - 1)
		global_position = _path[_i - 1].lerp(_path[_i], randf_range(0.1, 0.9))
		reset_physics_interpolation()
		_blocked_time = 0.0


func _follow(edge_idx: int, forward: bool) -> void:
	var e: Dictionary = graph["edges"][edge_idx]
	var pts: Array = e["pts"].duplicate()
	if not forward:
		pts.reverse()
	_node = e["b"] if forward else e["a"]
	var off: float = (LANE_ONE_WAY if e["oneway"] else LANE_TWO_WAY) + KINDS[kind]["kerb"]
	_path = PackedVector3Array()
	for k in pts.size():
		var p := Vector3(pts[k][0], _h(pts[k]), pts[k][1])
		var q: Vector3 = Vector3(pts[min(k + 1, pts.size() - 1)][0], p.y, pts[min(k + 1, pts.size() - 1)][1])
		if k == pts.size() - 1:
			q = p + (p - Vector3(pts[k - 1][0], p.y, pts[k - 1][1]))
		var dir := (q - p).normalized()
		_path.append(p + dir.cross(Vector3.UP) * off)
	_i = 1


## Ground height carried by a road point ([x, z, y]; flat maps have no y).
static func _h(pt: Array) -> float:
	return pt[2] if pt.size() > 2 else 0.0


## Buses: the next stop on their round and how long they still wait at one.
var _stop_i := -1
var _dwell := 0.0
var _left_stop := true
var _held := 0.0                     # extra wait for people still boarding
const DWELL_S := 6.0


## The stops of this bus's line: with bus lines designed in the map editor
## ("lines" in the road graph) each bus keeps to one, the buses spread over
## them; otherwise every stop is one round.
var line := -1
func _line_stops() -> Array:
	var lines: Array = graph.get("lines", [])
	if lines.is_empty():
		return graph.get("stops", [])
	if line < 0 or line >= lines.size():
		line = get_instance_id() % lines.size()
		_stop_i = -1
	return lines[line]


## A bus picks the street towards its next stop (shortest way through the
## road graph); null when it has no stops to serve.
func _bus_pick(options: Array) -> Variant:
	var stops: Array = _line_stops()
	if kind != "bus" or stops.is_empty() or options.is_empty():
		return null
	if _stop_i < 0:
		_stop_i = randi() % stops.size()
	var target: int = stops[_stop_i][0]
	var dist := _dist_to_edge(target)
	return _cheapest(options, target, dist)


## Shortest way (metres) from every node to the street `target` (Dijkstra
## over the allowed travel directions; the graphs are small).
func _dist_to_edge(target: int) -> Dictionary:
	var te: Dictionary = graph["edges"][target]
	var dist := {int(te["a"]): 0.0, int(te["b"]): 0.0}
	var frontier: Array = dist.keys()
	while not frontier.is_empty():
		frontier.sort_custom(func(x, y): return dist[x] < dist[y])
		var n: int = frontier.pop_front()
		for i in graph["edges"].size():
			var e: Dictionary = graph["edges"][i]
			# edges that lead INTO n in an allowed direction
			for spec in [[int(e["a"]), int(e["b"]), true], [int(e["b"]), int(e["a"]), false]]:
				if spec[1] != n or (not spec[2] and e["oneway"]):
					continue
				var nd: float = dist[n] + graph["len"][i]
				if nd < dist.get(spec[0], INF):
					dist[spec[0]] = nd
					frontier.append(spec[0])
	return dist


## Of [edge, forward] options, the one on the shortest way to `target`; null if none leads there.
func _cheapest(options: Array, target: int, dist: Dictionary) -> Variant:
	var best: Variant = null
	var bd := INF
	for o in options:
		if o[0] == target:
			return o                             # the stop's own street
		var e: Dictionary = graph["edges"][o[0]]
		var end_node := int(e["b"]) if o[1] else int(e["a"])
		var d: float = graph["len"][o[0]] + dist.get(end_node, INF)
		if d < bd:
			bd = d
			best = o
	return best


## Bus at its stop: pull up for a few seconds, then make for the next one.
func _bus_at_stop(delta: float) -> bool:
	if kind != "bus" or driver_peer != 0:
		return false
	if _dwell > 0.0:
		_dwell -= delta
		_speed = 0.0
		# someone still walking to the door: hold on a little longer
		if _dwell < 0.5 and _held < 6.0 and get_tree().get_nodes_in_group("civilians").any(func(c): return c.get("_boarding") == self):
			_held += delta
			_dwell = 0.5
		if _dwell <= 0.0:
			_held = 0.0
			var stops: Array = _line_stops()
			_stop_i = (_stop_i + 1) % max(stops.size(), 1)
		return true
	var stops: Array = _line_stops()
	if _stop_i < 0 or stops.is_empty():
		return false
	var s: Array = stops[_stop_i]
	var d := Vector2(global_position.x, global_position.z).distance_to(Vector2(s[1], s[2]))
	if not _left_stop:
		_left_stop = d > 15.0            # pulled away: the next pass may stop here again
		return false
	if d < 5.0:
		_left_stop = false
		_dwell = DWELL_S
		get_tree().current_scene.bus_at_stop(self, s)
		Sfx.play_at("reload", global_position + Vector3(0, 1.5, 0), 0.0, 30.0)     # doors open
		return true
	return false


func _next_edge() -> void:
	var options: Array = graph["out"].get(_node, [])
	var came_from := -1
	if _path.size() >= 2:
		came_from = _node
	if options.is_empty():
		_enter_from_edge()   # left the map: come back in from another border street
		return
	var route: Variant = _bus_pick(options)
	var pick: Array = route if route != null else options.pick_random()
	_follow(pick[0], pick[1])


func _physics_process(delta: float) -> void:
	if driver_peer != 0:
		_drive(delta)
		return
	if _shove != Vector3.ZERO:
		_apply_shove(delta)
		return
	if _path.size() < 2:
		return
	if _bus_at_stop(delta):
		return
	var target := _path[min(_i, _path.size() - 1)]
	var to := target - global_position
	to.y = 0
	if to.length() < 1.2:
		_i += 1
		if _i >= _path.size():
			_next_edge()
		return
	# the way ahead is checked ten times a second (each car from its own phase)
	_block_cd -= delta
	if _block_cd <= 0.0:
		_block_cd = BLOCK_CHECK_S
		_was_blocked = _blocked()
	var blocked := _was_blocked
	_blocked_time = _blocked_time + delta if blocked else 0.0
	_honk_if_blocked(delta)
	if _blocked_time > 6.0:
		_enter_from_edge()   # gridlock: re-enter from the map border
		return
	_yield_cd -= delta
	if _yield_cd <= 0.0:
		_yield_cd = 0.25
		_yielding = _someone_on_zebra_ahead()
	var want := _cruise if not blocked and not _yielding else 0.0
	_speed = move_toward(_speed, want, (4.0 if want > _speed else 12.0) * delta)
	var dir := to.normalized()
	global_position += dir * _speed * delta
	# follow the ground: the road points are far apart, so a straight line
	# between their heights cuts through crests and floats over dips. Probe
	# the street under the front and rear axles; their mean is the height,
	# their difference the pitch.
	var prev := _path[max(_i - 1, 0)]
	var seg := Vector2(target.x - prev.x, target.z - prev.z)
	var t: float = clamp(Vector2(global_position.x - prev.x, global_position.z - prev.z).dot(seg) / max(seg.length_squared(), 1e-4), 0.0, 1.0)
	var guess: float = lerp(prev.y, target.y, t)
	var ahead := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
	var half: float = max(_length * 0.35, 0.5)
	# the street under the axles is probed again once the car has moved a
	# little (a crawl in a queue or a stop costs no rays); in between it
	# follows the last slope found
	var flat_at := Vector2(global_position.x, global_position.z)
	if _probe_at.distance_to(flat_at) > PROBE_EVERY_M or _probe_at == Vector2.INF:
		_probe_at = flat_at
		var yf := _ground_at(global_position + ahead * half, guess)
		var yr := _ground_at(global_position - ahead * half, guess)
		_probe_y = (yf + yr) / 2.0
		_probe_pitch = clamp(atan2(yf - yr, half * 2.0), -deg_to_rad(Tune.vehicle_max_pitch_deg), deg_to_rad(Tune.vehicle_max_pitch_deg))     # streets stay under ~12 degrees
		_probe_guess = guess
		_roll_to_ground(guess, delta)
	rotation.z = lerp_angle(rotation.z, _probe_roll, min(1.0, delta * 8.0))
	# on between probes along the slope (guess: the road's own height change)
	global_position.y = _probe_y + (guess - _probe_guess)
	rotation.x = lerp_angle(rotation.x, _probe_pitch, min(1.0, delta * 8.0))
	rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), min(1.0, delta * 5.0))


## Server: a player takes the vehicle (whoever was aboard gets out and runs).
func take(peer: int, by: Node3D) -> void:
	if not multiplayer.is_server() or driver_peer != 0 or _wrecked:
		return
	if occupied:
		apply_damage(0, by)
	driver_peer = peer
	_path = PackedVector3Array()
	_speed = 0.0
	collision_mask = 1 | 2 | 8 | 16 | 32      # 8: the map's edge walls
	set_driven.rpc(peer)


## Server: the player got out; the vehicle stays parked where it is.
func release() -> void:
	if not multiplayer.is_server():
		return
	driver_peer = 0
	_speed = 0.0
	_input = Vector3.ZERO
	collision_mask = 0
	set_driven.rpc(0)


## Every peer: show the player's figure at the wheel / on the saddle; ride
## clear of kerbs (collision box lifted a little while driven).
@rpc("authority", "call_local", "reliable")
func set_driven(peer: int) -> void:
	driver_peer = peer
	if peer != 0:
		_sleep(false)
	var model := get_child(0) as Node3D
	if _rider:
		_rider.visible = peer != 0
		if _fall_tween and peer != 0:
			_fall_tween.kill()       # taken while still falling over: it laid down under the rider
		model.rotation.z = 0.0
		model.position.y = 0.0
		if _cs:
			_cs.rotation.z = 0.0
			_cs.position = _box_centre
		if _anim and peer != 0:
			_anim.play()
	if _driver:
		_driver.visible = peer != 0
	for part in _rider_parts:
		(part as Node3D).visible = peer != 0
	if _anim and kind == "horse" and peer != 0:
		_anim.play()
	if _cs and _box:
		var lift := 0.25 if peer != 0 else 0.0
		_cs.position.y = _box_centre.y + lift / 2
		_box.size.y = max(0.3, (_box.size.y + (_cs.get_meta("lift", 0.0) as float)) - lift)
		_cs.set_meta("lift", lift)


## Driver's controls, sent every physics frame by the driving player.
@rpc("any_peer", "call_local", "unreliable")
func drive_input(throttle: float, steer: float, handbrake: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and (sender if sender != 0 else 1) == driver_peer:
		_input = Vector3(clamp(throttle, -1, 1), clamp(steer, -1, 1), handbrake)


## Server: arcade handling - speed-dependent steering, coasting, braking,
## reverse; bumps stop it, people and robots in the way are run over.
## Harvester (server): the reel and its blades in front cut into whatever
## robot stands against them - driven slowly or standing still too (only a
## hit at speed hurt before): REEL_DPS a second, five bites a second, sparks
## and the clang of metal each time.
const REEL_DPS := 150.0
var _reel_cd := 0.0
func _reel_tick(delta: float) -> void:
	_reel_cd -= delta
	if _reel_cd > 0.0:
		return
	_reel_cd = 0.2
	var main := get_tree().current_scene
	var front: float = _box_centre.z - _box.size.z / 2.0           # the header's edge (front is -Z)
	var half_w: float = _box.size.x / 2.0 + 0.3
	var driver := main.players_root.get_node_or_null(str(driver_peer)) as Node3D
	var bite := int(REEL_DPS * 0.2)
	for e in main.enemies_root.get_children():
		if e.get("variant") == "swarm":
			for i in e.positions.size():
				var lp: Vector3 = to_local(e.positions[i])
				if (e.alive_mask >> i) & 1 == 1 and lp.z > front - 2.0 and lp.z < front + 1.5 and absf(lp.x) < half_w and lp.y < 3.0:
					e.hit_unit(i, 9999, driver)
			continue
		if not e.has_method("is_alive") or not e.is_alive():
			continue
		var l := to_local((e as Node3D).global_position)
		if l.z > front - 2.0 and l.z < front + 1.5 and absf(l.x) < half_w and l.y < 3.0:
			e.apply_damage(bite, driver)
			reel_bite.rpc((e as Node3D).global_position + Vector3(0, 1.0, 0))


## Every peer: sparks and the clang of the blades on a robot.
@rpc("authority", "call_local", "unreliable")
func reel_bite(at: Vector3) -> void:
	Sfx.play_at("robot_hit", at, 2.0, 50.0)
	var main := get_tree().current_scene
	if main.get("props"):
		main.props._sparks(at)


func _drive(delta: float) -> void:
	if kind == "harvester":
		_reel_tick(delta)
	var spec: Array = DRIVE.get(kind, DRIVE["car"])
	var top: float = spec[0]
	var acc: float = spec[1]
	if _input.x > 0.1:
		_speed = move_toward(_speed, top, acc * delta * (1.0 if _speed >= 0 else 3.0))
	elif _input.x < -0.1:
		_speed = move_toward(_speed, -top * 0.3, acc * delta * (2.5 if _speed > 0 else 1.0))
	else:
		_speed = move_toward(_speed, 0.0, 1.5 * delta)
	if _input.z > 0.5:
		_speed = move_toward(_speed, 0.0, 14.0 * delta)
	var wheelbase: float = max(_length * 0.6, 1.0)
	# less lock at speed, like a real car (and far easier to hold a lane)
	var lock: float = spec[2] * lerp(1.0, 0.5, clamp(abs(_speed) / top, 0.0, 1.0))
	var steer: float = _input.y
	if kind in ["motoboy", "cyclist"]:
		# a two-wheeler is short (about 1 m between its wheels here): at speed
		# full lock spun it ~5 rad/s. At top speed lean, not lock, does the
		# turning (a quarter of the lock left)
		wheelbase = max(wheelbase, 1.4)
		lock = spec[2] * lerp(1.0, 0.25, clamp(abs(_speed) / top, 0.0, 1.0))
	rotation.y -= _speed / wheelbase * tan(steer * lock) * delta
	var fwd := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
	var main := get_tree().current_scene
	var step := fwd * _speed * delta
	if not main.in_bounds(global_position + step * 4.0, 2.0):
		_speed *= -0.25                      # the map ends here (edge walls as well)
		step = Vector3.ZERO
	var col := move_and_collide(step)
	if col:
		var other := col.get_collider()
		var driver := main.players_root.get_node_or_null(str(driver_peer)) as Node3D
		if other and (other.has_meta("prop_index") or other.has_meta("crush")) \
				and main.props.crush(other, MASS.get(kind, 1.3), abs(_speed), fwd * signf(_speed)):
			# a bin, bench or lamp knocked over: it costs a little speed, we drive on
			_speed *= clamp(1.0 - 0.15 / MASS.get(kind, 1.3), 0.6, 0.97)
		elif other and other.has_method("apply_damage") and abs(_speed) > 2.5:
			if other.is_in_group("robots") and kind == "harvester":
				other.apply_damage(400, driver)      # the reel shreds whatever it catches
				_speed *= 0.85
			elif other.is_in_group("robots"):
				# robots are armoured: a hard hit hurts, it takes several to wreck one
				other.apply_damage(int(min(abs(_speed) * 1.5, 25.0)), driver)
				_speed *= 0.5
			elif other.is_in_group("civilians"):
				other.apply_damage(int(abs(_speed) * 5.0), driver)    # counts as a civilian lost
				_speed *= 0.7
			elif other.get("kind") != null and MASS.has(other.kind):
				_ram(other, driver)
			else:
				other.apply_damage(int(abs(_speed) * 3.0), driver)
				_speed *= -0.25
		else:
			_speed *= -0.25
	var half: float = max(_length * 0.35, 0.5)
	var yf := _ground_at(global_position + fwd * half, global_position.y)
	var yr := _ground_at(global_position - fwd * half, global_position.y)
	global_position.y = (yf + yr) / 2.0
	rotation.x = lerp_angle(rotation.x, clamp(atan2(yf - yr, half * 2.0), -deg_to_rad(Tune.vehicle_max_pitch_deg), deg_to_rad(Tune.vehicle_max_pitch_deg)), min(1.0, delta * 8.0))
	_probe_y = global_position.y
	_roll_to_ground(global_position.y, delta)       # the driven one: probed every tick, as precise as it gets
	global_position.y = _probe_y
	rotation.z = lerp_angle(rotation.z, _probe_roll, min(1.0, delta * 8.0))
	_probe_at = Vector2.INF                          # traffic again after: probe at once


## tonnes, roughly: who pushes whom in a crash
const MASS := {"cyclist": 0.1, "horse": 0.5, "motoboy": 0.25, "car": 1.3, "truck": 14.0, "bus": 12.0, "harvester": 16.0,
		"lorry": 9.0}


## Server: the driven vehicle hits another one. The heavier one wins: a much
## lighter vehicle is run over (bikes, motorbikes, horses: the rider is hit
## too), a lighter car is shoved along; a heavier one stops us.
func _ram(other: Node, driver: Node3D) -> void:
	var mine: float = MASS.get(kind, 1.3)
	var theirs: float = MASS[other.kind]
	var ratio := mine / theirs
	var v: float = abs(_speed)
	var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y)) * signf(_speed)
	if ratio >= 3.0 and theirs < 1.0:
		# a bicycle / motorbike / horse under a car or bus: rider down, machine wrecked
		other.apply_damage(int(v * 6.0 * ratio), driver)
		if other.has_method("run_over"):
			other.run_over(driver)
		add_collision_exception_with(other)     # drive over the wreck, don't stall on it
	elif ratio >= 1.5:
		# shove it: it slides away along our heading, its driver bails
		other.apply_damage(int(v * 2.0 * ratio), driver)
		if other.has_method("shove"):
			other.shove(fwd * v * min(ratio / 4.0, 1.0) * 0.9)
		_speed *= clamp(1.0 - theirs / mine, 0.3, 0.9)
	else:
		other.apply_damage(int(v * 2.0), driver)
		_speed *= -0.25 * clamp(theirs / mine, 0.2, 1.0)
		if other.has_method("shove") and ratio > 0.6:
			other.shove(fwd * v * 0.3)


var _shove := Vector3.ZERO


## Server: pushed by a heavier vehicle - slide (spinning a little) and stop.
func shove(vel: Vector3) -> void:
	if driver_peer != 0:
		return
	_shove = vel
	collision_mask = 1 | 16          # slide into buildings and other cars, not through them
	_cruise = 0.0
	_speed = 0.0
	_path = PackedVector3Array()          # knocked off its route: it stays where it ends up


## Server: a light vehicle run over by a heavy one: the rider is hurt and
## thrown off, the machine falls over.
func run_over(by: Node3D) -> void:
	if not occupied or driver_peer != 0:
		return
	occupied = false
	_cruise = 0.0
	_speed = 0.0
	bail.rpc()
	var main := get_tree().current_scene
	if main.has_method("spawn_fleeing"):
		var side := global_transform.basis.x * 1.2
		main.spawn_fleeing(global_position + side, global_position, -1, by, 35)


func _apply_shove(delta: float) -> void:
	if _shove.length() < 0.1:
		_shove = Vector3.ZERO
		return
	var step := _shove * delta
	var col := move_and_collide(step)
	if col and col.get_normal().y > 0.5:
		# scraping along the street: keep sliding over it
		global_position += col.get_remainder().slide(col.get_normal())
		col = null
	rotation.y += _shove.length() * delta * 0.15
	global_position.y = _ground_at(global_position, global_position.y)
	_shove = _shove.lerp(Vector3.ZERO, min(1.0, delta * 1.5)) if not col else _shove * 0.3


## Bank with a street that slopes sideways: probe under the left and right
## wheels (the +x side up means a positive roll about the car's z axis).
const BLOCK_CHECK_S := 0.1
const PROBE_EVERY_M := 1.5
var _block_cd := randf() * BLOCK_CHECK_S
var _was_blocked := false
var _probe_at := Vector2.INF
var _probe_y := 0.0
var _probe_pitch := 0.0
var _probe_guess := 0.0
var _probe_roll := 0.0
static var _block_box: BoxShape3D


func _roll_to_ground(guess: float, delta: float) -> void:
	if not kind in ["car", "bus", "truck", "harvester", "lorry"]:
		return                       # two wheels / a horse: no sideways lean from the road
	var w: float = max((_box.size.x if _box else 1.8) * 0.25, 0.3)
	var right := Vector3(cos(rotation.y), 0, -sin(rotation.y))
	var yl := _ground_at(global_position - right * w, guess)
	var yr := _ground_at(global_position + right * w, guess)
	if abs(yr - yl) > Tune.vehicle_kerb_step_m:
		return                       # a kerb under one side, not a sloping street
	var roll: float = clamp(atan2(yr - yl, w * 2.0), -deg_to_rad(Tune.vehicle_max_roll_deg), deg_to_rad(Tune.vehicle_max_roll_deg))
	_probe_roll = roll
	_probe_y = max(_probe_y, (yl + yr) / 2.0)


## A standing vehicle rests on the street under its four wheels: height,
## pitch along a climbing street and roll on a cambered one.
func settle_parked() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if driver_peer != 0 or not is_inside_tree():
		return
	settle_now()
	if not occupied:
		_sleep(true)


## A parked, empty vehicle does nothing per frame and its engine is off
## until someone gets in (set_driven).
## the driver's radio is playing: the engine steps back under the music
var radio_on := false
const RADIO_DUCK_DB := 12.0


func _sleep(on: bool) -> void:
	set_physics_process(not on and multiplayer.is_server())
	set_process(not on)
	if _engine:
		if on:
			_engine.stop()
		elif not _engine.playing:
			_engine.play()


func settle_now() -> void:
	var half_l: float = (_box.size.z if _box else 4.0) * 0.35
	var half_w: float = (_box.size.x if _box else 1.8) * 0.35
	var fwd := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
	var right := Vector3(cos(rotation.y), 0, -sin(rotation.y))
	var guess := global_position.y
	var yf := (_ground_at(global_position + fwd * half_l - right * half_w, guess) + _ground_at(global_position + fwd * half_l + right * half_w, guess)) / 2.0
	var yb := (_ground_at(global_position - fwd * half_l - right * half_w, guess) + _ground_at(global_position - fwd * half_l + right * half_w, guess)) / 2.0
	var yl := (_ground_at(global_position + fwd * half_l - right * half_w, guess) + _ground_at(global_position - fwd * half_l - right * half_w, guess)) / 2.0
	var yr := (_ground_at(global_position + fwd * half_l + right * half_w, guess) + _ground_at(global_position - fwd * half_l + right * half_w, guess)) / 2.0
	global_position.y = (yf + yb) / 2.0
	rotation.x = clamp(atan2(yf - yb, half_l * 2.0), -deg_to_rad(Tune.vehicle_max_pitch_deg), deg_to_rad(Tune.vehicle_max_pitch_deg))
	rotation.z = clamp(atan2(yr - yl, half_w * 2.0), -deg_to_rad(Tune.vehicle_max_roll_deg), deg_to_rad(Tune.vehicle_max_roll_deg))


func speed_kmh() -> float:
	return abs(_speed) * 3.6


## Street height under `p` (the city's ground collision), or `guess` when the
## probe finds nothing plausible (a parked car's roof, a gap).
func _ground_at(p: Vector3, guess: float) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, guess + 4.0, p.z), Vector3(p.x, guess - 12.0, p.z), 1)
	for attempt in 3:
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		# only the city's ground meshes (their trimesh bodies hang under the
		# MeshInstance); props such as parked cars or bins are skipped
		if hit.collider.get_parent() is MeshInstance3D:
			return hit.position.y if abs(hit.position.y - guess) < 3.0 else guess
		q.exclude = q.exclude + [hit.rid]
	return guess


## Enter the map on a street that starts at the border, as if driving in.
func _enter_from_edge() -> void:
	var entries: Array = graph.get("entries", [])
	if entries.is_empty():
		var k: int = randi() % graph["edges"].size()
		start(k, graph["edges"][k]["oneway"] or randf() < 0.5)
		return
	var pick: Array = entries.pick_random()
	# a bus comes back in where its next stop can be reached (the street graph
	# is in pieces and mostly one-way); stops no entry reaches are skipped
	var stops: Array = _line_stops()
	if kind == "bus" and not stops.is_empty():
		if _stop_i < 0:
			_stop_i = randi() % stops.size()
		for tries in stops.size():
			var target: int = stops[_stop_i][0]
			var via: Variant = _cheapest(entries, target, _dist_to_edge(target))
			if via != null:
				pick = via
				break
			_stop_i = (_stop_i + 1) % stops.size()
	_follow(pick[0], pick[1])
	global_position = _path[0]
	reset_physics_interpolation()       # a jump back in at the map's edge, not a streak across it
	_i = 1
	_speed = _cruise * 0.6
	_blocked_time = 0.0


## Something (person, robot, player, car) right in front of the bumper?
## Somebody (a player or a pedestrian) on a zebra crossing just ahead: stop
## before it and let them cross.
var _yield_cd := 0.0
var _yielding := false
func _someone_on_zebra_ahead() -> bool:
	var main := get_tree().current_scene
	var zebras: Array = main.road_graph.get("crossings", []) if main.get("road_graph") else []
	var fwd := -global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized()
	for zb in zebras:
		var at := Vector3(zb[0], global_position.y, zb[1])
		var rel := at - global_position
		var ahead := rel.dot(fwd)
		if ahead < _length / 2.0 or ahead > _length / 2.0 + 12.0 or Vector2(rel.x - fwd.x * ahead, rel.z - fwd.z * ahead).length() > 3.5:
			continue
		for group in ["players", "civilians"]:
			for who in get_tree().get_nodes_in_group(group):
				var p: Vector3 = (who as Node3D).global_position
				if Vector2(p.x - at.x, p.z - at.z).length() < 4.0 and absf(p.y - global_position.y) < 3.0 \
						and (group == "players" or who.is_alive()):
					return true
	return false


func _blocked() -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	if _block_box == null:
		_block_box = BoxShape3D.new()          # one shape for every car's check
		_block_box.size = Vector3(2.2, 1.4, 5.0)
	q.shape = _block_box
	var fwd := -global_transform.basis.z
	q.transform = Transform3D(global_transform.basis, global_position + fwd * (_length / 2 + 2.8) + Vector3(0, 0.8, 0))
	q.collision_mask = 2 | 4 | 16 | 32
	q.exclude = [get_rid()]
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 6):
		# cyclists keep to the kerb: motor traffic passes them instead of queueing
		if kind != "cyclist" and hit.collider.get("kind") == "cyclist":
			continue
		_blocker = hit.collider
		return true
	_blocker = null
	return false


## Server: someone stands in the way - sound the horn; a pedestrian steps
## off the carriageway to the side away from the car's path.
var _blocker: Object
var _horn_cd := 0.0
func _honk_if_blocked(delta: float) -> void:
	_horn_cd -= delta
	if _blocker == null or _blocked_time < 0.8 or _horn_cd > 0 or not occupied:
		return
	if not ((_blocker as Node).is_in_group("players") or (_blocker as Node).is_in_group("civilians")):
		return
	_horn_cd = Tune.horn_interval_s * randf_range(0.75, 1.25)
	honk.rpc()
	if (_blocker as Node).has_method("step_aside"):
		var right := global_transform.basis.x
		var side: float = sign(right.dot((_blocker as Node3D).global_position - global_position))
		_blocker.step_aside(right * (side if side != 0 else 1.0))


## The driving player pressed the horn: everyone hears it, people in the way step aside.
var _player_horn_cd := 0.0
@rpc("any_peer", "call_local", "unreliable")
func request_honk() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or (sender if sender != 0 else 1) != driver_peer:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _player_horn_cd:
		return
	_player_horn_cd = now + 0.35
	honk.rpc()
	var fwd := -global_transform.basis.z
	for c in get_tree().get_nodes_in_group("civilians"):
		var to: Vector3 = c.global_position - global_position
		if c.has_method("step_aside") and to.length() < 14.0 and to.normalized().dot(fwd) > 0.6:
			c.step_aside(global_transform.basis.x * signf(global_transform.basis.x.dot(to)))


@rpc("authority", "call_local", "unreliable")
func honk() -> void:
	var cue: String = {"bus": "horn_bus", "truck": "horn_bus", "lorry": "horn_bus", "motoboy": "horn_moto", "cyclist": "bell_bike"}.get(kind, "horn_car")
	if kind != "horse":
		Sfx.play_at(cue, global_position + Vector3(0, 1.0, 0), 2.0, 70.0)
