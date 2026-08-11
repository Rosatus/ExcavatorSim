# Implementation Plan: GLB-derived URDF v4

## Task Map

| Milestone | Child task | Exit gate |
| --- | --- | --- |
| M1 | `08-11-generate-sy205-urdf` | Deterministic candidate, evidence, and SY135 reference copy |
| M2 | `08-11-migrate-backend-urdf-v4` | Active backend uses the SY205 URDF and normal backend checks pass |
| M3 | `08-11-align-godot-urdf-v4` | Godot identity/fixtures match and normal client checks pass |

## Ordered Plan

1. [x] Generate and test the deterministic SY205 URDF and evidence manifest.
2. [x] Store the old URDF as `assets/model/library/sy135_reference.urdf`.
3. [ ] Replace `assets/model/kinematic_excavator.urdf` with the generated SY205 URDF.
4. [ ] Update backend/protocol model identity, backend fixtures, and provenance.
5. [ ] Update Godot model identity and parity fixture hashes.
6. [ ] Run ordinary backend verification and focused Godot standalone/MCP smoke tests.

## Validation

```powershell
pixi run verify
pixi run backend-smoke
godot/client/tests/run_standalone_matrix.ps1 -GodotExe <Godot-console-exe>
```

Focused tests only need to prove that the replacement model loads, its four joints produce finite
transforms, Godot accepts the model identity, and the existing visual pivot adapter still moves the
SY205 GLB correctly.
