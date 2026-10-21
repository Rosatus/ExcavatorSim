# Design

## Open Articulated Chain

Use a five-body open chain: chassis/base -> upper -> boom -> arm -> bucket. Slew is
Y-axis in Godot; work-equipment hinges use their validated local axes after the
existing complete coordinate conversion. Adjacent-link collisions are disabled or
explicitly filtered; non-adjacent collisions are descriptor-controlled.

`JoltChassisTrackRuntime` evolves from its Phase 1 single-body implementation into
the registry and lifecycle owner for the complete chain. It creates and destroys
all bodies, joints, collision shapes, actuators, and payload coupling together.
The controller remains the profile/lifecycle adapter and does not own a second rig.

Each versioned model descriptor carries explicit Godot-local body rest transforms
and parent/child joint anchors derived offline from the validated visual manifest.
Loading rejects a descriptor unless names are unique, topology is exact, axes are
unit length, limits are finite and ordered, anchors bind the declared frames, and
catalog model/rig identity matches.

## Actuator Approximation

The actuator layer owns target rate/position shaping, acceleration/jerk limits,
effort caps, damping, limit anticipation, and load-dependent saturation. Jolt owns
actual body/joint state. No presentation node writes a joint transform.

The controller samples the existing four operator axes once per fixed tick and
passes the accepted command sequence into the runtime. The runtime shapes targets,
applies effort before the physics step, and captures actual state after the step.
The first tick after rebuild remains disarmed until lifecycle identity and neutral
input are accepted.

## Physical Snapshot

After each Jolt fixed step, the runtime emits one immutable snapshot containing the
five body transforms/velocities, four joint targets/positions/velocities/efforts,
contacts, payload identity, rig/model identity, authority epoch, and physics tick.
`MotionPresentation` and `SimulationTruthPublisher` consume this same snapshot.
The publisher only converts/serializes it; it does not sample presentation nodes or
reconstruct physics independently.

## Visual Adaptation

`MotionPresentation` is split by profile: legacy consumes Python frames; Jolt mode
consumes the physical snapshot. Shared GLB mapping, rest offsets, parity, and model
activation remain reusable. The visual adapter writes only mapped GLB pivots and
never writes a Jolt body or joint.

The SY205 four-bar runs after physical arm/bucket pivots are applied. It uses actual
arm/bucket angles as inputs and preserves its YZ plane, branch continuity, and
last-valid fallback while remaining visual-only.

## Payload And Terrain Contact

BucketSoilState remains payload authority. A single adapter applies bounded mass and
local COM changes at safe physics-tick boundaries and records the applied payload
identity in truth state.

Terrain mutation stays disabled in this phase. Physical bucket collision/contact
may react on the chain and appear in truth, but the legacy kinematic
`BucketGroundLiftReaction` is disabled in Jolt-authoritative mode so there is no
second chassis writer.

## Lifecycle

Authority epoch, reset, model, and profile changes destroy the complete chain and
rebuild it from the selected descriptor. Rebuild clears actuators, payload adapter
state, contacts, and cached snapshots. It waits for a neutral, identity-valid input
before applying effort. Invalid descriptors fail closed before any body is created.

## Rollback

The whole articulated rig is profile-scoped. Rollback destroys it and starts a new
legacy session; partial joint fallback is forbidden.
