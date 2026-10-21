# Implementation Plan

1. [x] Add `scenes/`, `scripts/`, `resources/` and `tests/` directories under `godot/client/`.
2. [x] Create `res://scenes/main.tscn` with the approved root, anchors and five frame nodes.
3. [x] Add minimal visible primitives, camera and light so the scene is inspectable.
4. [x] Set the project main scene without changing Forward+/D3D12/Jolt settings.
5. [x] Run MCP editor state, filesystem scan and scene hierarchy inspection.
6. [x] Run a Godot project import/start smoke and inspect Git status for only child-scope files.

Exit gate: the scene opens and runs with no errors, the five frame names are visible, MCP inspection succeeds, and no backend/protocol files changed.
