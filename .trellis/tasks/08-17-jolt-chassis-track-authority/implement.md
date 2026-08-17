# Implementation Plan

- [x] Add validated chassis/track physics descriptors and provenance for both models.
- [x] Build the isolated dynamic chassis rig, collision layers, safe spawn/reset,
      and visual follower adapter.
- [x] Implement distributed track contact/traction and command safety integration.
- [x] Gate old `TrackedChassisController` transform writes by authority profile and
      add runtime single-writer assertions.
- [x] Integrate terrain collider identity and safe activation/failure behavior.
- [x] Publish chassis/track truth through the Phase 0 snapshot contract.
- [x] Add headless tests for motion cases, slopes/obstacles, clamps, invalid values,
      terrain identity, lifecycle, both models, and energy/speed bounds.
- [x] Run standalone matrix and Godot MCP live handling/tuning scenes; record fixed
      tick costs and tuning values with evidence status.
- [x] Update frontend authority and model contract specs without changing default.

## Validation Evidence

- `pixi run verify`: 158 backend tests, lint, mypy, provenance, and path checks passed.
- `pixi run backend-smoke`: health/model/GLB/WebSocket/terrain smoke passed.
- Godot 4.7.1 standalone matrix: 15 scripts passed, including real Jolt coverage
  for SY205/SY135, slope/mound traversal, lifecycle, model failure, and truth isolation.
- The bounded track-force test asserts a peak fixed-step cost below 10 ms.
- Godot AI MCP live inspection verified a running SY205 rig with bilateral contact,
  local authoritative truth without shadow transport, and a runtime SY135 rebuild.

## Rollback Point

Disable `jolt_authoritative` selection and destroy the chassis rig. Legacy tracked
locomotion remains available in its explicit profile until Phase 5.
