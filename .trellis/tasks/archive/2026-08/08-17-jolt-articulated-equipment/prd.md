# Jolt Articulated Work Equipment

## Goal

Add physical upper, boom, arm, and bucket bodies with bounded actuator-driven joints
so actual work-equipment motion and load response come from the same Jolt state as
the chassis for SY205 and SY135.

## Dependency

Requires accepted Jolt chassis/track authority from
`08-17-jolt-chassis-track-authority`. Phase 1 is archived and supplies the
single-owner `JoltChassisTrackRuntime`, versioned five-body/four-joint rig
descriptors, local authoritative truth, lifecycle gates, and terrain identity.

## Confirmed Facts

- Phase 1 creates only the chassis `RigidBody3D`; upper, boom, arm, and bucket
  truth are currently frozen presentation values with zero joint state.
- Both model descriptors already declare exactly five bodies and four joints,
  but their mass, inertia, collision, and actuator values are provisional tuning
  seeds rather than validated engineering data.
- Visual manifests contain the model-specific rest transforms and runtime axes
  needed to derive explicit Jolt body rest poses and joint anchors. The adapter
  must not consume legacy `frame_map.pivot_axis` values as runtime authority.
- The four work-equipment input axes already exist in `MotionClient`; the Jolt
  runtime does not yet consume them.
- The existing bucket-ground lift reaction is a legacy kinematic path. It cannot
  remain active once the physical bucket participates in Jolt contact.
- SY205 passive linkage is an open visual follower driven by arm/bucket pose. It
  is not a fifth physical DOF or a closed physical loop.

## Requirements

- Extend `JoltChassisTrackRuntime` into the sole owner of chassis/base, upper,
  boom, arm, and bucket bodies; do not introduce a parallel articulated-rig owner.
- Add explicit converted body rest transforms and parent/child joint anchors to
  each model descriptor. Validate unique names, exact topology, unit axes,
  ordered finite limits, frame ownership, collision policy, and catalog identity.
- Implement one slew and three hinge DOFs with model-specific anchors, axes,
  limits, damping, motor/effort caps, and self-collision policy.
- Translate the four operator axes into actuator targets; command target and actual
  position/velocity/effort remain distinct observable values.
- Provide perceptual hydraulic response: smooth startup/stopping, limit anticipation,
  load-aware slowdown, holding behavior, and bounded drift.
- Feed bucket payload mass/local COM through one bounded mass-properties adapter.
- Capture one immutable post-step physical snapshot in the runtime and use that
  same snapshot for visual following and truth serialization. Neither consumer
  may independently reconstruct physical state.
- Drive visual pivots from actual physics state. Keep SY205 passive four-bar and
  decorative cylinders as visual followers; do not create a competing closed loop.
- Disable the legacy bucket-ground lift reaction in Jolt-authoritative mode; Phase
  2 exposes physical bucket contact but does not mutate terrain.
- Rebuild the complete rig on reset, authority epoch, model, or profile switch and
  reject incomplete or wrong-model descriptors without fallback. No old input or
  contact may drive the rebuilt rig in its first tick.

## Acceptance Criteria

- [ ] Both models move each axis in the correct plane/direction with validated rest
      pose, limits, and frame parity.
- [ ] Descriptor validation rejects duplicate/missing bodies or joints, invalid
      topology, non-unit axes, unordered limits, wrong frames, and wrong identity
      before any Jolt node is created.
- [ ] Actual joints approach commands smoothly, hold bounded poses, stop at limits,
      and slow/saturate under representative load without solver explosion.
- [ ] Chassis reacts physically to work-equipment acceleration and offset payload.
- [ ] One runtime snapshot supplies all five body states and four target/actual/
      velocity/effort joint states to both presentation and truth; Phase 1 frozen
      placeholders and quality flags are removed.
- [ ] Visual GLB and passive linkage follow actual state without writing physics;
      the SY205 linkage preserves lengths, plane, branch continuity, and last-valid
      behavior without adding Jolt bodies or joints.
- [ ] Jolt-authoritative mode has no simultaneous legacy bucket-lift writer.
- [ ] Long-running mixed-axis, reset, disconnect, and model-switch scenarios remain
      finite, rotate authority identity correctly, and leave no stale bodies/joints.

## Out Of Scope

- Calibrated hydraulic circuit pressure/flow, physical closed-loop four-bar,
  excavation terrain mutation, soil transactions, support/lift tuning, structural
  flexibility, or component damage.

## Key Decisions

- Extend the Phase 1 runtime rather than composing a second physics owner.
- Derive explicit Jolt anchors from validated manifest rest transforms, then store
  them in versioned physics descriptors; do not infer anchors every runtime.
- Reset is a full rig rebuild with a new authority epoch, trading a small reset
  cost for clean solver/contact state and a simpler single-writer invariant.
- Physics snapshots are produced once after the fixed step and shared by visual
  and telemetry consumers.
- Excavation mutation remains deferred to Phase 3.
