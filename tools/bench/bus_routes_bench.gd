extends Node
## Isolated bus-routing timings, with full distance-table and choice regression.
## BUS_BENCH_REPORT=<path> godot --headless --path godot res://../tools/bench/bus_routes_bench.tscn
const Car = preload("res://scripts/car.gd")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var report: Dictionary = {"engine": Engine.get_version_info()["string"], "maps": []}
	for id in ["gasometro", "centro", "mercado", "poa"]:
		var graph: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://city/%s.roads.json" % id))
		graph["len"] = []
		graph["out"] = {}
		for i in graph["edges"].size():
			var e: Dictionary = graph["edges"][i]
			var length: float = 0.0
			for j in range(1, e["pts"].size()):
				var a: Array = e["pts"][j - 1]
				var b: Array = e["pts"][j]
				length += Vector2(a[0], a[1]).distance_to(Vector2(b[0], b[1]))
			graph["len"].append(length)
			graph["out"].get_or_add(int(e["a"]), []).append([i, true])
			if not e["oneway"]:
				graph["out"].get_or_add(int(e["b"]), []).append([i, false])
		var car := Car.new()
		car.graph = graph
		var times: Array = []
		var tables: Dictionary = {}
		var legacy_times: Array = []
		var choices: int = 0
		for target in graph["edges"].size():
			var start: int = Time.get_ticks_usec()
			var actual: Dictionary = car._dist_to_edge(target)
			times.append(Time.get_ticks_usec() - start)
			var legacy_start: int = Time.get_ticks_usec()
			var expected: Dictionary = _legacy(graph, target)
			legacy_times.append(Time.get_ticks_usec() - legacy_start)
			assert(actual == expected, "%s target %d distance mismatch" % [id, target])
			for options in graph["out"].values():
				assert(car._cheapest(options, target, actual) == car._cheapest(options, target, expected))
				choices += 1
			tables[target] = actual
		# Repeated requests for a shared stop set, representative of several buses.
		var hot: Array = []
		var legacy_hot: Array = []
		var hot_count: int = mini(16, graph["edges"].size())
		for i in range(160):
			var start: int = Time.get_ticks_usec()
			car._dist_to_edge(i % hot_count)
			hot.append(Time.get_ticks_usec() - start)
			start = Time.get_ticks_usec()
			_legacy(graph, i % hot_count)
			legacy_hot.append(Time.get_ticks_usec() - start)
		report["maps"].append({"map": id, "nodes": graph["nodes"].size(), "edges": graph["edges"].size(),
			"cold_us": _summary(times), "repeated_us": _summary(hot),
			"legacy_cold_us": _summary(legacy_times), "legacy_repeated_us": _summary(legacy_hot), "choices_checked": choices,
			"distance_tables": tables, "diagnostics": graph.get("_bus_routes", {}).get("stats", {})})
		car.free()
	report["cache_regressions"] = _cache_regressions()
	var path: String = OS.get_environment("BUS_BENCH_REPORT")
	if path.is_empty():
		path = "/tmp/bus_routes_bench.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ") + "\n")
	for row in report["maps"]:
		print(row["map"], " cold ", row["cold_us"], " repeated ", row["repeated_us"])
	get_tree().quit()

func _summary(values: Array) -> Dictionary:
	values.sort()
	var total: float = 0.0
	for value in values:
		total += value
	return {"count": values.size(), "median": values[values.size() / 2],
		"p95": values[int((values.size() - 1) * 0.95)], "max": values.back(), "total": total}

## The pre-cache production implementation, retained as an independent oracle.
func _legacy(graph: Dictionary, target: int) -> Dictionary:
	var te: Dictionary = graph["edges"][target]
	var dist := {int(te["a"]): 0.0, int(te["b"]): 0.0}
	var frontier: Array = dist.keys()
	while not frontier.is_empty():
		frontier.sort_custom(func(x, y): return dist[x] < dist[y])
		var n: int = frontier.pop_front()
		for i in graph["edges"].size():
			var e: Dictionary = graph["edges"][i]
			for spec in [[int(e["a"]), int(e["b"]), true], [int(e["b"]), int(e["a"]), false]]:
				if spec[1] != n or (not spec[2] and e["oneway"]):
					continue
				var nd: float = dist[n] + graph["len"][i]
				if nd < dist.get(spec[0], INF):
					dist[spec[0]] = nd
					frontier.append(spec[0])
	return dist

func _cache_regressions() -> Dictionary:
	var routes = Car.BusRoutes
	var g: Dictionary = {"edges": [{"a": 0, "b": 1, "oneway": false},
		{"a": 1, "b": 2, "oneway": true}], "len": [5.0, 7.0]}
	var first: Dictionary = routes.distances(g, 0)
	assert(not first.has(2), "One-way street must remain one-way")
	assert(first.is_read_only(), "Shared tables must be read-only")
	var other_bus := Car.new()
	other_bus.graph = g
	assert(is_same(first, other_bus._dist_to_edge(0)), "Buses must share the table")
	other_bus.free()
	g["edges"][1]["oneway"] = false
	routes.invalidate(g)
	assert(routes.distances(g, 0)[2] == 7.0, "Direction edits must invalidate")
	g["len"][1] = 70.0
	routes.invalidate(g)
	assert(routes.distances(g, 0)[2] == 70.0, "Cost edits must invalidate")
	g["edges"].append({"a": 2, "b": 3, "oneway": false})
	g["len"].append(9.0)
	assert(routes.distances(g, 0)[3] == 79.0, "Appended streets must rebuild the index")
	var separate: Dictionary = {"edges": [{"a": 0, "b": 1, "oneway": false}], "len": [5.0]}
	assert(not routes.distances(separate, 0).has(3), "Map caches must remain isolated")
	# Exercise the actual streaming hooks with an already-known tile's ways.
	var world = preload("res://scripts/open_world.gd").new()
	var host := FakeMain.new()
	host.road_graph = g
	g["nodes"] = [[0.0, 0.0], [5.0, 0.0], [75.0, 0.0], [84.0, 0.0]]   # the hooks also work out the entries
	g["out"] = {0: [[0, true]]}
	world.main = host
	var tile: Dictionary = {"ways": [[0, [0, true]]]}
	world._streets_out(tile)
	assert(not g.has(routes.KEY), "Closing a tile must invalidate")
	routes.distances(g, 0)
	world._streets_in("fixture", tile)
	assert(not g.has(routes.KEY), "Reopening a tile must invalidate")
	world.free()
	host.free()
	# More target edges than the cap: all results remain correct and memory is bounded.
	var large: Dictionary = {"edges": [], "len": []}
	for i in 40:
		large["edges"].append({"a": i, "b": i + 1, "oneway": false})
		large["len"].append(1.0)
	for i in 40:
		assert(routes.distances(large, i) == _legacy(large, i))
	assert(large[routes.KEY]["tables"].size() == routes.MAX_TARGETS)
	return {"shared_read_only_tables": true, "direction_and_cost_edits": true,
		"appended_edges": true, "map_isolation": true, "tile_close_reopen": true,
		"bounded_fifo": true}

class FakeMain:
	extends Node
	var road_graph: Dictionary

	func in_bounds(_p: Vector3, _margin := 0.0) -> bool:
		return true
