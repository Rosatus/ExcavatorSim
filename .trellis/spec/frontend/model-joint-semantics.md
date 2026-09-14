# Model Joint Semantics

## 1. Scope / Trigger

Changing model joint signs, limits, input mappings or physical frame adapters.
SY135 is the maintained reference. Do not change its q meaning, rig, manifest,
calibration, telemetry source or gateway/QML projection to accommodate SY205.

## 2. Signatures

```text
EquipmentCommandMapper.to_joint_axes(operator_axes: Vector4) -> Vector4
KinematicArticulationState.configure(descriptor, chassis_transform) -> bool
Sy205JointModel.configuration_from_angles(joint_angles) -> ndarray
pixi run python backend/scripts/sync_sy205_joint_contract.py [--check]
```

## 3. Contracts

- Operator order: swing, boom, arm, bucket; positive means right rotation,
  boom raise, arm extend, bucket curl. W/S extend/retract, I/K lower/raise,
  J/L curl/dump. Both models use `[-1,+1,+1,-1]` operator-to-logical signs.
- SY135 hinge axes remain +X. SY205's three work-equipment axes are -X because
  its segment geometry is baked in different asset coordinates. Its swing
  remains +Y. Keep SY205 rest transforms and anchors unchanged.
- FK applies `parent * anchor_parent * rotation(axis,q) * inverse(anchor_child)`.
  Do not apply a second sign in presentation or telemetry. Frame-derived
  asset angles and logical q are distinct quantities for SY205.
- SY205 limits/actuators follow the SY135 rig via the sync command, except its
  geometry-specific bucket range [-20,95] degrees. Boom stays [-25,45], arm
  [-60,45]. Negative bucket q curls, positive q dumps. SY135 bucket remains
  [-45,45]. These are relative q, not link elevations or QML joint angles.
- SY205 faces local +Z. Its spawn yaw is zero; its track +Z and cab PI yaw
  remain intentional asset adaptations. External cameras reverse both rear
  and right relative to asset basis for SY205 only. Do not rotate the chassis
  to compensate for a camera convention.
- The sync tool copies SY205 `tracks.local_forward_axis` into catalog
  `tracked_locomotion.local_forward_axis` for Python/shadow compatibility.
  `TrackedLocomotionState` accepts optional `-Z`/`+Z` (default `-Z`); travel
  and support samples use that heading, but support reconstructs the asset
  basis without adding a half-turn. SY135 omits the field and retains exactly
  the original calculation path.
- SY205 soil proxies are measured in the imported bucket pivot frame after
  applying the mesh-child transform. Actual teeth occupy the maximum-Y band
  near [0.005,1.156,-0.990]; maximum negative Z identifies curved back geometry,
  not tooth tips. Keep cutting/opening/shell semantic regions synchronized with
  query proxies and the catalog hash. Mesh AABB containment alone is insufficient:
  also check blocker distance to actual triangles and full-range stick clearance.
- Python compatibility wraps the raw SY205 URDF in `Sy205JointModel`, including
  replay, and uses the Godot rig limits. Cylinder offsets reverse with q to
  preserve physical lengths; the legacy terrain posture is converted back
  to its asset-oriented normalized convention. SY135 keeps the original
  model and calibration objects. The raw import URDF/parity fixtures remain
  asset-space evidence, not logical runtime fixtures.
- The sync tool updates only SY205 fields, shared profile output/hash and
  associated provenance. SY135 entries in shared catalogs/profiles are immutable.

## 4. Validation / Error Matrix

| Case | Result |
|---|---|
| Shared signs with SY205 +X work axes | Reversed controls: regression must fail |
| Old SY205 signs with -X work axes | Double reversal: regression must fail |
| Profile/rig content without matching hash | Loader rejects; update through sync |
| Sync output drift | `--check` exits nonzero without writing |
| SY135 passed to the SY205 model adapter | Reject; never adapt SY135 |
| SY205 profile applied to raw Python FK | Invalid runtime boundary; use adapter |

## 5. Good / Base / Bad Cases

Good: W produces common positive arm q, SY205 -X FK moves its bucket endpoint
forward; SY135's original +X FK is unchanged. Base: neutral input/rest remains
neutral. Bad: copying SY135 signs alone and changing only expected sign tuples.

## 6. Tests Required

`equipment_command_mapper_test.gd` must exercise mapper → integrator → FK in
both directions and reach both finite work-joint endpoints. Verify actual W
extension/K raise, not just scalar signs. `test_sy205_joint_contract.py` compares
logical SY205 FK with the original asset motion, checks replay/calibration,
and proves SY135 identity and frames unchanged. Existing gateway attitude,
bucket parity and QML tests guard the physical-output chain. Human review owns
linkage appearance and approximate usability; headless results do not prove it.
`sy205_bucket_geometry_test.gd` checks imported tips/rim, mouth plane, surface
distances for blockers/cutters/plates, cavity bounds, all bucket degree samples
for stick-envelope clearance and passive linkage reachability, and attainable
dump orientation. Camera tests check heading for all five modes and both models;
compatibility locomotion tests check +Z SY205 travel/support and unchanged -Z SY135.

## 7. Wrong vs Correct

Wrong: unify profile signs, retain SY205 +X axes, then approve because profile
tests pass. Correct: pair shared logical signs with SY205 -X asset adaptation,
sync all hashes, and test the resulting physical frames and both motion consumers.
