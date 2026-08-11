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
3. [x] Replace `assets/model/kinematic_excavator.urdf` with the generated SY205 URDF.
4. [x] Update backend/protocol model identity, backend fixtures, and provenance.
5. [x] Update Godot model identity and parity fixture hashes.
6. [x] Run ordinary backend verification and focused Godot standalone/MCP smoke tests.

## Validation

```powershell
pixi run verify
pixi run backend-smoke
godot/client/tests/run_standalone_matrix.ps1 -GodotExe <Godot-console-exe>
```

Focused tests only need to prove that the replacement model loads, its four joints produce finite
transforms, Godot accepts the model identity, and the existing visual pivot adapter still moves the
SY205 GLB correctly.

## Integration Review

- Active and candidate SY205 URDF SHA-256:
  `5707f454624fadd5630fcbfd66893b4edf7e8c5b97c84e65e06bf9f8fa46c02c`.
- Future SY135 reference SHA-256:
  `2f32a9f635f6fb1b43da9fb624612ade5b7a7b7d2d84f5eed401ffb414afc485`.
- `pixi run verify`: Ruff, strict mypy, 144 backend tests, provenance, and standalone paths passed.
- `pixi run backend-smoke`: health, URDF, GLB, WebSocket handshake, and terrain snapshot passed.
- Godot 4.7.1 standalone matrix: all seven scripts passed.
- Godot MCP: zero and asymmetric poses applied with empty pivot diagnostics and reachable passive
  linkage, then zero was restored and the project stopped.
