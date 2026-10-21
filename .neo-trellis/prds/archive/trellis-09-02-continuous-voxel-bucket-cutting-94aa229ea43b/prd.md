# Continuous voxel bucket cutting

## Goal

Implement the sole voxel excavation authority, swept bucket cutter, coalesced SDF edits, bucket inventory, and both-model deterministic cutting.

## Requirements

- Depend on the archived foundation task's selected scale, scene seam,
  coordinate adapter, and proven collision-readiness behavior.
- Add one generation-scoped `VoxelExcavationAuthority`; no other runtime may
  mutate work-zone SDF or bucket inventory.
- Derive a continuous cut from accepted fixed-tick SY205/SY135 bucket poses and
  hash-bound teeth/main-edge/side-edge geometry.
- Add constrained floor/interior clearance behind the leading cut so accepted
  sweeps leave no residual spikes, without making the bucket an unconditional
  eraser.
- Reject stationary, above-ground, separating, teleported, stale, protected
  boundary, and out-of-zone motion.
- Coalesce overlapping proposals and execute localized bulk SDF operations at a
  bounded starting cadence of 20 Hz.
- Measure accepted material mass/volume deterministically enough to credit a
  bounded model-specific bucket. A full bucket shall not delete more soil.
- Store per-cell fixed-point stable and mobile mass components plus mobile
  compaction state, committed atomically with SDF, so mixed surface cells and
  density changes are replayable and auditable.
- Expose transaction, queue, data/mesh/collision revision, bucket, conservation,
  rejection, and performance diagnostics without per-voxel logs.
- Keep the complete voxel work zone inside the hard-terrain presentation domain
  so its ownership hole cannot expose overlapping Terrain3D ground.
- Provide an explicit developer-only large finite bucket-capacity mode for
  manual cutting tests, without mutating the hash-bound model capacity contract.
- Preserve Jolt chassis/track/kinematic equipment authority and existing
  Python/Gateway protocols.

## Acceptance Criteria

- [x] Pure geometry tests prove connected, ordered coverage for both models and
  slow/fast/translated/curling strokes at the selected scale.
- [x] Valid sweeps remove a continuous cavity and no authoritative solid remains
  inside the accepted constrained clearance envelope.
- [x] All invalid motion cases and duplicate/stale transactions change neither
  SDF nor bucket inventory.
- [x] Capacity clipping ensures accepted terrain mass equals bucket credit within
  the declared discretization tolerance, including the full-bucket boundary.
- [x] Identical fixed inputs under different render cadences produce identical
  transaction order, SDF digest, and bucket state.
- [x] Queues and dirty work remain bounded in one stable representative runtime
  performance run.
- [x] Terrain3D covers the complete voxel ownership domain, deep solid soil is
  present to `Y=-5.5 m`, and test capacity reports both contract and effective
  values.
- [x] Human Forward+ review accepts clean, responsive, aligned cutting for SY205
  and SY135 before dumping work begins.

## Out of scope

- Dumping soil back into the zone, repose settling, or track compaction.
- Final legacy deletion/product cutover.
- Persistence or network terrain replication.
