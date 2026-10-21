extends RefCounted
## Difficulty: one table for everything it changes. The host's choice
## (Settings.difficulty) applies to the round and is sent to every client
## (main.gd set_difficulty), so all peers build robots the same way.
## "easy" is how the game played before levels existed.

const LEVELS := ["easy", "medium", "hard"]
const NAMES := {"easy": "EASY", "medium": "MEDIUM", "hard": "HARD"}

const TABLE := {
	"easy": {
		"trooper_hp": 60, "mech_hp": 360, "drone_hp": 30, "commander_hp": 900,
		"trooper_dmg": 5, "mech_dmg": 10, "fire_interval": 1.8, "aim_max": 0.6, "sight": 35.0,
		"enemies_per_player": 8, "relax_s": 25.0, "antenna_reinforce": 0.8,
		"goals": {"gasometro": 20, "centro": 25, "mercado": 30}, "goal_scale": 0.8,
		"mechs": {"gasometro": 2, "centro": 3, "mercado": 4}, "mech_default": 2,
		"pickups": 1.3, "pala_absorb": 0.6, "respawn_s": 2.0,
		"death_penalty": 0, "civ_fail": 0.0, "antennas": 3, "collectors": 1, "swarm_s": 150.0,
		# the drone swarm: how many, a kamikaze's blast and a gunner's bolt on a player, seconds between dives / a gunner's shots
		"swarm_n": [4, 6], "swarm_blast": 6, "swarm_bolt": 2, "swarm_dive_s": 3.2, "swarm_fire_s": 2.8,
		"containers": 2, "container_cap": 10,
	},
	"medium": {
		"trooper_hp": 100, "mech_hp": 700, "drone_hp": 45, "commander_hp": 1500,
		"trooper_dmg": 8, "mech_dmg": 14, "fire_interval": 1.4, "aim_max": 0.8, "sight": 40.0,
		"enemies_per_player": 12, "relax_s": 18.0, "antenna_reinforce": 0.6,
		"goals": {"gasometro": 30, "centro": 35, "mercado": 40}, "goal_scale": 1.2,
		"mechs": {"gasometro": 3, "centro": 4, "mercado": 5}, "mech_default": 3,
		"pickups": 1.0, "pala_absorb": 0.5, "respawn_s": 4.0,
		"death_penalty": 150, "civ_fail": 0.0, "antennas": 4, "collectors": 1, "swarm_s": 110.0,
		# the drone swarm: how many, a kamikaze's blast and a gunner's bolt on a player, seconds between dives / a gunner's shots
		"swarm_n": [6, 8], "swarm_blast": 9, "swarm_bolt": 2, "swarm_dive_s": 2.6, "swarm_fire_s": 2.2,
		"containers": 2, "container_cap": 8,
	},
	"hard": {
		"trooper_hp": 140, "mech_hp": 1100, "drone_hp": 60, "commander_hp": 2200,
		"trooper_dmg": 11, "mech_dmg": 18, "fire_interval": 1.1, "aim_max": 0.9, "sight": 50.0,
		"enemies_per_player": 16, "relax_s": 12.0, "antenna_reinforce": 0.45,
		"goals": {"gasometro": 40, "centro": 45, "mercado": 55}, "goal_scale": 1.6,
		"mechs": {"gasometro": 5, "centro": 6, "mercado": 7}, "mech_default": 5,
		"pickups": 0.7, "pala_absorb": 0.4, "respawn_s": 6.0,
		# losing 30% of the people the phase started with loses the phase
		"death_penalty": 300, "civ_fail": 0.3, "antennas": 5, "collectors": 2, "swarm_s": 75.0,
		# the drone swarm: how many, a kamikaze's blast and a gunner's bolt on a player, seconds between dives / a gunner's shots
		"swarm_n": [8, 12], "swarm_blast": 12, "swarm_bolt": 3, "swarm_dive_s": 2.0, "swarm_fire_s": 1.8,
		"containers": 3, "container_cap": 6,
	},
}

## Weak points (every level): a mech is armoured in front, its reactor at the
## back is not; a trooper's head takes double, its legs less.
const MECH_FRONT := 0.5
const MECH_BACK := 2.0
const HEAD := 2.0
const LEGS := 0.7

static var level := "medium"


static func get_value(key: String) -> Variant:
	return TABLE.get(level, TABLE["medium"])[key]


static func label() -> String:
	return NAMES.get(level, "MEDIUM")
