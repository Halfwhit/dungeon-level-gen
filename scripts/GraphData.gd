class_name GraphData
extends RefCounted

# Node kinds
const KIND_NORMAL = ""
const KIND_KEY = "key"
const KIND_LOCK = "lock"
const KIND_DEADLOCK = "deadlock"  # lock with no key — intentional barrier
const KIND_SPECIAL  = "special"   # special room / point of interest

# Cardinal sides: 0=top 1=right 2=bottom 3=left
const SIDE_DIRS = [Vector2(0,-1), Vector2(1,0), Vector2(0,1), Vector2(-1,0)]
const SIDE_NAMES = ["↑","→","↓","←"]
const MAX_SIDES = 4
const MAX_EDGES = 3  # maximum connections per node

var grid_size: int = 60
var nodes: Array = []   # Array of NodeData
var edges: Array = []   # Array of EdgeData
var node_counter: int = 0
var _node_map: Dictionary = {}   # Must stay in sync via add_node/remove_node/clear_graph only.

# ── Node ──────────────────────────────────────────────────────────────────────
class NodeData:
	var id: int
	var pos: Vector2   # always snapped to grid
	var label: String
	var kind: String   # "", "key", "lock"
	var vel: Vector2   # for force sim

	func _init(p_id: int, p_pos: Vector2, p_label: String, p_kind: String = ""):
		id = p_id
		pos = p_pos
		label = p_label
		kind = p_kind
		vel = Vector2.ZERO

# ── Edge ──────────────────────────────────────────────────────────────────────
class EdgeData:
	var id: int
	var a: int   # node id
	var b: int   # node id
	var side_a: int  # 0-3
	var side_b: int  # 0-3

	func _init(p_id: int, p_a: int, p_b: int, p_sa: int = 1, p_sb: int = 3):
		id = p_id
		a = p_a
		b = p_b
		side_a = p_sa
		side_b = p_sb

# ── Helpers ───────────────────────────────────────────────────────────────────
func snap(v: float) -> float:
	return round(v / grid_size) * grid_size

func snap_vec(v: Vector2) -> Vector2:
	return Vector2(snap(v.x), snap(v.y))

func is_vert_side(s: int) -> bool:
	return s == 0 or s == 2

# horiz=true: horizontal segment (fixed y, range over x); horiz=false: vertical (fixed x, range over y).
func _node_on_seg(r1: float, r2: float, fixed: float, horiz: bool, skip_a: int, skip_b: int) -> bool:
	var sf: float = snap(fixed)
	var lo: float = minf(r1, r2)
	var hi: float = maxf(r1, r2)
	for n in nodes:
		if n.id == skip_a or n.id == skip_b:
			continue
		if horiz:
			if snap(n.pos.y) == sf and n.pos.x > lo and n.pos.x < hi:
				return true
		else:
			if snap(n.pos.x) == sf and n.pos.y > lo and n.pos.y < hi:
				return true
	return false

# Check whether an existing routed segment overlaps this proposed segment.
# segs layout: {snapped_coord: [[lo, hi], ...]} where coord is y for h, x for v.
func _seg_overlaps(coord: float, a1: float, a2: float, segs: Dictionary) -> bool:
	var sc: float = snap(coord)
	if not segs.has(sc):
		return false
	var lo: float = minf(a1, a2)
	var hi: float = maxf(a1, a2)
	for seg in segs[sc]:
		if seg[0] < hi and seg[1] > lo:
			return true
	return false

func _mark_seg(coord: float, a1: float, a2: float, segs: Dictionary) -> void:
	var sc: float = snap(coord)
	if not segs.has(sc):
		segs[sc] = []
	segs[sc].append([snap(minf(a1, a2)), snap(maxf(a1, a2))])

# Returns true if the proposed segment (fixed coord, range r1→r2) crosses any segment
# recorded in perp_segs (the perpendicular-axis dictionary: h_edge for V→H, v_edge for H→V).
func _seg_crosses_perp(fixed: float, r1: float, r2: float, perp_segs: Dictionary) -> bool:
	var sf: float = snap(fixed)
	var lo: float = minf(r1, r2)
	var hi: float = maxf(r1, r2)
	for key in perp_segs:
		if key <= lo or key >= hi:
			continue
		for seg in perp_segs[key]:
			if seg[0] < sf and sf < seg[1]:
				return true
	return false

# Returns true if the point (px, py) lies on (or touches the endpoint of) any
# already-recorded segment. Used to keep turning-point coordinates unique.
func _point_on_seg(px: float, py: float, h_edge: Dictionary, v_edge: Dictionary) -> bool:
	var sx: float = snap(px)
	var sy: float = snap(py)
	if h_edge.has(sy):
		for seg in h_edge[sy]:
			if seg[0] <= sx and sx <= seg[1]:
				return true
	if v_edge.has(sx):
		for seg in v_edge[sx]:
			if seg[0] <= sy and sy <= seg[1]:
				return true
	return false

