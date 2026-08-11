# Replace Backend With SY205 URDF v4

## Goal

Make the generated SY205 URDF the active Python backend model and update the directly affected
backend/protocol fixtures and provenance.

## Requirements

- Depend on the completed M1 generated artifacts.
- Replace `assets/model/kinematic_excavator.urdf` with the generated SY205 URDF bytes.
- Change backend/protocol `model_version` to `sy205-glb-urdf-v4` while keeping protocol
  `babylon-sim-v3`.
- Regenerate the active backend frame-parity fixture from the new URDF.
- Keep current joint limits and provisional calibration unless a normal test demonstrates an
  incompatibility.
- Update provenance so the active URDF is described as generated from the approved GLB.
- Update ordinary tests and fixtures that directly encode the old model identity or transforms.

## Acceptance Criteria

- [ ] The active `URDF_PATH` loads the SY205 model with four DOF and all required frames.
- [ ] Backend state/hello/model metadata consistently report `sy205-glb-urdf-v4`.
- [ ] The active frame-parity fixture matches the new URDF.
- [ ] Provenance records the GLB-derived generation chain and the SY135 reference role correctly.
- [ ] `pixi run verify` and `pixi run backend-smoke` pass.

## Out of Scope

- Godot constant or fixture changes; those are M3.
- Replay conversion or support for running the old URDF as SY205.
- New protocol fields or message kinds.
