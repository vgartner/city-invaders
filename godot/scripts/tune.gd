extends Node
## Gameplay tuning values in one place, read live by the scripts every time
## they are used: the DevAgent `tune` method changes them in the running game
## (try a value, look, keep it by writing it here). Units in the names.

var vehicle_max_pitch_deg := 12.0     # streets steeper than this don't tilt vehicles further
var vehicle_max_roll_deg := 6.0       # sideways bank on cross-sloping streets
var vehicle_kerb_step_m := 0.1        # a height jump under one side bigger than this is a kerb, not a slope
var horn_interval_s := 4.0            # a blocked vehicle honks this often
var engine_db := 6.0                  # every engine louder than its base level (traffic too)
var engine_driving_db := 8.0          # on top of that for the vehicle you drive
var engine_rev_db := 6.0              # up to this much more at full speed
var pigeon_spook_m := 3.5             # walk this close and the flock flies off
var police_range_m := 35.0            # officers engage robots this far away
var police_damage := 8.0              # per hit on a robot
var robot_aim_officer := 0.5          # robots' hit chance on an officer at ~20 m (closer: more)
var robot_sight_m := 40.0
var pala_absorb := 0.5                # share of each hit the poncho takes
var adrenaline_s := 12.0              # Fruki effect length
var adrenaline_speed := 1.4           # running speed factor while on Fruki


func values() -> Dictionary:
	var out := {}
	for p in get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out[p["name"]] = get(p["name"])
	return out