func node_by_id(id: int) -> NodeData:
	return _node_map.get(id, null)

func has_edge(a: int, b: int) -> bool:
	for e in edges:
		if (e.a == a and e.b == b) or (e.a == b and e.b == a):
			return true
	return false

func start_node() -> NodeData:
	return nodes[0] if nodes.size() > 0 else null

func end_node() -> NodeData:
	return nodes[1] if nodes.size() > 1 else null

func used_sides(node_id: int) -> Array:
	var used = []
	for e in edges:
		if e.a == node_id:
			used.append(e.side_a)
		if e.b == node_id:
			used.append(e.side_b)
	return used

func free_sides(node_id: int) -> Array:
	var used = used_sides(node_id)
	if used.size() >= MAX_EDGES:
		return []
	var free = []
	for s in range(MAX_SIDES):
		if not s in used:
			free.append(s)
	return free

func is_full(node_id: int) -> bool:
	return free_sides(node_id).is_empty()


func pick_sides_for_new(na: NodeData, nb: NodeData) -> Dictionary:
	var fa = free_sides(na.id)
	var fb = free_sides(nb.id)
	if fa.is_empty() or fb.is_empty():
		return {}
	var dx = nb.pos.x - na.pos.x
	var dy = nb.pos.y - na.pos.y
	var dist = Vector2(dx, dy).length()
	if dist < 0.01:
		dist = 1.0
	var best_sa = fa[0]
	var best_sb = fb[0]
	var best_score = -INF
	for sa in fa:
		for sb in fb:
			var da = SIDE_DIRS[sa]
			var db = SIDE_DIRS[sb]
			var score = (da.x*dx + da.y*dy)/dist + (-db.x*dx - db.y*dy)/dist
			if score > best_score:
				best_score = score
				best_sa = sa
				best_sb = sb
	return {"side_a": best_sa, "side_b": best_sb}

func best_side_for(na: NodeData, nb: NodeData, used: Array) -> int:
	var dx = nb.pos.x - na.pos.x
	var dy = nb.pos.y - na.pos.y
	var dist = Vector2(dx, dy).length()
	if dist < 0.01:
		dist = 1.0
	var best = -1
	var best_score = -INF
	for s in range(MAX_SIDES):
		if s in used:
			continue
		var d = SIDE_DIRS[s]
		var score = (d.x*dx + d.y*dy)/dist
		if score > best_score:
			best_score = score
			best = s
	return best

func reassign_all_sides() -> void:
	# A global sort fails: two edges at the same node can both be cardinal and
	# whichever arrives first steals the side, forcing the other to exit backward.
	# Per-node processing ensures each node independently assigns its most
	# direction-sensitive edge first.
	for n in nodes:
		var n_edges: Array = edges.filter(func(e): return e.a == n.id or e.b == n.id)
		if n_edges.is_empty():
			continue

		n_edges.sort_custom(func(ea, eb):
			var oa := node_by_id(ea.b if ea.a == n.id else ea.a)
			var ob := node_by_id(eb.b if eb.a == n.id else eb.a)
			if oa == null:
				return false
			if ob == null:
				return true
			var da: Vector2 = (oa.pos - n.pos).normalized()
			var db: Vector2 = (ob.pos - n.pos).normalized()
			return max(abs(da.x), abs(da.y)) > max(abs(db.x), abs(db.y))
		)

		var used: Array = []
		for e in n_edges:
			var other := node_by_id(e.b if e.a == n.id else e.a)
			if other == null:
				continue
			var s := best_side_for(n, other, used)
			if s < 0:
				continue
			if e.a == n.id:
				e.side_a = s
			else:
				e.side_b = s
			used.append(s)

# One-shot pass after layout: if an assigned side faces away from its neighbour
# and the opposite side is free, flip it so port indicators match the actual exit direction.
func correct_backward_sides() -> void:
	for e in edges:
		var na := node_by_id(e.a)
		var nb := node_by_id(e.b)
		if na == null or nb == null:
			continue
		var ab: Vector2 = (nb.pos - na.pos).normalized()
		if SIDE_DIRS[e.side_a].dot(ab) < -0.1:
			var opp_a: int = (e.side_a + 2) % 4
			if not _sides_used_except(e.a, e.id).has(opp_a):
				e.side_a = opp_a
		if SIDE_DIRS[e.side_b].dot(-ab) < -0.1:
			var opp_b: int = (e.side_b + 2) % 4
			if not _sides_used_except(e.b, e.id).has(opp_b):
				e.side_b = opp_b

func snap_all() -> void:
	for n in nodes:
		n.pos = snap_vec(n.pos)

