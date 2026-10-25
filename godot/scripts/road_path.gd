extends RefCounted
## Horizontal lane geometry for the test driver's pursuit controller.
## Distances follow the polyline, not chords between distant OSM vertices.

static func flat(p: Vector3) -> Vector3:
	return Vector3(p.x, 0, p.z)


static func turn_angle(forward: Vector3, to: Vector3) -> float:
	# Vehicle pitch on a hill is not a horizontal steering error.
	return flat(forward).signed_angle_to(flat(to), Vector3.UP)


static func project(path: PackedVector3Array, here: Vector3, start := 0, segments := 0) -> Dictionary:
	var best := {"segment": 0, "point": here, "distance": INF}
	var end := path.size() - 1 if segments == 0 else mini(path.size() - 1, start + segments)
	for i in range(maxi(0, start), end):
		var a := flat(path[i])
		var b := flat(path[i + 1])
		var line := b - a
		var t := clampf((flat(here) - a).dot(line) / maxf(line.length_squared(), 0.000001), 0, 1)
		var point := path[i].lerp(path[i + 1], t)
		var distance := flat(here - point).length()
		if distance < best.distance:
			best = {"segment": i, "point": point, "distance": distance}
	return best


static func ahead(path: PackedVector3Array, projection: Dictionary, distance: float) -> Vector3:
	var point: Vector3 = projection.point
	for i in range(int(projection.segment) + 1, path.size()):
		var length := flat(path[i] - point).length()
		if length >= distance:
			return point.lerp(path[i], distance / maxf(length, 0.000001))
		distance -= length
		point = path[i]
	return point


static func remaining(path: PackedVector3Array, projection: Dictionary) -> float:
	var distance := 0.0
	var point: Vector3 = projection.point
	for i in range(int(projection.segment) + 1, path.size()):
		distance += flat(path[i] - point).length()
		point = path[i]
	return distance


## Brake before a bend, including bends beyond the current road edge.
static func speed_limit(path: PackedVector3Array, projection: Dictionary) -> float:
	var limit := 13.0
	var distance := 0.0
	var point: Vector3 = projection.point
	for i in range(int(projection.segment) + 1, path.size() - 1):
		distance += flat(path[i] - point).length()
		point = path[i]
		if distance > 40.0:
			break
		var before := flat(path[i] - path[i - 1]).normalized()
		var after := flat(path[i + 1] - path[i]).normalized()
		var bend := absf(before.signed_angle_to(after, Vector3.UP))
		if bend > 0.15:
			# Closely spaced points can describe a tight curve whose individual
			# angles are small. Bound radius by both spacing and junction room.
			var spacing := minf(6.0, minf(flat(path[i] - path[i - 1]).length(), flat(path[i + 1] - path[i]).length()))
			var radius := spacing / (2.0 * tan(bend * 0.5))
			var corner_speed := clampf(sqrt(2.0 * maxf(0, radius)), 2.5, 12.0)
			limit = minf(limit, sqrt(corner_speed * corner_speed + 2.0 * 2.5 * maxf(0, distance - 3.0)))
	return limit


## Select real keys against the player's asymmetric steering filter: pressing
## turns at rate, releasing centres at twice that rate. Duty alone understeers.
static func steer_key(desired: float, actual: float, rate: float) -> String:
	var key := ""
	var error := absf(move_toward(actual, 0.0, rate * 2.0) - desired)
	for option in [["left", -1.0], ["right", 1.0]]:
		var candidate := absf(move_toward(actual, float(option[1]), rate) - desired)
		if candidate < error:
			error = candidate
			key = option[0]
	return key
