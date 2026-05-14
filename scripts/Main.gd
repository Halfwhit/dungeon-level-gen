extends Control

var graph: GraphData
var canvas: GraphCanvas
var sim_alpha: float = 1.0
var _worker: Thread = null
var _computing: bool = false
var _puzzle_hint: String = ""
var _p1_ids: Array = []   # node ID sequence for P1 (set before thread launch, read by thread)
var _p2_ids: Array = []   # node ID sequence for P2
var _cycles: Array = []   # [{anchor_id, c_ids:[c0,c1,c2], y_dir}] for post-layout repositioning

@onready var hint_label: Label = $UI/Bottom/HintLabel
@onready var stats_label: Label = $UI/Bottom/StatsLabel
@onready var path_label: RichTextLabel = $UI/Bottom/PathLabel

const _SPINNER := ["◐", "◓", "◑", "◒"]

func _ready() -> void:
	graph = GraphData.new()
	canvas = $UI/CanvasArea/GraphCanvas
	canvas.graph = graph
	$UI/Toolbar/NewPuzzleBtn.pressed.connect(_generate_random_puzzle)
	set_process(true)
	_generate_random_puzzle()

func _process(delta: float) -> void:
	if _computing:
		if _worker != null and not _worker.is_alive():
			_worker.wait_to_finish()
			_worker = null
			_computing = false
			canvas.graph = graph
			canvas.fit_to_view()
			_update_stats()
			hint_label.text = _puzzle_hint
			hint_label.modulate = Color("888780")
		else:
			hint_label.text = "Computing… " + _SPINNER[int(Time.get_ticks_msec() / 150) % 4]
			canvas.queue_redraw()
		return
	if not canvas.sim_running: return
	var max_vel := 0.0
	for _i in range(8):
		max_vel = graph.simulate_step(delta, -1, sim_alpha)
	graph.reassign_all_sides()
	sim_alpha -= 0.004
	if sim_alpha <= 0.0 or (max_vel < 1.0 and sim_alpha < 0.5):
		_stop_sim()
	else:
		canvas.queue_redraw()

func _start_sim() -> void:
	if graph.nodes.size() < 2: return
	sim_alpha = 1.0
	var gs := float(graph.grid_size)
	var s_x: float = graph.nodes[0].pos.x; var e_x: float = graph.nodes[1].pos.x
	for i in range(graph.nodes.size()):
		var n: GraphData.NodeData = graph.nodes[i]
		n.vel = Vector2.ZERO
		if i >= 2:   # S (nodes[0]) and E (nodes[1]) are fixed anchors — don't jitter them
			n.pos += Vector2(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)) * graph.grid_size
			# Clamp x so jitter never places a node outside the S–E corridor.
			n.pos.x = clampf(n.pos.x, s_x + gs, e_x - gs)
			n.pos = graph.snap_vec(n.pos)
	canvas.sim_running = true

func _stop_sim() -> void:
	canvas.sim_running = false
	sim_alpha = 1.0
	canvas.graph = null   # detach canvas so _draw() is safe during background work
	canvas.queue_redraw()
	_computing = true
	_worker = Thread.new()
	_worker.start(_compute_layout_threaded)

func _compute_layout_threaded() -> void:
	graph.snap_all()
	graph.reassign_all_sides()
	graph.resolve_crossings()
	graph.compact_layout()
	graph.fix_stub_positions()      # anchor any remaining degree-1 stubs
	_fix_cycle_positions()          # reposition ring nodes into rectangular arrangement
	graph.compact_layout()          # re-compact after repositioning
	_enforce_path_x_order()         # P1/P2 x-order and y-band enforcement
	_fix_cycle_positions()          # reposition again after path nodes may have shifted
	graph.reassign_all_sides()
	graph.resolve_crossings()
	graph.correct_backward_sides()  # flip any remaining backward exits where opposite is free

# Reposition 3-node ring cycles into a rectangular arrangement that routes without
# orthogonal crossings: c0 directly above/below anchor, c1 to the right of c0,
# c2 directly above/below c0 (one more step further from center than c0).
func _fix_cycle_positions() -> void:
	var gs: float = float(graph.grid_size)
	var e_x: float = graph.nodes[1].pos.x if graph.nodes.size() > 1 else 9999.0
	for entry in _cycles:
		var anchor := graph.node_by_id(entry.anchor_id)
		if anchor == null: continue
		var c0 := graph.node_by_id(entry.c_ids[0])
		var c1 := graph.node_by_id(entry.c_ids[1])
		var c2 := graph.node_by_id(entry.c_ids[2])
		if c0 == null or c1 == null or c2 == null: continue
		var y_dir: float = entry.y_dir
		c0.pos = graph.snap_vec(anchor.pos + Vector2(0.0, y_dir * 2.0 * gs))
		# c1 to the right of c0, clamped within the S–E corridor
		var c1_x: float = clampf(anchor.pos.x + gs, 0.0, e_x - gs)
		c1.pos = graph.snap_vec(Vector2(c1_x, anchor.pos.y + y_dir * 2.0 * gs))
		c2.pos = graph.snap_vec(anchor.pos + Vector2(0.0, y_dir * 3.0 * gs))

