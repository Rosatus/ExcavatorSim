# Coordinate parity evidence

- Python frame matrices are right-handed `T_world_frame` row arrays from
  Pinocchio. The URDF swing axis is +Z; boom, arm and bucket axes are +X.
- Calibration gravity `[0, 0, -9.80665]` establishes Python Z-up.
- Imported SY205 pivot rest positions establish Godot Y-up. The five pivot local
  bases are identity at rest.
- Raw GLB node extras declare source axes Z/Z/X/X/X. The local manifest copies
  them, but runtime presentation never reads `pivot_axis`.
- `MotionProtocol.rows_to_transform()` currently performs row/column assembly
  only. `MotionPresentation` writes `incoming * offset` directly to each pivot
  global transform.
- The correct right-handed conversion is `p_g = (x_p, z_p, -y_p)` and
  `T_g = C * T_p * C^-1`.
- Existing tests validate source hash, node mapping, imported rest transforms and
  non-zero movement, but not numerical five-frame axis parity.
- Regression coverage now checks the manifest's full conjugation formula,
  zero/swing/asymmetric deltas for all five frames, and zero reapplication after
  motion restores every imported rest transform.
- The Godot tooth proxy is intentionally visual/local and currently has no
  backend/GLB marker contract; it must not be promoted to motion authority by
  this fix.
- Scene coverage verifies the proxy equals the corrected bucket frame multiplied
  by its local offset, without comparing it to backend tooth frames.
- User-supplied `E:/projects/blender/Excavator/SY205/export/godot/SY205_Godot_Import_Guide.md`
  confirms the GLB was already exported Y-up, forbids an extra global +/-90
  degree scene rotation, and explicitly maps Blender/authority Z slew to Godot
  Y while work-equipment hinges remain Godot X. It also documents four-linkage
  solver semantics as a separate downstream behavior, not part of this matrix
  boundary fix.
