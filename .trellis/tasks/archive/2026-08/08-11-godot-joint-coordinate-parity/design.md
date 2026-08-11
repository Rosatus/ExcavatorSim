# Design — Godot joint coordinate parity

## Boundary and data flow

```text
Python Pinocchio T_world_frame (right-handed Z-up rows)
  -> MotionProtocol.rows_to_transform
  -> C * T_python * C^-1 (right-handed Godot Y-up)
  -> MotionClient pose buffer/interpolation
  -> MotionPresentation incoming * visual_rest_offset
  -> imported SY205 pivot global transform
```

`MotionProtocol` remains the single matrix conversion owner. Consumers receive
only Godot-space `Transform3D` values and must not repeat or partially undo the
conversion.

## Coordinate contract

Use the orthonormal basis change:

```text
C = [[1, 0,  0],
     [0, 0,  1],
     [0,-1,  0]]

p_godot = C * p_python = (x, z, -y)
T_godot = C * T_python * C^-1
```

This preserves handedness (`det(C) = +1`), maps Python +Z up to Godot +Y up,
maps Python +Y to Godot -Z, maps `RotZ(+theta)` to `RotY(+theta)`, and leaves
`RotX(+theta)` about +X.

## Calibration contract

For each mapped frame:

```text
authority_zero_g = convert(authority_zero_python)
offset_g = inverse(authority_zero_g) * imported_rest_global_g
visual_global_g = convert(authority_pose_python) * offset_g
```

The calibration remains per-frame because the visual asset link origins differ
from the URDF frame origins. The basis conversion is global and shared; it must
not be folded into five unrelated offsets.

## Metadata

The existing `pivot_axis` values came from GLB source extras. Keep them for
provenance and add an explicit Godot/runtime axis field or coordinate-system
section so source Z is not mistaken for Godot vertical Z. Runtime motion remains
matrix-driven; axis strings are validation/documentation only.

## Tests

1. Pure conversion tests assert translation `(1,2,3) -> (1,3,-2)`, +90-degree
   Z -> +90-degree Y, +90-degree X -> +90-degree X, and determinant +1.
2. Extend the Godot handoff fixture with the backend's existing
   `swing_positive_90` five-link frames while retaining the baseline SHA-256.
3. In the mounted main scene, record every imported rest global transform and
   assert for each pose/frame:

   ```text
   actual_global * inverse(rest_global)
     == convert(pose_frame) * inverse(convert(zero_frame))
   ```

4. Keep existing reconnect/generation and excavation tests to catch downstream
   regressions. Add only a local proxy-follow assertion for the bucket tooth.

## Compatibility and rollback

- No wire, backend or GLB change is required.
- Existing clients and the legacy backend remain wire-compatible.
- Rollback is the focused Godot adapter/test/manifest/spec commit; the asset and
  Python authority are untouched.
- A failed live visual review leaves the task in progress and records the
  observed frame/sign mismatch rather than changing URDF axes by guesswork.
