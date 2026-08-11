# Fix Godot joint coordinate parity

## Goal

Make the supplied SY205 excavator rotate in the correct mechanical planes when
driven by Python `frame_transforms`. Preserve Python as the sole motion
authority and preserve the exact user-supplied GLB bytes and pivot hierarchy.

## Confirmed facts

- The Python Pinocchio/URDF authority is right-handed and Z-up. The swing joint
  rotates about Python +Z; boom, arm and bucket rotate about Python +X.
- Godot and the imported SY205 scene are right-handed and Y-up.
- `MotionProtocol.rows_to_transform()` currently copies the Python matrix into
  a Godot `Transform3D` without changing basis.
- `MotionPresentation` writes the resulting full global transform to each GLB
  pivot. Its rest-pose offset can align zero pose, but cannot repair an omitted
  world-coordinate conversion for non-zero poses.
- The GLB contains the five pivot nodes and source-authoring axis metadata. The
  local manifest copies those source axes, but the runtime does not use them.
- Existing tests prove node/hash/rest-pose stability and that an asymmetric pose
  moves one arm node. They do not numerically prove the rotation plane or sign.

## Requirements

### R1 — One explicit coordinate boundary

- Convert every backend matrix at the shared protocol boundary using the
  right-handed mapping `(x_python, y_python, z_python) ->
  (x_godot, y_godot, z_godot) = (x_python, z_python, -y_python)`.
- Apply the conversion to a complete frame transform by conjugation:
  `T_godot = C * T_python * C^-1`.
- Do not add per-node ad-hoc axis swaps or reinterpret protocol identifiers.

### R2 — Preserve visual calibration and authority

- Compute visual rest offsets from already-converted authority zero matrices.
- Continue applying full authoritative global transforms followed by the
  Godot-local visual offset.
- Do not write visual transforms, local terrain state or contact points back to
  Python.
- Preserve the exact SY205 GLB bytes, node names and hierarchy.

### R3 — Make axis metadata unambiguous

- Preserve the GLB/source-authoring axis values for provenance.
- Document the runtime Godot-space axis mapping separately: Python/authoring Z
  becomes Godot Y, while X remains Godot X under the selected right-handed
  basis change.
- Do not use string axis metadata as a substitute for the full matrix
  conversion.

### R4 — Regression coverage

- Add pure conversion assertions for translation, positive Z/swing rotation,
  positive X/work-equipment rotation and right-handed determinant.
- Strengthen presentation parity for all five mapped frames at zero,
  `swing_positive_90` and asymmetric poses using exact calibrated transform
  deltas.
- Keep the local bucket-tooth proxy Godot-owned; verify it follows the corrected
  bucket transform, but do not claim parity with backend tooth frames until a
  separate visual marker contract exists.

## Out of scope

- Re-exporting or editing the supplied GLB.
- Changing Python kinematics, URDF joint axes, wire schema or version IDs.
- Adding dynamic rigid-body/hydraulic authority or collision geometry.
- Calibrating a production bucket cavity or backend-authoritative tooth marker.

## Acceptance criteria

- [x] Backend +Z-up translations convert to Godot +Y-up with no reflection.
- [x] Positive Python swing rotation is positive Godot Y-axis rotation; positive
      boom/arm/bucket X rotation remains a positive Godot X-axis rotation.
- [x] Zero pose restores the imported rest pose for all five frames.
- [x] `swing_positive_90` and asymmetric fixtures match the expected calibrated
      global transform for all five frames within `1e-4`.
- [x] The supplied GLB SHA-256 and hierarchy remain unchanged.
- [x] The seven-script Godot standalone matrix, MCP live motion smoke,
      `pixi run backend-smoke`, `pixi run verify`, task validation and
      `git diff --check` pass.