# ── Path finding ──────────────────────────────────────────────────────────────
func bfs_path(adj_fn: Callable, start_id: int, end_id: int) -> Array:
	if start_id == end_id:
		return [start_id]
	var prev = {}
	var queue = [start_id]
	var visited = {start_id: true}
	while not queue.is_empty():
		var u = queue.pop_front()
		if u == end_id:
			break
		for v in adj_fn.call(u):
			if not visited.has(v):
				visited[v] = true
				prev[v] = u
				queue.append(v)
	if not prev.has(end_id):
		return []
	var path = []
	var cur = end_id
	while prev.has(cur):
		path.push_front(cur)
		cur = prev[cur]
	path.push_front(start_id)
	return path if path[0] == start_id else []

func find_two_paths(start_id: int, end_id: int) -> Dictionary:
	if start_id == end_id or start_id < 0 or end_id < 0:
		return {}
	# Build adjacency
	var adj = {}
	for n in nodes:
		adj[n.id] = []
	for i in range(edges.size()):
		var e = edges[i]
		adj[e.a].append({"v": e.b, "i": i})
		adj[e.b].append({"v": e.a, "i": i})

	var p1 = bfs_path(func(u): return adj[u].map(func(x): return x.v), start_id, end_id)
	if p1.is_empty():
		return {}

	# Remove p1 edges
	var used_edge_keys = {}
	for i in range(p1.size() - 1):
		var u = p1[i]
		var v = p1[i+1]
		for entry in adj[u]:
			var key = str(u) + "," + str(v) + "_" + str(entry.i)
			if not used_edge_keys.has(key) and entry.v == v:
				used_edge_keys[key] = true
				break

	var adj_rem = {}
	for n in nodes:
		adj_rem[n.id] = []
	for i in range(edges.size()):
		var e = edges[i]
		var k1 = str(e.a)+","+str(e.b)+"_"+str(i)
		var k2 = str(e.b)+","+str(e.a)+"_"+str(i)
		if not used_edge_keys.has(k1) and not used_edge_keys.has(k2):
			adj_rem[e.a].append(e.b)
			adj_rem[e.b].append(e.a)

	# P2 is returned E→S (reversed) so that the two paths travel in opposite directions.
	var p2 = bfs_path(func(u): return adj_rem[u], start_id, end_id)
	if not p2.is_empty():
		p2.reverse()   # convert S→E result to E→S
		return {"p1": p1, "p2": p2}

	# Node-disjoint fallback
	var forbidden = {}
	for i in range(1, p1.size() - 1):
		forbidden[p1[i]] = true
	var adj_full = {}
	for n in nodes:
		adj_full[n.id] = []
	for e in edges:
		adj_full[e.a].append(e.b)
		adj_full[e.b].append(e.a)
	var p2b = bfs_path(func(u): return adj_full[u].filter(func(v): return not forbidden.has(v)), start_id, end_id)
	if not p2b.is_empty():
		p2b.reverse()   # convert S→E result to E→S
		return {"p1": p1, "p2": p2b}

	return {}

# ── Lock/Key validation ───────────────────────────────────────────────────────

# Build a kind sequence for one path that also includes branch-node kinds
# immediately after each anchor. Branch nodes are all nodes reachable from
# a path node without crossing any other main-path node. This lets keys
# stored in side-branches count as collected before the lock that follows
# their anchor on the main path.
func _path_with_branch_kinds(path: Array, all_path_ids: Dictionary) -> Array:
	var result: Array = []
	var visited: Dictionary = all_path_ids.duplicate()
	for node_id in path:
		var n = node_by_id(node_id)
		result.append(n.kind if n else "")
		var queue: Array = [node_id]
		while not queue.is_empty():
			var cur: int = queue.pop_front()
			for e in edges:
				var nb_id: int = -1
				if e.a == cur:
					nb_id = e.b
				elif e.b == cur:
					nb_id = e.a
				if nb_id < 0 or visited.has(nb_id):
					continue
				visited[nb_id] = true
				var nb = node_by_id(nb_id)
				if nb:
					result.append(nb.kind)
				queue.append(nb_id)
	return result

