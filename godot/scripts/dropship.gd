extends Node3D
## Robot dropship. The server flies it in from the map border above the
## tallest tower and visits its drop zones in turn (spread over the city):
## over each it sinks straight down to just above the surrounding roofs (its
## 20 m wingspan doesn't fit between buildings), lowers a few robots down a
## light beam and climbs straight back up; after the last one it leaves on
## the far side. Clients mirror position/rotation/beam and build the visuals.
## The same ship in other roles (`kind`): a small "transport" that takes a
## Coletor's captive up its beam and down into a people container, and the
## "mother" ship that hauls a full container away. Those don't drop robots:
## at each stop the server's `on_stop` runs once and the ship holds there
## for the stop's seconds (stops[i][2]).

signal finished

const MODEL := "res://assets/common/enemies/dropship/dropship.glb"   # generated model, if present
const CRUISE_Y := 85.0          # default cruise altitude (main raises it above the tallest building)
const HOVER_Y := 22.0           # lowest hover height above the street while dropping
const SPEED := 32.0
const VERTICAL_SPEED := 9.0     # straight down to the hover height / back up to cruise
const RELEASE_EVERY := 1.1
const POD_CRUISE_TILT := -0.5   # rad about the pod's X: nozzles point back, thrust forward

enum Phase { APPROACH, HOVER, CLIMB, DEPART }

const SCALES := {"drop": 1.0, "transport": 0.55, "mother": 1.7}     # the dropship standing in for the others
const MODELS := {"transport": "res://assets/common/enemies/transport/transport_ship.glb",
		"mother": "res://assets/common/enemies/mothership/mothership.glb"}
const DOCK_Y := -2.955            # the mothership's bay: where a container hangs (its base, ship-local)


## How far below the hull a carried container's base hangs.
static func carry_drop(k: String) -> float:
	if k == "mother" and ResourceLoader.exists(MODELS["mother"]):
		return -DOCK_Y
	return 3.5 * SCALES.get(k, 1.0) + 3.4


func _own_model() -> bool:
	return MODELS.has(kind) and ResourceLoader.exists(MODELS[kind])

@export var beam_on := false
var kind := "drop"
var on_stop: Callable           # server, other kinds: func(stop_index: int) -> void
var carry: Node3D               # mother: the container hanging under it
var carry_down := false         # mother: bringing it - lowered and let go at the stop
var _waited := 0
@export var beam_len := HOVER_Y # current hover height = beam length
var stops: Array = []           # [[ground point, hover height above it, robots], ...]
var heading := Vector3.FORWARD  # direction of travel (horizontal)
var cruise_y := CRUISE_Y
var map_exit := 280.0           # leave (and free) beyond this distance from the centre
var release: Callable           # server: func(pos: Vector3) -> void, spawns one robot
var phase := Phase.APPROACH
var _speed := SPEED
var _stop := 0
var _released := 0
var _release_cd := 1.2
var _t := 0.0
var _beam: MeshInstance3D
var _bay_light: SpotLight3D
var _blinkers: Array = []
var _pods: Array = []           # engine_* nodes of the generated model (tilt about local X)


func _ready() -> void:
	_build_visual()
	var engine := AudioStreamPlayer3D.new()
	var stream: AudioStreamWAV = load("res://assets/audio/ship_engine.wav")
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_end = stream.data.size() / 2
	engine.stream = stream
	engine.unit_size = 35.0
	engine.max_distance = 450.0
	engine.volume_db = 4.0
	engine.autoplay = true
	add_child(engine)
	var sync := MultiplayerSynchronizer.new()
	var cfg := SceneReplicationConfig.new()
	for prop in [".:position", ".:rotation", ".:beam_on", ".:beam_len"]:
		cfg.add_property(NodePath(prop))
	sync.replication_config = cfg
	add_child(sync)
	set_physics_process(multiplayer.is_server())


