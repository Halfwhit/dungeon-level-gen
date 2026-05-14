class_name GraphCanvas
extends Control

var graph: GraphData:
	set(value):
		graph = value
		_paths_valid = false
var _paths_valid: bool = false
var sim_running: bool = false

var zoom: float = 1.0
var pan: Vector2 = Vector2.ZERO
var _panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO
const ZOOM_MIN = 0.15
const ZOOM_MAX = 5.0

const NODE_RADIUS = 22.0
const SQ_SIZE = 44.0

const C_NODE_FILL = Color("EEEDFE")
const C_NODE_STROKE = Color("534AB7")
const C_NODE_TEXT = Color("3C3489")
const C_START_FILL = Color("2E86C1")
const C_START_BORDER = Color("1A5276")
const C_END_FILL = Color("C0392B")
const C_END_BORDER = Color("7B241C")
const C_PATH1 = Color("2E86C1")
const C_PATH2 = Color("C0392B")
const C_EDGE = Color("888780")
const C_OFF_PATH = Color("F5CBA7")
const C_OFF_PATH_BORDER = Color("E59866")
const C_OFF_PATH_TEXT = Color("784212")
const C_KEY_FILL = Color("D7BDE2")
const C_KEY_BORDER = Color("8E44AD")
const C_KEY_TEXT = Color("6C3483")
const C_LOCK_FILL = Color("A9CCE3")
const C_LOCK_BORDER = Color("2471A3")
const C_LOCK_TEXT = Color("1A5276")
const C_FULL_FILL = Color("FAECE7")
const C_FULL_BORDER = Color("D85A30")
const C_GRID = Color(0.53, 0.53, 0.5, 0.25)
const C_DEAD_FILL = Color("1E1E1E")
const C_DEAD_BORDER = Color("CC2222")
const C_DEAD_TEXT = Color("FF8888")
const C_SPECIAL_FILL = Color("FEF9E7")
const C_SPECIAL_BORDER = Color("D4AC0D")
const C_SPECIAL_TEXT = Color("7D6608")

var two_paths: Dictionary = {}
var on_path_set: Dictionary = {}
var edge_path_map: Dictionary = {}
var routed_paths: Array = []

func s2w(p: Vector2) -> Vector2:
	return (p - pan) / zoom

func fit_to_view() -> void:
	if graph == null or graph.nodes.is_empty():
		return
	var mn = graph.nodes[0].pos
	var mx = graph.nodes[0].pos
	for n in graph.nodes:
		mn = mn.min(n.pos)
		mx = mx.max(n.pos)
	var margin = graph.grid_size * 4.0
	mn -= Vector2(margin, margin)
	mx += Vector2(margin, margin)
	var world_sz = mx - mn
	if world_sz.x < 1 or world_sz.y < 1:
		return
	zoom = clampf(min(size.x / world_sz.x, size.y / world_sz.y), ZOOM_MIN, ZOOM_MAX)
	pan = size * 0.5 - (mn + world_sz * 0.5) * zoom
	queue_redraw()

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var wp = s2w(screen_pos)
	zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	pan = screen_pos - wp * zoom
	queue_redraw()

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)

func _process(_delta):
	if sim_running:
		queue_redraw()

func _draw():
	if graph == null:
		var font := ThemeDB.fallback_font
		var msg := "Computing layout…"
		var tw: float = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var th: float = font.get_height(14)
		draw_string(font, size * 0.5 - Vector2(tw * 0.5, -th * 0.3), msg,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.5, 0.5, 0.5, 0.6))
		return
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	_draw_grid()
	if not sim_running and not _paths_valid:
		_compute_paths()
		_paths_valid = true
	_draw_edges()
	_draw_nodes()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_grid():
	var gs = graph.grid_size
	var tl = s2w(Vector2.ZERO)
	var br = s2w(size)
	var dot_r = 1.5 / zoom
	var x = floor(tl.x / gs) * gs
	while x <= br.x:
		var y = floor(tl.y / gs) * gs
		while y <= br.y:
			draw_circle(Vector2(x, y), dot_r, C_GRID)
			y += gs
		x += gs

