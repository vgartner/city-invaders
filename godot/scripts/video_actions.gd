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
var _initial_pickups: Dictionary = {}
var _observed_drops: Dictionary = {}
var _grenades: Array = []
var _drone_target: Node3D

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
	_initial_pickups.clear()
	_observed_drops.clear()
	_grenades.clear()
	_aim_yaw = player.rotation.y
	_aim_pitch = player.pitch
	for pickup in main.pickups_root.get_children(): _initial_pickups[pickup.get_instance_id()] = true
	for enemy in get_tree().get_nodes_in_group("robots"):
		if enemy.get("variant") == "trooper": _drone_target = enemy
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
	Settings.virtual.erase("run")
	observe_drops()
	observe_grenades()
	var take: Dictionary = stage.scene.take
	var fighting := false
	for cue in take.get("fight",[]):
		if t >= cue.start and t < cue.end:
			fighting = true
			fight(delta, bool(cue.get("fire",true)))
	var guided := false
	for cue in take.get("loot",[]) + take.get("grenade_aim",[]):
		if t >= cue.start and t < cue.end: guided = true
	if not fighting and not guided and take.has("fight"):
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
	for cue in take.get("loot",[]):
		if t >= cue.start and t < cue.end: loot(t,cue,delta)
	for cue in take.get("grenade_aim",[]):
		if t >= cue.start and t < cue.end: aim_grenade(delta,cue)
	for cue in take.get("fly",[]):
		if t >= cue.start and t < cue.end and is_instance_valid(player._drone):
			if cue.get("forward",true): Settings.virtual["forward"] = true
			if cue.get("up",false): Settings.virtual["jump"] = true
			if cue.get("fast",false): Settings.virtual["run"] = true
			var yaw: float = player.rotation.y
			var pitch: float = player.pitch
			if cue.has("destination"):
				var offset: Vector3 = vec(cue.destination) - player._drone.global_position
				yaw = atan2(-offset.x,-offset.z)
				if Vector2(offset.x,offset.z).length() < 1.0: Settings.virtual.erase("forward")
			if cue.get("aim_target",false) and is_instance_valid(_drone_target) and _drone_target.is_alive():
				var offset: Vector3 = (_drone_target.global_position + Vector3(0,1.1,0)) - player._drone_cam.global_position
				yaw = atan2(-offset.x,-offset.z)
				pitch = atan2(offset.y,Vector2(offset.x,offset.z).length())
			player._drone.rotation.y = rotate_toward(player._drone.rotation.y,yaw,1.8*delta)
			player._drone_cam.rotation.x = move_toward(player._drone_cam.rotation.x,pitch,1.4*delta)
			if cue.get("fire",false) and absf(angle_difference(player._drone.rotation.y,yaw)) + absf(player._drone_cam.rotation.x-pitch) < 0.06:
				Settings.virtual["fire"] = true
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

func observe_drops() -> void:
	for pickup in main.pickups_root.get_children():
		var id: int = pickup.get_instance_id()
		if _initial_pickups.has(id) or _observed_drops.has(id) or pickup.kind != "circuit": continue
		_observed_drops[id] = weakref(pickup)
		pickup.body_entered.connect(stage._pickup_entered.bind(pickup))

func loot(t: float, cue: Dictionary, delta: float) -> void:
	var target: Node3D
	var best := INF
	for ref in _observed_drops.values():
		var pickup: Node3D = ref.get_ref()
		if not is_instance_valid(pickup) or pickup.is_queued_for_deletion(): continue
		var distance: float = pickup.global_position.distance_to(player.position)
		if distance < best: best = distance; target = pickup
	if not target: return
	var offset: Vector3 = target.global_position - player.position
	var yaw := atan2(-offset.x,-offset.z)
	_aim_yaw = rotate_toward(_aim_yaw,yaw,2.5*delta)
	_aim_pitch = move_toward(_aim_pitch,deg_to_rad(-18.0),0.9*delta)
	player.rotation.y = _aim_yaw
	player.pitch = _aim_pitch
	player.head.rotation.x = _aim_pitch
	stage._pickup_targets["dropped_circuit"] = target.global_position
	player.scripted_move = stage._approach({"pickup":"dropped_circuit","start":cue.start,"end":cue.end,"speed_mps":5.0,"ramp_s":0.5},t).limit_length()

func nearest_robot() -> Node3D:
	var target: Node3D
	var best := INF
	for node in get_tree().get_nodes_in_group("robots"):
		if not node.has_method("is_alive") or not node.is_alive(): continue
		var distance: float = node.global_position.distance_to(player.position)
		if distance < best: best = distance; target = node
	return target

func aim_grenade(delta: float, cue: Dictionary) -> void:
	var target := nearest_robot()
	if not target: return
	var lead: float = cue.get("lead_s",1.5)
	var predicted: Vector3 = target.global_position + target.velocity * lead
	var offset: Vector3 = predicted - player.camera.global_position
	var distance := clampf(Vector2(offset.x,offset.z).length()-3.0,1.5,12.0)
	# Solve the real 11 m/s throw, including its 2.5 m/s upward impulse.
	# Lead moving feet, then allow for ground bounce during the fuse.
	var low := deg_to_rad(-80.0)
	var high := deg_to_rad(10.0)
	var height := maxf(0.2,player.camera.global_position.y-target.global_position.y-0.15)
	for i in range(24):
		var angle := (low+high)*0.5
		var vy := 11.0*sin(angle)+2.5
		var flight := (vy+sqrt(vy*vy+2.0*9.8*height))/9.8
		if 11.0*cos(angle)*flight > distance: high = angle
		else: low = angle
	_aim_yaw = rotate_toward(_aim_yaw,atan2(-offset.x,-offset.z),2.5*delta)
	_aim_pitch = move_toward(_aim_pitch,(low+high)*0.5,2.0*delta)
	player.rotation.y = _aim_yaw
	player.pitch = _aim_pitch
	player.head.rotation.x = _aim_pitch

func observe_grenades() -> void:
	for child in main.get_children():
		if child.get_script() != main.Grenade: continue
		if _grenades.any(func(item: Dictionary) -> bool: return item.id == child.get_instance_id()): continue
		_grenades.append({"id":child.get_instance_id(),"ref":weakref(child),"kind":child.kind,"done":false})
	for item in _grenades:
		var grenade: Node3D = item.ref.get_ref()
		if is_instance_valid(grenade):
			item["position"] = grenade.global_position
			var nearest := INF
			for enemy in main.enemies_root.get_children():
				if enemy.has_method("is_alive") and enemy.is_alive(): nearest = minf(nearest,enemy.global_position.distance_to(grenade.global_position))
			item["nearest_m"] = nearest
		elif not item.done:
			item.done = true
			ledger.append({"t":stage.elapsed,"action":"grenade_burst","kind":item.kind,"position":[item.position.x,item.position.y,item.position.z],"nearest_robot_before_burst_m":item.get("nearest_m",INF)})

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
	for key in ["fire","forward","back","jump","run"]: Settings.virtual.erase(key)
	if is_instance_valid(player):
		if player._drone: player._land_drone()
		if player.vehicle: player.request_exit()
		if player._tablet: player._tablet.close()
		player.camera.current = true
	if camera: camera.queue_free(); camera = null
	for layer in _hidden:
		if is_instance_valid(layer): layer.visible = true
	_hidden.clear()
