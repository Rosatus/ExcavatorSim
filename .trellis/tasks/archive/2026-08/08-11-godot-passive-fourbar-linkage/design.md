# Design — SY205 passive four-bar linkage

## Authority and data flow

```text
Python view_state (five main frame globals)
  -> MotionProtocol Z-up -> Y-up conversion
  -> MotionPresentation applies base/slew/boom/arm/bucket globals
  -> Passive linkage solver reads current B/C/D geometry
  -> Godot-only B pivot + side-link controller presentation
```

The solver is downstream of `MotionPresentation`. It consumes converted
`Transform3D` values and never reads raw joint angles or performs another axis
conversion. It never publishes a transform or contact point to Python.

## Guide-defined geometry

The solver resolves these paths from the imported SY205 asset:

```text
arm = .../PIVOT_ARM_JOINT
D   = arm/PIVOT_BUCKET_JOINT
B   = arm/PIVOT_LINKAGE_B_ARM
A   = B/PIVOT_LINKAGE_A_COMMON
C   = D/PIVOT_LINKAGE_C_BUCKET
side = arm/CTRL_LINKAGE_SIDE_LINKS
```

At initialization, all pin positions are converted to `arm` local space and
the rest lengths are captured from the imported zero pose:

```text
AB = distance(A0, B0) in arm-local YZ
AC = distance(A0, C0) in arm-local YZ
CD = distance(C0, D0) in arm-local YZ (diagnostic invariant)
```

Each update reads the current C and D positions in arm-local space after the
authoritative bucket frame has been applied. A is solved as the intersection
of circles centered at B and C with radii AB and AC. The candidate nearest the
previous valid A is selected to prevent branch flips. B's local X rotation is
adjusted by the delta between the rest B-A angle and solved B-A angle. The
side controller's local position is set to A and its X rotation is adjusted by
the rest A-C angle delta. A and C pivot positions are never directly written.

## Failure and reset behavior

- If the circle distance is zero, non-finite, outside the triangle inequality,
  or produces a non-finite candidate, the solver leaves B/side at the last
  valid local transforms and records `reachable=false` with a stable reason.
- `_restore_rest_pose()` restores the authoritative five frame globals and the
  captured B/side local transforms. A subsequent zero pose can solve again from
  the rest branch.
- Solver status is a local diagnostic only. It is not serialized into the
  Python protocol and cannot alter terrain, bucket soil or replay state.

## Compatibility

The GLB remains a static, non-skinned visual asset. No animation tracks,
collision resources, backend files, URDF axes, protocol identifiers or
authoritative physics are changed. A future dynamic physics adapter may reuse
the same pin metadata, but must be a separate contract.

## Test seams

`MotionPresentation.get_passive_linkage_snapshot_for_test()` exposes only
finite world pin positions, local invariant lengths, reachability and a reason.
The Godot test applies zero/swing/asymmetric fixtures, checks AB/AC/CD
conservation, verifies passive B/side changes and re-applies zero to verify
restoration. It also injects an unreachable bucket pose to ensure no NaN/inf or
last-valid-pose corruption.
