extends RefCounted
## Brief visible tracer only: hits/damage stay in Player.server_shoot.
## Shared geometry/material; no light, physics, or per-shot resource loading.
const LIFETIME := 0.10
static var _mesh: CylinderMesh

static func mesh() -> CylinderMesh:
	if _mesh == null:
		_mesh = CylinderMesh.new()
		_mesh.top_radius = 0.008
		_mesh.bottom_radius = 0.008
		_mesh.height = 1.0
		_mesh.radial_segments = 6
		_mesh.rings = 1
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.55, 1.0, 0.65)
		material.emission_enabled = true
		material.emission = Color(0.2, 1.0, 0.35)
		material.emission_energy_multiplier = 3.0
		_mesh.material = material
	return _mesh

static func show(parent: Node, origin: Vector3, direction: Vector3, to: Vector3) -> MeshInstance3D:
	if not is_instance_valid(parent) or not origin.is_finite() or not to.is_finite() \
			or not direction.is_finite() or direction.is_zero_approx():
		return null
	var distance := origin.distance_to(to)
	if distance < 0.001:
		return null
	var forward := direction.normalized()
	var right := forward.cross(Vector3.UP).normalized()
	if right.is_zero_approx():
		right = Vector3.RIGHT
	var up := right.cross(forward).normalized()
	# Start below/right of the camera so the ray is visible in first person.
	# Shrink the offset for nearby hits, keeping the end on the actual hit.
	var from := origin + (forward * 0.55 + right * 0.14 - up * 0.12) * minf(distance / 0.8, 1.0)
	var segment := to - from
	var length := segment.length()
	if length < 0.001:
		return null
	var tracer := MeshInstance3D.new()
	tracer.name = "DroneShot"
	tracer.mesh = mesh()
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(tracer)
	tracer.global_position = (from + to) * 0.5
	var axis := segment / length
	tracer.look_at(tracer.global_position + axis, Vector3.UP if absf(axis.y) < 0.99 else Vector3.RIGHT)
	tracer.rotate_object_local(Vector3.RIGHT, PI / 2)
	tracer.scale.y = length
	tracer.create_tween().tween_interval(LIFETIME).finished.connect(tracer.queue_free)
	return tracer
