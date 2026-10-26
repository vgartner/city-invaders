extends Node3D
const Enemy := preload("res://scripts/enemy.gd")
class QuietEnemy:
	extends "res://scripts/enemy.gd"
	func _ready() -> void:
		_v = {"muzzle": Vector3.ZERO, "clips": {}}
		set_process(false)
		set_physics_process(false)

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var enemy := QuietEnemy.new()
	add_child(enemy)
	# Previously look_at(target) failed exactly at half a bolt length,
	# and pointed backwards for closer targets. Exercise the real shot path.
	for distance in [0.0, 0.1, Enemy.BOLT_LENGTH / 2, 10.0]:
		var before := find_children("*", "MeshInstance3D", false, false).size()
		enemy.show_shot(Vector3(0, 0, -distance))
		if distance == 0:
			assert(find_children("*", "MeshInstance3D", false, false).size() == before, "Zero-length shots must not allocate tracers")
		else:
			var bolt := get_child(get_child_count() - 1) as MeshInstance3D
			assert(bolt != null and bolt.global_basis.is_finite())
			assert(absf(bolt.global_basis.y.dot(Vector3.FORWARD)) > 0.999,
				"Tracer axis must follow the shot even when the target is closer than its centre")
	await get_tree().create_timer(1.5).timeout
	for child in get_children():
		child.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("Enemy tracer close-hit regression passed")
	get_tree().quit()
