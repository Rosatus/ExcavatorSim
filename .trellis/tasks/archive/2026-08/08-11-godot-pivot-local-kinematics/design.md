# Design — SY205 local pivot kinematics

## Authority and data flow

```text
Python view_state frame transforms
  -> MotionProtocol.rows_to_transform (唯一 Z-up -> Y-up adapter)
  -> relative frame transforms against converted zero pose
  -> local single-axis deltas on imported GLB pivots
  -> Godot passive four-bar solver after main pivots
```

Python remains authoritative for the five named frame transforms and lifecycle.
Godot does not reinterpret raw joint angles and does not publish local transforms
or linkage results back to Python.

## Local delta derivation

For each adjacent pair `(parent, child)` in
`base_link -> upper_structure_link -> boom_link -> arm_link -> bucket_link`,
capture the converted zero relation:

```text
R0 = T_parent_zero^-1 * T_child_zero
Rq = T_parent_current^-1 * T_child_current
Delta = R0^-1 * Rq
```

`Delta` is the joint motion relative to the URDF/link frame's zero joint origin.
Only `Delta.basis` is applied; the imported child `transform.origin` remains the
guide-defined parent-local pin position. The root may receive a whole-machine
base delta, but it is not treated as the slew joint.

The imported pivot bases are identity (B contains only a negligible export
rounding quaternion), so the implementation can enforce the manifest runtime
axis by extracting one signed angle and constructing a clean `Basis` around:

- `Vector3.UP` for `upper_structure_link` / `PIVOT_SLEW`;
- `Vector3.RIGHT` for boom, arm and bucket pivots.

If the authority delta has a non-finite value, material non-axis residual, or
invalid scale, retain the last valid local transform and emit a deduplicated
diagnostic. Do not silently move the pivot origin to make a bad frame fit.

## Passive linkage ordering

1. Apply root whole-machine delta and the four local main-pivot rotations.
2. Read current B/C/D hierarchy positions in arm-local space.
3. Solve A using the existing arm-local Y-Z circle intersection and nearest
   previous branch policy.
4. Set only B local rotation and `CTRL_LINKAGE_SIDE_LINKS` local position/X
   rotation. A remains B's child; C remains D's child; meshes remain children.

The solver therefore sees the corrected local hierarchy and cannot hide a
parent-child pivot error by writing global transforms.

## Compatibility and rollback

- Keep the current manifest frame paths and passive-linkage paths. Add explicit
  runtime axis/local-position metadata only where it removes ambiguity; retain
  source/authoring axis metadata separately from Godot runtime axes.
- Keep existing frame parity fixtures as checks that the presentation follows
  the authority's relative joint rotation, then add local invariants that catch
  the old bug. Do not require GLB visual pin world origins to equal Python
  link-frame world origins; those are different calibrated frames.
- If a runtime smoke reveals an authority frame with a non-axis residual, fail
  the local application for that frame and leave the last valid pose rather than
  falling back to independent global writes.
- Rollback is limited to `motion_presentation.gd`, manifest metadata, tests and
  frontend specs; the GLB and backend remain untouched.

## Evidence anchors

- User guide local pivot table and hierarchy: `E:/projects/blender/Excavator/SY205/export/godot/SY205_Godot_Pivot_Definition_Guide.md:79-172`.
- Current global-write defect: `godot/client/scripts/motion_presentation.gd:112-151`.
- Existing passive solver boundary: `godot/client/scripts/motion_presentation.gd:258-308`.
- Existing global-only test gap: `godot/client/tests/motion_client_test.gd:294-360`.
