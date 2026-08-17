# Parent Integration Plan

This parent owns roadmap and integration acceptance. Implementation occurs in the
ordered child tasks; do not start the parent as an implementation target.

- [ ] Phase 0: complete `08-17-authority-contract-shadow-state`.
- [ ] Phase 1: complete `08-17-jolt-chassis-track-authority`.
- [ ] Phase 2: complete `08-17-jolt-articulated-equipment`.
- [ ] Phase 3: complete `08-17-jolt-terrain-excavation-coupling`.
- [ ] Phase 4: complete `08-17-sensor-telemetry-python-gateway`.
- [ ] Phase 5: complete `08-17-jolt-authority-cutover`.
- [ ] Run final cross-layer review against `prd.md`, `scope.md`, `roadmap.md`, and
      `design.md` after all children are archived.
- [ ] Update `docs/architecture/engineering.md`, `docs/godot-integration.md`,
      frontend/backend Trellis specs, protocol/version manifests, test docs, and
      release-candidate evidence to the shipped authority boundary.
- [ ] Verify `pixi run verify`, backend smoke, Godot standalone matrix, Godot MCP
      live scenarios, model switching, reset/disconnect, profile rollback, and
      bounded performance before archiving this parent.

## Parent Rollback Point

Until Phase 5 is accepted, `python_kinematic` remains the explicit product-safe
rollback. No child may silently change the default profile.