func _compute_paths():
	routed_paths = graph.build_all_paths()
	var s = graph.start_node()
	var e = graph.end_node()
	two_paths = {}
	on_path_set = {}
	edge_path_map = {}
	if s != null and e != null:
		two_paths = graph.find_two_paths(s.id, e.id)
	if not two_paths.is_empty():
		for id in two_paths.p1: on_path_set[id] = true
		for id in two_paths.p2: on_path_set[id] = true
		_mark_path(two_paths.p1, 1)
		_mark_path(two_paths.p2, 2)

func _mark_path(path: Array, idx: int):
	for i in range(path.size() - 1):
		var u = path[i]
		var v = path[i+1]
		edge_path_map[str(u)+","+str(v)] = idx
		edge_path_map[str(v)+","+str(u)] = idx

func _draw_edges():
	for i in range(graph.edges.size()):
		var e = graph.edges[i]
		var na = graph.node_by_id(e.a)
		var nb = graph.node_by_id(e.b)
		if na == null or nb == null:
			continue
		var pts = routed_paths[i] if i < routed_paths.size() else []
		if pts.is_empty():
			continue
		var key = str(e.a)+","+str(e.b)
		var pi = edge_path_map.get(key, edge_path_map.get(str(e.b)+","+str(e.a), 0))
		var col = C_PATH1 if pi == 1 else (C_PATH2 if pi == 2 else C_EDGE)
		var lw = 3.0 if pi > 0 else 2.0
		_draw_polyline_clamped(pts, col, lw)

func _draw_polyline_clamped(pts: Array, col: Color, lw: float):
	if pts.size() < 2:
		return
	var p0 = pts[0]
	var p1 = pts[1]
	var d0 = (p1 - p0)
	if d0.length() > 0.1:
		p0 = p0 + d0.normalized() * NODE_RADIUS
	var pn = pts[pts.size()-1]
	var pn1 = pts[pts.size()-2]
	var dn = (pn1 - pn)
	if dn.length() > 0.1:
		pn = pn + dn.normalized() * NODE_RADIUS
	var draw_pts = [p0] + pts.slice(1, pts.size()-1) + [pn]
	var deduped = [draw_pts[0]]
	for i in range(1, draw_pts.size()):
		var prev = deduped[deduped.size()-1]
		var cur = draw_pts[i]
		if abs(prev.x - cur.x) > 0.1 or abs(prev.y - cur.y) > 0.1:
			deduped.append(cur)
	if deduped.size() < 2:
		return
	for i in range(deduped.size() - 1):
		draw_line(deduped[i], deduped[i+1], col, lw, true)

func _draw_nodes():
	var s = graph.start_node()
	var e = graph.end_node()
	for n in graph.nodes:
		var is_start = (s != null and n.id == s.id)
		var is_end = (e != null and n.id == e.id)
		var full = graph.is_full(n.id)
		var is_off = not two_paths.is_empty() and not is_start and not is_end \
				and not on_path_set.has(n.id) and n.kind == GraphData.KIND_NORMAL
		var is_key = (n.kind == GraphData.KIND_KEY)
		var is_lock = (n.kind == GraphData.KIND_LOCK)
		var is_dead = (n.kind == GraphData.KIND_DEADLOCK)
		var is_special = (n.kind == GraphData.KIND_SPECIAL)

		if is_key or is_lock or is_dead or is_special:
			_draw_lock_key_node(n, is_key, is_lock, is_dead, is_special)
		else:
			var fill: Color
			var stroke: Color
			var lw = 1.5
			if is_start:
				fill = C_START_FILL
				stroke = C_START_BORDER
				lw = 2.5
			elif is_end:
				fill = C_END_FILL
				stroke = C_END_BORDER
				lw = 2.5
			elif is_off:
				fill = C_OFF_PATH
				stroke = C_OFF_PATH_BORDER
				lw = 2.0
			elif full:
				fill = C_FULL_FILL
				stroke = C_FULL_BORDER
				lw = 1.5
			else:
				fill = C_NODE_FILL
				stroke = C_NODE_STROKE
				lw = 1.5
			draw_circle(n.pos, NODE_RADIUS, fill)
			_draw_circle_outline(n.pos, NODE_RADIUS, stroke, lw)
			var text_col: Color
			if is_start or is_end:
				text_col = Color.WHITE
			elif is_off:
				text_col = C_OFF_PATH_TEXT
			elif full:
				text_col = Color("993C1D")
			else:
				text_col = C_NODE_TEXT
			_draw_label(n.pos, n.label, text_col)

		_draw_ports(n)