# Enforce left-to-right x-ordering for P1/P2 path nodes, and clamp each path's
# y-positions so they stay within ±1 grid step of the path's first node, preventing
# U-shaped dips. Also ensures P1 stays strictly above y=0 and P2 strictly below y=0.
func _enforce_path_x_order() -> void:
	var gs: float = float(graph.grid_size)
	var e_x: float = graph.nodes[1].pos.x if graph.nodes.size() > 1 else 9999.0

	for pi in range(2):
		var path: Array = _p1_ids if pi == 0 else _p2_ids
		var above: bool = (pi == 0)  # P1 must stay above center (y < 0); P2 below (y > 0)

		if path.size() < 2: continue

		# Step 1: clamp every intermediate node to its correct side of center.
		for i in range(1, path.size() - 1):
			var n := graph.node_by_id(path[i])
			if n == null: continue
			if above and n.pos.y > -gs:    n.pos.y = -gs
			elif not above and n.pos.y < gs: n.pos.y = gs

		# Step 2: use the first intermediate node as the y-reference band.
		var ref_node := graph.node_by_id(path[1])
		var ref_y: float = ref_node.pos.y if ref_node != null else (-gs if above else gs)

		# y-band bounds honour the path's required side of y=0.
		var y_lo: float = maxf(ref_y - gs, (-99999.0 if above else gs))
		var y_hi: float = minf(ref_y + gs, (-gs if above else 99999.0))

		for _pass in range(10):
			var changed := false
			for i in range(1, path.size() - 1):
				var n_cur := graph.node_by_id(path[i])
				var n_prev := graph.node_by_id(path[i - 1])
				if n_cur == null or n_prev == null: continue

				# x: must be at least 1 step right of predecessor
				var min_x: float = graph.snap(n_prev.pos.x + gs)
				if n_cur.pos.x < min_x:
					n_cur.pos.x = clampf(min_x, 0.0, e_x - gs)
					changed = true

				# y: clamp within band while honouring the side constraint
				var clamped_y: float = graph.snap(clampf(n_cur.pos.y, y_lo, y_hi))
				if absf(clamped_y - n_cur.pos.y) > 0.1:
					n_cur.pos.y = clamped_y; changed = true

			if not changed: break

func _reset_graph() -> void:
	if _computing:
		if _worker != null: _worker.wait_to_finish()
		_worker = null; _computing = false
	graph.clear_graph()
	canvas.graph = graph   # re-attach in case it was nulled during computation
	canvas.sim_running = false
	sim_alpha = 1.0
	_p1_ids = []; _p2_ids = []; _cycles = []

func _update_stats() -> void:
	stats_label.text = "Nodes: %d   Edges: %d" % [graph.nodes.size(), graph.edges.size()]
	var s := graph.start_node()
	var e := graph.end_node()
	if s == null or e == null:
		path_label.text = ""; return
	var tp := graph.find_two_paths(s.id, e.id)
	if tp.is_empty():
		path_label.bbcode_text = "[color=#C0392B]No two distinct paths from S to E[/color]"; return
	var l1 := _path_label(tp.p1)
	var l2 := _path_label(tp.p2)
	var v := graph.validate_lock_key(tp)
	var rule_txt := ""
	if v.keys > 0 or v.locks > 0 or v.deadlocks > 0:
		var col := "#0F6E56" if v.valid else "#C0392B"
		rule_txt = "   [color=%s]%s[/color]" % [col, v.msg]
	path_label.bbcode_text = "[color=#2E86C1]P1: %s[/color]   [color=#C0392B]P2: %s[/color]%s" % [l1, l2, rule_txt]

func _path_label(path: Array) -> String:
	var parts: Array = []
	for id in path:
		var n := graph.node_by_id(id)
		parts.append(n.label if n else str(id))
	return "→".join(parts)

# ── Puzzle generation ─────────────────────────────────────────────────────────

