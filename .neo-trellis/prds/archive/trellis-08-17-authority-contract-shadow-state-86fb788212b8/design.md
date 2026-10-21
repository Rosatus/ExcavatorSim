# Design

## Contract First

Add a new schema/version family rather than extending the strict v3 pose message in
place. The Godot client remains the WebSocket initiator and may publish negotiated
shadow truth to a Python gateway endpoint/message handler. Python stores only the
latest accepted sample plus diagnostics in this phase.

## Godot Seams

- `AuthorityProfile`: selects writer/producer behavior before runtime activation.
- `SimulationTruthSnapshot`: immutable normalized post-tick value object.
- `SimulationTruthPublisher`: owns Y-up -> canonical Z-up conversion, sequence,
  batching/rate, and transport serialization.
- `PhysicsRigDescriptor`: validates JSON/resource data before any body is spawned.
- `JoltCapabilityProbe`: disposable tests only; no product-scene authority.

In `jolt_shadow`, the existing product path continues to write pose. The shadow
producer observes current local/world state and probe outputs but exposes no setter
back to motion, terrain, or payload owners.

## Python Seams

- A strict decoder owns all unknown-to-typed conversion.
- A latest-value slot rejects stale epoch/tick, wrong negotiated identity, invalid
  numbers, and excessive rate/size.
- Health/status may expose shadow freshness and validation errors.
- `RuntimeController.simulator` and published v3 state do not consume the slot.

## Coordinate Contract

The publisher uses the inverse of the existing canonical-Z-up -> Godot-Y-up basis
for complete transforms and the corresponding basis for vectors. Unit tests cover
translation, swing axis, hinge axis, angular velocity, gravity, determinant, and
round-trip parity.

## Rollback

Disabling the negotiated shadow capability removes the publisher/slot while leaving
the current v3 path byte-for-byte and behaviorally compatible.

