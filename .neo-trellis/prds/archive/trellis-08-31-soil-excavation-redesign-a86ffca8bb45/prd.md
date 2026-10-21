# Soil excavation system redesign — arcade stamp v3

## Goal and user value

Replace the twice-rejected conservative surface solver with a deliberately
visual-first excavation mode. A moving bucket cutting edge must carve a broad,
continuous and immediately readable trench without obvious frame stalls, even
if the removed soil is not physically simulated. The bucket receives a cheap
visual load state and soil effects so the interaction still reads as digging.

The primary product value is clean and decisive excavation. Soil mechanics,
strict material conservation and granular realism are no longer acceptance
goals for this mode.

## Confirmed facts

- Manual acceptance rejected `surface_patch_v2` twice: it produced only small
  marks, failed to remove most contacted soil and felt abnormal/stuttery.
- The product terrain is a `129 x 129` heightfield at `0.5 m` spacing. The v2
  path combines semantic classification, continuous rasterization, material
  reservations, synchronous cell-patch commit, collider work, Terrain3D update,
  active aggregates and loose-soil flux.
- `TerrainState` is the persistent terrain authority. `TerrainCommitScheduler`
  is the production mutation seam; `TerrainCollider` and Terrain3D/fallback are
  derived consumers. Terrain3D native collision remains disabled.
- Accepted previous/current bucket poses and cutting-edge proxies already come
  from `MotionPresentation.sample_bucket_pose_fixed()` for both SY205 and SY135.
- `SoilEffects` can display bucket fill, flow, dust and clods from a status
  snapshot without making those visuals authoritative.
- Public evidence does not reveal one common proprietary algorithm used by
  commercial excavator games. It does support local immediate terrain
  deformation, stamp/height-offset techniques, and separating simplified bucket
  visuals from machine physics. See `research/market-and-architecture-v3.md`.

## Requirements

### R1 — Clean, decisive swept cut

Use only the previous/current cutting-edge work band and model bucket width to
form a conservative 2D swept stamp. The stamp must cover motion between fixed
ticks, fill interior cell gaps and lower every covered terrain sample to a
simple target envelope. It must not depend on sparse contact points, a selected
best region, full-bucket semantic face classification or active-soil capture.

### R2 — Minimal engagement policy

Cut when the cutting edge is moving and any representative edge sample is at or
below the local terrain working band. Use small enter/exit hysteresis and reset
pose history only for genuine teleports. Do not require Jolt contact identity,
surface-role arbitration, resting normals, active-material scope or exact
penetration classification. A stationary bucket must not repeatedly deepen the
same cells.

### R3 — Aggressive but bounded response

Expose a small supported tuning surface: bucket-width multiplier, engagement
band, minimum visible cut, maximum depth removed per committed stamp and commit
rate. Defaults must favor a clearly visible result on the `0.5 m` product grid.
Safety floor and terrain bounds remain hard limits. Repeated passes may deepen a
trench; one discontinuous pose may not erase a long path.

### R4 — Coalesced terrain commits

Accumulate latest minimum target height per terrain index and commit one sorted
unique cell patch at a fixed default of 10 Hz, with a maximum pending latency of
100 ms. Do not force Terrain3D or collider rebuilds on every physics tick.
Immediate dust/cut VFX may be emitted from engagement, but bucket fill changes
only after a terrain patch is accepted.

### R5 — Visual bucket load and visual-only spoil piles

Track only a bounded scalar visual fill ratio and a compatible estimated payload
snapshot. Accepted changed terrain volume may increment the scalar cheaply, but
there are no active aggregates, bucket cells, loose-soil flux, compaction,
repose solver or particle-owned volume in this mode. Visual particles and the
bucket fill mesh remain disposable effects.

Dumping clears the scalar bucket load and produces a non-colliding visual soil
pile at the release location. The pile is a pooled presentation object using the
existing soil material family; its scale is derived from the released visual
fill. It does not alter TerrainState, collider height, Jolt contacts or any
material ledger. The pool is bounded and may recycle its oldest pile; world
reset removes all visual piles.

### R6 — Preserve machine and terrain boundaries