func validate_lock_key(two_paths: Dictionary) -> Dictionary:
	if two_paths.is_empty():
		return {"valid": true, "msg": "", "keys": 0, "locks": 0, "deadlocks": 0}

	var all_path_ids: Dictionary = {}
	for id in two_paths.p1:
		all_path_ids[id] = true
	for id in two_paths.p2:
		all_path_ids[id] = true
	# p2 is stored E→S (travel direction), so use it directly — branch(K2) precedes L2.
	var k1_raw = _path_with_branch_kinds(two_paths.p1, all_path_ids)
	var k2_raw = _path_with_branch_kinds(two_paths.p2, all_path_ids)
	var total_deadlocks = (k1_raw + k2_raw).filter(func(k): return k == KIND_DEADLOCK).size()
	# Replace deadlocks with empty so they don't affect key/lock balance.
	var k1 = k1_raw.map(func(k): return "" if k == KIND_DEADLOCK else k)
	var k2 = k2_raw.map(func(k): return "" if k == KIND_DEADLOCK else k)
	var all_kinds = k1 + k2
	var total_keys = all_kinds.filter(func(k): return k == KIND_KEY).size()
	var total_locks = all_kinds.filter(func(k): return k == KIND_LOCK).size()
	var dl_note = "   +%d keyless gate(s)" % total_deadlocks if total_deadlocks > 0 else ""

	if total_keys == 0 and total_locks == 0:
		return {"valid": true, "msg": dl_note.strip_edges(), "keys": 0, "locks": 0, "deadlocks": total_deadlocks}

	var max_len: int = max(k1.size(), k2.size())
	var bank = 0
	var deficit = false
	for i in range(max_len):
		if i < k1.size() and k1[i] == KIND_KEY:
			bank += 1
		if i < k2.size() and k2[i] == KIND_KEY:
			bank += 1
		if i < k1.size() and k1[i] == KIND_LOCK:
			if bank > 0:
				bank -= 1
			else:
				deficit = true
				break
		if i < k2.size() and k2[i] == KIND_LOCK:
			if bank > 0:
				bank -= 1
			else:
				deficit = true
				break

	if deficit:
		return {"valid": false, "msg": "Lock reached before enough keys collected" + dl_note, "keys": total_keys, "locks": total_locks, "deadlocks": total_deadlocks}
	if total_keys != total_locks:
		return {"valid": false, "msg": str(total_keys)+" key(s) but "+str(total_locks)+" lock(s) — must match" + dl_note, "keys": total_keys, "locks": total_locks, "deadlocks": total_deadlocks}

	return {"valid": true, "msg": str(total_keys)+" key(s) unlock "+str(total_locks)+" lock(s)" + dl_note, "keys": total_keys, "locks": total_locks, "deadlocks": total_deadlocks}

