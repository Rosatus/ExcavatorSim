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
- All assists share one hotkey: T opens the assist menu (machine frozen
  while open), W/S rides the arm axis to navigate, Enter activates the
  highlighted entry, T/Esc closes. Each entry maps to that assist's own
  advance/toggle semantics — slope's row runs the same
  off->preview->active->off state machine, and inside preview T/Enter is
  still the confirm shortcut and Esc the cancel. Mutual exclusion stays
  the pipeline's terminal_surface group, so picking a different assist
  while one is active switches cleanly.
- The `bucket_level` assist stage (`jolt_authoritative` only) works downstream
  of the mapper in joint command space and never changes logical signs: while
  enabled it owns boom/arm/bucket outright — operator boom (I/K) and bucket
  (J/L) input is ignored — and the arm channel becomes bucket-edge horizontal
  translation (W pushes out, S pulls in) with latched height/pitch setpoints.
  Swing is never written by the stage. If any required joint cannot move in
  the solved direction the whole tick outputs zero — but the response depends
  on *why* it is blocked. A kinematic bound (position limit, faded ceiling,
  braking-distance law) is `level_assist_infeasible`: the setpoints relatch
  so reversing the stick is always reachable. Pure residual momentum — the
  joint still carries velocity opposite the solve and cannot cross zero in
  one tick — is `level_assist_reversing`: the same zero output brakes it, but
  setpoints are held so feedback pulls the coast excursion back instead of
  ratifying it. Neither state latches; every tick is re-judged.
- The assist tracks constraints by *integrator inversion*, not blind rate
  commands: `EquipmentKinematicsContext` mirrors `propose_step`'s cut/limit
  multipliers and the accel/jerk `move_toward` chain, and the stage scales
  the solved joint triplet uniformly into each joint's reachable velocity
  interval. Any change to `KinematicArticulationState.propose_step`
  execution semantics must be mirrored there or tracking silently degrades.
  Chassis linear/angular velocity feeds forward as a transport term so the
  held pose is ground-relative, not chassis-relative.
- Two additional shapings keep limit/singular transitions smooth. A
  braking-law bound (`v <= k*sqrt(2*a_max*d)`) makes approach velocity decay
  to ~0 at any joint limit, so the infeasible tick arrives with no residual
  coast. When the DLS solve inflates joint rates far past task need (deep
  retract is ill-conditioned for horizontal translation), per-joint ceilings
  shrink proportionally — the machine creeps through the degenerate zone
  instead of charging a kinematic toggle point at speed. Held channels also
  subtract the joints' current task velocity (rate damping), otherwise the
  P correction rings through the forced reversals as a ~1 Hz limit cycle.
- The `slope_grade` assist stage is the second terminal-surface guide and
  shares `bucket_level`'s whole control law — the solve/integrator mechanics
  live in `AssistRateSolver`, the per-tick law in `GuidedProfileStage`, and
  each stage only declares its target surface. Its differences are declared,
  not reimplemented: `writes_mask` adds the swing channel (held at zero so
  the slew cannot rotate the profile plane relative to the chassis), the
  tracked surface is a confirmed `SlopeProfile` (piecewise: flat bench at
  toe height for `s < toe_s`, `tan(angle)` grade beyond — positive angles
  rise away from the machine), and the horizontal task axis is the
  profile's anchor axis. The profile is NOT frozen: `capture_anchor`
  records the origin's (s,t) offset from the swing pivot once, and the
  stage's `step` override calls `reanchor` every enabled tick with the
  live upper forward + swing pivot — the surface rides with the machine
  so the undercarriage can drive or yaw along the slope and grading
  continues on the current heading. The toe knee is C1-rounded by
  `knee_blend_m` (assist_profiles.json; a smooth-relu quadratic blend,
  max deviation `grade*w/4`) so the grade feedforward ramps across the
  toe instead of stepping and kicking the tooth off the surface through
  its own momentum. Its flags are namespaced
  `slope_assist_infeasible` / `slope_assist_reversing` with identical block
  semantics. Both stages sit in exclusive group `terminal_surface` —
  enabling one disables the other — and `slope_grade` refuses to enable
  without an injected profile (`apply_params`), which is consumed only on a
  real enabled->disabled transition.
- Slope setup is a controller-side state machine (`SLOPE_MODE_*`): preview
  freezes tracks and equipment and reroutes W/S to toe distance and A/D to
  slope angle, `update_slope_preview` sweeps the reachable band via
  `KinematicArticulationState.frames_for_positions` and samples terrain
  through the same `TerrainState` the dig system reads (physics raycast
  outside the grid), and confirm injects exactly the previewed profile
  into the stage — after which it follows the live heading via the
  per-tick re-anchor. The toe height is sampled terrain at the junction
  point, so the bench always starts at real ground level.
