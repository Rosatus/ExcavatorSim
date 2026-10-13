# Optional off-zone soil piles

## Authorization and behavior
User authorized implementation after evaluating the alternatives. Add a default-off
setting allowing soil dug from the voxel work zone to be deposited on static ground
in urban and construction. Deposits must have vehicle-supporting collisions and be
re-excavatable. Static roads remain immutable. One bucket/material owner retains
exact mass conservation. Disabled mode retains the existing export sink; disabling
must not delete existing piles. Simple digging continues to prohibit unloading.
Reset/map lifecycle clears piles consistently with material generation. No disk
savegame persistence or whole-map voxelization is required.

## Acceptance
- Actual pose admission unloads onto eligible static ground only after confirmed
  opening, debits accepted mass only, and publishes the existing release event.
- Repeated deposits grow/fuse with a repose profile, including chunk boundaries.
- Cutting removes only deposited mass; repeated cutting cannot mine static ground.
- Generated mesh/collision supports physics ray queries and a dynamic body.
- Disabled/unsupported/no-ground/budget rejection does not accidentally lose mass.
- UI setting persists through theme/map transitions; reset retires geometry.
- Focused integration covers both optional map packs and existing voxel behavior.

## Scope limits
First version uses static ground only, not vehicles, roof/bridge decks, moving
objects or multiple stacked receiving surfaces. Resource limits retain bucket stock.
Subjective appearance and driving feel remain a human Forward+ acceptance gate.

Boundary refinement from implementation review: new overlay piles stop at the
original voxel rectangle. Spreading onto an excavatable foundation would require
mass-conserving support-change settlement; this is deferred. Original in-zone
deposit behavior remains active. Chunk-to-chunk pile merging is implemented.
