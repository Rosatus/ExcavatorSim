# Bucket Ground Lift Reaction Design

## Input Contract

Consume the raw pre-reaction bucket support proxy, chassis pose, authoritative
terrain surface, and operation/contact classification produced by the first two
children. Jolt may contribute a generation-matched hit normal/point.

## Support Solver

Classify support only when the rear/shell proxy moves toward the terrain, the normal
opposes motion, the bucket orientation is outside the cutting window, and raw
penetration exceeds a dead zone. Map bounded penetration to a target chassis heave
and pitch/roll around the track support polygon, then apply critically damped or
spring-damper smoothing with strict displacement/velocity/angle limits.

The solver samples geometry before support presentation is applied. The resulting
offset is composed after the locomotion terrain-following transform. This avoids a
self-amplifying loop in which lifting the machine changes the penetration input that
then changes the lift again.

## Authority Boundary

The MVP is a Godot visual/kinematic reaction, not a Jolt rigid-body force and not a
Python base pose. It cannot edit terrain or bucket payload. Aggregate contact quality
and resistance can reuse `bucket_load_feedback_v1`, but Python remains a mirror unless a
future chassis-dynamics task explicitly migrates authority.

## Degradation

If the bucket proxy, terrain transform, or generation is invalid, decay reaction to
zero. If Jolt is missing/stale, use coarse heightfield penetration. Disabling
the feature restores zero reaction without changing chassis travel or articulation.
