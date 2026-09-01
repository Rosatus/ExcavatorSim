# Current soil excavation findings — 2026-08-31

## Current authority and tick flow

- `TerrainState` is the logical terrain authority. It stores `stable_heights` and
  `loose_depth`; its public surface is their sum and snapshots carry epoch,
  generation, revision and dirty rectangles
  (`godot/client/scripts/terrain_state.gd:93-194`).
- `TerrainCommitScheduler` is the production mutation owner. A flush applies the
  queued terrain commands, advances one revision, then feeds one copied snapshot
  to `TerrainWorld` (Terrain3D or fallback) and the project `TerrainCollider`
  (`godot/client/scripts/terrain_commit_scheduler.gd:132-192`).
- Terrain3D is a copied presentation derivative and its native collision remains
  disabled. Identity-matched `TerrainCollider`/logical `TerrainState` remain the
  Jolt evidence sources (`.trellis/spec/frontend/client-boundary.md:885-948`).
- The active product lifecycle is `active_patch`. Its
  `SoilInteractionAuthority` owns the generation-scoped ledger compartments
  `persistent_stable`, `persistent_loose`, `active`, `bucket`, and `released`
  (`godot/client/scripts/soil_interaction_authority.gd:121-157`,
  `.trellis/spec/frontend/client-boundary.md:1213-1244`).
- Physics order is Jolt/controller first, excavation second. Jolt queries the
  already-applied collider revision; excavation then samples accepted bucket
  poses and may commit the next terrain revision. The new revision is therefore
  logically a tick-end result and should first be consumed by Jolt on the next
  physics tick (`godot/client/scripts/excavation_world.gd:112-165`).

## Root cause of the current cutting artifacts

The current model contracts already describe nine semantic regions in bucket
local space: teeth, left/right side cutters, floor, three outer-shell regions,
inner shell, and opening. `BucketSoilTool` also receives previous/current
accepted bucket transforms and adaptively interpolates them
(`godot/client/scripts/bucket_soil_tool.gd:41-109`,
`.trellis/spec/frontend/client-boundary.md:1003-1026`).

However, that information is reduced twice:

1. A segment is sampled at only three points, a plane at center/corners, and a
   box at center/corners. Classification queries those points only and retains
   one best point per region (`godot/client/scripts/bucket_soil_tool.gd:145-207`,
   `:269-305`). The region swept AABB is not rasterized.
2. `SoilInteractionAuthority` then picks one best region for the entire tick,
   estimates volume from penetration × motion × width × an action factor, and
   sends one center/volume to `ActiveSoilPatch`
   (`godot/client/scripts/soil_interaction_authority.gd:206-284`, `:497-516`).
   `ActiveSoilPersistentField` converts that request back into one circular
   falloff brush (`godot/client/scripts/active_soil_persistent_field.gd:137-211`).

Consequences:

- surface interiors and temporal gaps can be missed even though corners hit;
- all other valid surfaces in the same tick are discarded;
- multiple contacts cannot form one canonical footprint;
- the circular falloff cannot match the swept teeth/plate envelope;
- requested volume is an estimate rather than the exact changed-cell volume;
- increasing sample count or brush radius can only trade holes for over-erasure.

The earlier approved architecture explicitly required full swept regions and
rejected circular tooth brushes as the primary owner, so this is implementation
drift rather than a new product direction
(`.trellis/tasks/archive/2026-08/08-24-gameplay-soil-interaction-rebuild/prd.md`,
`.trellis/tasks/archive/2026-08/08-24-conservative-soil-material-lifecycle/prd.md`).

## Conservation and atomicity gaps

- The ledger rows are equal/opposite, but some current operations mutate an
  aggregate before confirming the destination bucket cells, or inject released
  volume before confirming the bucket debit. The mismatch path increments an
  invariant counter rather than rolling back
  (`godot/client/scripts/soil_interaction_authority.gd:287-412`, `:519-543`).
- Settlement writes the terrain before the authority clamps the source ledger;
  an already-corrupt source can therefore create a terrain/ledger difference
  (`godot/client/scripts/active_soil_patch.gd:624-652`,
  `godot/client/scripts/soil_interaction_authority.gd:415-437`).
- Reset currently permits clearing unsettled active representatives without
  settling or restoring them. That is acceptable only as an explicit destructive
  world reset, not as a normal material transfer
  (`godot/client/scripts/active_soil_patch.gd:140-158`).
- Current deduplication caches only 512 generation/tick identities. They are a
  replay guard, not a replacement for atomic cell ownership.

## Loose soil behavior and presentation boundary

- `TerrainState` has no product-path repose relaxation. Positive brushes add
  loose depth at their falloff shape and leave it there
  (`godot/client/scripts/terrain_state.gd:314-379`).
- `ActiveSoilPatch` has bounded representatives with gravity, damping, neighbor
  overlap/cohesion, sleep and settlement. Material presets expose 30–43 degree
  repose angles, but those values do not constrain the persistent heightfield
  (`godot/client/scripts/active_soil_patch.gd:41-81`, `:504-652`).
- Compaction is currently metadata updated around brush footprints; it does not
  influence cut resistance, repose, mobility or surface volume
  (`godot/client/scripts/active_soil_persistent_field.gd:224-241`).
- `push`/`back_drag` classifications do not currently displace persistent loose
  soil. Stable displacement is restricted to cut/side-cut/scrape/grade.
- The old Python legacy terrain contains a useful deterministic, conservative
  four-neighbor repose relaxation, but it is explicitly a legacy visual authority
  and cannot be copied across as a second owner (`docs/terrain-api.md:38-55`).
- `ActiveSoilPatchPresenter`, dust and hero clods are derived presentation. The
  redesign must go further and ensure disposable visual representatives never
  own aggregate volume or decide bucket/settlement transfers.

## Terrain/physics synchronization findings

- Current scheduler refresh is synchronous in GDScript, but it advances logical
  state before rendering and collider rebuild. A collider build/install failure
  can therefore leave presentation/logical revision ahead while the old physical
  shape remains installed (`godot/client/scripts/terrain_commit_scheduler.gd:132-192`).
- Identity gates correctly reject stale query evidence, but they do not by
  themselves remove the old StaticBody shape or prove Jolt broadphase has already
  observed a just-assigned replacement.
- Terrain3D native collision must stay off; enabling it would create a second,
  asynchronously rebuilt physical terrain (`.trellis/spec/frontend/client-boundary.md:885-926`).

## Existing gates worth preserving

- Every accepted transaction balances within
  `max(1e-6 m3, 0.1% accepted volume)`; the deterministic journey currently uses
  `1e-5 m3` drift tolerance and 20 cycles use
  `max(1e-5 m3, 0.5% bucket capacity)`
  (`.trellis/spec/frontend/client-boundary.md:1268-1279`).
- Logical results must not change with low/balanced/high visual representative
  budgets.
- Existing active-soil p95 budgets are 2/4/6 ms and memory budgets are
  96/256/512 MiB for low/balanced/high.
- Agent validation should use focused deterministic/headless checks. Visual
  trench continuity, material feel and interactive digging remain one final
  human Forward+ review; full matrices and performance runs happen only once
  after the implementation is stable
  (`.trellis/spec/frontend/validation-budget.md`).
