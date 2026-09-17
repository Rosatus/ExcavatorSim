# Godot Mechanical Adapter

## Import validation

Load the GLB through Godot and instantiate the resulting `PackedScene`. Validate the imported scene,
not the binary `.godot/imported/*.scn` cache.

Recursively capture:

- exact NodePaths and parent types;
- each candidate pivot's local/global `Transform3D`, scale, and visual descendants;
- mesh/surface/material/texture counts and aggregate `AABB`;
- `AnimationPlayer`, `Skeleton3D`, physics/collision resources, and unexpected scripts.

Persist rest transforms only after source SHA and semantic mapping are approved. At runtime, fail
loudly when the imported hierarchy, local origin, or scale drifts outside the manifest tolerance.

## Rest pose is the semantic zero

With the delta scheme below, the imported rest-local basis is the joint's zero reference: a joint
angle of `0` renders exactly the GLB rest pose, and physics joint limits are anchored relative to
it. Two consequences:

1. **An exporter must normalize, not record.** If the source scene is assembled in an arbitrary
   pose (transport, mid-work), the exporter must rigidly re-pose each sub-chain about its validated
   pin so the pin-to-pin direction equals the contract link direction, then bake the mesh into the
   pivot frame. Copying the authored world matrix as the pivot rest bakes a wrong zero that no
   amount of correct delta math can repair — every pose is offset by the same constant.
2. **Fixtures derived from the asset under test are tautologies.** A parity fixture generated from
   the GLB rest proves the delta math round-trips, not that the zero is right. Anchor the zero
   check to the authority model (URDF FK at zero) or to a proven sibling contract.

For this repository's excavator contract the canonical zero is the *extended* arrangement: pivot
`-Z` is the link direction, child pins sit at pure `(0, 0, -L)` locals with the URDF link lengths,
and the boom/arm/bucket world bases are `RotX(+35)/RotX(-55)/RotX(-105)` (locals `+35/-90/-50`
under identity slew). Mount points and link lengths are per-model geometry; the basis convention
and the `-Z` rule are shared semantics.

## Convert coordinates once

Define one rigid basis conversion `C` at the transport or presentation boundary:

```text
T_runtime = C * T_authority * inverse(C)
```

Validate `C` with basis vectors, translation, a positive rotation on every joint family, determinant
near `+1`, and an asymmetric pose. Do not add per-node ±90-degree repairs after this conversion.

## Preserve the imported local chain

For a child authority frame and its parent:

```text
R0 = inverse(parent_zero) * child_zero
Rq = inverse(parent_current) * child_current
Delta = inverse(R0) * Rq
```

Use only `Delta.basis` for the visual joint. Extract the signed angle around the validated runtime
axis, reconstruct a clean single-axis basis, and apply it to the imported rest-local basis:

```gdscript
var target_local := imported_rest_local
target_local.basis = imported_rest_local.basis * clean_axis_delta
pivot.transform = target_local
```

Keep `target_local.origin` and scale unchanged. Process parent-to-child. Python/robotics link-frame
world origins need not equal visual CAD pin origins; compare adjacent relations and local invariants.

For the whole-machine base, apply the authority root delta to the imported root global transform.
Do not confuse the base/root with the first slew hinge when the asset represents both.

## Validate every applied relation

Reject and retain the last valid local pose when:

- a required transform is missing or non-finite;
- a basis is materially non-rigid, mirrored, or scaled;
- current parent-child origin differs from the zero relation beyond tolerance;
- the relation contains material rotation outside the allowed axis;
- a parent relation is invalid;
- applying the result would create NaN/Inf.

Emit stable per-frame diagnostics. Clearing stale/reconnect/reset state must restore every captured
rest-local transform and reset passive solver continuity.

## Rebuild passive mechanisms after driven joints

Do not send passive visual transforms back to the authority service.

When the topology is approved, derive fixed pin locations and bar lengths from imported rest-local
transforms. Express the solver in a stable parent-local plane. A common four-bar pattern is:

- two pins fixed to a driven parent/child hierarchy;
- one moving pin found by intersecting two circles with fixed bar lengths;
- two mathematical solutions, selecting the candidate nearest the previous valid pin;
- visual controls oriented to the solved pins without directly moving mesh children.

Treat coincident centers, no circle intersection, negative height beyond tolerance, non-finite
solutions, or broken length conservation as unreachable. Retain the previous valid passive pose.
Update all driven pivots first, then run the passive solver once.

## Regression matrix

At minimum test:

1. Import identity: SHA, paths, parents, rest local origins/scales, resources, and bounds.
2. Zero pose: every imported local/global rest transform is restored.
3. Zero cross-check: the zero pose's world pin/joint positions match the authority zero (URDF FK)
   or the sibling contract within tolerance — this catches a wrong rest that self-generated
   fixtures cannot see.
4. Isolated poses: one test per independently driven joint, verifying subtree, axis, sign, and pin.
5. Asymmetric pose: catches duplicated conversion, wrong multiplication order, and hierarchy drift.
6. Invalid relations: missing/non-rigid/off-axis/origin-drifting inputs are mutation-free.
7. Lifecycle: reconnect, stale, reset, and authority-generation changes restore/clear presentation.
8. Passive linkage: fixed lengths, continuous branch, reachable movement, and unreachable retention.
9. Live runtime check: read actual `Transform3D`s of the running pivot chain (and which model root
   is active) rather than inferring the pose from a screenshot or stale import cache.
10. Visual review: materials, scale, neutral pose, rotation planes, penetrations, and linkage
    alignment.

Headless tests prove contracts, not realism. Record a separate human visual gate before calling the
asset production-ready.