# ── Routing ───────────────────────────────────────────────────────────────────
func route_edge(e: EdgeData, h_occ: Dictionary, v_occ: Dictionary, h_edge: Dictionary, v_edge: Dictionary) -> Array:
	var na = node_by_id(e.a)
	var nb = node_by_id(e.b)
	if na == null or nb == null or na.id == nb.id:
		return []
	var ax: float = na.pos.x
	var ay: float = na.pos.y
	var bx: float = nb.pos.x
	var by: float = nb.pos.y
	# Route directly from node centre to node centre — no stubs.
	# _draw_polyline_clamped trims NODE_RADIUS from each end so the line
	# always starts and ends cleanly at the node boundary regardless of
	# which direction the first/last segment runs.
	var a_vert: bool = is_vert_side(e.side_a)
	var b_vert: bool = is_vert_side(e.side_b)
	# dir_y/dir_x: nudge toward B so detours never U-turn away from the destination.
	var dir_y := signf(by - ay) if absf(by - ay) > 0.1 else 1.0
	var dir_x := signf(bx - ax) if absf(bx - ax) > 0.1 else 1.0
	var pts: Array = []

	if a_vert and b_vert:
		# Both exits vertical → Z-shape: V then H then V.
		if absf(ax - bx) < 0.1:
			# Two nodes in the same column: offset through a free adjacent column.
			if _seg_overlaps(ax, ay, by, v_edge):
				var off := find_free_lane(ax, v_edge, v_edge, float(grid_size), 0)
				pts = [Vector2(ax, ay), Vector2(off, ay), Vector2(off, by), Vector2(bx, by)]
			else:
				pts = [Vector2(ax, ay), Vector2(bx, by)]
		else:
			var mid_y: float = snap((ay + by) / 2.0)
			# node/corner checks trigger the initial lane move; seg checks drive the nudge loop.
			var _bv_seg := func(my: float) -> bool:
				return _seg_overlaps(my, ax, bx, h_edge) or _seg_crosses_perp(my, ax, bx, v_edge)
			if _node_on_seg(ax, bx, mid_y, true, e.a, e.b) \
					or _point_on_seg(ax, mid_y, h_edge, v_edge) or _bv_seg.call(mid_y):
				mid_y = find_free_lane(mid_y, h_edge, h_edge, float(grid_size), int(dir_y))
				var _t := 0
				while _t < 8 and _bv_seg.call(mid_y):
					mid_y += float(grid_size) * dir_y
					_t += 1
			pts = [Vector2(ax, ay), Vector2(ax, mid_y), Vector2(bx, mid_y), Vector2(bx, by)]

	elif not a_vert and not b_vert:
		# Both exits horizontal → Z-shape: H then V then H.
		if absf(ay - by) < 0.1:
			# Two nodes in the same row: offset through a free adjacent row.
			if _seg_overlaps(ay, ax, bx, h_edge):
				var off := find_free_lane(ay, h_edge, h_edge, float(grid_size), 0)
				pts = [Vector2(ax, ay), Vector2(ax, off), Vector2(bx, off), Vector2(bx, by)]
			else:
				pts = [Vector2(ax, ay), Vector2(bx, by)]
		else:
			var mid_x: float = snap((ax + bx) / 2.0)
			# node/corner checks trigger the initial lane move; seg checks drive the nudge loop.
			var _bh_seg := func(mx: float) -> bool:
				return _seg_overlaps(mx, ay, by, v_edge) or _seg_crosses_perp(mx, ay, by, h_edge)
			if _node_on_seg(ay, by, mid_x, false, e.a, e.b) \
					or _point_on_seg(mid_x, ay, h_edge, v_edge) or _bh_seg.call(mid_x):
				mid_x = find_free_lane(mid_x, v_edge, v_edge, float(grid_size), int(dir_x))
				var _t := 0
				while _t < 8 and _bh_seg.call(mid_x):
					mid_x += float(grid_size) * dir_x
					_t += 1
			pts = [Vector2(ax, ay), Vector2(mid_x, ay), Vector2(mid_x, by), Vector2(bx, by)]

	elif a_vert:
		# A exits vertically, B exits horizontally → L/Z-shape.
		var safe_y: float = by
		# node/corner checks trigger the initial lane move; seg checks drive the nudge loop.
		var _av_seg := func(sy: float) -> bool:
			return _seg_overlaps(sy, ax, bx, h_edge) or _seg_crosses_perp(sy, ax, bx, v_edge)
		if _node_on_seg(ax, bx, safe_y, true, e.a, e.b) \
				or _point_on_seg(ax, safe_y, h_edge, v_edge) or _av_seg.call(safe_y):
			safe_y = find_free_lane(by, h_edge, h_edge, float(grid_size), int(dir_y))
			var _t := 0
			while _t < 8 and _av_seg.call(safe_y):
				safe_y += float(grid_size) * dir_y
				_t += 1
		if absf(safe_y - by) < 0.1:
			pts = [Vector2(ax, ay), Vector2(ax, by), Vector2(bx, by)]
		else:
			pts = [Vector2(ax, ay), Vector2(ax, safe_y), Vector2(bx, safe_y), Vector2(bx, by)]

	else:
		# A exits horizontally, B exits vertically → L/Z-shape.
		var safe_x: float = bx
		# node/corner checks trigger the initial lane move; seg checks drive the nudge loop.
		var _ah_seg := func(sx: float) -> bool:
			return _seg_overlaps(sx, ay, by, v_edge) or _seg_crosses_perp(sx, ay, by, h_edge)
		if _node_on_seg(ay, by, safe_x, false, e.a, e.b) \
				or _point_on_seg(safe_x, ay, h_edge, v_edge) or _ah_seg.call(safe_x):
			# Detour toward ax (backward), not past bx, to stay within the graph bounds.
			safe_x = find_free_lane(bx, v_edge, v_edge, float(grid_size), -int(dir_x))
			var _t := 0
			while _t < 8 and _ah_seg.call(safe_x):
				safe_x -= float(grid_size) * dir_x
				_t += 1
		if absf(safe_x - bx) < 0.1:
			pts = [Vector2(ax, ay), Vector2(bx, ay), Vector2(bx, by)]
		else:
			pts = [Vector2(ax, ay), Vector2(safe_x, ay), Vector2(safe_x, by), Vector2(bx, by)]

	# Corridor clamp: if the route goes left of S or right of E, fall back to a simple
	# L-shape. The L-shape may still cross; resolve_crossings handles that via side reassignment.
	if nodes.size() >= 2:
		var s_bound: float = nodes[0].pos.x          # no route point may go left of S
		var e_bound: float = nodes[1].pos.x + float(grid_size)  # allow 1 step past E
		for p in pts:
			if p.x < s_bound or p.x > e_bound:
				# Try V-H first (exit A vertically), then H-V as fallback.
				if absf(ax - bx) > 0.1 and absf(ay - by) > 0.1:
					pts = [Vector2(ax, ay), Vector2(ax, by), Vector2(bx, by)]
				else:
					pts = [Vector2(ax, ay), Vector2(bx, by)]
				break

	# Snap all points and drop consecutive duplicates (handles degenerate cases).
	var result: Array = []
	for p in pts:
		var sp := Vector2(snap(p.x), snap(p.y))
		if result.is_empty() or result[result.size() - 1].distance_to(sp) > 0.1:
			result.append(sp)
	if result.size() < 2:
		return []

	# Mark the exact segments used so later edges avoid overlapping them.
	for i in range(result.size() - 1):
		var p1: Vector2 = result[i]
		var p2: Vector2 = result[i + 1]
		if abs(p1.y - p2.y) < 0.1:
			_mark_seg(p1.y, p1.x, p2.x, h_edge)
		elif abs(p1.x - p2.x) < 0.1:
			_mark_seg(p1.x, p1.y, p2.y, v_edge)
	return result

# pref_dir: 0=bidirectional, -1=only negative offset (up/left), 1=only positive (down/right)
func find_free_lane(base: float, occ1: Dictionary, occ2: Dictionary, min_gap: float, pref_dir: int = 0) -> float:
	var d = min_gap
	while d <= 2000:
		if pref_dir >= 0 and not occ1.has(base + d) and not occ2.has(base + d):
			return base + d
		if pref_dir <= 0 and not occ1.has(base - d) and not occ2.has(base - d):
			return base - d
		d += grid_size
	return base + (1 if pref_dir >= 0 else -1) * min_gap

