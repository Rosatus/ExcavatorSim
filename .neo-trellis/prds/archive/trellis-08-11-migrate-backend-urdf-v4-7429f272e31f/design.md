# Design: Replace Backend With SY205 URDF v4

## Replacement Flow

```text
assets/model/sy205_glb_derived_v4.urdf
    -> assets/model/kinematic_excavator.urdf
    -> backend frame-parity fixture
    -> backend/protocol model identity
    -> provenance
```

The existing `URDF_PATH` can remain unchanged because the file at that path is replaced. The old
file is already preserved by M1 as `assets/model/library/sy135_reference.urdf`.

## Fixtures And Calibration

Regenerate the existing active backend frame-parity fixture rather than maintaining simultaneous v3
and v4 runtime fixtures. Keep joint limits and cylinder values provisional; only change calibration
data when required to load or operate the new model.

The protocol identifier remains `babylon-sim-v3`; only `model_version` changes because the wire
format is unchanged.
