# Implementation plan

1. [x] Extend `TerrainState` with deterministic surface sampling and brush
   volume estimation helpers; add focused tests for bounds and Float32 volume.
2. [x] Implement `BucketSoilState` and `ExcavationWorld` with generation-safe
   cut/deposit queues, explicit bucket contact proxy, reset and status seams.
3. [x] Implement optional `TerrainCollider` heightfield derivation and attach
   `ExcavationWorld`/collider to `TerrainRoot` without changing Python transport.
4. [x] Add explicit dig/deposit UI hooks and a standalone Godot test covering
   repeatability, conservation, rejection, reset and no-collider operation.
5. [x] Run MCP scene/game smoke, `pixi run verify`, review manifests/specs, then
   archive the child task and journal the milestone.

Exit gate: [x]

## Scope guard

No GLB replacement, dynamic rigid bodies, Python terrain protocol changes,
replay implementation, unbounded particles, or wall-clock authority belongs in
this milestone.
