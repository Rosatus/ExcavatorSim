# Design — full bucket soil tool contract

## Contract shape

Extend the existing model soil/interaction descriptor with versioned semantic
regions. Prefer lines, convex polygons, boxes, capsules, and planes expressed in
the canonical bucket frame. Runtime paths resolve through existing model semantic
nodes; contracts never point directly at incidental mesh children.

Each composed snapshot contains model/generation/pose identity, current and
previous transforms, world-space primitives, region role, outward normal, motion
vector, and opening/cavity facts. Swept primitives are analytic where simple and
conservatively sampled at a bounded count otherwise.

## Classification boundary

The classifier emits candidates only. It samples logical terrain/patch queries
through read-only interfaces, evaluates role + relative motion + orientation,
and publishes a stable ordered list. The later authority decides material
transfers. Existing analytic cut and parcels remain the only owners during this
child.

## Compatibility

Missing/invalid descriptors fail closed for the new path and leave legacy mode
available. Debug geometry uses non-colliding presentation nodes and clears on
generation/model/disable boundaries.

The implemented owner is `SoilContractDescriptor`, shared by presentation and
Jolt through the hash-bound model catalog. `BucketSoilTool` is a pure observer:
it composes bounded swept samples from accepted `bucket_link` frames and emits
canonical-order candidates. `ExcavationWorld` attaches them only when the
default-off shadow flag is enabled; existing soil reducers never consume them.