func _physics_process(delta: float) -> void:
	var flat := Vector3(position.x, 0, position.z)
	match phase:
		Phase.APPROACH:
			var drop: Vector3 = stops[_stop][0]
			var to := Vector3(drop.x, 0, drop.z) - flat
			var d := to.length()
			if d > 0.5:
				# level flight above every roof, braking over the last stretch
				heading = to.normalized()
				_speed = clamp(d * 0.5, 2.0, SPEED)
				position.y = move_toward(position.y, cruise_y, VERTICAL_SPEED * delta)
				position += heading * min(_speed * delta, d)
			else:
				# then straight down, easing in near the hover height
				var want_y: float = drop.y + stops[_stop][1]
				var v: float = clamp((position.y - want_y) * 0.6, 1.5, VERTICAL_SPEED)
				position.y = move_toward(position.y, want_y, v * delta)
				if abs(position.y - want_y) < 0.1:
					phase = Phase.HOVER
					beam_len = stops[_stop][1]
					beam_on = true
					_released = 0
					_waited = 0
					_release_cd = 1.0
		Phase.HOVER:
			var drop: Vector3 = stops[_stop][0]
			_t += delta
			position.y = drop.y + stops[_stop][1] + sin(_t * 1.3) * 0.25
			_release_cd -= delta
			if kind != "drop":
				if _released == 0 and _release_cd <= 0.0:
					# false: not ready (the Coletor isn't below yet) - ask again in a
					# second, for half a minute at most
					var done: bool = on_stop.call(_stop) if on_stop.is_valid() else true
					_waited += 1
					if done or _waited > 30:
						_released = 1
						_release_cd = float(stops[_stop][2])
					else:
						_release_cd = 1.0
				elif _released == 1 and _release_cd <= 0.0:
					phase = Phase.CLIMB
					beam_on = false
			elif _release_cd <= 0 and _released < int(stops[_stop][2]):
				_release_cd = RELEASE_EVERY
				_released += 1
				if release.is_valid():
					var side := Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
					# the first drop(s) of a stop can be heavy mechs (stops[i][3])
					var mechs: int = stops[_stop][3] if stops[_stop].size() > 3 else 0
					var drones: int = stops[_stop][4] if stops[_stop].size() > 4 else 0
					var kind := "mech" if _released <= mechs else ("drone" if _released <= mechs + drones else "trooper")
					release.call(Vector3(drop.x, position.y - 3.5, drop.z) + side, kind)
			elif _released >= int(stops[_stop][2]) and _release_cd <= -1.0:
				phase = Phase.CLIMB
				beam_on = false
		Phase.CLIMB:
			position.y = move_toward(position.y, cruise_y, VERTICAL_SPEED * delta)
			if position.y > cruise_y - 8.0:
				_stop += 1
				_speed = 2.0
				phase = Phase.APPROACH if _stop < stops.size() else Phase.DEPART
		Phase.DEPART:
			position.y = move_toward(position.y, cruise_y, VERTICAL_SPEED * delta)
			_speed = min(SPEED * 1.3, _speed + 9.0 * delta)
			position += heading * _speed * delta
			if flat.length() > map_exit:
				finished.emit()
				queue_free()
	# nose along the travel direction
	rotation.y = atan2(-heading.x, -heading.z)
	if is_instance_valid(carry):
		# the container rises up the beam, then hangs under the hull
		var under := global_position - Vector3(0, carry_drop(kind), 0)
		var at: Vector3 = carry.global_position
		if carry_down and phase == Phase.HOVER:
			# down the beam onto its spot, then let go
			var g: Vector3 = stops[_stop][0]
			at = Vector3(g.x, move_toward(at.y, g.y, 3.0 * delta), g.z)
			if absf(at.y - g.y) < 0.02:
				carry.global_position = g
				carry.lifting = false
				carry = null
				return
		elif carry_down:
			at = under
		elif phase == Phase.HOVER:
			at.y = move_toward(at.y, under.y, 0.14 * delta)     # slowly: there is time to open it
		else:
			at = at.move_toward(under, 9.0 * delta)
		carry.global_position = at


func _process(delta: float) -> void:
	_beam.visible = beam_on
	_bay_light.visible = beam_on
	_beam.scale.y = beam_len
	_beam.position.y = -1.5 - beam_len / 2.0
	if beam_on:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.012)
		(_beam.material_override as StandardMaterial3D).albedo_color.a = 0.10 + 0.10 * pulse
	var blink := fmod(Time.get_ticks_msec() * 0.001, 1.2) < 0.15
	for b in _blinkers:
		(b as Node3D).visible = blink
	# VTOL pods: vectored back for cruise, straight down while hovering
	var tilt := 0.0 if beam_on else POD_CRUISE_TILT
	for pod in _pods:
		(pod as Node3D).rotation.x = lerp_angle((pod as Node3D).rotation.x, tilt, min(1.0, delta * 1.5))


# ---- visuals ---------------------------------------------------------------

