# Technical Design

## Target Runtime

```text
local controls -----------------------------+
                                            v
external controls -> Python gateway -> Godot CommandReducer
                                            |
                                            v
                              Godot SimulationCore fixed tick
                              |  actuator targets / limits
                              |  Jolt bodies, joints, contacts
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

The physics tick is the only mutation clock for coupled motion. Rendering may
interpolate accepted physics snapshots. Network cadence, telemetry recording,
Terrain3D refresh, and sensor output rates do not advance simulation time.

## Godot Components

### SimulationCore

- Owns `authority_mode`, authority epoch, physics tick, lifecycle, model rig, and
  command reducer.
- Applies command targets before stepping physics and captures immutable truth
  immediately after the step.
- Rejects stale model/terrain/command identity and publishes explicit quality.

### PhysicsRig

- Separate project-owned scene/resource graph, never inferred from visual mesh.
- Bodies: chassis/base, upper structure, boom, arm, bucket.
- Joints: slew plus three work-equipment hinges. The first SY205 four-bar remains
  a presentation follower driven by actual bucket angle.
- Collision: model-specific compound convex primitives with collision layers and
  adjacent-link self-collision policy.
- Parameters carry provenance labels and a rig schema/hash.

### TrackForceModel

- Uses several support/contact points per side, not individual track links.
- Converts left/right commands into capped longitudinal traction, braking, and
  differential yaw using normal load and slip estimates.
- Exposes command, actual ground speed, slip, contact count, and saturation.

### ActuatorModel

- Converts operator commands into target joint rate/position and bounded effort.
- Applies limit anticipation, acceleration/jerk smoothing, damping, and load-aware
  saturation. It is explicitly a perceptual hydraulic approximation.

### TerrainContactBridge

- Consumes a collider snapshot with exact `(world_generation, terrain_revision)`.
- Collects bucket/chassis contacts during the tick, then emits bounded immutable
  contact summaries.
- A separate soil transaction classifier decides cut/carry/spill/dump and commits
  TerrainState/BucketSoilState changes once at a tick boundary.
- Collider replacement is transactional: prepare next revision, switch at a safe
  boundary, invalidate old contacts, and expose the applied revision.

## State Contract

The new contract is versioned separately from `godot-pinocchio-v3`. Its minimum
truth envelope contains:

- protocol/state/rig/model/calibration versions;
- session ID, authority epoch, physics tick, source command sequence;
- monotonic simulation/sample time;
- canonical coordinate frame and units;
- terrain world generation and revision;
- body pose, linear velocity, angular velocity;
- joint target, position, velocity, and bounded effort/load;
- track command/speed/slip/contact;
- bucket payload mass, local center of mass, fill ratio;
- bounded contact summaries and quality flags.

Godot uses Y-up internally. The publisher performs the complete rigid-transform,
vector, angular-vector, and gravity conversion once to canonical right-handed
Z-up. Python validates and stores this normalized external form.

## Sensor Contract

Sensor samples reference a truth `(authority_epoch, physics_tick)` and include
sensor ID, frame ID, calibration version, sample sequence/time, rate, validity,
quality, and uncertainty/noise configuration.

- Joint encoders: actual joint positions/velocities.
- IMUs: pose orientation, angular velocity, and specific force derived from body
  motion at each declared sensor frame, then noise/bias applied.
- GNSS: canonical world position/velocity with configurable noise and validity.
- Track/contact: side speeds, slip, contact state, forces or bounded proxies.
- Payload/load: mass, local center of mass, fill, and resistance.

Camera/LiDAR/radar are deferred because they require separate rendering and data
bandwidth contracts.

## Python Gateway

- Keeps aiohttp/WebSocket lifecycle, schema validation, rate limiting, diagnostics,
  recording/export, and future hardware adapter seams.
- External command ingress is validated in Python and revalidated by Godot's
  command reducer; command leases expire in Godot.
- Does not call the current `Simulator.step()` or Pinocchio FK to reconstruct the
  Jolt-profile pose.
- Legacy profiles remain isolated and continue using their existing runtime.

## Migration Modes

| Mode | Pose writer | Egress | Purpose |
|---|---|---|---|
| `python_kinematic` | Python -> MotionPresentation | Existing v3 | Compatibility |
| `jolt_shadow` | Existing product path | New truth diagnostics only | Contract/performance validation |
| `jolt_authoritative` | Godot SimulationCore/Jolt | New truth + sensors | Target product |

Changing modes or models requires a lifecycle rebuild and new authority epoch.
There is no hot handoff of transforms or solver warm-start state.

## Rollback

Before final cutover, rollback selects `python_kinematic`, rebuilds the current
session, and reloads the corresponding visual/local-world state. A Jolt failure
never causes frame-by-frame fallback to Python because that would reintroduce two
authorities. Terrain and bucket data are preserved only when their identity and
schema are compatible; otherwise the transition requires an explicit world reset.

