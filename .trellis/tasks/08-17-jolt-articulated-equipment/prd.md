# Jolt Articulated Work Equipment

## Goal

Add physical upper, boom, arm, and bucket bodies with bounded actuator-driven joints
so actual work-equipment motion and load response come from the same Jolt state as
the chassis for SY205 and SY135.

## Dependency

Requires accepted Jolt chassis/track authority from
`08-17-jolt-chassis-track-authority`.

## Requirements

- Extend each validated rig to chassis/base, upper, boom, arm, and bucket bodies.
- Implement one slew and three hinge DOFs with model-specific joint frames, axes,
  limits, damping, motor/effort caps, and self-collision policy.
- Translate the four operator axes into actuator targets; command target and actual
  position/velocity/effort remain distinct observable values.
- Provide perceptual hydraulic response: smooth startup/stopping, limit anticipation,
  load-aware slowdown, holding behavior, and bounded drift.
- Feed bucket payload mass/local COM through one bounded mass-properties adapter.
- Drive visual pivots from actual physics state. Keep SY205 passive four-bar and
  decorative cylinders as visual followers; do not create a competing closed loop.
- Rebuild the complete rig on reset/model/profile switch and reject incomplete or
  wrong-model descriptors without fallback.

## Acceptance Criteria

- [ ] Both models move each axis in the correct plane/direction with validated rest
      pose, limits, and frame parity.
- [ ] Actual joints approach commands smoothly, hold bounded poses, stop at limits,
      and slow/saturate under representative load without solver explosion.
- [ ] Chassis reacts physically to work-equipment acceleration and offset payload.
- [ ] Visual GLB and passive linkage follow actual state without writing physics.
- [ ] Long-running mixed-axis, reset, disconnect, and model-switch scenarios remain
      finite and leave no stale bodies/joints.

## Out Of Scope

- Calibrated hydraulic circuit pressure/flow, physical closed-loop four-bar,
  excavation terrain mutation, structural flexibility, or component damage.

