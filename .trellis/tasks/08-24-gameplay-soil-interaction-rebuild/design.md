# Design — gameplay soil interaction rebuild

## Architecture

The new product path has one fixed-tick `SoilInteractionAuthority` and several
derived consumers:

```text
accepted chassis + articulation pose
  -> BucketToolDescriptor / swept semantic regions
  -> SoilInteractionAuthority
       -> PersistentTerrainField
       -> LocalActiveSoilPatch
       -> BucketMaterialLedger
       -> MaterialTransfer journal
       -> SoilResponseSnapshot
  -> derived Terrain3D/fallback mesh, fill surface, particles/clods, audio, HUD
  -> bounded work-equipment speed scale
```

`TerrainState` and `TerrainCommitScheduler` remain the persistence/revision
foundation. They may be extended or wrapped rather than replaced. Terrain3D,
fallback rendering, collision patches, VFX, and audio consume snapshots and
never become material owners.

## Bucket tool contract

Each model contract defines simplified local-space regions tied to semantic
bucket frames rather than raw GLB triangle topology:

| Region | Stable terrain | Active soil |
| --- | --- | --- |
| teeth / main cutting edge | penetrate and initiate failure/cut | collide and guide |
| side cutters / leading side edges | side-cut and widen | constrain/lateral push |
| floor / wear plate | shallow scrape, scoop, grade, compact | support and carry |
| outer back / side plates | push, back-drag, grade, compact | push and deflect |
| inner shell | no independent stable-terrain deletion | contain, friction, compress |
| opening plane | no terrain mutation | entry, overflow, spill, dump boundary |

The runtime composes these regions from the same accepted bucket pose identity
used by interaction queries. A swept descriptor covers previous-to-current
fixed-step motion so fast movement cannot tunnel through the logical soil field.
Debug rendering is optional and presentation-only.

## Persistent field and active patch

The persistent field owns long-lived material. Its minimum gameplay schema is
stable height, loose thickness, material preset, and compaction. It keeps the
existing generation, revision, dirty-rectangle, snapshot, and scheduler
discipline.

One patch follows the currently active machine/tool. Because dump occurs at the
bucket, the same 3–5 m patch covers the release stream and receiving ground; a
second simultaneous patch is not part of this scope. Fixed budgets cap cells/
particles, neighbors/constraints, substeps, memory, and work per tick. Patch
activation converts an explicit volume from persistent cells into active
material; sleeping, boundary-crossing, or evicted material is conservatively
rasterized back into loose thickness and compaction before resources are reused.

The prototype compares a CPU fixed-grid/particle path with a Godot compute path
only as needed. Selection criteria are visual behavior, bucket coupling latency,
debuggability, platform support, and measured balanced-profile budget. A coarse
CPU/fixed-grid implementation remains the low/fallback option if GPU compute is
selected for balanced/high.

## Transaction and authority model

Every accepted material movement receives a generation-scoped transfer ID and
stable source/destination compartments:

```text
persistent_stable|persistent_loose
  <-> active_patch
  <-> bucket_ledger
  <-> released_or_settling
  -> persistent_loose
```

One tick computes candidate interaction, validates capacity/generation, applies
all compartment deltas, publishes a journal entry, and only then exposes derived
events. Transactions are atomic from product state readers' perspective. Mass,
volume, material preset, and provenance are aggregate authority fields; visual
representatives can be spawned or culled without changing them.

The bucket ledger retains capacity, fill ratio, mass, center of mass, and a
coarse fill distribution. Entering material is credited by the accepted opening
flux from the active patch, not by later Jolt-sphere coincidence. Dump/spill
debits the same cells and creates active/released material in the same
transaction.

## Game-feel response

The authority emits normalized phase and intensity rather than hydraulic values:

- phase: free, contact, scrape, cut, load, near_full, overflow, dump, blocked;
- intensity: 0–1 engagement/load scalar;
- recommended work-equipment speed scale and presentation accents;
- fill ratio, material flow rate, and coarse resistance band.

The equipment controller clamps speed scale to a safe nonzero range, smooths
attack/release, and applies it only to work-equipment commands affected by soil.
It does not synthesize pressure/force telemetry or alter neutral, lifecycle,
emergency recovery, track control, or authoritative accepted-pose identity.

## Quality and presentation

Low/balanced/high may alter active-patch resolution, visual representative
density, solver substeps, dust/clod count, fill-mesh tessellation, and update
cadence. Aggregate transfers, capacity, fill ratio, and lifecycle outcomes must
remain equivalent within quantization tolerance.

The existing `SoilParcelPool` changes roles in primary mode: it may render a
bounded number of hero clods sourced from accepted transfer events, but it may
not call bucket credit, release debit, or terrain deposit APIs. In legacy mode
it retains its current compatibility ownership unchanged.

## Migration and rollback

Modes are explicit: `legacy`, `shadow`, and `active_patch`.

- `legacy`: current analytic brush + parcel transport owns material.
- `shadow`: current owner remains active; new tool/patch/ledger computes
  candidates and comparison telemetry but cannot mutate product material.
- `active_patch`: the new authority exclusively owns cut, bucket entry/release,
  and settle. Legacy parcels are visual-only or disabled.

Mode changes occur only after a reset/model/authority generation transition.
No in-flight material is migrated between owners. A mismatch, unsupported
compute path, or initialization failure falls back on the next clean generation;
it never switches owners halfway through a scoop.

## Evidence and tests

Unit tests cover tool-region geometry, swept classification, transaction
conservation, patch activation/settle, bucket capacity/fill, speed scaling, and
generation cleanup. Integration tests use real offline product motion on both
models and must obtain nonzero payload without test-only credit. Visual evidence
covers cut, scoop, carry, spill, dump, pile settle, push/back-drag, grading, and
fallback parity at low/balanced/high.
