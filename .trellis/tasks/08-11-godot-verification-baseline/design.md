# Design

## Boundaries

This task changes release configuration and verification only. Python remains
the motion/input/lifecycle authority. Godot keeps the approved local world,
bucket convenience state and presentation ownership. The supplied GLB, protocol
schema, terrain algorithms and runtime reducers are not changed.

## Project baseline

`project.godot` owns the source viewport size. Set the viewport to 1920x1080 and
keep `canvas_items` plus `expand` so the HUD and camera continue adapting when a
developer or test harness uses a smaller window. `VisualQualityController`
continues to own the 60 FPS cap and quality profiles.

## Verification layers

The evidence is intentionally split by responsibility:

1. `run_standalone_matrix.ps1` executes the seven deterministic SceneTree
   scripts through a caller-supplied Godot 4.7 executable.
2. Godot MCP checks the live editor bridge, scene composition, game helper and
   runtime UI. It is not the standalone test framework and is not required by
   exported builds.
3. `pixi run backend-smoke` launches the production HTTP/WebSocket service and
   probes real serialized contracts.
4. `pixi run verify` remains the hermetic Python lint/type/test/provenance gate.

This avoids making the product dependent on the untracked MCP addon and avoids
putting a live network process inside the deterministic backend gate.

## Rollback

Revert the viewport keys, the standalone runner and the release documentation.
No persisted simulation data or protocol version changes are involved.
