# Design - continuous voxel bucket cutting

The parent design and archived foundation decision are authoritative.

`VoxelBucketCutter` is a pure proposal generator. It transforms accepted prior
and current bucket poses into local voxel coordinates, subdivides motion by the
farthest semantic point (maximum half-voxel displacement per segment), samples
SDF/gradients, and applies direction/speed/engagement hysteresis. It unions main
edge/teeth and side-edge capsule sweeps, then adds only the clearance volume
behind the active leading plane.

`VoxelExcavationAuthority` validates and orders typed proposals. A bounded
20 Hz scheduler copies only the dirty AABB plus SDF halo, coalesces overlap,
computes represented mass change, clips work to remaining bucket capacity,
publishes one localized edit, advances data revision, and marks readiness
tickets. Bulk native operations or one buffer paste follow the executor chosen
by the foundation benchmark.

Mass, not raw edited sample count, is ledger authority. Each touched cell keeps
fixed-point stable/mobile mass components and mobile compaction state beside the
SDF geometry in the same authority transaction. Cutting consumes mobile before
stable material; partial-cell residuals are assigned canonically. Surface solid
fraction is evaluated by one fixed algorithm and checked against mass-implied
volume before publication. A rejected edit is a no-op; an accepted edit credits
the bucket in the same transaction. Mesh/collider completion is derivative and
cannot veto or retroactively change accepted soil data.

Jolt supplies accepted articulation/chassis identity and later consumes collider
readiness plus payload mass/COM. Stale Jolt contacts never decide removal.
Effects subscribe only to committed transaction events.
