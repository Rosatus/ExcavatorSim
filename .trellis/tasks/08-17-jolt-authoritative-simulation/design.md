# Technical Design

## Target Runtime

```text
local controls ------------------------------+
                                             v
external controls -> Python gateway -> Godot CommandReducer
                                             |
                                             v
                               Godot HybridSimulationCore
                               |  KinematicArticulationState
                               |  FK + bucket proxy sweep
                               |  Jolt chassis/tracks
                               |  bounded chassis wrench adapter
                               |  TerrainState soil transaction
                               |  BucketSoilState payload adapter
                               +--------------+---------------+
                                              |
                          +-------------------+-------------------+
                          v                                       v
               MotionPresentation/GLB                 State/Sensor Publisher
                                                                  |
                                                                  v
                                                    Python gateway/record/export
```

The fixed tick is the only mutation clock for coupled motion. Rendering may
interpolate accepted snapshots. Network cadence, telemetry recording, Terrain3D
refresh, and sensor output rates do not advance simulation time.

## Godot Components

### HybridSimulationCore

- Owns `authority_mode`, authority epoch, physics tick, lifecycle, selected model
  contracts, command reducer, and the accepted hybrid snapshot.
- Samples commands once, advances kinematic articulation, evaluates bucket sweep
  and contact, queues bounded chassis feedback, steps/observes the Jolt chassis,
  commits at most one soil transaction, and captures immutable truth.
- Rejects stale model/terrain/command identities and publishes explicit quality.

### DynamicChassisRig

- Owns one excavator chassis `RigidBody3D`, simplified compound/convex collision,
  and left/right traction probes.
- Uses several support/contact points per side rather than individual track links.
- Converts track commands into capped traction, braking, and differential yaw.
- Accepts only bounded external wrench requests carrying authority epoch, source
  physics tick, eligible apply tick, expiry tick, model, and terrain identity.
- Does not own slew, boom, arm, bucket, or their visual frame transforms.

### KinematicArticulationState

- Owns four joint positions, velocities, accelerations, command identity, and
  accepted frame transforms for slew, boom, arm, and bucket.
- Applies velocity, acceleration, braking, optional jerk, limit anticipation, and
  load-dependent tuning directly in fixed-step state space.
- Computes model-specific FK from validated rest frames and axes. Pinocchio parity
  fixtures remain an oracle, not a runtime dependency.
- Produces one immutable articulation snapshot consumed by presentation, bucket
  collision, truth, and sensors.
- SY205's passive four-bar remains a visual follower after accepted arm/bucket FK.

### BucketContactBridge

- Owns model-specific cutting-edge, opening/cavity, shell, and rear-support proxy
  shapes; intermediate links have no terrain collision proxies.
- Sweeps previous accepted transforms to candidate bucket proxy transforms against
  the current derived terrain collider. A pre-implementation Godot 4.7.1/Jolt spike chooses
  the exact query API and verifies contact point, normal, travel fraction, collider
  identity, and teardown behavior.
- Clamps or scales an inadmissible kinematic step instead of moving a forced
  infinite-mass bucket through terrain.
- Emits bounded immutable contact summaries. It never writes chassis transform,
  joint state, TerrainState, or BucketSoilState directly.

### ChassisReactionAdapter

- Converts accepted rear/shell support evidence into a capped equivalent force and
  torque applied to the dynamic chassis on a later safe physics step.
- Cutting-edge evidence produces kinematic resistance and soil classification, not
  the support response.
- Bounds contact lifetime, penetration recovery, heave, pitch/roll torque, rate of
  change, and loss-of-contact decay.
- Replaces the legacy transform-offset lift in authoritative mode; the two paths
  may never run together.

### TerrainContactAndSoilBridge

- Consumes a collider snapshot with exact `(world_generation, terrain_revision)`.
- Classifies accepted bucket sweep/contact as cut, carry, spill, dump, or support.
- Commits TerrainState/BucketSoilState changes exactly once through the existing
  logical transaction owner.
- Rebuilds colliders transactionally: prepare the next revision, switch at a safe
  boundary, invalidate old contacts, and expose the applied revision.
- Treats payload mass/fill as logical truth. Payload changes tune kinematic motion;
  they do not create a dynamic bucket body or claim rigid-body COM transfer.

