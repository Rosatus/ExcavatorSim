# Implementation Plan

## Phase A: Logical Dirty Bounds

- [x] Add dirty rectangle accumulation to `TerrainState` and scheduler snapshots.
- [x] Bound brush iteration to the brush rectangle and preserve full-snapshot compatibility.
- [x] Add unit tests for clamping, halo expansion, batched union, reset, and generation changes.

## Phase B: Terrain3D Patch Path

- [x] Add initial/full versus ordinary/patched materialization states.
- [x] Keep the active native terrain visible while patch work is pending.
- [x] Edit existing region height maps and call edited-region `update_maps`.
- [x] Keep dressing stable and instrument full-import/patch counters.
- [x] Add failure fallback to previous surface plus full resync.

## Phase C: Derived Collision/Renderer

- [x] Partition custom terrain collision into stable chunks.
- [x] Implement dirty-chunk prepare/swap and applied-identity gating.
- [x] Avoid full fallback mesh rebuilds on native ordinary patches.
- [x] Add stale/revision-gap tests for bucket queries and tracked support.

## Phase D: Verification

- [x] Run focused TerrainState/Terrain3D/collider tests.
- [x] Run standalone matrix and `pixi run verify`.
- [x] Run Godot MCP repeated contact/deformation smoke with frame capture or visibility counters.
- [x] Update specs, commit, push if requested, and archive this child before child 3 starts.

## Risky Files

- `godot/client/scripts/terrain_state.gd`
- `godot/client/scripts/terrain_commit_scheduler.gd`
- `godot/client/scripts/terrain3d_adapter.gd`
- `godot/client/scripts/terrain_collider.gd`
- `godot/client/scripts/terrain_renderer.gd`
- `godot/client/scripts/terrain_world.gd`

