extends RefCounted
## Shared reverse-distance tables for buses on one road graph.
## The graph owns the cache: replacing a map releases it, with no static references.
const KEY := "_bus_routes"
const MAX_TARGETS := 32

static func invalidate(graph: Dictionary) -> void:
	graph.erase(KEY)

static func distances(graph: Dictionary, target: int) -> Dictionary:
	var started: int = Time.get_ticks_usec()
	var state: Dictionary = graph.get(KEY, {})
	if state.is_empty() or state["edge_count"] != graph["edges"].size():
		state = _build(graph)
		graph[KEY] = state
	var stats: Dictionary = state["stats"]
	stats["calls"] += 1
	var tables: Dictionary = state["tables"]
	if tables.has(target):
		stats["hits"] += 1
		return tables[target]
	var te: Dictionary = graph["edges"][target]
	var dist := {int(te["a"]): 0.0, int(te["b"]): 0.0}
	var frontier: Array = dist.keys()
	while not frontier.is_empty():
		frontier.sort_custom(func(x, y): return dist[x] < dist[y])
		var n: int = frontier.pop_front()
		for incoming in state["incoming"].get(n, []):
			var from: int = incoming[0]
			var nd: float = dist[n] + incoming[1]
			if nd < dist.get(from, INF):
				dist[from] = nd
				frontier.append(from)
	# Callers only read distances. Prevent accidental mutation of a shared table.
	dist.make_read_only()
	if tables.size() >= MAX_TARGETS:
		tables.erase(tables.keys()[0])              # bounded FIFO; no per-hit list allocation
		stats["evictions"] += 1
	tables[target] = dist
	stats["builds"] += 1
	var elapsed: int = Time.get_ticks_usec() - started
	stats["build_total_us"] += elapsed
	stats["build_max_us"] = maxi(stats["build_max_us"], elapsed)
	return dist

static func _build(graph: Dictionary) -> Dictionary:
	var incoming: Dictionary = {}
	# Preserve the legacy edge order and allowed directions, including its
	# seeding of both target endpoints. Loading/closing tiles invalidates this
	# index; changing which roads routing considers is a separate behaviour change.
	for i in graph["edges"].size():
		var e: Dictionary = graph["edges"][i]
		var a: int = int(e["a"])
		var b: int = int(e["b"])
		var length: float = graph["len"][i]
		incoming.get_or_add(b, []).append([a, length])
		if not e["oneway"]:
			incoming.get_or_add(a, []).append([b, length])
	return {"edge_count": graph["edges"].size(), "incoming": incoming, "tables": {},
		"stats": {"calls": 0, "hits": 0, "builds": 0, "evictions": 0,
			"build_total_us": 0, "build_max_us": 0}}
