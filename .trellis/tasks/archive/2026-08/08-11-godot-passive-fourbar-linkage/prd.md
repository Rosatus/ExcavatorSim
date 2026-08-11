# Implement SY205 passive four-bar linkage

## Goal

Rebuild the SY205 GLB's passive A/B/C/D linkage in Godot according to the
user-supplied `SY205_Godot_Import_Guide.md`. The linkage is presentation-only:
the authoritative Python pose controls the five main pivots, D moves with the
authoritative bucket frame, and Godot derives A/B/side-link motion without
changing the GLB or wire protocol.

## Requirements

- Preserve the exact GLB bytes, imported hierarchy and five authoritative frame
  mappings.
- Resolve the guide's nodes exactly: D=`PIVOT_BUCKET_JOINT`,
  B=`PIVOT_LINKAGE_B_ARM`, A=`PIVOT_LINKAGE_A_COMMON`,
  C=`PIVOT_LINKAGE_C_BUCKET`, and `CTRL_LINKAGE_SIDE_LINKS`.
- Solve in `PIVOT_ARM_JOINT` local Y-Z space. B and D remain fixed in that
  arm-local frame; C follows D through the imported bucket hierarchy; A is the
  continuous circle-intersection solution satisfying captured AB and AC lengths.
- Rotate the B pivot around Godot +X so `bucket_linkage_primary` follows B-A.
  Move/rotate `CTRL_LINKAGE_SIDE_LINKS` so its origin is A and its X axis
  follows A-C. Do not directly reposition A or C and do not rotate mesh nodes
  independently.
- Preserve the previous valid A branch when a pose is unreachable or nearly
  degenerate; emit a diagnostic and keep the last valid passive pose.
- Recompute passive linkage after every authoritative five-frame application
  and restore captured linkage-local transforms on reset, disconnect, stale
  pose, and zero-pose reapplication.
- Keep linkage state visual-only. It must not write transforms, terrain, tooth
  markers, bucket volume or replay state back to Python.

## Acceptance Criteria

- [x] Zero pose reproduces the guide's imported linkage hierarchy and all A/B/C/D
      nodes resolve under the expected parents.
- [x] Applying a reachable bucket pose (independent of the main-frame parity
      fixture) produces a corresponding passive A/B/side-link pose; no linkage
      remains frozen at imported zero pose. The arbitrary asymmetric fixture is
      still covered as an unreachable-input diagnostic case.
- [x] For zero, swing and asymmetric poses, AB and AC remain within `1e-4` of
      captured rest lengths; C-D remains fixed by the imported hierarchy within
      the same tolerance.
- [x] A follows the continuous circle-intersection branch; unreachable input
      does not produce NaN/inf or corrupt the last valid linkage pose.
- [x] Restoring zero after motion restores B and side-control local transforms;
      authoritative five-frame globals and the local bucket-tooth proxy remain
      unchanged by the solver.
- [x] GLB SHA-256 and hierarchy remain unchanged; no backend, URDF, schema,
      animation, collision or rigid-body authority changes are introduced.
- [x] Godot standalone matrix, MCP live motion/linkage smoke, `pixi run backend-smoke`,
      `pixi run verify`, task validation and `git diff --check` pass.
