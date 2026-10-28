extends Node
## Dev-only, simulation-time presentation choreography. All combat uses gameplay APIs.
var stage: Node
var player: Node3D
var main: Node3D
var camera: Camera3D
var events: Array = []
var ledger: Array = []
var _next := 0
var _aim_yaw := 0.0
var _aim_pitch := 0.0
var container: Node3D
var vehicle: Node3D
var _hidden: Array = []

func setup(owner_stage: Node) -> void:
	stage = owner_stage
	player = stage._player
	main = stage.agent._main()
	events = stage.scene.get("take",{}).get("events",[])
	if stage.scene.has("container_offset"):
		var at: Vector3 = stage._ground(main, player.position + vec(stage.scene.container_offset))
		container = main._add_container(at,at)
		container.lifting = false
		for i in range(4): container.add_person(i)
		stage._created.append(weakref(container))
	if stage.scene.has("vehicle_kind"):
		# Reserve a clear rehearsal corridor; keep normal vehicle/world collisions.
		for traffic in main.traffic_root.get_children():
			if traffic.global_position.distance_to(player.position) < 150: traffic.queue_free()
		var car = main.Car.new()
		car.name = "VideoVehicle"
		var kind: String = stage.scene.vehicle_kind
		for i in main.Car.MODELS.size():
			if main.Car.kind_of(main.Car.MODELS[i]) == kind:
				car.model_idx = i
				break
		car.graph = main.road_graph
		car.occupied = false
		main.traffic_root.add_child(car)
		car.global_position = stage._ground(main,player.position + Vector3(-7,0,0))
		car.rotation.y = deg_to_rad(stage.scene.yaw)
		car.reset_physics_interpolation()
		vehicle = car
		stage._created.append(weakref(car))
		print("VIDEO_VEHICLE_SETUP ",car.name," kind=",car.kind," at=",car.global_position," player=",player.position)

static func vec(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])

func begin() -> void:
	_next = 0
	ledger = []
	_aim_yaw = player.rotation.y
	_aim_pitch = player.pitch
	if stage.scene.take.has("camera"):
		camera = Camera3D.new()
		camera.fov = 66
		add_child(camera)
		camera.current = true
		for layer in main.find_children("*","CanvasLayer",true,false):
			if layer.visible:
				_hidden.append(layer)
				layer.visible = false

func tick(t: float, delta: float) -> void:
	Settings.virtual.erase("fire")
	Settings.virtual.erase("forward")
	Settings.virtual.erase("back")
	Settings.virtual.erase("jump")
	var take: Dictionary = stage.scene.take
	var fighting := false
	for cue in take.get("fight",[]):
		if t >= cue.start and t < cue.end:
			fighting = true
			fight(delta, bool(cue.get("fire",true)))
	if not fighting and take.has("fight"):
		_aim_yaw = rotate_toward(_aim_yaw,player.rotation.y,3.2*delta)
		_aim_pitch = move_toward(_aim_pitch,player.pitch,2.4*delta)
		player.rotation.y = _aim_yaw
		player.pitch = _aim_pitch
		player.head.rotation.x = _aim_pitch
	for cue in take.get("drive",[]):
		if t >= cue.start and t < cue.end:
			if cue.get("brake",false):
				if is_instance_valid(vehicle) and vehicle._speed > 0.5: Settings.virtual["back"] = true
			else: Settings.virtual["forward"] = true
	for cue in take.get("fly",[]):
		if t >= cue.start and t < cue.end and is_instance_valid(player._drone):
			Settings.virtual["forward"] = true
			if cue.get("up",false): Settings.virtual["jump"] = true
			player._drone.rotation.y = player.rotation.y
			player._drone_cam.rotation.x = player.pitch
			if cue.get("fire",false): Settings.virtual["fire"] = true
	if is_instance_valid(player.vehicle) and take.has("vehicle_look"):
		var orbit: Vector2 = stage.looking(take.vehicle_look,t)
		player._chase_yaw = orbit.x
		player._chase_pitch = orbit.y
	if camera:
		var keys: Array = take.camera
		var a: Dictionary = keys[0]
		var b: Dictionary = keys[-1]
		for i in range(1,keys.size()):
			if t <= float(keys[i].t):
				a = keys[i-1]; b = keys[i]; break
		var f: float = stage.smooth_weight((t-float(a.t))/maxf(0.001,float(b.t)-float(a.t)))
		camera.global_position = vec(a.pos).lerp(vec(b.pos),f)
		camera.look_at(vec(a.target).lerp(vec(b.target),f))
	# Actions use the aim evaluated for this tick, rather than the base look key.
	while _next < events.size() and float(events[_next].t) <= t:
		perform(events[_next])
		_next += 1

