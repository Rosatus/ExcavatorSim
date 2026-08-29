# Terrain3D snapshot lifecycle and fallback

## Goal

Restore ordered Terrain3D snapshot materialization, incremental deformation,
one-visible-surface fail-open fallback, and reversible Test Grid transitions.

## Dependencies

- Phase 0 must prove the native renderer is stable and non-black.
- Phase 1 must provide the approved project soil material and dressing policy.

## Requirements

- Keep accepted `(terrain_epoch, world_generation, terrain_revision)` ordering
  and deep-copy snapshot inputs before native work.
- Use full materialization only for startup, generation/reset/model transition,
  skipped/stale recovery, material replacement, or explicit resync.
- Use dirty-region plus halo patching for contiguous ordinary revisions. Patch
  failure retains the previous native surface and retries through full resync.
- Maintain a synchronized `TerrainRenderer` fallback. Never show coincident
  native and fallback meshes, and never expose a missing-surface frame.
- Hard native/material/map failures activate the latest full-synced fallback
  without stopping or mutating terrain/soil/Jolt state.
- Test Grid hides native and all site dressing, presents the authoritative
  fallback grid, and restores the prior backend only after native resync succeeds.
- Expand bounded diagnostics for configured/active backend, material, latest
  accepted/queued/applied identity, fallback reason, full/patch/failure counts,
  and dressing exclusions.
- Restore `terrain3d_adapter_test.gd` to the standalone matrix and remove the
  obsolete black-surface exclusion.

## Acceptance Criteria

- [ ] Startup/reset/generation/model changes perform exactly the expected full
  materialization and converge to the accepted identity.
- [ ] Two or more contiguous excavation revisions increment patch count without
  incrementing full-import count or replacing native/dressing node identity.
- [ ] Stale or retired work cannot overwrite newer queued/applied terrain.
- [ ] Failed patch keeps the old native surface visible and full-resyncs; failed
  full import exposes a synchronized fallback with a bounded reason.
- [ ] At every observed transition exactly one valid terrain surface is visible.
- [ ] Test Grid changes presentation only and restores the prior product backend.
- [ ] `terrain3d_adapter_test.gd` is active in the matrix and covers success,
  failure, stale, patch/full, Test Grid, and fallback paths.

## Out of Scope

- Product default switch, native collision, soil/Jolt equivalence certification,
  plugin upgrade, or subjective visual redesign.
