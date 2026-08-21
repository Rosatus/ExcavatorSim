# Incremental Terrain3D deformation updates

## Goal

Make ordinary excavation/deposit revisions visually continuous and cheaper by applying only the changed terrain region while preserving the current Terrain3D surface and exact-revision collider until replacement work is ready.

## Confirmed Problems

- `Terrain3DAdapter.queue_snapshot()` hides native terrain before every revision.
- The adapter rebuilds complete height/control images and calls `import_images` for every revision.
- Terrain dressing is freed/recreated on every native materialization.
- The fallback renderer builds a new full `ArrayMesh`, and the custom collider replaces a complete static body per revision.

## Requirements

- `TerrainState` and `TerrainCommitScheduler` publish dirty cell bounds for every accepted brush batch, including a one-cell normal/seam halo.
- Startup, reset, generation change, stale recovery, and explicit full resync retain a full materialization path.
- Ordinary revisions edit the existing Terrain3D region map, mark only affected regions edited, and call edited-region `update_maps`.
- Native Terrain3D remains visible during queued/applying work; a failed patch leaves the previous surface visible and schedules a full resync.
- Dressing nodes are stable across ordinary revisions.
- The custom collider updates only affected chunks and exposes the new `(generation, revision)` after all dirty chunks are installed.
- Fallback rendering remains available when the native extension is unavailable, but it must not cause a native/fallback hide-show flash.

## Acceptance Criteria

- [ ] A repeated cut/deposit sequence never sets the active native terrain invisible and never replaces the Terrain3D node.
- [ ] Ordinary revisions increment a patch counter and do not increment the full-import counter.
- [ ] Dirty bounds are smaller than the full logical grid for local brushes and include the normal/seam halo.
- [ ] Unchanged collider chunks retain their body/shape identity while dirty chunks swap transactionally.
- [ ] Terrain3D and custom-collider applied identities converge to the accepted revision without stale contact queries.
- [ ] Reset/model switch still performs a clean full rebuild and clears stale pending patch work.
- [ ] Godot MCP smoke shows no whole-ground flash during repeated bucket contact.

## Out of Scope

- Arbitrary GPU pixel-subrect upload not guaranteed by Terrain3D's public API.
- Runtime terrain caves/overhangs or replacement of the logical heightfield.
- Terrain material redesign unrelated to revision update behavior.
