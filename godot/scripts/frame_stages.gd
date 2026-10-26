extends Node
## Opt-in DevAgent timing at existing frame signals. CPU callback intervals,
## not GPU timings: post-draw to next process also includes pacing/physics.
var frames := 0
var over_100ms := 0
var max_ms := 0.0
var slow_frames: Array = []
var _process_us := 0
var _process_frame := 0
var _pre_us := 0
var _post_us := 0
var _pre_frame := 0
var _post_frame := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().process_frame.connect(_begin)
	RenderingServer.frame_pre_draw.connect(_before_draw)
	RenderingServer.frame_post_draw.connect(_after_draw)

func _begin() -> void:
	var now := Time.get_ticks_usec()
	if _process_us > 0:
		frames += 1
		var ms := (now - _process_us) / 1000.0
		max_ms = maxf(max_ms, ms)
		if ms > 100.0: over_100ms += 1
		if ms > 50.0:
			var matched := _pre_frame == _process_frame and _post_frame == _process_frame \
					and _process_us <= _pre_us and _pre_us <= _post_us and _post_us <= now
			slow_frames.append({"frame": _process_frame, "tick_us": now, "frame_ms": ms,
				"matched": matched, "pre_frame": _pre_frame, "post_frame": _post_frame,
				"before_draw_ms": (_pre_us - _process_us) / 1000.0 if matched else -1.0,
				"draw_signal_ms": (_post_us - _pre_us) / 1000.0 if matched else -1.0,
				"after_draw_ms": (now - _post_us) / 1000.0 if matched else -1.0})
			if slow_frames.size() > 400: slow_frames.pop_front()
	_process_us = now
	_process_frame = Engine.get_process_frames()
	_pre_us = 0
	_post_us = 0

func _before_draw() -> void:
	_pre_us = Time.get_ticks_usec()
	_pre_frame = Engine.get_process_frames()

func _after_draw() -> void:
	_post_us = Time.get_ticks_usec()
	_post_frame = Engine.get_process_frames()

func snapshot() -> Dictionary:
	return {"frames": frames, "over_100ms": over_100ms, "max_ms": max_ms,
		"slow_frames": slow_frames.duplicate(true)}