func _metal(c: Color, metallic := 0.7, rough := 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	return m


func _glow(c: Color, energy := 3.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _part(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	add_child(mi)
	return mi


func _build_visual() -> void:
	var path: String = MODELS[kind] if _own_model() else MODEL
	if ResourceLoader.exists(path):
		var model: Node3D = (load(path) as PackedScene).instantiate()
		model.scale = Vector3.ONE * (1.0 if _own_model() else SCALES.get(kind, 1.0))
		add_child(model)
		var blink: Array = model.find_children("*", "AnimationPlayer", true, false)
		if not blink.is_empty():
			(blink[0] as AnimationPlayer).stop()            # the nav lights blink by script
		for n in ["engine_fl", "engine_fr", "engine_rl", "engine_rr"]:
			var pod := model.find_child(n, true, false)
			if pod:
				_pods.append(pod)
				var glow := OmniLight3D.new()       # thruster wash on roofs and streets
				glow.light_color = Color(0.4, 1.0, 0.6)
				glow.light_energy = 2.5
				glow.omni_range = 14.0
				glow.position = Vector3(0, -2.5, 0)
				pod.add_child(glow)
		for n in ["nav_light_l", "nav_light_r"]:
			var nav := model.find_child(n, true, false)
			if nav:
				_blinkers.append(nav)
	else:
		_build_placeholder()
	# tractor beam and bay light (both for any model): the hull's belly is at y ~ -1.5
	var cone := CylinderMesh.new()
	cone.top_radius = 1.3
	cone.bottom_radius = 3.2
	cone.height = 1.0
	var beam_mat := StandardMaterial3D.new()
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam_mat.albedo_color = Color(0.45, 1.0, 0.5, 0.15)
	_beam = _part(cone, beam_mat, Vector3(0, -2.0, 0))
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bay_light = SpotLight3D.new()
	_bay_light.light_color = Color(0.5, 1.0, 0.55)
	_bay_light.light_energy = 8.0
	_bay_light.spot_range = 70.0
	_bay_light.spot_angle = 14.0
	_bay_light.position = Vector3(0, -1.6, 0)
	_bay_light.rotation.x = -PI / 2
	add_child(_bay_light)


## Stand-in until the generated model arrives: a heavy cargo hull with
## swept wings, two engine pods and red running lights. Nose towards -Z.
func _build_placeholder() -> void:
	var hull_mat := _metal(Color(0.16, 0.17, 0.19))
	var plate_mat := _metal(Color(0.32, 0.08, 0.07), 0.5, 0.55)
	var hull := CapsuleMesh.new()
	hull.radius = 2.4
	hull.height = 16.0
	_part(hull, hull_mat, Vector3.ZERO, Vector3(PI / 2, 0, 0)).scale = Vector3(1.0, 1.0, 0.65)
	var spine := BoxMesh.new()
	spine.size = Vector3(1.6, 1.0, 10.0)
	_part(spine, plate_mat, Vector3(0, 1.5, 1.0))
	var cockpit := SphereMesh.new()
	cockpit.radius = 1.3
	cockpit.height = 1.6
	_part(cockpit, _glow(Color(1.0, 0.18, 0.08), 2.5), Vector3(0, 0.7, -6.6))
	var wing := BoxMesh.new()
	wing.size = Vector3(9.0, 0.35, 3.6)
	for side in [-1.0, 1.0]:
		var w := _part(wing, hull_mat, Vector3(side * 5.6, 0.0, 2.0), Vector3(0, side * 0.35, side * -0.08))
		w.name = "Wing"
		var pod := CylinderMesh.new()
		pod.top_radius = 1.05
		pod.bottom_radius = 1.25
		pod.height = 5.0
		_part(pod, plate_mat, Vector3(side * 8.8, 0.1, 3.4), Vector3(PI / 2, 0, 0))
		var nozzle := CylinderMesh.new()
		nozzle.top_radius = 0.95
		nozzle.bottom_radius = 0.95
		nozzle.height = 0.15
		_part(nozzle, _glow(Color(1.0, 0.45, 0.15), 5.0), Vector3(side * 8.8, 0.1, 5.95), Vector3(PI / 2, 0, 0))
		var flame := OmniLight3D.new()
		flame.light_color = Color(1.0, 0.5, 0.2)
		flame.light_energy = 3.0
		flame.omni_range = 9.0
		flame.position = Vector3(side * 8.8, 0.1, 6.8)
		add_child(flame)
		var tip := SphereMesh.new()
		tip.radius = 0.22
		tip.height = 0.44
		_blinkers.append(_part(tip, _glow(Color(1.0, 0.1, 0.05), 8.0), Vector3(side * 10.2, 0.0, 2.6)))
	var bay := BoxMesh.new()
	bay.size = Vector3(3.4, 0.5, 4.5)
	_part(bay, _metal(Color(0.08, 0.08, 0.09)), Vector3(0, -1.35, 0.4))
	var belly := SphereMesh.new()
	belly.radius = 0.3
	belly.height = 0.6
	_blinkers.append(_part(belly, _glow(Color(1.0, 0.1, 0.05), 8.0), Vector3(0, -1.5, -5.0)))
