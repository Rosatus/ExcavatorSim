# Bounded soil parcel transport loop

## Goal

Give excavated soil a physical afterlife on top of the analytic cutting loop:
cut volume spawns a bounded pool of coarse Jolt parcels that fly off the
tooth, can be captured into the bucket cavity, carry with the fill
presentation, pour out under gravity on dump/spill, and settle back into the
TerrainState loose layer through the existing batched brush pipeline.

The analytic cutting loop stays exactly as shipped: penetration evidence,
engagement, resistance, and terrain yield are untouched. Parcels are purely
the transport/visual stage downstream of accepted cuts and never gate,
modify, or veto digging.

## Background

- Today cut soil retires to decorative GPU clods the moment its transfer
  commits; the bucket can never hold anything, carry is meaningless, and
  dump/spill have no visible effect.
- The earlier pure-parcel plan (archived `08-20-physics-informed-bucket-soil`)
  bundled cutting activation with transport. Cutting activation is now solved
  analytically; only the transport half remains valuable.
- Reusable infrastructure already exists: `queue_deposit_volume` raises the
  loose heightfield, the scheduler force-flushes same tick, the fill mesh in
  SoilEffects lights up from occupancy, and the rig descriptor carries a
  payload collision layer concept.

## Requirements

### R1. Parcel pool

- One `SoilParcelPool` node owns every dynamic soil parcel. Pool size is
  bounded by a quality budget (default 48); spawning beyond the budget
  recycles the oldest settled/idle parcel first, never allocates unbounded.
- Parcels are coarse volume carriers (sphere approximation of their volume),
  not per-grain simulation. Mass derives from volume and soil density.
- Collision: parcels collide with terrain and machine shells only. They never
  affect chassis support, articulation, or cutting decisions.

### R2. Cut spawning

- Every accepted analytic cut produces parcels at the recorded tooth position
  carrying the cut volume, inheriting the tooth's world velocity plus a small
  spread. Volume splits across one or two parcels sized within clamp bounds.
- Spawning consumes no additional authority: it happens after the cut is
  accepted and the terrain transaction queued.

### R3. Capture and carry

- A parcel whose center enters the bucket cavity region in bucket-local
  coordinates, moving slowly relative to the bucket, is captured: its volume
  credits the occupancy ledger (up to remaining capacity) and the body
  recycles. Overflow parcels are not captured and fall past the bucket.
- Captured volume restores the existing fill presentation and payload mass
  through the unchanged `get_status_snapshot` consumers.
- Released/dumped parcels carry a temporary recapture guard so pouring does
  not instantly re-swallow material.

### R4. Dump, spill, settle

- Dump and spill release ledger volume as parcels at the bucket lip with
  inherited bucket velocity instead of writing terrain directly.
- A grounded, slow parcel dwells briefly, then settles: its volume is queued
  as a loose-layer deposit at its XZ position through
  `queue_deposit_volume`, and the body recycles once accepted. Rejected
  deposits retry with a bounded budget before forced recycling.
- Settled piles therefore persist as real terrain the machine can dig again.

### R5. Lifecycle

- Generation change, model switch, reset, and focus loss clear all parcels
  and pending settle work without touching the ledger beyond what the
  existing reset already does.
- Fixed-step timing gates must not regress; pool work is O(active parcels)
  per tick with no allocations in the hot path beyond Godot minimums.

## Acceptance Criteria

- [ ] An accepted cut spawns bounded parcels at the tooth with inherited
      velocity; shell/rear-only contact spawns nothing.
- [ ] Active parcel count never exceeds the configured budget under repeated
      digging.
- [ ] Parcels entering the cavity credit occupancy up to capacity; the fill
      mesh and payload mass reflect captured volume.
- [ ] Dump pours parcels under gravity with a recapture guard; poured
      material lands and, after dwelling, raises the loose layer where it
      rested.
- [ ] Missed parcels also settle into terrain; total spawned volume equals
      captured + settled + in-flight within tolerance while the pool is
      non-empty.
- [ ] Reset/generation change leaves zero live parcels and no stale settle
      retries.
- [ ] Focused parcel tests pass and the full standalone matrix stays green.

## Out of Scope

- Per-grain simulation, continuum soil, or force feedback from parcels into
  equipment.
- Changes to cutting activation, engagement, resistance, or terrain yield.
- Parcel-vs-parcel cohesion, angle-of-repose piling above the heightfield.
- SY135-specific tuning beyond contract-driven sizes (contract data already
  parameterizes the pool).