func build_all_paths() -> Array:
	var h_occ = {}
	var v_occ = {}
	for n in nodes:
		h_occ[snap(n.pos.y)] = true
		v_occ[snap(n.pos.x)] = true
	var h_edge = {}
	var v_edge = {}
	var result = []
	for e in edges:
		result.append(route_edge(e, h_occ, v_occ, h_edge, v_edge))
	return result

# ── Intersection check ────────────────────────────────────────────────────────
func segs_cross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 = p2 - p1
	var d2 = p4 - p3
	var den = d1.x*d2.y - d1.y*d2.x
	if abs(den) < 1e-9:
		return false
	var t = ((p3.x-p1.x)*d2.y - (p3.y-p1.y)*d2.x) / den
	var u = ((p3.x-p1.x)*d1.y - (p3.y-p1.y)*d1.x) / den
	return t > 0.05 and t < 0.95 and u > 0.05 and u < 0.95

func paths_cross(pts1: Array, pts2: Array) -> bool:
	for i in range(pts1.size() - 1):
		for j in range(pts2.size() - 1):
			if segs_cross(pts1[i], pts1[i+1], pts2[j], pts2[j+1]):
				return true
	return false

# ── Node creation ─────────────────────────────────────────────────────────────
func next_id() -> int:
	node_counter += 1
	return node_counter

func add_node(pos: Vector2, label: String = "", kind: String = "") -> NodeData:
	var id = next_id()
	if label == "":
		label = "n" + str(id)
	var n = NodeData.new(id, snap_vec(pos), label, kind)
	nodes.append(n)
	_node_map[n.id] = n
	return n

func add_edge(a: int, b: int) -> EdgeData:
	var na = node_by_id(a)
	var nb = node_by_id(b)
	if na == null or nb == null:
		return null
	var sides = pick_sides_for_new(na, nb)
	if sides.is_empty():
		return null
	var e = EdgeData.new(next_id(), a, b, sides.side_a, sides.side_b)
	edges.append(e)
	return e

func remove_node(id: int) -> void:
	_node_map.erase(id)
	nodes = nodes.filter(func(n): return n.id != id)
	edges = edges.filter(func(e): return e.a != id and e.b != id)

func remove_edge(id: int) -> void:
	edges = edges.filter(func(e): return e.id != id)

func clear_graph() -> void:
	nodes.clear()
	edges.clear()
	_node_map.clear()
	node_counter = 0

# ── Layout compaction ─────────────────────────────────────────────────────────
# Pure proximity compaction: squeezes nodes toward the centroid one grid step
# at a time, accepted only when every other node stays ≥ MIN_SEP apart.
# Crossings are repaired by resolve_crossings() before and after this call.
func compact_layout() -> void:
	if nodes.size() < 2:
		return
	const MIN_SEP = 1.5
	const MAX_ITERS = 200  # safety cap
	var min_px: float = MIN_SEP * float(grid_size)
	var gs: float = float(grid_size)

	# Pure proximity compaction — no routing or crossing checks here.
	# Crossings are fixed by resolve_crossings() before and after this call.
	for _iter in range(MAX_ITERS):
		var centroid := Vector2.ZERO
		for n in nodes: centroid += n.pos
		centroid /= float(nodes.size())

		var order: Array = []
		for i in range(nodes.size()): order.append(i)
		order.sort_custom(func(a: int, b: int) -> bool:
			return nodes[a].pos.distance_squared_to(centroid) > nodes[b].pos.distance_squared_to(centroid))

		var moved := false
		for idx in order:
			if idx < 2:
				continue  # S/E are fixed anchors
			var n: NodeData = nodes[idx]
			var to_center: Vector2 = centroid - n.pos
			if to_center.length() < gs * 0.5:
				continue

			var steps: Array = []
			if abs(to_center.x) > 1.0:
				steps.append(Vector2(signf(to_center.x) * gs, 0.0))
			if abs(to_center.y) > 1.0:
				steps.append(Vector2(0.0, signf(to_center.y) * gs))
			if steps.is_empty():
				continue
			steps.sort_custom(func(a: Vector2, b: Vector2) -> bool:
				return (n.pos + a).distance_squared_to(centroid) < (n.pos + b).distance_squared_to(centroid))

			var old_pos: Vector2 = n.pos
			for step: Vector2 in steps:
				var new_pos: Vector2 = old_pos + step
				# Enforce S–E x-corridor: no non-anchor node may be compacted past either anchor.
				if new_pos.x < nodes[0].pos.x + min_px or new_pos.x > nodes[1].pos.x - min_px:
					continue
				var ok := true
				for other: NodeData in nodes:
					if other.id == n.id:
						continue
					if new_pos.distance_to(other.pos) < min_px:
						ok = false
						break
				if ok:
					n.pos = new_pos
					moved = true
					break

		if not moved:
			break  # fully packed — nothing left to move

