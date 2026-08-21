# Technical Design

## Dirty Revision Contract

`TerrainState._apply_brush()` converts each brush to a clamped grid rectangle and records changed cells. The fixed-step batch unions rectangles and publishes:

```text
full_refresh: bool
dirty_rect_cells: Rect2i
dirty_rect_with_halo: Rect2i
terrain_epoch/world_generation/revision
surface snapshot and digest
```

The full surface remains in the snapshot for compatibility and recovery. Consumers use the dirty rectangle for normal updates.

## Terrain3D Adapter

### Full Path

Use existing `build_maps`/`import_images` only when no compatible native region exists or when `full_refresh=true`. Configure the node/material before activation and keep the current backend visible until the new full materialization succeeds.

### Patch Path

1. Resolve the affected Terrain3D region(s) from the dirty world rectangle.
2. Retrieve each region's height map image.
3. Copy logical surface values for the mapped dirty pixels plus halo into that image.
4. Update region height bounds and edited/modified flags.
5. Call `Terrain3DData.update_maps(TYPE_HEIGHT, false, false)`.
6. Reconfigure collision only for affected chunks/region bounds.
7. Publish the new applied identity and retain native visibility throughout.

The official Terrain3D 1.0.2 API explicitly supports region image editing and edited-region map refresh. It does not promise an arbitrary pixel-subrect GPU update, so the contract is region-local rather than overstated as pixel-local.

## Fallback Renderer

Keep cached vertex/index arrays. If native is active, ordinary patches need not rebuild the fallback. If native is unavailable, update dirty vertices plus a normal halo and replace only the derived surface resource at a safe frame boundary.

## Collider Chunk Swap

- Partition the logical terrain into stable chunk rectangles.
- Map dirty bounds to affected chunks plus one neighboring ring.
- Build replacement shapes without removing old chunks.
- Add replacements, then remove old chunks, then advance the applied identity.
- If a replacement fails, retain old chunks and mark the collider stale; bucket queries fail closed until a full rebuild succeeds.

## No Flicker Invariant

There is always one visible valid surface: previous native, new native, or fallback. The adapter may report `pending` or `stale`, but it must never hide the only visible terrain while waiting for asynchronous map/collision work.

