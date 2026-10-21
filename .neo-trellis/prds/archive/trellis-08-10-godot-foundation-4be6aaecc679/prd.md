# Godot Foundation

## Goal

Create the first reproducible Godot client shell under `godot/client/` so later motion, terrain and visual milestones have a stable scene and frame hierarchy to build on.

## Requirements

- Add a main scene at `res://scenes/main.tscn` and configure it as the project entry scene.
- Provide stable placeholder nodes named `base_link`, `upper_structure_link`, `boom_link`, `arm_link`, and `bucket_link` under an `ExcavatorRig` root.
- Add minimal camera, lighting, terrain-root, presentation-root and operator-UI anchors without implementing transport or gameplay.
- Keep Forward+, Windows D3D12 and Jolt settings from the created project; local physics must remain optional.
- Establish directories for `scripts/`, `scenes/`, `resources/` and `tests/` without committing editor caches or generated exports.
- Use Godot MCP for read/author/inspect validation and keep the MCP plugin a development-time dependency only.

## Acceptance Criteria

- [x] Godot imports and opens `res://scenes/main.tscn` without a scene or script error.
- [x] The main scene runs and exposes the five exact frame node names in the scene tree.
- [x] The editor camera can show the placeholder rig, ground anchor and basic lighting.
- [x] MCP state, filesystem scan and scene hierarchy checks succeed for the project.
- [x] No transport, terrain algorithm, GLB asset, replay, or authority code is introduced in this milestone.
- [x] Existing uncommitted user files outside this child scope are preserved.