func _generate_random_puzzle() -> void:
	_reset_graph()

	var p1_n: int = randi_range(3, 5)
	var p2_n: int = p1_n + randi_range(1, 2)
	var gs := float(graph.grid_size)
	# Compact initial spacing — the force sim spreads nodes to their ideal distance.
	var total_w := float(p2_n + 1) * 2.0 * gs
	var v_off := (2 + randi_range(0, 1)) * gs

	# S = nodes[0], E = nodes[1] (convention used by start_node / end_node)
	var s_id := graph.add_node(Vector2(0.0, 0.0), "S").id
	var e_id := graph.add_node(Vector2(total_w, 0.0), "E").id

	var p1 := [s_id]
	for i in range(p1_n):
		var x := (float(i + 1) / float(p1_n + 1)) * total_w
		var y := -v_off + float(randi_range(-1, 1)) * gs
		p1.append(graph.add_node(graph.snap_vec(Vector2(x, y))).id)
	p1.append(e_id)

	var p2 := [s_id]
	# p2[1] = DL: start directly below S so the sim spring keeps it near the start.
	p2.append(graph.add_node(graph.snap_vec(Vector2(0.0, v_off))).id)
	for i in range(1, p2_n):
		var x := (float(i) / float(p2_n)) * total_w
		var y := v_off + float(randi_range(-1, 1)) * gs
		p2.append(graph.add_node(graph.snap_vec(Vector2(x, y))).id)
	p2.append(e_id)

	for i in range(p1.size() - 1): graph.add_edge(p1[i], p1[i + 1])
	for i in range(p2.size() - 1): graph.add_edge(p2[i], p2[i + 1])

	# Store paths so the layout thread can enforce left-to-right x-ordering.
	_p1_ids = p1.duplicate()
	_p2_ids = p2.duplicate()

	# Locks sit at the last intermediate of each path; DL seals p2 at the first step.
	var res1 := [p1_n]
	var res2 := [1, p2_n]

	var cycle_p1 := _add_path_cycle(p1, res1, -1.0)
	var cycle_p2 := _add_path_cycle(p2, res2,  1.0)

	graph.reassign_all_sides()

	_set_node_kind(p1[p1_n],   GraphData.KIND_LOCK,     "L1")
	_set_node_kind(p2[1],      GraphData.KIND_DEADLOCK, "DL")
	_set_node_kind(p2[p2_n],   GraphData.KIND_LOCK,     "L2")

	# K1: branch preferred, main-path fallback.
	if cycle_p1.size() >= 3:
		_set_node_kind(cycle_p1[1].id, GraphData.KIND_KEY, "K1")
	else:
		_set_node_kind(p1[randi_range(1, p1_n - 1)], GraphData.KIND_KEY, "K1")

	# K2: branch preferred, main-path fallback (must be after DL, before L2).
	if cycle_p2.size() >= 3:
		_set_node_kind(cycle_p2[1].id, GraphData.KIND_KEY, "K2")
	else:
		_set_node_kind(p2[randi_range(2, p2_n - 1)], GraphData.KIND_KEY, "K2")

	_puzzle_hint = "P1: branch(K1) → L1   P2: DL → branch(K2) → L2"
	hint_label.text = _puzzle_hint
	hint_label.modulate = Color("888780")
	_start_sim()

# Attach a 3-node ring cycle (anchor→c0, c0→c1, c1→c2, c2→c0) to a plain path node.
# Nodes are positioned in a rectangular arrangement that enables crossing-free
# orthogonal routing: c0 below/above anchor (same x), c1 to the right of c0 (same y),
# c2 below/above c0 (same x, one more step away).
func _add_path_cycle(path: Array, reserved: Array, y_dir: float) -> Array:
	var plain: Array = []
	for i in range(1, path.size() - 1):
		if not reserved.has(i): plain.append(i)
	if plain.is_empty(): return []

	var anchor := graph.node_by_id(path[plain[randi() % plain.size()]])
	if anchor == null or graph.free_sides(anchor.id).is_empty(): return []

	var gs := float(graph.grid_size)
	var c: Array = []
	c.append(graph.add_node(graph.snap_vec(anchor.pos + Vector2(0.0, y_dir * 2.0 * gs))))  # c0
	c.append(graph.add_node(graph.snap_vec(anchor.pos + Vector2(gs, y_dir * 2.0 * gs))))   # c1
	c.append(graph.add_node(graph.snap_vec(anchor.pos + Vector2(0.0, y_dir * 3.0 * gs))))  # c2
	graph.add_edge(anchor.id, c[0].id)
	graph.add_edge(c[0].id, c[1].id)
	graph.add_edge(c[1].id, c[2].id)
	graph.add_edge(c[2].id, c[0].id)
	_cycles.append({"anchor_id": anchor.id, "c_ids": [c[0].id, c[1].id, c[2].id], "y_dir": y_dir})
	return c

func _set_node_kind(node_id: int, kind: String, label: String) -> void:
	var n := graph.node_by_id(node_id)
	if n != null:
		n.kind = kind
		n.label = label
