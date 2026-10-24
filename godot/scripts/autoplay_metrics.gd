extends RefCounted
## Observed player motion, not camera travel. Times are simulation seconds.
var foot_m := 0.0
var vehicle_m := 0.0
var relocation_m := 0.0
var discontinuity_m := 0.0
var stationary_s := 0.0
var stationary_combat_s := 0.0
var time_s := 0.0
var activity_s: Dictionary = {}
var weapon_s: Dictionary = {}
var cells: Dictionary = {}
var _position := Vector3.ZERO
var _driving := false
var _initialized := false

func reset(position: Vector3, driving: bool) -> void:
	_position = position
	_driving = driving
	_initialized = true

func relocate(position: Vector3, driving: bool) -> void:
	if _initialized:
		relocation_m += Vector2(position.x - _position.x, position.z - _position.z).length()
	reset(position, driving)

func sample(position: Vector3, driving: bool, delta: float, activity: String, weapon: String) -> void:
	time_s += delta
	activity_s[activity] = activity_s.get(activity, 0.0) + delta
	weapon_s[weapon] = weapon_s.get(weapon, 0.0) + delta
	cells[Vector2i(floori(position.x / 50.0), floori(position.z / 50.0))] = true
	if _initialized and driving == _driving:
		var step := Vector2(position.x - _position.x, position.z - _position.z).length()
		if step > maxf(3.0, delta * 60.0):
			discontinuity_m += step # External teleports must not inflate travel.
		else:
			if driving:
				vehicle_m += step
			else:
				foot_m += step
			if step < delta * 0.15:
				stationary_s += delta
				if activity == "fight":
					stationary_combat_s += delta
	reset(position, driving)

func snapshot() -> Dictionary:
	return {"foot_m": snappedf(foot_m, 0.1), "vehicle_m": snappedf(vehicle_m, 0.1),
			"relocation_m": snappedf(relocation_m, 0.1), "discontinuity_m": snappedf(discontinuity_m, 0.1),
			"time_s": snappedf(time_s, 0.1), "stationary_s": snappedf(stationary_s, 0.1),
			"stationary_combat_s": snappedf(stationary_combat_s, 0.1),
			"unique_cells_50m": cells.size(), "activity_s": activity_s.duplicate(), "weapon_s": weapon_s.duplicate()}