# After compact_layout, reposition 2-node stubs (anchor→c0→c1) so they hang straight
# above or below their anchor regardless of where the force sim placed them.
# y_dir is inferred from whether the anchor is above or below the node centroid.
func fix_stub_positions() -> void:
	if nodes.size() < 3:
		return
	var gs := float(grid_size)
	var centroid_y := 0.0
	for n in nodes: centroid_y += n.pos.y
	centroid_y /= float(nodes.size())

	var degree: Dictionary = {}
	for n in nodes: degree[n.id] = 0
	for e in edges:
		degree[e.a] += 1
		degree[e.b] += 1

	for leaf in nodes:
		if leaf.id == nodes[0].id or leaf.id == nodes[1].id:
			continue
		if degree[leaf.id] != 1:
			continue  # must be a dead-end (c1)

		# Find c0 (leaf's only neighbour)
		var c0: NodeData = null
		for e in edges:
			if e.a == leaf.id:
				c0 = node_by_id(e.b)
				break
			if e.b == leaf.id:
				c0 = node_by_id(e.a)
				break
		if c0 == null or degree[c0.id] != 2:
			continue

		# Find the anchor (c0's other neighbour, not the leaf)
		var anchor: NodeData = null
		for e in edges:
			var other_id := -1
			if e.a == c0.id:
				other_id = e.b
			elif e.b == c0.id:
				other_id = e.a
			if other_id >= 0 and other_id != leaf.id:
				anchor = node_by_id(other_id)
				break
		if anchor == null:
			continue

		var y_dir: float = -1.0 if anchor.pos.y < centroid_y else 1.0
		c0.pos = snap_vec(anchor.pos + Vector2(0.0, y_dir * 2.0 * gs))
		leaf.pos = snap_vec(anchor.pos + Vector2(0.0, y_dir * 3.0 * gs))

# Route all edges except e once, then for each valid side combination re-route
# only e and check it against the cached other-edge paths. Far cheaper than
# rebuilding all paths for every combination.
func _try_alternative_sides(e: EdgeData) -> bool:
	var used_a: Array = _sides_used_except(e.a, e.id)
	var used_b: Array = _sides_used_except(e.b, e.id)
	var orig_a := e.side_a
	var orig_b := e.side_b

	var h_occ: Dictionary = {}
	var v_occ: Dictionary = {}
	for n in nodes:
		h_occ[snap(n.pos.y)] = true
		v_occ[snap(n.pos.x)] = true
	var base_h: Dictionary = {}
	var base_v: Dictionary = {}
	var e_idx := -1
	var other_paths: Array = []
	for i in range(edges.size()):
		var ei: EdgeData = edges[i]
		if ei.id == e.id:
			e_idx = i
			other_paths.append([])
		else:
			other_paths.append(route_edge(ei, h_occ, v_occ, base_h, base_v))
	if e_idx < 0:
		e.side_a = orig_a
		e.side_b = orig_b
		return false

	for sa in range(4):
		if sa in used_a:
			continue
		for sb in range(4):
			if sb in used_b:
				continue
			if sa == orig_a and sb == orig_b:
				continue
			e.side_a = sa
			e.side_b = sb
			# Deep-copy one level: values are Arrays we append to, so inner lists must not be shared.
			var h_copy: Dictionary = {}
			for k in base_h:
				h_copy[k] = base_h[k].duplicate()
			var v_copy: Dictionary = {}
			for k in base_v:
				v_copy[k] = base_v[k].duplicate()
			var e_path := route_edge(e, h_occ, v_occ, h_copy, v_copy)
			if e_path.is_empty():
				continue
			var ok := true
			for j in range(other_paths.size()):
				if j == e_idx or other_paths[j].is_empty():
					continue
				if paths_cross(e_path, other_paths[j]):
					ok = false
					break
			if ok:
				return true

	e.side_a = orig_a
	e.side_b = orig_b
	return false

func _sides_used_except(node_id: int, skip_edge_id: int) -> Array:
	var used: Array = []
	for i in range(edges.size()):
		var e: EdgeData = edges[i]
		if e.id == skip_edge_id:
			continue
		if e.a == node_id:
			used.append(e.side_a)
		if e.b == node_id:
			used.append(e.side_b)
	return used

# Repair any crossings by searching for alternative side assignments.
# Runs before and after compaction.
func resolve_crossings() -> void:
	reassign_all_sides()
	const MAX_FIXES = 60
	for _fix in range(MAX_FIXES):
		var paths := _crossing_paths()
		if paths.is_empty():
			return
		var fixed := false
		for i in range(edges.size() - 1):
			if i >= paths.size() or paths[i].is_empty():
				continue
			for j in range(i + 1, edges.size()):
				if j >= paths.size() or paths[j].is_empty():
					continue
				var ei: EdgeData = edges[i]
				var ej: EdgeData = edges[j]
				if not paths_cross(paths[i], paths[j]):
					continue
				if _try_alternative_sides(ei) or _try_alternative_sides(ej):
					fixed = true
					break
			if fixed:
				break
		if not fixed:
			break  # no side reassignment can fix remaining crossings

