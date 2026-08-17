# Jolt Authoritative Simulation Migration

## Goal

Evolve ExcavatorSim from a split Python-kinematic/Godot-presentation prototype
into an operator-oriented excavator simulator whose coupled real-time motion,
contact, and scene-dependent sensor truth have one authority in Godot/Jolt.
Python remains the external device, telemetry, diagnostics, and integration
gateway instead of recomputing a competing excavator pose.

## Product Value

- Track motion, bucket-ground support, machine lift/tilt, and work-equipment load
  influence the same physical state in the same fixed tick.
- Visual motion and exported telemetry describe the same machine state.
- Future cab controls and external consumers can use a stable Python gateway
  without placing a network round trip inside the contact loop.

## Confirmed Facts

- The current Python `Simulator` integrates four independent joint channels with
  position, velocity, and acceleration limits; Pinocchio currently supplies FK,
  not contact or rigid-body dynamics.
- The current Godot client has no excavator `RigidBody3D`/joint rig. Jolt is used
  only by optional derived terrain collision queries and visual soil clods.
- `TerrainState` and `BucketSoilState` are already the Godot-first logical owners
  of terrain layers and bucket inventory. Terrain3D, colliders, meshes, and
  particles are derivatives.
- Available masses, inertias, centers of mass, and collision proxies are
  provisional estimates. They are seed values for tuning, not validated physics
  assets.
- Deterministic replay equivalence is not a product requirement for this
  migration. Stable lifecycle, bounded behavior, and observable state identity
  remain required.

## Requirements

### R1. One Coupled Runtime Authority

In the new product profile, one Godot fixed-step simulation core must own chassis
pose/velocity, actual joint state, actuator targets, contact results, and physics
tick identity. No Python snapshot or presentation script may overwrite those
transforms.

### R2. Explicit Migration Profiles

The existing Python-kinematic path must remain available as an explicit legacy
profile until cutover acceptance. Shadow and authoritative Jolt modes must be
versioned and selected deliberately; silent cross-profile fallback is forbidden.

### R3. Separate Physics And Visual Assets

SY205 and SY135 require model-specific physics descriptors for bodies, joint
frames, limits, collision shapes, mass properties, contact materials, and
actuator tuning. Visual GLBs remain presentation skins and may not be reused as
dynamic concave collision meshes.

### R4. Practical Excavator Dynamics

The simulator must prioritize convincing operator response over engineering-grade
hydraulic analysis. Tracks use bounded distributed traction rather than individual
track links. Work-equipment commands use a tunable actuator/servo approximation
with velocity, acceleration, effort, damping, and joint limits.

### R5. Unified Terrain And Bucket Interaction

`TerrainState` and `BucketSoilState` remain the semantic owners of terrain volume
and bucket payload. Jolt contact manifolds may produce resistance and body
reaction, but terrain mutation must pass through an identity-tagged soil
transaction. Per-grain authoritative soil is out of scope.

### R6. Authoritative State And Sensor Export

Godot must publish versioned truth snapshots containing authority epoch, physics
tick, monotonic sample time, model/rig identity, terrain identity, body and joint
state, contact summaries, track state, and bucket payload. Initial sensor products
are joint encoders, four IMUs, GNSS, track/chassis contact, and payload/load
observations. Python validates, records, diagnoses, and exports these samples but
does not recalculate authoritative motion.

### R7. Input Safety And Lifecycle

Local and external controls must retain monotonic sequence handling, focus/disconnect
disarm, zero-input arming, leases/timeouts, bounded queues, idempotent lifecycle
commands, model-switch rebuilds, and explicit reset epochs.

### R8. Coordinate And Clock Contracts

Godot physics remains right-handed Y-up internally. External truth and sensor
messages use one declared canonical right-handed Z-up frame, converted once at the
publisher boundary, with explicit monotonic timestamps and calibration identity.

### R9. Operability And Rollback

Every phase needs headless contract tests, Godot MCP live evidence where rendering
or contact matters, bounded performance metrics, and an explicit rollback to the
last accepted profile without mixed authority state.

## Acceptance Criteria

- [ ] The selected Jolt profile has exactly one writer for chassis and articulated
      body state, and Python does not publish a competing pose.
- [ ] Independent track commands produce stable straight, arc, pivot, braking,
      slope, and obstacle response from physical chassis state.
- [ ] Slew, boom, arm, and bucket actual motion comes from bounded physical joints
      and actuator targets for both SY205 and SY135.
- [ ] Bucket support and cutting contacts produce consistent chassis reaction,
      work-equipment resistance, terrain edits, and bucket payload without volume
      double counting or self-feedback.
- [ ] Exported state and initial sensor samples share one authority epoch/tick/time
      model and survive Python validation without pose reconstruction.
- [ ] Reset, disconnect, model switch, stale terrain collider, invalid rig, and
      feature/profile switch have tested fail-closed or explicit rollback behavior.
- [ ] The final product profile defaults to Jolt authority only after all child
      exit gates pass; the legacy Python profile remains explicit until a separate
      removal decision.

## Out Of Scope

- Engineering-certified hydraulic pressure/flow simulation or production HIL
  fidelity.
- Individual physical track links, granular per-particle soil authority, fracture,
  structural damage, rollover injury modeling, or multiplayer/network prediction.
- Camera, LiDAR, radar, or production CAN/USB device drivers in this roadmap.
- Bit-identical deterministic replay of Jolt contact history.

## Key Decisions

- Long-term product motion authority moves to Godot/Jolt.
- Python becomes a gateway and analysis service, not a second physics solver.
- Pinocchio remains useful for offline/model parity, frame validation, and future
  robotics tooling, but is not the Jolt-profile runtime pose authority.
- The migration is incremental and profile-gated; there is never a dual-writer
  runtime mode.

