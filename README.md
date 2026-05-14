# Cyclic Dungeon Generator

A procedural dungeon connectivity generator built in Godot 4. Each run produces a two-path lock/key graph that encodes a solvable dungeon layout: two routes connect a Start room (S) to an End room (E), with keys, locks, a special room, and a deadlock gate arranged so the puzzle always has exactly one valid solution order.

## Requirements

- Godot 4.2 or later

## Setup

1. Open Godot 4
2. Click **Import** and select the `project.godot` file in this folder
3. Press **F5** or click the Play button to run
4. Click **New Puzzle** to generate a new layout

## How it works

### Two-path structure

Every generated dungeon has exactly two paths between S and E:

- **Path 1 (blue)** — travels S → E
- **Path 2 (red)** — travels E → S

Each path has a branch (a 3-node ring cycle) hanging off one of its intermediate rooms. The ring is the home of a key item.

### Room types

| Label | Type | Meaning |
|-------|------|---------|
| S | Start | Entry point for Path 1 |
| E | End | Entry point for Path 2 |
| K1 | Key | Collectable key on a Path 1 branch |
| K2 | Key | Collectable key on a Path 2 branch |
| L1 | Lock | Gate on Path 1 — requires a key to pass |
| L2 | Lock | Gate on Path 2 — requires a key to pass |
| SR | Special Room | Point of interest between L2 and the deadlock gate |
| DL | Deadlock | Permanent barrier — no key exists for it |

### Intended traversal order

**Path 1 (S → E):** collect K1 on the branch → pass L1 → reach E

**Path 2 (E → S):** collect K2 on the branch → pass L2 → visit SR → blocked by DL

The deadlock on Path 2 means a player approaching from E cannot reach S that way — they must use Path 1.

### Validation

The status bar shows whether the generated puzzle is valid. Validity requires:

- Keys are collected before their corresponding locks (checked across both paths simultaneously using a shared bank)
- Total key count equals total lock count
- Deadlocks are counted separately and never consume a key

### Layout

After the graph topology is built, a force-directed simulation spreads nodes apart, then a multi-pass post-processing pipeline snaps positions to a grid, resolves edge crossings, and enforces that Path 1 lies horizontally above centre and Path 2 lies horizontally below centre. Orthogonal edge routing ensures no lines cross.

## Architecture

| File | Role |
|------|------|
| `scripts/GraphData.gd` | Pure data model: nodes, edges, BFS path-finding, force simulation, orthogonal routing, compaction, crossing resolution, lock/key validation |
| `scripts/GraphCanvas.gd` | Renders the graph using Godot's `_draw()` API; handles zoom and pan |
| `scripts/Main.gd` | Scene controller: puzzle generation, layout thread, path ID tracking, ring cycle registry |
| `scenes/Main.tscn` | Scene tree with UI layout |

See `CLAUDE.md` for detailed invariants and constraints that must be preserved when modifying the generation logic.
