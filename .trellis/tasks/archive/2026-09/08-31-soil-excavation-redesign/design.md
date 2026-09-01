# Design — visual-first arcade excavation stamp

## 1. Decision

`surface_patch_v2` is not the new product path. It remains an unaccepted
experiment and temporary diagnostic option. The replacement is a separate
`arcade_stamp_v3` path that deliberately removes the soil lifecycle from the
cutting hot path.

```text
accepted previous/current cutting-edge pose
  -> ArcadeExcavationStamp (cheap swept work band)
       -> engagement hysteresis
       -> grid-cell coverage + simple target depth
       -> latest-minimum coalescer
  -> fixed 10 Hz flush
       -> one SoilCellPatch
       -> TerrainCommitScheduler
       -> TerrainState revision
       |-> project TerrainCollider / Jolt next tick
       `-> TerrainWorld -> Terrain3D/fallback
  -> accepted changed volume
       -> ArcadeBucketLoadState (scalar only)
       `-> existing SoilEffects / payload-compatible status
```

No call from this path enters `SoilInteractionAuthority`, `ActiveSoilPatch`,
`ActiveSoilPersistentField` or `LooseSoilFluxSolver`.

## 2. Geometry and engagement

The input adapter reuses `MotionPresentation.sample_bucket_pose_fixed()` but
reads only stable identity plus cutting-edge endpoints/center and current bucket
orientation. It does not classify every semantic surface.

For each accepted pose pair:

1. Reject invalid identity and genuine teleports; otherwise interpolate at a
   maximum step tied to terrain spacing so fast motion cannot tunnel.
2. Sample terrain below the left, center and right cutting edge.
3. Enter engagement when the edge is moving and at least one sample is within or
   below the configured working band. Exit with a slightly larger band.
4. Project the previous/current edge segments to XZ. Their union forms swept
   quads plus end caps. Expand by a small width multiplier so the `0.5 m` grid
   cannot leave an interior spike.
5. For every overlapped support cell, choose a simple target: the lower of the
   current terrain and an interpolated cutting-edge height minus response bias,
   clamped by minimum visible cut, per-flush depth cap and terrain safety floor.

The policy intentionally accepts more false-positive cutting than v2. Its hard
guards are movement, terrain proximity, bounds, safety floor and teleport reset.
A stationary or above-ground bucket does not erase terrain.

## 3. Coalescing and commit cadence

`ArcadeExcavationStamp` does not commit during every physics tick. A bounded map
stores one pending row per terrain index; a new proposal replaces the pending
target only when it is lower. Flush is driven by fixed tick count at 10 Hz or by
the 100 ms maximum-latency boundary.

At flush, rows are sorted, originals are read from the current TerrainState view
and one valid `SoilCellPatch` is queued. The existing scheduler retains atomic
state/collider/presentation identity. The v3 integration must not call the v2
forced `step_fixed(0.0, true)` path every frame.

Cut dust or small grains may begin immediately on engagement so control feedback
does not wait for the next terrain flush. These events are presentation-only.
The visible terrain follows within at most 100 ms. A preview ribbon is deferred;
it is added only if human acceptance shows that the bounded delay is visible.

## 4. Bucket load and visual spoil pile

`ArcadeBucketLoadState` contains only:

- generation/reset identity;
- `fill_ratio` in `[0, 1]`;
- estimated volume/mass for compatibility with the current status and optional
  Jolt payload feedback;
- last accepted cut and dump event IDs.

Accepted changed terrain volume increments fill using a tunable gain and bucket
capacity. There are no bucket cells, active representatives or authoritative
loose material. A rejected terrain patch cannot increment fill.

An MVP dump clears the scalar load over a short visual release, emits existing
falling-soil/dust effects and places one visual-only mound at the release point.
The mound presenter uses a bounded pool of non-colliding mesh instances sharing
the existing soil material family. Its position follows the terrain height at
the dump X/Z and its scale is derived from the released fill ratio. The oldest
mound may be faded/recycled when the pool is full; generation/world reset clears
the pool. Mounds never call TerrainState, TerrainCommitScheduler, physics shape
or material-ledger APIs.

## 5. Compatibility and rollout

Extend the generation-bound solver enum with `arcade_stamp_v3`. Selection is
exclusive:

- `point_brush_v1`: rollback owner;
- `surface_patch_v2_shadow` / `surface_patch_v2`: unaccepted diagnostic paths;
- `arcade_stamp_v3`: new candidate owner.

The first pass leaves old files and tests in place, but v3 has no dependency on
their active-material lifecycle. After human acceptance, v3 becomes the default;
deletion of v2 is a later cleanup task so rollback and diff review stay simple.

## 6. Performance strategy

- O(covered cells) stamp generation with a small, fixed input set;
- no per-surface semantic classifier and no active-soil/loose-flux step;
- no forced Terrain3D/collider refresh every physics tick;
- at most one pending target per cell and bounded dirty rectangle;
- compact aggregate timing/counter diagnostics only;
- agent tests exercise pure coverage and commit cadence; human Forward+ owns
  perceived cleanliness and stutter acceptance.

## 7. Known limitations

- Heightfield edits cannot form overhangs, vertical walls or true bucket-shaped
  cavities.
- The cut is intentionally wider/deeper and less physical than the bucket mesh.
- Visual-pile dumping does not restore removed terrain and is not mass-conserving;
  the mound can be walked through and may be recycled when the pool is full.
- A 10 Hz terrain presentation can lag the immediate dust response by up to
  100 ms; a render-only preview is a contingency, not part of the initial MVP.
