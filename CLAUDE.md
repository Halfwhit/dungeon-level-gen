# Cyclic Graph Editor — Developer Notes

## Project overview

Godot 4 puzzle generator that produces two-path lock/key graphs. The output is a dungeon-level connectivity diagram: two routes (P1 and P2) connect a Start node (S) to an End node (E), with keys, locks, a deadlock gate, and a special room arranged along those routes.

---

## Critical invariants — do not break these

### 1. nodes[0] = S, nodes[1] = E (always)

`start_node()` returns `nodes[0]` and `end_node()` returns `nodes[1]`. Every piece of code that references S or E by array index depends on this. S and E are created first in `_generate_random_puzzle` and are treated as fixed anchors by the force sim and compact_layout (both skip `i < 2`).

### 2. P1 travels S→E, P2 travels E→S

`find_two_paths()` returns `{"p1": [...S→E...], "p2": [...E→S...]}`. P2's BFS finds a second S→E path, then unconditionally reverses it before returning. Do not add a conditional reverse — P2 is **always** stored E→S.

`validate_lock_key()` uses `two_paths.p2` directly (E→S order) to check that K2 is encountered before L2. If you reverse p2 before passing it to `_path_with_branch_kinds`, K2 will appear after L2 and validation will fail.

### 3. P2 node index layout

The p2 array is built in this fixed order:

| Index | Node | Kind |
|-------|------|------|
| 0 | S | (anchor, shared with P1) |
| 1 | DL | KIND_DEADLOCK |
| 2 | SR | KIND_SPECIAL |
| 3 | L2 | KIND_LOCK |
| 4..p2_n+1 | plain intermediates | KIND_NORMAL (K2 branch attaches here) |
| p2_n+2 | E | (anchor, shared with P1) |

`res2 = [1, 2, 3]` reserves those three positions so `_add_path_cycle` only picks anchor nodes from indices 4 and up. If you change which index holds which kind, update `res2`, all three `_set_node_kind` calls, the K2 fallback range (`randi_range(4, p2_n + 1)`), and the hint string.

Traveling E→S the sequence is: **branch(K2) → L2 → SR → DL → S**. K2 must be encountered before L2 or validation fails.

### 4. P1 node index layout

| Index | Node | Kind |
|-------|------|------|
| 0 | S | (anchor) |
| 1..p1_n | plain intermediates | K1 branch attaches to one |
| p1_n | L1 | KIND_LOCK (last intermediate) |
| p1_n+1 | E | (anchor) |

`res1 = [p1_n]` reserves only L1. K1 branch attaches to any other intermediate.

Traveling S→E: **branch(K1) → L1 → E**.

### 5. Ring cycle structure (3-node rectangular arrangement)

`_add_path_cycle` attaches a 3-node ring (c0→c1→c2→c0) to an anchor on the main path. The initial positions form a rectangle that routes without crossings:

```
anchor
  |  (vertical: anchor→c0)
  c0 — c1   (horizontal: c0→c1)
  |         (vertical: c1→c2 routes via c0's x then c1's y)
  c2
```

- c0: same x as anchor, 2 grid steps away (above for P1, below for P2)
- c1: 1 step right of anchor, same y as c0
- c2: same x as anchor, 3 grid steps away

`_fix_cycle_positions()` enforces these positions after the force sim and after each `compact_layout` call. If you change the geometry, verify no routing crossings are introduced in either path's branch direction.

`_cycles` stores `{anchor_id, c_ids:[c0,c1,c2], y_dir}` so `_fix_cycle_positions` can reposition them. Reset `_cycles = []` in `_reset_graph()`.

### 6. Layout pipeline order (in `_compute_layout_threaded`)

```
snap_all
reassign_all_sides
resolve_crossings
compact_layout
fix_stub_positions        ← repositions degree-1 leaf pairs
_fix_cycle_positions      ← repositions ring cycles after compaction
compact_layout            ← second pass after repositioning
_enforce_path_x_order     ← pins P1 above y=0, P2 below y=0; enforces left-to-right x
_fix_cycle_positions      ← second pass (path nodes may have shifted)
reassign_all_sides
resolve_crossings
correct_backward_sides
```

Do not reorder these steps. `_fix_cycle_positions` must follow every `compact_layout` call or ring nodes drift. `_enforce_path_x_order` must run after all compaction or path nodes may still zigzag.

### 7. _enforce_path_x_order — horizontal path guarantee

All intermediate nodes on P1 are pinned to a single y-value (< 0, i.e. above centre) and all intermediate nodes on P2 are pinned to a single y-value (> 0, i.e. below centre). The y reference is taken from the first intermediate node on each path (`path[1]`). This makes both paths perfectly horizontal, which eliminates zigzag crossings. The 10-pass monotone-x enforcement additionally ensures consecutive nodes never have decreasing x values.

---

## Key/lock validation rules

`validate_lock_key` uses a shared-bank model:

1. Walk both `k1` (P1 in S→E) and `k2` (P2 in E→S) in parallel by position index.
2. At each step, keys from either path are added to a bank.
3. Locks spend from the bank — if the bank is empty when a lock is reached, the puzzle is invalid.
4. Total keys must equal total locks (deadlocks are counted separately and do not participate in the bank).

Branch nodes are collected immediately after their main-path anchor via BFS (`_path_with_branch_kinds`). This means a key in a side branch counts as collected at the same step as its anchor.

The two-key / two-lock layout (`K1 on P1`, `K2 on P2 branch`, `L1 on P1`, `L2 on P2`) is designed so both keys are collected before either lock is reached when both paths are traversed simultaneously from their respective starting ends (S for P1, E for P2).

---

## Node kinds and visual appearance

| Constant | String value | Shape | Colour | Meaning |
|----------|-------------|-------|--------|---------|
| KIND_NORMAL | `""` | circle | purple | plain room |
| KIND_KEY | `"key"` | square | lavender/purple | collectable key |
| KIND_LOCK | `"lock"` | square | blue | gate requiring a key |
| KIND_DEADLOCK | `"deadlock"` | square | black/red with ✕ | permanent barrier (no key) |
| KIND_SPECIAL | `"special"` | square | gold/yellow with ★ | special room / point of interest |

S is always rendered as a blue circle; E as a red circle regardless of kind.

---

## File responsibilities

| File | Role |
|------|------|
| `GraphData.gd` | Pure data model. Nodes, edges, BFS, force sim, routing, compaction, validation. No Godot scene dependencies. |
| `GraphCanvas.gd` | Renders the graph using `_draw()`. Reads `graph` (GraphData) and re-computes routed paths when `_paths_valid` is false. |
| `Main.gd` | Scene controller. Owns puzzle generation, layout thread, path ID arrays, and cycle registry. |
| `Main.tscn` | Scene tree with UI layout. |

`GraphCanvas.graph` is set to `null` while the layout thread is running (so `_draw` shows the "Computing…" message safely) and restored when the thread finishes.
