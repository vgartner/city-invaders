extends RefCounted
## Step-up for CharacterBody3D over curbs and low edges (<= MAX_STEP). The
## curb's top edge sits between two triangles of a trimesh collider, so the
## physics reports the vertical face and the capsule never rides over it.
## If the horizontal motion is blocked but the same motion is free from
## MAX_STEP higher, lift the body; gravity/floor snap settles it on top.

const MAX_STEP := 0.3


static func try_step(body: CharacterBody3D, motion: Vector3) -> bool:
	motion.y = 0
	if motion.length() < 0.001 or not body.is_on_floor():
		return false
	if not body.is_on_wall():
		return false                          # nothing in the way last step: skip the costly probes
	var t := body.global_transform
	var hit := KinematicCollision3D.new()
	if not body.test_move(t, motion, hit):
		return false                          # not blocked
	if hit.get_normal().y > 0.7:
		return false                          # just the ground sloping up, walk on
	var up := Vector3(0, MAX_STEP, 0)
	if body.test_move(t, up):
		return false                          # no head room
	if body.test_move(t.translated(up), motion):
		return false                          # a real wall, not a step
	# a trimesh's inner edges also report a vertical face: only climb when
	# the ground just ahead really is higher than the ground underfoot
	var space := body.get_world_3d().direct_space_state
	var ahead := body.global_position + motion.normalized() * 0.35
	var here := _ground(space, body, body.global_position)
	var there := _ground(space, body, ahead)
	if is_nan(here) or is_nan(there) or there - here < 0.04:
		return false
	body.global_position += up
	return true


static func _ground(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, at: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, MAX_STEP + 0.5, 0), at - Vector3(0, 1.5, 0), 1)
	q.exclude = [body.get_rid()]
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else NAN