func _draw_lock_key_node(n: GraphData.NodeData, is_key: bool, is_lock: bool, is_dead: bool, is_special: bool):
	var fill: Color
	var border: Color
	var lw := 1.5
	if is_dead:
		fill = C_DEAD_FILL
		border = C_DEAD_BORDER
		lw = 2.0
	elif is_special:
		fill = C_SPECIAL_FILL
		border = C_SPECIAL_BORDER
		lw = 2.0
	elif is_key:
		fill = C_KEY_FILL
		border = C_KEY_BORDER
	else:
		fill = C_LOCK_FILL
		border = C_LOCK_BORDER
	var h = SQ_SIZE / 2.0
	var r = Rect2(n.pos - Vector2(h, h), Vector2(SQ_SIZE, SQ_SIZE))
	draw_rect(r, fill)
	_draw_rect_outline(r, border, lw)
	var icon = "🔑" if is_key else ("★" if is_special else "🔒")
	var icon_col = C_SPECIAL_BORDER if is_special else Color.WHITE
	_draw_label(n.pos + Vector2(0, -5), icon, icon_col, 14)
	var text_col: Color
	if is_dead:
		text_col = C_DEAD_TEXT
	elif is_special:
		text_col = C_SPECIAL_TEXT
	elif is_key:
		text_col = C_KEY_TEXT
	else:
		text_col = C_LOCK_TEXT
	_draw_label(n.pos + Vector2(0, 8), n.label, text_col, 9)
	if is_dead:
		var m = h * 0.55
		draw_line(n.pos + Vector2(-m, -m), n.pos + Vector2(m, m), C_DEAD_BORDER, 1.5)
		draw_line(n.pos + Vector2(m, -m), n.pos + Vector2(-m, m), C_DEAD_BORDER, 1.5)

func _draw_ports(n: GraphData.NodeData):
	var used = graph.used_sides(n.id)
	for s in range(4):
		var d = GraphData.SIDE_DIRS[s]
		var pp = n.pos + d * (NODE_RADIUS + 9)
		var col = C_FULL_BORDER if s in used else Color("AFA9EC")
		_draw_label(pp, GraphData.SIDE_NAMES[s], col, 10)

func _draw_label(pos: Vector2, text: String, col: Color, size: int = 12):
	var font = ThemeDB.fallback_font
	var tw = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var th = font.get_height(size)
	draw_string(font, pos + Vector2(-tw/2, th/3), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_circle_outline(center: Vector2, radius: float, col: Color, width: float):
	var pts = 32
	var prev = center + Vector2(radius, 0)
	for i in range(1, pts + 1):
		var a = (float(i) / pts) * TAU
		var cur = center + Vector2(cos(a), sin(a)) * radius
		draw_line(prev, cur, col, width, true)
		prev = cur

func _draw_rect_outline(r: Rect2, col: Color, width: float):
	draw_line(r.position, Vector2(r.end.x, r.position.y), col, width)
	draw_line(Vector2(r.end.x, r.position.y), r.end, col, width)
	draw_line(r.end, Vector2(r.position.x, r.end.y), col, width)
	draw_line(Vector2(r.position.x, r.end.y), r.position, col, width)

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom_at(event.position, 1.15)
				accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at(event.position, 1.0 / 1.15)
				accept_event()
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
				if event.pressed:
					_pan_start = event.position - pan
				accept_event()
	elif event is InputEventMouseMotion:
		if _panning:
			pan = event.position - _pan_start
			queue_redraw()
			accept_event()
