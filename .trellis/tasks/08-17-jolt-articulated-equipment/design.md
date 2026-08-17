# Design

## Open Articulated Chain

Use a five-body open chain: chassis/base -> upper -> boom -> arm -> bucket. Slew is
Y-axis in Godot; work-equipment hinges use their validated local axes after the
existing complete coordinate conversion. Adjacent-link collisions are disabled or
explicitly filtered; non-adjacent collisions are descriptor-controlled.

## Actuator Approximation

The actuator layer owns target rate/position shaping, acceleration/jerk limits,
effort caps, damping, limit anticipation, and load-dependent saturation. Jolt owns
actual body/joint state. No presentation node writes a joint transform.

## Visual Adaptation

`MotionPresentation` is split by profile: legacy consumes Python frames; Jolt mode
consumes physical body/joint snapshots. Shared GLB mapping, rest offsets, parity,
and model activation remain reusable. The SY205 four-bar uses actual arm/bucket
angles as input to the existing visual-only solver.

## Payload

BucketSoilState remains payload authority. A single adapter applies bounded mass and
local COM changes at safe physics-tick boundaries and records the applied payload
identity in truth state.

## Rollback

The whole articulated rig is profile-scoped. Rollback destroys it and starts a new
legacy session; partial joint fallback is forbidden.

