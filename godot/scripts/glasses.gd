extends Control
## The information glasses (O, once found): what is normally hidden, laid
## over the view - robots and drones nearby with a bracket and their
## distance (through walls), the Coletor carrying someone, communication
## antennas and people containers within sight range, robot parts on the
## ground, and the street
## you are on. They run on a battery (BATTERY_S while on); a drone battery
## from a repair shop or the ground fills it again.

const BATTERY_S := 150.0
const ROBOT_M := 70.0
const ANTENNA_M := 260.0
const PART_M := 30.0
const CYAN := Color(0.3, 0.95, 1.0)
const RED := Color(1.0, 0.3, 0.25)
const ORANGE := Color(1.0, 0.6, 0.2)
const PURPLE := Color(0.85, 0.45, 1.0)

var player: Node3D
var on := false
var charge := BATTERY_S


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func toggle() -> void:
	if not on and charge <= 0.0:
		return
	on = not on
	visible = on
	Sfx.play("pickup", -14.0)


func recharge() -> void:
	charge = BATTERY_S


func _process(delta: float) -> void:
	if not on:
		return
	charge -= delta
	if charge <= 0.0:
		charge = 0.0
		on = false
		visible = false
		return
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(player):
		return
	var cam: Camera3D = player.camera
	var f := ThemeDB.fallback_font
	var main := get_tree().current_scene
	var eye: Vector3 = cam.global_position
	size = get_viewport_rect().size          # the whole view (the HUD layer may not size it)
	# a cyan rim and the battery: these are glasses
	draw_rect(Rect2(Vector2.ZERO, size), Color(CYAN, 0.05))
	draw_rect(Rect2(Vector2(8, 8), size - Vector2(16, 16)), Color(CYAN, 0.35), false, 2.0)
	var pct := charge / BATTERY_S
	draw_rect(Rect2(size.x - 190, 24, 150, 12), Color(0, 0, 0, 0.4))
	draw_rect(Rect2(size.x - 190, 24, 150 * pct, 12), CYAN if pct > 0.25 else RED)
	draw_string(f, Vector2(size.x - 190, 58), "ÓCULOS  %d s" % int(charge), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, CYAN)
	for e in main.enemies_root.get_children():
		if not (e is Node3D) or not e.has_method("is_alive") or not e.is_alive():
			continue
		var p: Vector3 = (e as Node3D).global_position + Vector3(0, 1.2, 0)
		var d := eye.distance_to(p)
		var carrying: bool = is_instance_valid(e.get("_captive"))
		if d > ROBOT_M and not carrying:
			continue
		if cam.is_position_behind(p):
			continue
		var sp := cam.unproject_position(p)
		var r := clampf(900.0 / maxf(d, 1.0), 14.0, 70.0)
		var c := ORANGE if carrying else RED
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var at: Vector2 = sp + corner * r
			draw_line(at, at - Vector2(corner.x * r * 0.4, 0), c, 2.5)
			draw_line(at, at - Vector2(0, corner.y * r * 0.4), c, 2.5)
		var label := "%s  %d m" % [("COLETOR" if carrying else String(e.get("variant") if e.get("variant") else "robô").to_upper()), int(d)]
		draw_string(f, sp + Vector2(-r, -r - 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, c)
	for a in get_tree().get_nodes_in_group("relay"):
		if not a.is_alive():
			continue
		var p: Vector3 = (a as Node3D).global_position + Vector3(0, 6, 0)
		var d := eye.distance_to(p)
		if d > ANTENNA_M or cam.is_position_behind(p):
			continue
		var sp := cam.unproject_position(p)
		draw_colored_polygon(PackedVector2Array([sp + Vector2(0, -14), sp + Vector2(12, 8), sp + Vector2(-12, 8)]), ORANGE)
		draw_string(f, sp + Vector2(16, 6), "TORRE  %d m" % int(d), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ORANGE)
	for c in get_tree().get_nodes_in_group("people_containers"):
		var p: Vector3 = (c as Node3D).global_position + Vector3(0, 4.2, 0)
		var d := eye.distance_to(p)
		if d > ANTENNA_M or cam.is_position_behind(p):
			continue
		var sp := cam.unproject_position(p)
		draw_rect(Rect2(sp - Vector2(11, 11), Vector2(22, 22)), PURPLE, false, 3.0)
		draw_string(f, sp + Vector2(16, 6), "CONTAINER %d/%d  %d m" % [c.people.size(), c.capacity, int(d)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, PURPLE)
	# the GPS route on the ground ahead: chevrons every 3 m for 45 m
	var path: PackedVector3Array = player.get("route_path") if player.get("route_path") != null else PackedVector3Array()
	if path.size() >= 2:
		var walked := 0.0
		var next_at := 2.0
		for i in range(1, path.size()):
			var a: Vector3 = path[i - 1]
			var b: Vector3 = path[i]
			var seg := a.distance_to(b)
			while next_at <= walked + seg and next_at < 45.0:
				var p: Vector3 = a.lerp(b, (next_at - walked) / maxf(seg, 0.001)) + Vector3(0, 0.15, 0)
				if not cam.is_position_behind(p):
					var sp := cam.unproject_position(p)
					var fwd := cam.unproject_position(p + (b - a).normalized() * 0.6)
					var dir := (fwd - sp).normalized() if fwd != sp else Vector2.UP
					var side := Vector2(-dir.y, dir.x)
					var sz := clampf(160.0 / maxf(eye.distance_to(p), 1.0), 5.0, 26.0)
					var alpha := 1.0 - next_at / 50.0
					draw_polyline(PackedVector2Array([sp - dir * sz + side * sz, sp, sp - dir * sz - side * sz]),
							Color(1.0, 0.85, 0.15, alpha), 3.0, true)
				next_at += 3.0
			walked += seg
			if walked > 45.0:
				break
		var left := 0.0
		for i in range(1, path.size()):
			left += path[i - 1].distance_to(path[i])
		draw_string(f, Vector2(size.x / 2.0 - 160, 96), "→ %s  %d m" % [player.route_name, int(left)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1.0, 0.85, 0.15))
	for pk in main.pickups_root.get_children():
		var kind: String = str(pk.get("kind"))
		if not kind in ["circuit", "core", "lens", "module"] or not pk.get("active"):
			continue
		var p: Vector3 = (pk as Node3D).global_position + Vector3(0, 0.4, 0)
		if eye.distance_to(p) > PART_M or cam.is_position_behind(p):
			continue
		var sp := cam.unproject_position(p)
		draw_colored_polygon(PackedVector2Array([sp + Vector2(0, -8), sp + Vector2(8, 0), sp + Vector2(0, 8), sp + Vector2(-8, 0)]), CYAN)
