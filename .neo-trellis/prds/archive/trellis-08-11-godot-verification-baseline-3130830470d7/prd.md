# Godot verification and release baseline

## Goal

Close the release-evidence gaps found after the completed M1-M7 roadmap without
changing the approved runtime authority split or the user-supplied GLB.

## Requirements

- Encode the approved Windows desktop rendering baseline as a 1920x1080 Godot
  viewport while preserving Forward+, D3D12, Jolt and the current responsive UI
  stretch policy.
- Provide one deterministic Windows command that runs all seven standalone
  Godot SceneTree contract scripts with an explicit Godot executable.
- Document the distinction between the standalone matrix, Godot MCP editor and
  runtime smoke, the live Python backend smoke, and `pixi run verify`.
- Keep Godot MCP optional and development-only; release code must not depend on
  MCP test discovery or send local terrain, bucket or physics state to Python.
- Preserve the exact supplied SY205 GLB bytes and its five-pivot manifest.
- Do not add backend smoke to the hermetic `pixi run verify` gate; run it as an
  explicit live release check because it launches an HTTP/WebSocket server.

## Acceptance Criteria

- [x] `project.godot` reports a 1920x1080 viewport and retains Forward+,
  responsive stretch, D3D12 and Jolt settings.
- [x] One PowerShell runner executes the full standalone Godot matrix and
  propagates the first non-zero exit code.
- [x] The release documentation gives reproducible standalone, MCP and backend
  smoke steps with expected evidence.
- [x] Godot MCP connects to `ExcavatorSim` 4.7.1, opens `main.tscn`, runs the
  scene, and exposes the expected release-candidate nodes/UI.
- [x] The standalone matrix, `pixi run backend-smoke`, `pixi run verify`, task
  validation and `git diff --check` all pass.
- [x] The SY205 GLB SHA-256 and five-pivot manifest remain unchanged.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
