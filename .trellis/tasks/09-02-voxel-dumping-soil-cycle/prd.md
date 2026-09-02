# Voxel dumping and soil cycle

## Goal

Implement in-zone authoritative dumping, repose settling, track compaction, re-excavation, and conservation diagnostics.

## Requirements

- Depend on accepted foundation and cutting tasks; use their sole SDF/mass
  authority and collision-readiness contracts.
- Validate bucket opening/release state and debit inventory only for an accepted
  in-zone deposit transaction.
- Convert released mass to smooth loose-soil SDF deposits using a configured
  bulk density, support query, and bounded aggregate shapes.
- Mark deposits as loose and relax only dirty surface neighborhoods through a
  deterministic, bounded angle-of-repose solver that transfers rather than
  creates/deletes mass.
- Let track footprints compact loose material under bounded load/rate rules;
  untouched stable soil shall not be continuously flattened.
- Make settled/compacted deposits collidable, traversable, and re-excavatable
  through the same voxel authority.
- Reject deposits outside the work zone before bucket debit; provide one
  deduplicated diagnostic and transient visual effect.
- Preserve bounded queues and concise mass/conservation/readiness diagnostics.

## Acceptance Criteria

- [ ] Partial and full dump sequences create smooth piles whose credited mass
  equals bucket debit within the declared discretization tolerance.
- [ ] Piles relax toward the configured repose range without fluid-like global
  spreading, unbounded work, or mass drift.
- [ ] Loose deposits become collision-ready, can support/obstruct the machine,
  can be compacted by tracks, and can be excavated again.
- [ ] Stable initial soil is unchanged by ordinary track passage except where
  explicitly configured as loose material.
- [ ] Out-of-zone, duplicate, stale, and reset-crossing dumps leave SDF and
  bucket inventory unchanged.
- [ ] Repeated cut/dump/settle/compact/re-cut cycles remain deterministic and
  conserve mass within cumulative tolerance.
- [ ] Human Forward+ review accepts pile appearance, behavior, traversal, and
  re-excavation without noticeable sustained stutter.

## Out of scope

- Per-grain rigid-body/DEM/MPM/SPH soil.
- Deposits on Terrain3D hard ground.
- Final removal of legacy excavation code.
- Persistence.
