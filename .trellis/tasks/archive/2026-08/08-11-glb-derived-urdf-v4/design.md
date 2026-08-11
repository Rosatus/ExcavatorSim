# Design: GLB-derived URDF v4

## Architecture

```text
approved SY205 GLB + checked-in estimates
    -> deterministic candidate URDF + evidence
    -> replace active backend URDF and regenerate backend fixtures/provenance
    -> align Godot model identity and parity fixtures
```

The GLB remains the visual source. The generated URDF becomes Python's active kinematic authority.
The old URDF is copied to the model library only as a starting reference for future SY135 work.

## Artifact Ownership

| Artifact | Purpose |
| --- | --- |
| `godot/client/assets/visual/SY205_excavator_godot.glb` | Immutable SY205 visual source |
| `backend/scripts/generate_sy205_urdf.py` | Deterministic offline generator |
| `assets/model/sy205_glb_derived_v4.urdf` | Generated SY205 candidate |
| `assets/model/sy205_glb_derived_v4.json` | Generation evidence and provisional estimates |
| `assets/model/kinematic_excavator.urdf` | Active backend URDF after M2 replacement |
| `assets/model/library/sy135_reference.urdf` | Old URDF retained for future SY135 GLB work |

## Coordinate Contract

```text
p_godot = (x_python, z_python, -y_python)
p_python = (x_godot, -z_godot, y_godot)
T_godot = C * T_python * inverse(C)
```

| Joint | URDF origin xyz | Axis |
| --- | --- | --- |
| `swing_joint` | `(0, 0, 0.91)` | `(0,0,1)` |
| `boom_joint` | `(-0.119, 0.075, 0.713)` | `(1,0,0)` |
| `arm_joint` | `(0.066, -3.915, 4.295)` | `(1,0,0)` |
| `bucket_joint` | `(-0.008, 0.630, -3.026)` | `(1,0,0)` |

The joints remain `continuous`; limits stay in the calibration file.

## Replacement Strategy

- M1 generates and validates files without changing the active runtime.
- M2 copies the generated SY205 URDF over the active backend URDF, updates
  `model_version`, backend fixtures, and provenance, then runs ordinary backend checks.
- M3 updates Godot constants and parity fixture hashes, then runs focused motion and normal client
  smoke tests.
- No special replay migration, release rollback bundle, or separate human approval sequence is
  required for this replacement.
