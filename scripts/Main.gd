extends Control

var graph: GraphData
var canvas: GraphCanvas
var sim_alpha: float = 1.0
var _worker: Thread = null
var _computing: bool = false
var _puzzle_hint: String = ""

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
	for i in range(graph.nodes.size()):
		var n: GraphData.NodeData = graph.nodes[i]
		n.vel = Vector2.ZERO
		if i >= 2:   # S (nodes[0]) and E (nodes[1]) are fixed anchors — don't jitter them
			n.pos += Vector2(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)) * graph.grid_size
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
	graph.reassign_all_sides()
	graph.resolve_crossings()
	graph.correct_backward_sides()  # flip any remaining backward exits where opposite is free

func _reset_graph() -> void:
	if _computing:
		if _worker != null: _worker.wait_to_finish()
		_worker = null; _computing = false
	graph.nodes.clear(); graph.edges.clear(); graph.node_counter = 0
	canvas.graph = graph   # re-attach in case it was nulled during computation
	canvas.sim_running = false
	sim_alpha = 1.0

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

	# Locks sit at the last intermediate of each path; DL seals p2 at the first step.
	# Keys prefer to live in branch cycles (validate_lock_key now walks branches).
	# If no branch can attach, fall back to a random main-path position before the lock.
	var res1 := [p1_n]
	var res2 := [1, p2_n]

	# Attach a 3-node ring to each path; return cycle nodes for key placement.
	# With MAX_EDGES=3, chain nodes have exactly 1 free edge, so the ring must not
	# close back to the anchor. Instead: anchor→c0, then ring c0→c1→c2→c0.
	# anchor: 2+1=3 edges ✓   c0: 3 edges ✓   c1,c2: 2 edges each ✓
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

# Attach a 3-node ring (c0→c1→c2→c0) to a randomly chosen plain node on the path.
# Returns [c0, c1, c2], or [] if no plain anchor is available.
func _add_path_cycle(path: Array, reserved: Array, y_dir: float) -> Array:
	var plain: Array = []
	for i in range(1, path.size() - 1):
		if not reserved.has(i): plain.append(i)
	if plain.is_empty(): return []

	var anchor := graph.node_by_id(path[plain[randi() % plain.size()]])
	if anchor == null or graph.free_sides(anchor.id).is_empty(): return []

	var gs := float(graph.grid_size)
	var cx_off := float(randi_range(-1, 1)) * gs
	var center := anchor.pos + Vector2(cx_off, y_dir * 2.5 * gs)
	var c: Array = []
	for i in range(3):
		var angle := float(i) / 3.0 * TAU + PI * 0.5
		c.append(graph.add_node(graph.snap_vec(center + Vector2(cos(angle), sin(angle)) * gs * 1.2)))
	graph.add_edge(anchor.id, c[0].id)
	for i in range(3):
		graph.add_edge(c[i].id, c[(i + 1) % 3].id)
	return c

func _set_node_kind(node_id: int, kind: String, label: String) -> void:
	var n := graph.node_by_id(node_id)
	if n != null:
		n.kind = kind
		n.label = label
