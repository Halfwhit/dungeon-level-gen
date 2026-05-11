# Cyclic Graph Editor — Godot 4 Project

An interactive cyclic graph editor with lock/key puzzle mechanics, ported from the HTML/Canvas version.

## Requirements
- Godot 4.2 or later

## Setup
1. Open Godot 4
2. Click **Import** and select the `project.godot` file in this folder
3. Press **F5** or click the Play button to run

## Features
- **Add node** — click the canvas to place nodes; first = Start (S), second = End (E)
- **Add edge** — click two nodes to connect them (one edge per cardinal side)
- **Delete** — click a node or edge to remove it
- **Replace with cycle** — click a node to replace it with a k-cycle (graph replacement grammar)
- **Replace with lock/key** — click a node on a path to convert it; counterpart inserted on the other path
- **Insert lock/key** — automatically splits middle edges of both paths to insert a key/lock pair
- **Auto-layout** — force-directed simulation minimising edge length with axis-alignment forces
- **Grid snap** — all nodes always snap to the grid

## Lock/Key rules
- Keys and locks are evaluated **across both paths combined**
- At each step (by position index), keys from both paths are collected into a shared bank
- Locks consume from the bank — if the bank goes negative, a lock was reached too early → invalid
- Total key count must equal total lock count

## Architecture
- `GraphData.gd` — pure data model: nodes, edges, path-finding (BFS), routing, force simulation, validation
- `GraphCanvas.gd` — Godot Control that renders the graph using `_draw()` calls
- `Main.gd` — scene controller: handles input routing, popup management, toolbar actions, preset loading
- `Main.tscn` — scene tree with UI layout, canvas, and popups

## Code structure mirrors the original HTML version
The GDScript closely follows the JavaScript architecture:
- `GraphData` = the JS graph state object
- `GraphCanvas._draw()` = the JS `draw()` function
- `Main.gd` = the JS event handlers and toolbar callbacks
# level-gen
# dungeon-level-gen
