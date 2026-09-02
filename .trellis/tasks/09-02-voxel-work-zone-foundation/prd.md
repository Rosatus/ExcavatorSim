# Voxel work-zone foundation

## Goal

Validate Voxel Tools 1.7 APIs and establish the bounded VoxelTerrain, Terrain3D seam, material, reset, collision readiness, and performance baseline.

## Requirements

- Implement an isolated, deterministic Voxel Tools probe using the pinned Godot
  4.7.2/Voxel Tools 1.7 editor and release template.
- Verify the actual v1.7 API and scaled-coordinate behavior for bounded
  `VoxelTerrain`, 16-bit SDF, Transvoxel, viewers, bulk edits, copy/paste,
  editability, meshing readiness, statistics, collision, and teardown.
- Compare a `0.125 m` voxel scale with one coarser candidate under identical
  bucket-sized edits and select a stable product scale.
- Establish one north-side `32 x 32 x 10 m` voxel work-zone scene, with initial
  grade at `Y=0`, 6 m soil below, and 4 m deposit headroom.
- Keep spawn `(0,0)` on hard Terrain3D and provide an approximately 8 m southern
  approach plus vehicle entrance.
- Apply one shared ownership mask so Terrain3D/hard collision omit the voxel
  interior and Voxel Tools never owns the exterior.
- Implement generation/revision readiness diagnostics and a reset that cannot
  accept stale asynchronous mesh/collider results.
- Replace the incompatible heightfield support/fallback clauses in the frontend
  client-boundary spec with an explicit transitional hard-terrain/voxel
  ownership contract before downstream voxel implementation relies on it.
- Do not integrate bucket cutting, inventory, dumping, settling, or compaction.

## Acceptance Criteria

- [ ] The pinned editor and export template instantiate the chosen terrain,
  generator, mesher, viewers, and Jolt collision without missing-class errors.
- [ ] Bulk SDF removal/addition modifies only the expected bounded area and can
  be observed through SDF reads and mesh/collision readiness.
- [ ] A recorded benchmark selects the voxel scale and declares data-edit,
  remesh, collider-ready, backlog, memory, and frame-time budgets.
- [ ] The product scene shows one north-side zone, hard spawn/apron, readable
  entrance, and no visual or collision overlap at sampled seam points.
- [ ] The excavator can enter and traverse the pristine zone only after its
  initial collision is ready.
- [ ] Reset advances generation, restores the initial SDF, and prevents old
  readiness work from reappearing.
- [ ] Collision readiness is proven by both newest-ticket meshing completion and
  a changed-geometry Jolt query acknowledgement; the exact sequence is recorded
  for downstream tasks.
- [ ] The frontend spec no longer mandates `TerrainState` height sampling or
  heightfield fallback inside the voxel work zone.
- [ ] Human Forward+ review accepts the foundation layout, material family,
  seam, entrance, and unedited traversal before the cutting child begins.

## Out of scope

- Bucket-driven edits or soil inventory.
- Authoritative dumping, loose-soil relaxation, or compaction.
- Legacy excavation deletion or product-default cutover.
- Persistence and multiple work zones.
