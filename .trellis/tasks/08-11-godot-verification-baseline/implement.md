# Implementation plan

## Project configuration

- [x] Add the 1920x1080 viewport baseline without changing the renderer,
  physics engine, main scene or stretch policy.
- [x] Confirm the connected editor reports the persisted project settings.

## Reproducible verification

- [x] Add a fail-fast PowerShell runner for all seven standalone Godot tests.
- [x] Expand the Godot test and release-candidate docs with exact standalone,
  MCP and backend smoke commands plus expected results.

## Quality gate

- [x] Run the standalone Godot matrix through the new runner.
- [x] Run Godot MCP connection/scene/runtime smoke.
- [x] Run `pixi run backend-smoke`, `pixi run verify`, task validation and
  `git diff --check`.
- [x] Recheck the GLB hash and five manifest mappings, then archive the task.