func fight(delta: float, shoot: bool) -> void:
	var target: Node3D
	var best := INF
	for node in get_tree().get_nodes_in_group("robots"):
		if not node.has_method("is_alive") or not node.is_alive(): continue
		var d: float = node.global_position.distance_to(player.position)
		if d < best: best = d; target = node
	if not target:
		player.rotation.y = _aim_yaw
		player.pitch = _aim_pitch
		player.head.rotation.x = _aim_pitch
		return
	var at: Vector3 = target.aim_position() if target.has_method("aim_position") else target.global_position + Vector3(0,2.4 if target.get("variant") == "mech" else (0.0 if target.get("variant") == "drone" else 1.1),0)
	var direction: Vector3 = at - player.camera.global_position
	var yaw := atan2(-direction.x,-direction.z)
	var pitch := atan2(direction.y,Vector2(direction.x,direction.z).length())
	_aim_yaw = rotate_toward(_aim_yaw,yaw,3.2*delta)
	_aim_pitch = move_toward(_aim_pitch,pitch,2.4*delta)
	player.rotation.y = _aim_yaw
	player.pitch = _aim_pitch
	player.head.rotation.x = _aim_pitch
	var ready: bool = player.WEAPONS[player.weapon].get("auto",false) or not player._trigger_held
	if shoot and ready and absf(angle_difference(_aim_yaw,yaw)) + absf(_aim_pitch-pitch) < 0.07:
		Settings.virtual["fire"] = true

func perform(event: Dictionary) -> void:
	var result := "ok"
	match event.action:
		"spawn":
			var at: Vector3 = stage._ground(main,stage._take_origin+vec(event.offset)) + Vector3(0,event.get("height",0.2),0)
			stage.agent._m_spawn_enemy({"x":at.x,"y":at.y,"z":at.z,"variant":event.variant,"n":event.get("count",6)})
			stage._created.append(weakref(main.enemies_root.get_child(main.enemies_root.get_child_count()-1)))
		"grenade":
			player.grenade = event.kind
			player._throw_grenade()
		"reload": player._start_reload()
		"weapon": player.give(event.kind); player._switch(event.kind)
		"lasso":
			var target: Node3D = player._lasso_target()
			result = str(target.get("variant")) if target else "no target"
			player._throw_lasso()
		"drone": player._toggle_drone(); result = "flying" if player._drone else "landed"
		"open_container":
			if is_instance_valid(container) and player._people_container() == container:
				main.open_container(container.get_path())
				result = str(container.people.size()) + " remaining"
			else: result = "out of interaction reach"
		"enter_vehicle":
			if is_instance_valid(vehicle):
				print("VIDEO_VEHICLE_ENTER ",vehicle.name," distance=",vehicle.global_position.distance_to(player.position)," peer=",vehicle.driver_peer," wreck=",vehicle._wrecked)
				player.request_vehicle(str(vehicle.name))
				result = str(player.vehicle != null)
		"exit_vehicle": player.request_exit()
		"grain":
			if is_instance_valid(vehicle):
				var tip := vehicle.find_child("muzzle_auger",true,false) as Node3D
				var origin: Vector3 = tip.global_position if tip else vehicle.position + Vector3(0,4.5,0)
				vehicle.grain_fire.rpc((player._harvester_aim()-origin).normalized())
		"tablet":
			if player._tablet:
				player._tablet.open()
				player._tablet._open_app(event.get("app","home"))
				if event.get("app", "") == "radio": player._radio_tune(0)
		"close_tablet":
			if player._tablet: player._tablet.close()
		"dropship": result = str(main.call_dropship(player.position,4))
	ledger.append({"t":event.t,"action":event.action,"result":result})

func finish() -> void:
	for key in ["fire","forward","back","jump"]: Settings.virtual.erase(key)
	if is_instance_valid(player):
		if player._drone: player._land_drone()
		if player.vehicle: player.request_exit()
		if player._tablet: player._tablet.close()
		player.camera.current = true
	if camera: camera.queue_free(); camera = null
	for layer in _hidden:
		if is_instance_valid(layer): layer.visible = true
	_hidden.clear()
