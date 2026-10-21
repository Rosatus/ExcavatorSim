# Design

## Rig Shape

Instantiate one dynamic chassis body with model-specific compound convex shapes,
mass, inertia, COM, damping, sleep policy, collision layers, and spawn transform.
Upper/work-equipment presentation remains locked to a validated safe rest pose.

## Track Model

Each side owns multiple support probes/contact points distributed over track length.
At each fixed tick, calculate desired belt-ground relative speed, longitudinal slip,
normal-load-limited traction, braking, and capped lateral resistance. Apply forces
at contact positions so left/right imbalance creates physical yaw and body roll.

The model reports command, actual side speed, slip, normal load/contact count,
applied force, saturation, and quality. It does not instantiate individual shoes.

## Single Writer

`jolt_authoritative` routes visual root pose from the chassis body snapshot.
`TrackedLocomotionState` may remain for legacy tests/profile but cannot write the
same root. Python base transforms are ignored/rejected by the Jolt presentation
adapter.

## Terrain Identity

Physics activation requires a collider tagged with the current terrain generation
and revision. The snapshot records the applied revision. Collider rebuild behavior
must be measured, but full excavation-time transactional replacement belongs to
Phase 3.

## Rollback

Profile teardown frees the dynamic rig and reinstates the legacy kinematic owner
only after a new lifecycle/session epoch; there is no hot same-frame handoff.