# Returns build_all_paths() result if any non-empty pair crosses, empty Array otherwise.
# Avoids a redundant build_all_paths() call compared to a separate _any_edges_cross bool.
func _crossing_paths() -> Array:
	var paths := build_all_paths()
	for i in range(paths.size() - 1):
		if paths[i].is_empty():
			continue
		for j in range(i + 1, paths.size()):
			if paths[j].is_empty():
				continue
			if paths_cross(paths[i], paths[j]):
				return paths
	return []

# ── Force simulation ──────────────────────────────────────────────────────────
func simulate_step(delta: float, dragging_id: int, alpha: float) -> float:
	var n = nodes.size()
	if n < 1:
		return 0.0
	# Cardinal edges route straight → shorter ideal. Diagonal edges need turns → longer.
	const IDEAL_STRAIGHT = 1.5  # grid units for a perfectly cardinal edge
	const IDEAL_TURNING  = 2.5  # grid units for a 45° diagonal edge
	const MIN_SEP = 2.0  # minimum node separation in grid units
	const REPEL = 120.0  # repulsion coefficient
	const SK = 0.35      # spring constant
	const AXIS_K = 0.8   # axis-alignment strength
	var damp: float = lerp(0.25, 0.6, alpha)  # cool from exploratory to settling
	var min_sep_px: float = MIN_SEP * grid_size
	var repel_px: float = REPEL * min_sep_px * min_sep_px

	var forces: Array = []
	forces.resize(n)
	for i in range(n): forces[i] = Vector2.ZERO

	# Repulsion
	for i in range(n):
		for j in range(i+1, n):
			var diff = nodes[i].pos - nodes[j].pos
			var d2 = diff.length_squared()
			var dir = diff.normalized() if d2 > 0.01 else Vector2(randf() - 0.5, randf() - 0.5).normalized()
			var f = repel_px / max(d2, min_sep_px * min_sep_px)
			forces[i] += dir * f
			forces[j] -= dir * f

	# Springs + alignment
	var node_index: Dictionary = {}
	for i in range(n):
		node_index[nodes[i].id] = i
	for e in edges:
		var si = node_index.get(e.a, -1)
		var ti = node_index.get(e.b, -1)
		if si < 0 or ti < 0:
			continue
		var diff = nodes[ti].pos - nodes[si].pos
		var d: float = diff.length()
		if d < 0.01:
			d = 0.01
		var adx: float = abs(diff.x)
		var ady: float = abs(diff.y)
		var longer: float = maxf(adx, ady)
		if longer < 0.01:
			longer = 0.01
		var diag: float = minf(adx, ady) / longer  # 0 = cardinal, 1 = 45°
		var edge_ideal: float = lerp(IDEAL_STRAIGHT, IDEAL_TURNING, diag) * float(grid_size)
		var fv = diff.normalized() * (d - edge_ideal) * SK
		forces[si] += fv
		forces[ti] -= fv
		var a_vert = is_vert_side(e.side_a)
		var b_vert = is_vert_side(e.side_b)
		if a_vert and b_vert:
			var x_err = nodes[ti].pos.x - nodes[si].pos.x
			forces[si].x += x_err * AXIS_K
			forces[ti].x -= x_err * AXIS_K
		elif not a_vert and not b_vert:
			var y_err = nodes[ti].pos.y - nodes[si].pos.y
			forces[si].y += y_err * AXIS_K
			forces[ti].y -= y_err * AXIS_K

	var centroid = Vector2.ZERO
	for node in nodes: centroid += node.pos
	centroid /= float(n)
	# Boundary springs: keep non-anchor nodes within the S–E x-corridor so the
	# path never routes backward. Applied before velocity integration.
	var s_x: float = nodes[0].pos.x
	var e_x: float = nodes[1].pos.x
	var max_vel = 0.0
	for i in range(n):
		forces[i] += (centroid - nodes[i].pos) * 0.02
		if i >= 2:
			var xi: float = nodes[i].pos.x
			if xi < s_x + min_sep_px:
				forces[i].x += (s_x + min_sep_px - xi) * 1.5
			elif xi > e_x - min_sep_px:
				forces[i].x -= (xi - (e_x - min_sep_px)) * 1.5
		if nodes[i].id == dragging_id or i < 2:
			continue  # S/E are fixed anchors
		nodes[i].vel = (nodes[i].vel + forces[i]) * damp
		max_vel = max(max_vel, nodes[i].vel.length())
		nodes[i].pos = snap_vec(nodes[i].pos + nodes[i].vel)
	return max_vel