Jolt continues to own machine rigid-body motion, support and blocking. The
accepted TerrainState snapshot remains the source for the project collider and
Terrain3D/fallback. Terrain3D native collision stays off. CAN/Gateway behavior,
machine controls, current materials/vegetation and bucket pass-through
performance mode are unchanged.

### R7 — Stable failure and diagnostics

Invalid generation or model reset must discard the generation-owned pending
stamp. Stale base revision, collider preparation failure or other commit
rejection must leave TerrainState unchanged and retain the latest-minimum targets
for a patch rebuilt from the next current read view.
Expose bounded counters for engaged ticks, covered/changed cells, coalesced
cells, accepted/rejected commits and build/commit time. Do not log per cell or
per frame.

### R8 — Migration and rollback

Add `arcade_stamp_v3` as a generation-bound solver and bypass the v2 material
lifecycle when selected. Keep `point_brush_v1` and `surface_patch_v2` selectable
only as temporary rollback/diagnostic paths until v3 is manually accepted. Do
not delete old experimental files in the first v3 implementation pass.

## Acceptance criteria

- [ ] AC1: On the product `129 x 129 @ 0.5 m` grid, a 5 m forward cutting-edge
  sweep creates one connected trench spanning at least 90% of the sampled path;
  no isolated one-cell marks remain inside the proven swept work band.
- [ ] AC2: Slow and fast fixed-tick journeys cover the same path without gaps.
  A stationary bucket, above-ground motion and a teleport create no repeated or
  bridged cut.
- [ ] AC3: A committed trench is visibly broad (approximately the configured
  cutting-edge width) and each accepted pass removes at least the configured
  minimum visible depth unless limited by the safety floor.
- [ ] AC4: Stamp accumulation is latest-minimum-per-cell, sorted and unique.
  Fixed input produces identical patch bytes; stale/rejected commits do not
  change terrain revision or bucket fill.
- [ ] AC5: During continuous cutting, TerrainState/Terrain3D/collider commits are
  bounded to the configured 10 Hz default and pending latency is at most 100 ms;
  the physics tick does not synchronously rebuild terrain derivatives every
  frame.
- [ ] AC6: Accepted cuts raise a bounded visual fill ratio and drive existing
  bucket soil/dust effects. Dumping clears that ratio and creates a readable
  non-colliding visual pile at the release point. Changing particle/pile density,
  recycling a pile or resetting VFX does not change terrain or Jolt collision.
- [ ] AC7: SY205 Forward+ manual acceptance confirms a continuous obvious trench,
  responsive effects and no abnormal or clearly perceptible cutting stutter
  during slow and fast strokes. Tiny isolated marks are an explicit failure.
- [ ] AC8: SY135 receives a shorter cut/alignment/no-error check. Existing
  controls, Terrain3D material appearance, Jolt support and pass-through mode
  remain intact.
- [ ] AC9: `point_brush_v1` remains a clean-generation rollback until v3 is
  accepted. `surface_patch_v2` is not promoted to the default.

## In scope

- A new lightweight cutting-edge swept-stamp builder; fixed-rate coalescing;
  direct typed TerrainState patch commit; scalar visual bucket load; existing
  SoilEffects integration; bounded visual-only spoil-pile presenter; diagnostics;
  focused deterministic tests; Godot MCP inspection; one SY205 and one short
  SY135 human acceptance pass.
- Narrow tuning of cut width/depth/engagement and presentation effects needed to
  make the result clean on the current heightfield.

## Out of scope

- Exact conservation, active aggregates, loose-soil transport, angle of repose,
  compaction, push/back-drag material flow, physical spoil piles, particle
  authority or soil resistance calibration.
- Voxels, caves, overhangs, DEM, MPM, FEM, CFD, raw bucket-mesh Boolean CSG,
  Terrain3D native collision, a higher-resolution global terrain migration or
  new excavator assets.
- Reworking Gateway/CAN, machine controls, hydraulic simulation, vegetation or
  the terrain material stack.

## Key decisions

- Removed soil is allowed to disappear from the authoritative terrain system.
- Bucket fill is a scalar presentation/load estimate, not conserved material.
- Dumping creates only a bounded, pooled, non-colliding visual soil pile; it
  never adds heightfield soil or changes Jolt collision.
- `arcade_stamp_v3` bypasses the rejected v2 active-material lifecycle while v1
  remains a temporary clean-generation rollback.
