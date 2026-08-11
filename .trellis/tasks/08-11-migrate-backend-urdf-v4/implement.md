# Implementation Plan: Replace Backend With SY205 URDF v4

1. [ ] Copy the generated SY205 URDF bytes to the active backend URDF path.
2. [ ] Update backend/protocol `model_version` to `sy205-glb-urdf-v4`.
3. [ ] Regenerate the active backend frame-parity fixture.
4. [ ] Update affected backend tests and fixture hashes.
5. [ ] Update provenance for the GLB-derived active URDF and SY135 reference copy.
6. [ ] Run `pixi run verify` and `pixi run backend-smoke`.

Exit gate: the backend directly runs the SY205 URDF and ordinary backend checks pass. M3 may then
align the Godot client.
