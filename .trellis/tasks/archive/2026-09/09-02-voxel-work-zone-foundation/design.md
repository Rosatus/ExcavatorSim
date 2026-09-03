# Design - work-zone foundation

The parent `design.md` is authoritative. This child proves its unverified Voxel
Tools assumptions before product cutting exists.

Create a self-contained probe scene first, then promote the verified resources
through `VoxelWorkZoneConfig`, `VoxelWorkZone`, and
`VoxelCollisionReadiness`. Start with uniform scale `0.125`, 16-voxel mesh
blocks, signed 16-bit SDF, a deterministic flat generator, one zone viewer, and
one chassis-local collision-priority viewer.

The benchmark operates on a bucket-sized connected path plus clearance volume,
not isolated spheres. It captures synchronous edit cost separately from
asynchronous mesh and collision latency. It also checks the documented
statistics/backlog counters and real Jolt queries. If `0.125` fails the stable
budget, test one coarser scale and record the quality/performance trade.

Extend the hard site toward +Z and mask `X=[-16,16], Z=[8,40]` out of every
Terrain3D/fallback/hard-collider derivative. A two-voxel protected shell and
static retaining skirt hide volume edges; the southern entry is flat and shares
one half-open ownership rule. Visual dressing may move.

Readiness tickets bind project generation/revision to dirty blocks and the
latest observed `is_area_meshed()` transition. Because that API does not promise
an exact collider revision, the probe must add a changed-geometry Jolt query
acknowledgement before support-ready publication. Reset discards the whole
terrain instance and its ticket namespace before recreating initial state.

The first spec update is transitional and explicit: outside the zone,
Terrain3D/project hard ground supplies immutable support; inside, voxel SDF is
soil truth and newest acknowledged voxel collision is Jolt support. Existing
`TerrainState.sample_surface_bilinear_at()` and stale-heightfield fallback rules
must not be preserved inside the work-zone mask.

Rollback is complete: the existing excavation path remains selected throughout
this child.