- Slope cut preview presentation is two layered views, no wedge mesh: the
  voxel soil shader (`voxel_soil_bounded.gdshader`) takes analytic
  `cut_*` uniforms (`SlopeCutPreview.preview_uniforms` packs them) and
  blinks the real terrain surface above the target profile between tinted
  and discarded — the mark self-erases as digging proceeds; the ghost
  ribbon (`SlopeCutPreviewVisual`) draws the finished-surface skin plus
  no-depth edge lines (bench borders, toe cross-line, grade borders) —
  but only while a graded section is inside the band: a flat ribbon's
  borders lie on the ground and read as a stray line from under the
  machine, so level/flat cases draw the skin alone; and `SlopeSideView`
  renders the cabin-plane
  2D guidance panel (links, terrain strip, target line, cut fill, tooth
  offset) from the top-level `assist_view` status, shown in preview and
  active modes only. `VoxelWorkZone.set_cut_preview` is the duck-typed sink
  the runtime discovers beside TerrainWorld — presentation only, never
  voxel data. Refresh economics: the ribbon's vertices are profile-local
  so `follow_profile` reposes it with one transform write, the soil mark
  chases with ~10 uniform writes, and the side-view snapshot is a context
  build plus a bilinear centerline strip — all cheap enough to run every
  physics tick while active. The genuinely expensive FK reach sweep is
  never on the per-tick path: `SlopeCutPreview.compute` accepts a
  pre-swept `swept_band`, and both consumers cache it — the preview keys
  its band on the profile parameters plus the cutting edge (re-swept only
  when the operator adjusts, at capped step count), while the level view
  keys on the latched height and edge with a 5 s drift fallback, since the
  flat profile's live-axis tracking makes its band nearly invariant in
  profile space. An unkeyed 24^3 sweep every 0.15 s refresh was a
  ~100 ms periodic hitch — do not reintroduce it.
- Bucket-level assist reuses the same guidance channel without any blink:
  `JoltChassisTrackRuntime.level_view_snapshot` builds a degenerate
  zero-grade `SlopeProfile` at the stage's latched `height_ref_m`, reuses
  the cached `reach_band` envelope, and publishes `assist_view` with
  `mode: "level"`; the controller also shows the flat target ribbon while
  level grading is live. `assist_view` is a single top-level status slot —
  whichever terminal-surface assist is live fills it (slope modes take
  priority over level).
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
- SY80U adds a fifth mechanical DOF — the offset-boom yaw (偏摆) on
  `PIVOT_BOOM_SWING` between `PIVOT_SLEW` and `PIVOT_BOOM_BASE`. It is a
  Godot-presentation-local axis, not an authority joint: the Python `Vector4`
  stays swing/boom/arm/bucket, the URDF and parity fixture fold the swing
  bracket offset into a fixed `boom_swing_link`, and `MotionPresentation`
  owns the angle. The manifest declares it under `local_articulation.axes`
  (`axis_id`, `node_path`, `parent_frame`, `runtime_axis`, `local_position`,
  `min_degrees`/`max_degrees`, `max_rate_degrees_per_second`,
  `input.positive_action`/`negative_action`); the affected frame contract
  sets `via_local_axis` to the axis id while keeping `parent_frame` as the
  authority parent so the kinematic delta math is unchanged. Keys are
  `operator_boom_swing_left` (E → +Y, tip moves machine left) and
  `operator_boom_swing_right` (U → −Y), limits +65°/−51°, rate 45°/s. Local
  axes are declared in `EquipmentCommandMapper.LOCAL_INPUT_ACTIONS` (keys
  only — no gamepad row, the binding test requires one joy event per
  `INPUT_ACTIONS` entry), registered by `MotionClient`, gated through
  `ProductSession.get_local_axis_input`, and integrated in
  `MotionPresentation._physics_process` with reset on rest-pose restore,
  pose clear, and model switch. On gamepad they ride the pad layer:
  `AttachmentInputMapper.LOCAL_PAD_LAYERS` maps `boom_swing` to D-pad-Left +
  right-stick X and `boom_fold` to D-pad-Up + right-stick Y, masking the
  borrowed base axis while the modifier is held; `MotionPresentation`
  registers the active model's axis ids and clears them on model switch.
  Soil cutting and bucket fill follow the
  visual node transforms, so the offset is already reflected in digging.

## 4. Validation / Error Matrix

SY155W is a wheeled two-piece boom, with a source-specific authority neutral
`[58, -47, -99, 97]` degrees (source `Work_Cycle` frame 91). Do not apply the
single-boom SY135 zero convention to its hydraulic geometry. `tools/import_sy155w.py`
cross-checks independent source equations, then builds its own rig/URDF/fixture.
The outer-boom fold sits between boom and arm as a local +X axis (`boom_fold`):
E folds, U unfolds, relative limits [-10,+10] degrees. Source demonstration ranges
are provisional, not manufacturer hard stops. `PassiveHydraulics` updates six
cylinder pairs and twelve multi-target hoses after driven poses; it never accepts
operator commands or writes authority frames. Its source four-bar is solved before
cylinder endpoints, with atomic passive-pose retention on invalid/unreachable pins.

The model catalog may declare `default_attachment` and
`attachment_bucket_limit_offsets_deg`. SY155W defaults to XTR13+GB12 and sets
`xtr13: 0`, because the older +130-degree XTR13 offset makes its four-bar unreachable.
Other models keep that legacy offset. Do not enlarge the SY155W authority bucket
limits to compensate for attachment orientation. Its absent native bucket is omitted
from selection. Host physics soil proxies include the neutral XTR13 socket offset;
active fill/cutting use the existing mounted GB12 frame and contract.
`AttachmentRig` also mounts outside `ProductSession` request paths (model-activation
defaults, cross-model remounts); the session resyncs `active_coupler_id`/`active_tool_id`
from every `attachment_activated` emission and once at startup — the menu selectors
guard on the session pair, so a stale pair silently no-ops the matching option.

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
extension/K raise, not just scalar signs. `bucket_level_assist_test.gd` covers
the task-space reinterpretation on both models: held height/pitch during arm
drive, boom/bucket input fully ignored while enabled, neutral gating,
passthrough when disabled, bounded behavior at limits with no single-tick
pose step above 4 mm / 4 mrad, and motion resuming on input reversal. `test_sy205_joint_contract.py` compares
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
