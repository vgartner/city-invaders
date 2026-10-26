extends Node3D
const Player := preload("res://scripts/player.gd")
const Shot := preload("res://scripts/drone_shot.gd")
var enemies_root: Node3D
var failures := 0
class QuietPlayer:
	extends "res://scripts/player.gd"
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
class Target:
	extends StaticBody3D
	var damage := 0
	func apply_damage(amount: int, _source: Node) -> void:
		damage += amount
func expect(ok: bool, reason: String) -> void:
	if not ok:
		failures += 1
		push_error(reason)
func _ready() -> void:
	call_deferred("_run_network" if "--network" in OS.get_cmdline_user_args() else "_run")
func _run() -> void:
	enemies_root = Node3D.new()
	add_child(enemies_root)
	var player := QuietPlayer.new()
	player.name = "1"
	add_child(player)
	player._drone_cam = Camera3D.new()
	player.add_child(player._drone_cam)
	var target := Target.new()
	target.collision_layer = 2
	target.position.z = -10
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	target.add_child(shape)
	add_child(target)
	await get_tree().physics_frame
	await get_tree().physics_frame
	player._drone_fire() # Real input route, RPC, authoritative damage and FX.
	var shots := find_children("DroneShot*", "MeshInstance3D", false, false)
	expect(shots.size() == 1 and target.damage == Player.DRONE_DAMAGE, "One drone trigger must show one shot and keep its damage")
	if not shots.is_empty():
		var shot: MeshInstance3D = shots[0]
		var a := shot.global_transform * Vector3(0, -0.5, 0)
		var b := shot.global_transform * Vector3(0, 0.5, 0)
		expect(absf(minf(a.z, b.z) + 9.5) < 0.02, "Ray must stop at the hit surface")
		expect(shot.mesh == Shot.mesh(), "Shots share geometry and material")
	player._drone_fire()
	expect(find_children("DroneShot*", "MeshInstance3D", false, false).size() == 1, "Cooldown must not create duplicate rays")
	await get_tree().create_timer(0.2).timeout
	expect(find_children("DroneShot*", "MeshInstance3D", false, false).is_empty(), "Shot must expire")
	var wall := StaticBody3D.new()
	wall.position.z = -3
	var wall_shape := CollisionShape3D.new()
	wall_shape.shape = BoxShape3D.new()
	wall.add_child(wall_shape)
	add_child(wall)
	await get_tree().physics_frame
	await get_tree().physics_frame
	player._fire_cd = 0
	player._drone_fire()
	shots = find_children("DroneShot*", "MeshInstance3D", false, false)
	expect(target.damage == Player.DRONE_DAMAGE and shots.size() == 1, "Wall must block both drone damage and ray")
	if not shots.is_empty():
		var shot: MeshInstance3D = shots[0]
		var a := shot.global_transform * Vector3(0, -0.5, 0)
		var b := shot.global_transform * Vector3(0, 0.5, 0)
		expect(absf(minf(a.z, b.z) + 2.5) < 0.02, "Blocked ray ends on the wall")
	for direction in [Vector3.UP, Vector3.DOWN, Vector3.FORWARD]:
		var shot := Shot.show(self, Vector3.ZERO, direction, direction * 150)
		expect(shot != null and shot.global_basis.is_finite(), "Vertical and sky shots stay finite")
	expect(Shot.show(self, Vector3.ZERO, Vector3.FORWARD, Vector3.ZERO) == null, "Zero-length shots are safe")
	await get_tree().create_timer(1.2).timeout
	for child in get_children(): child.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("Player drone shot regression failures: ", failures)
	get_tree().quit(1 if failures else 0)


func _run_network() -> void:
	var host := "--host" in OS.get_cmdline_user_args()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(24693, 1) if host else peer.create_client("127.0.0.1", 24693)
	expect(error == OK, "Network fixture must connect on its isolated test port")
	if error != OK:
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	enemies_root = Node3D.new()
	add_child(enemies_root)
	var player := QuietPlayer.new()
	player.name = "2"
	# The shooting player belongs to the client, not to the server broadcasting FX.
	player.set_multiplayer_authority(2)
	add_child(player)
	var target := Target.new()
	target.collision_layer = 2
	target.position.z = -10
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	target.add_child(shape)
	add_child(target)
	var seen := [0]
	child_entered_tree.connect(func(node: Node):
		if node is MeshInstance3D and str(node.name).begins_with("DroneShot"):
			seen[0] += 1)
	if host:
		var client_id: int = await multiplayer.peer_connected
		player.set_multiplayer_authority(client_id)
	else:
		await multiplayer.connected_to_server
		player.set_multiplayer_authority(multiplayer.get_unique_id())
		await get_tree().create_timer(0.1).timeout
		player.server_shoot.rpc_id(1, Vector3.ZERO, Vector3.FORWARD, "drone")
	await get_tree().create_timer(2.0 if host else 0.5).timeout
	expect(seen[0] == 1, "Server and owning client must each see exactly one ray")
	expect(target.damage == (Player.DRONE_DAMAGE if host else 0), "Only the server applies drone damage")
	expect(find_children("DroneShot*", "MeshInstance3D", false, false).is_empty(), "Network ray must expire on both peers")
	print("Network drone shot ", "host" if host else "client", ": ", seen[0], " ray, failures: ", failures)
	peer.close()
	for child in get_children(): child.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if failures else 0)
