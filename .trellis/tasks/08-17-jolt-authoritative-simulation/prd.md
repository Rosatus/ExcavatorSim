# Hybrid Jolt Authoritative Simulation Migration

## Goal

Evolve ExcavatorSim into an operator-oriented simulator with one Godot fixed-tick
authority composed from a dynamic Jolt chassis, a bounded kinematic work-equipment
state machine, bucket-only collision queries, and the existing logical terrain and
payload owners. Python remains the external device, telemetry, diagnostics, and
integration gateway instead of recomputing a competing excavator pose.

## Product Value

- Independent tracks, terrain support, bucket-ground support, machine lift/tilt,
  and excavation share one local fixed-tick identity.
- Slew, boom, arm, and bucket motion is smooth, load-aware, and easy to tune without
  requiring hydraulic circuits or a fragile articulated rigid-body solver.
- Visual motion, terrain edits, bucket fill, chassis reaction, and exported
  telemetry describe the same accepted machine state.
- Future cab controls and external consumers can use a stable Python gateway
  without placing a network round trip inside the contact loop.

## Confirmed Facts

- The Python `Simulator` already demonstrates a maintainable four-channel motion
  model with position, velocity, and acceleration limits; Pinocchio supplies FK,
  not contact or rigid-body dynamics.
- Phase 1 established a profile-gated dynamic Jolt chassis and bounded crawler
  traction for both models.
- Phase 2 established and validated a five-body/four-joint Jolt prototype. It proved
  the authority, lifecycle, visual-following, and truth seams, but also made mass,
  inertia, joint-anchor, motor, and solver tuning part of the permanent maintenance
  surface.
- The approved product direction supersedes that complete articulated dynamics
  target: only the chassis remains a dynamic excavator body. Work-equipment joint
  state is kinematic, and only model-specific bucket proxies participate in terrain
  interaction.
- `TerrainState` and `BucketSoilState` remain the semantic owners of terrain layers
  and bucket inventory. Terrain3D, colliders, meshes, particles, and collision
  queries are derivatives.
- Deterministic replay equivalence is not a product requirement. Stable lifecycle,
  bounded behavior, and observable state identity remain required.

## Requirements

### R1. One Hybrid Fixed-Tick Authority

In the new product profile, one Godot fixed-tick simulation core must own the
dynamic chassis state, kinematic work-equipment state, accepted bucket contact
summary, soil transaction identity, and physics tick. No Python snapshot or
presentation script may overwrite those states.

### R2. Explicit Migration Profiles

The existing Python-kinematic path must remain available as an explicit legacy
profile until cutover acceptance. Shadow and authoritative modes must be versioned
and selected deliberately; silent cross-profile fallback is forbidden.

### R3. Separate Dynamic, Kinematic, Collision, And Visual Contracts

SY205 and SY135 require model-specific descriptors for the dynamic chassis and
tracks, bounded kinematic joints and FK frames, bucket cutting/shell/support
proxies, terrain collision layers, and tuning. Visual GLBs remain presentation
skins and may not be reused as dynamic concave collision meshes.

### R4. Practical Work-Equipment Motion

Slew, boom, arm, and bucket commands must use direct fixed-step position/velocity
integration with joint limits, maximum velocity, acceleration, braking, and
optional jerk shaping. Payload may tune motion rates and stopping response. No
hydraulic pressure/flow circuit, physics joint motor, or link mass/inertia solver
is required for the product path.

### R5. Selective Jolt Contact And Chassis Reaction

Jolt owns the dynamic chassis and track/terrain reaction. Intermediate work-
equipment links do not collide with terrain. Bucket cutting, shell, cavity, and
rear-support proxies follow accepted FK, use continuous bounded sweep/contact
queries, and never act as an uncontrolled infinite-mass pusher. Eligible support
evidence is converted once into a capped equivalent chassis force/torque for a
later physics step.

### R6. Unified Terrain And Bucket Interaction