## Fixed-Tick Order

```text
1. Validate authority/model/terrain/command identity.
2. Sample track and work-equipment commands once.
3. Advance a candidate kinematic articulation step.
4. Sweep bucket proxies from previous to candidate FK.
5. Accept, scale, or reject the candidate step and classify contact.
6. Queue bounded support wrench for the dynamic chassis.
7. Apply current-tick track forces and previously accepted wrench to Jolt chassis.
8. Commit at most one logical soil/payload transaction.
9. Capture one hybrid post-step snapshot for presentation, truth, and sensors.
```

An implementation may adapt callback ordering to Godot/Jolt constraints, but it
must preserve the explicit one-tick handoff and may not use same-tick recursive
contact -> terrain rebuild -> contact feedback.

## State Contract

The versioned truth envelope contains:

- protocol/state/model/chassis-rig/articulation/calibration versions;
- session ID, authority epoch, physics tick, source command sequence;
- monotonic simulation/sample time;
- canonical coordinate frame and units;
- terrain world generation and applied collider revision;
- dynamic chassis pose, linear velocity, and angular velocity;
- kinematic joint target, position, velocity, acceleration, and quality;
- accepted FK frame transforms and derived frame velocities where required;
- track command/speed/slip/contact;
- bucket payload mass, local COM, fill ratio, and motion-load factor;
- bucket contact/sweep summaries, queued and applied chassis wrench identities,
  and quality flags.

The schema must distinguish dynamic body state from kinematic frame state. It must
not preserve five-body fields by relabelling FK frames as Jolt rigid bodies.

Godot uses Y-up internally. The publisher performs the complete rigid-transform,
vector, angular-vector, and gravity conversion once to canonical right-handed
Z-up. Python validates and stores this normalized external form.

## Sensor Contract

Sensor samples reference a truth `(authority_epoch, physics_tick)` and include
sensor ID, frame ID, calibration version, sample sequence/time, rate, validity,
quality, and uncertainty/noise configuration.

- Joint encoders: accepted kinematic joint positions/velocities.
- IMUs: chassis dynamics plus fixed-tick derivatives of accepted kinematic sensor
  frames, with quality distinguishing measured physics from derived kinematics.
- GNSS: canonical chassis/world position and velocity.
- Track/contact: side speeds, slip, contact state, and bounded force proxies.
- Payload/load: mass, fill, motion-load factor, contact resistance, and applied
  chassis wrench.

Camera/LiDAR/radar remain deferred because they need separate rendering and data
bandwidth contracts.

## Python Gateway

- Keeps aiohttp/WebSocket lifecycle, schema validation, rate limiting,
  diagnostics, recording/export, and future hardware adapter seams.
- External command ingress is validated in Python and revalidated by Godot's
  command reducer; command leases expire in Godot.
- Does not call the current `Simulator.step()` or Pinocchio FK to reconstruct the
  authoritative-profile pose.
- Legacy profiles remain isolated and continue using their existing runtime.

## Migration Modes

| Mode | Pose writer | Egress | Purpose |
|---|---|---|---|
| `python_kinematic` | Python -> MotionPresentation | Existing v3 | Compatibility |
| `jolt_shadow` | Existing product path | New truth diagnostics only | Contract/performance validation |
| `jolt_authoritative` | Godot dynamic chassis + kinematic articulation | Hybrid truth + sensors | Target product |

Changing modes or models requires a lifecycle rebuild and new authority epoch.
There is no hot handoff of transforms or solver warm-start state.

## Phase 2 Transition

The archived five-body/four-joint implementation remains evidence for model-frame
parity, lifecycle teardown, track authority, snapshot sharing, and Jolt API behavior.
Phase 3 must remove its product dependency on dynamic upper/boom/arm/bucket bodies,
physics hinge motors, dynamic bucket payload mass, and five-body truth counts while
preserving reusable chassis, command, identity, presentation, and test seams.

## Rollback

Before final cutover, rollback selects `python_kinematic`, rebuilds the session,
and reloads the visual/local-world state. A hybrid failure never causes
frame-by-frame fallback to Python or re-enables the archived five-body runtime.
Terrain and bucket data are preserved only when identity/schema is compatible;
otherwise transition requires an explicit world reset.
