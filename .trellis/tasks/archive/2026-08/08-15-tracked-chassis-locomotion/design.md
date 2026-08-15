# Tracked Chassis Locomotion Design

## Scene Ownership

Insert `ChassisMotionRoot` above the active excavator presentation and world-space
bucket probes. `MotionPresentation` continues to consume Python model/base and joint
poses below that root. A new fixed-step controller is the only writer of
`ChassisMotionRoot`.

## Kinematic Model

Normalize each track command to `[-1, 1]`, apply acceleration/brake/coast curves to
left/right linear speeds, then compute:

```text
forward_speed = (left_speed + right_speed) / 2
yaw_rate = (right_speed - left_speed) / track_gauge
```

Apply bounded slip based on slope and turn demand. Sample at least front/rear and
left/right support points from `TerrainState` to derive chassis elevation and a
damped pitch/roll target. Jolt raycasts can refine contact normals only when their
terrain generation/revision matches the authoritative snapshot.

## Input And Lifecycle

Track actions stay local to Godot in this child and are separate from the `Vector4`
articulation snapshot. A generation-scoped controller clears commands and velocities
on focus loss, transport replacement, model activation, world reset, or invalid
terrain transform.

## Model Contract

Extend the model catalog/descriptor with track gauge, contact length/width, support
sample offsets, maximum speed, acceleration, service brake, coast drag, pivot scale,
slope limit, and slip coefficients. Missing or invalid fields reject that model;
there is no cross-model fallback.

## Compatibility

Default-disabled rollout preserves the current stationary base. Disabling the
controller resets the local root to identity and leaves Python presentation intact.