`TerrainState` and `BucketSoilState` remain the semantic owners of terrain volume
and bucket payload. Contact/sweep evidence may produce kinematic resistance,
chassis reaction, and one identity-tagged soil transaction. Per-grain authoritative
soil is out of scope.

### R7. Authoritative State And Sensor Export

Godot must publish versioned truth containing authority epoch, physics tick,
monotonic sample time, model/rig identity, terrain identity, dynamic chassis state,
kinematic joint/frame state, bucket contact summary, track state, and payload.
Initial sensor products are joint encoders, declared-frame IMUs, GNSS,
track/chassis contact, and payload/load observations. Python validates, records,
diagnoses, and exports these samples without reconstructing product motion.

### R8. Input Safety And Lifecycle

Local and external controls must retain monotonic sequence handling,
focus/disconnect disarm, zero-input arming, leases/timeouts, bounded queues,
idempotent lifecycle commands, model-switch rebuilds, and explicit reset epochs.

### R9. Coordinate And Clock Contracts

Godot physics remains right-handed Y-up internally. External truth and sensor
messages use one declared canonical right-handed Z-up frame, converted once at the
publisher boundary, with explicit monotonic timestamps and calibration identity.

### R10. Operability And Rollback

Every phase needs headless contract tests, Godot MCP live evidence where rendering
or contact matters, bounded performance metrics, and an explicit rollback to the
last accepted profile without mixed authority state.

## Acceptance Criteria

- [ ] The selected authoritative profile has exactly one writer for dynamic
      chassis state and exactly one writer for kinematic work-equipment state;
      Python publishes no competing pose.
- [ ] Independent track commands produce stable straight, arc, pivot, braking,
      slope, and obstacle response from the dynamic chassis.
- [ ] Slew, boom, arm, and bucket motion is bounded by position, velocity,
      acceleration, braking, and optional jerk limits for SY205 and SY135 without
      runtime articulated Jolt bodies or physics joint motors.
- [ ] Bucket support and cutting evidence produces consistent capped chassis
      reaction, kinematic resistance, terrain edits, and payload updates without
      volume double counting, infinite-mass pushing, or self-feedback.
- [ ] Exported state and initial sensor samples share one authority epoch/tick/time
      model and survive Python validation without pose reconstruction.
- [ ] Reset, disconnect, model switch, stale terrain collider, invalid descriptor,
      and feature/profile switch have tested fail-closed or explicit rollback
      behavior.
- [ ] The final product profile defaults to the hybrid Godot authority only after
      all child exit gates pass; the legacy Python profile remains explicit until
      a separate removal decision.

## Out Of Scope

- Dynamic upper/boom/arm/bucket rigid bodies, physics joint motors, and automatic
  link-to-chassis momentum transfer in the product path.
- Engineering-certified hydraulics, pressure/flow simulation, or production HIL
  fidelity.
- Individual physical track links, granular per-particle soil authority, fracture,
  structural damage, rollover injury modeling, or multiplayer/network prediction.
- Camera, LiDAR, radar, or production CAN/USB device drivers in this roadmap.
- Bit-identical deterministic replay of Jolt contact history.

## Key Decisions

- Jolt is the chassis, track, and terrain-contact authority, not the work-equipment
  trajectory solver.
- A Godot kinematic state machine owns slew/boom/arm/bucket state and FK in the
  authoritative profile.
- Bucket contact is query-driven and converted to bounded resistance, soil edits,
  and equivalent chassis wrench; it is not a second pose writer.
- The completed five-body Phase 2 implementation remains a validated prototype and
  rollback/reference baseline, but is superseded as the product architecture.
- Python remains a gateway and analysis service, not a second motion solver.
- Pinocchio remains useful for model parity, frame validation, and future robotics
  tooling, but is not the authoritative-profile runtime pose writer.
- Migration remains incremental and profile-gated; there is never a dual-writer
  runtime mode.
