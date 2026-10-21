# Parent Integration Plan

This parent owns roadmap and integration acceptance. Implementation occurs in the
ordered child tasks; do not start the parent as an implementation target.

- [x] Phase 0: complete `08-17-authority-contract-shadow-state`.
- [x] Phase 1: complete `08-17-jolt-chassis-track-authority`.
- [x] Phase 2: complete `08-17-jolt-articulated-equipment` as the articulated
      prototype and record the approved hybrid supersession decision.
- [x] Phase 3: complete `08-17-jolt-terrain-excavation-coupling`.
- [x] Phase 4: complete `08-17-sensor-telemetry-python-gateway`.
- [x] Phase 5: complete `08-17-jolt-authority-cutover`.
- [x] Add one configurable Windows product soak harness that runs the
      `jolt_authoritative` + `gateway-only` path for SY205 and SY135, exercises
      tracks, articulation, loaded cut/carry/dump/support cycles, and records
      fixed-step, render, telemetry queue/drop, process-memory, and lifecycle
      evidence without reintroducing a Python pose writer.
- [x] Define and record quick/developer and release soak durations plus pass/fail
      budgets before implementing the harness.
- [x] Run final cross-layer review against `prd.md`, `scope.md`, `roadmap.md`, and
      `design.md` after all children are archived.
- [x] Verify the shipped authoritative profile contains one dynamic chassis body,
      one kinematic articulation writer, bucket-only collision queries, and no
      implicit five-body prototype fallback.
- [x] Update `docs/architecture/engineering.md`, `docs/godot-integration.md`,
      frontend/backend Trellis specs, protocol/version manifests, test docs, and
      release-candidate evidence to the shipped authority boundary.
- [x] Verify `pixi run verify`, backend smoke, Godot standalone matrix, Godot MCP
      live scenarios, model switching, reset/disconnect, profile rollback, and
      bounded performance before archiving this parent.

## Parent Rollback Point

Until Phase 5 is accepted, `python_kinematic` remains the explicit product-safe
rollback. No child may silently change the default profile.
