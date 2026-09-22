# Design - bounded volumetric excavation zone

## 1. Product decision

The final product has one excavation implementation:

```text
immutable Terrain3D hard worksite ──┐
                                    ├─ exclusive world-space ownership seam
bounded VoxelTerrain soil zone ─────┘

accepted fixed-tick bucket motion
  -> VoxelBucketCutter proposal
  -> VoxelExcavationAuthority transaction
  -> Voxel Tools SDF data mutation
       |-> asynchronous Transvoxel mesh
       |-> asynchronous static Jolt collider
       `-> material/particle presentation
  -> bucket/terrain mass ledger
```

The voxel zone is the sole mutable soil surface. The design does not adapt the
old heightfield patch, active-particle, or loose-flux solvers.

## 2. Voxel terrain choice and coordinates

Use `VoxelTerrain` with `VoxelMesherTransvoxel` and 16-bit SDF:

- constant detail is appropriate for one bounded work volume;
- it avoids LOD transitions and view-dependent edit resolution;
- official guidance places moderate smooth volumes around 300 voxels per axis;
- a `32 m` side at the starting uniform `0.125` scale is 256 voxels.

Starting configuration:

| Setting | Value |
|---|---:|
| World work-zone X | `[-16 m, 16 m]` |
| World work-zone Z | `[8 m, 40 m]` |
| World work-zone Y | `[-6 m, 4 m]` |
| Uniform node scale | `0.125` |
| Local voxel bounds | `256 x 80 x 256` |
| Initial surface | world `Y=0`, local `Y=48` |
| Mesh block | `16` voxels (`2 m` world side) |
| SDF storage | signed normalized 16-bit |
| Initial generator | deterministic flat SDF |

`VoxelWorkZoneConfig` owns every dimension, transform, scale, edit inset,
material constant, and budget. No consumer performs ad-hoc world/voxel
conversion. The foundation phase benchmarks `0.125 m` against one coarser
fallback (at most `0.20 m`) using the same physical strokes; it may choose the
coarser value only when the finer scale misses the stable frame/collider budget.

## 3. World ownership and seam

Extend the hard worksite toward +Z so the spawn remains at `(0,0)` with an
approximately 8 m approach. The voxel zone begins at `Z=8 m`; its southern side
contains the vehicle entrance.

One half-open ownership mask decides all rendering, support, and edit queries:

- inside the work-zone bounds: voxel authority;
- outside: immutable hard-terrain authority;
- boundary: a configured non-editable two-voxel shell plus static retaining
  skirt/curb owned by the site composition, with an aligned flat entrance.

Terrain3D presentation and the project hard-ground collider omit the voxel
interior. Voxel Tools mesh/collision never extends beyond its bounds. The
retaining skirt hides vertical volume edges but is not soil and cannot accept
dump transactions. The fallback hard-terrain renderer uses the same mask.

## 4. Runtime components and ownership

### `VoxelWorkZone`

Owns the `VoxelTerrain`, deterministic generator, Transvoxel mesher, material,
viewers, bounds, reset/recreate lifecycle, and raw Voxel Tools statistics. It
does not decide excavation.

Use one always-on zone viewer to keep the finite volume rendered and one
chassis-local collision viewer to prioritize work around the machine. Exact
v1.7 property names and scaled view distances are locked by the foundation API
probe, not guessed in product code.

### `VoxelExcavationAuthority`

Is the only object allowed to obtain and mutate a terrain `VoxelTool`. It owns:

- `generation`, monotonic `data_revision`, and transaction sequence;
- bounded cut/deposit/compact queues;
- bucket mass/fill state for the selected model;
- sparse chunk-aligned fixed-point material fields described below;
- transaction journal and conservation counters;
- dirty mesh/collision tickets and readiness projection.

All callers submit typed immutable proposals. Direct VoxelTool calls from Jolt,
scene scripts, effects, or UI are forbidden.

### `VoxelBucketCutter`

A pure fixed-tick geometry component. It converts the accepted previous/current
bucket transforms and per-model geometry contract into a canonical set of
capsules, side-edge sweeps, and a constrained clearance volume. It reads SDF
samples through an authority-owned read facade and never mutates data.

### `VoxelEditScheduler`

Coalesces proposals into bounded chunk-aligned commit windows, starting at
20 Hz (three 60 Hz physics ticks). It sorts operations by generation, tick,
sequence, operation class, and integer local coordinate. A dirty block is
processed once per window even when multiple surfaces overlap.

### `VoxelCollisionReadiness`

Wraps Voxel Tools asynchronous mesh/collider progress with project identities.
Each mutation supersedes older tickets for the affected blocks. A block becomes
support-ready only after the foundation-verified `is_area_meshed()` transition
for the newest ticket and the required safety delay/query check. Readiness is a
derived state and never changes accepted soil data.

## 5. Transaction and data flow

Each `VoxelEditTransaction` includes:

```text
generation, revision, sequence, fixed_tick_range, model/tool identity,
operation (cut | deposit | settle | compact), local voxel AABB,
canonical shape/input hash, requested mass, accepted mass,
pre/post SDF digest, affected block list, rejection reason
```

Commit flow:

1. Validate generation, model/tool hash, finite transforms, zone bounds,
   protected boundary shell, queue limits, and affected-area editability.
2. Copy only the affected SDF/material area plus a one-cell gradient halo.
3. Evaluate/coalesce the deterministic operation in local voxel coordinates.
   Prefer native bulk VoxelTool paths when they preserve the transaction; use a
   staged `VoxelBuffer` + one paste when arbitrary clearance/settling requires
   custom CSG. Never loop through the whole work volume.
4. Estimate pre/post represented material volume with a fixed cell/tetrahedral
   solid-fraction algorithm and reconcile it with the affected cells' fixed-point
   mass fields using the deterministic material rules below.
5. Enforce bucket capacity/mass before mutation. Slice or reject a proposal when
   the remaining capacity cannot cover its bounded geometric change.
6. Apply the accepted localized edit, advance `data_revision`, update material
   flags and mass ledger, mark affected blocks dirty, and emit one idempotent
   event. Rejected edits change nothing.
7. Mesh/collision finish asynchronously. Consumers use the ticket projection;
   they do not roll back accepted SDF because a derivative is late.

The foundation spike must verify whether v1.7 bulk copy/paste and editability
provide the assumed synchronous data boundary. If not, the scheduler owns
chunk `VoxelBuffer` data and publishes it to VoxelTerrain as a derivative; no
second writer is introduced.

## 6. Continuous bucket excavation

The cutter retains only useful model inputs: bucket link identity, tooth/main
edge, side edges, floor/back clearance primitives, opening direction, capacity,
and material density. The old point/heightfield classifier is not reused.

For every accepted fixed tick:

1. Convert both poses through the centralized work-zone transform.
2. Reject stale generation, invalid/teleport motion, or a sweep outside the
   editable inset.
3. Subdivide until the farthest semantic point moves no more than half a voxel
   per segment; rotation is bounded by the same far-point displacement rule.
4. Query SDF and its central-difference gradient around the cutting edge.
5. Enter engagement only when the edge overlaps matter and relative motion has
   a configured into-material component. Exit with hysteresis.
6. Union teeth/main-edge and side-edge capsule sweeps.
7. Add the bucket interior/floor clearance shape only behind the accepted
   leading cut plane and only while engagement remains valid. This removes
   residual spikes without making the entire shell an eraser.
8. Coalesce overlaps and clip the transaction to remaining bucket capacity and
   the protected zone shell.

The physics collider may lag the SDF; cutting evidence always reads accepted
SDF. Bucket equipment is kinematic, so the stale mesh is not permitted to veto
a valid edit.

## 7. Mass, bucket, dumping, settling, and compaction

Mass is the conserved quantity. SDF geometry and material accounting are two
atomically committed fields owned by the same authority, not independent
writers. Every touched cell stores fixed-point `stable_mass_q` and
`mobile_mass_q`; mobile cells also store a bounded compaction/density class.
There is no ambiguous single flag for a mixed surface cell.

Deterministic material rules are:

- cutting removes mobile mass first, then stable mass, in canonical cell order;
- partial cuts reduce a component by the measured solid-fraction change, with
  the last affected cell receiving the quantized residual so transaction mass
  is exact;
- deposits add mobile mass only into measured free volume and never reclassify
  an overlapping stable component;
- repeated deposits merge mobile mass by weighted fixed-point compaction state;
- compaction changes only mobile density and represented SDF volume;
- before publication, SDF solid fraction and mass-implied occupied volume must
  agree within a declared per-cell tolerance or the staged edit is rejected.

This makes transaction replay and cumulative conservation independently
auditable when stable and redeposited soil share one surface voxel. Displayed
volumes derive from material state:

- stable material uses configured bank density;
- bucket material uses bounded in-bucket bulk density and model capacity;
- dumped loose material uses lower loose density, so a pile may occupy more
  volume without creating mass;
- compaction raises density and correspondingly reduces represented volume.

The invariant is:

```text
accepted terrain mass delta + bucket mass delta = 0 +/- quantization tolerance
```

Cut transactions measure represented SDF/material change and credit the bucket.
A full bucket rejects further removal. Dump begins only from a validated opening
orientation and in-zone release path. It releases bounded mass per fixed tick,
finds support through SDF ray/gradient queries, and adds a small union of smooth
ellipsoids/capsules sized from loose density.

New deposits are marked `loose`. A bounded settle queue examines only dirty
surface neighborhoods and transfers material down/outward when the local slope
exceeds the configured repose angle. Transfer is paired subtract/add work in
one transaction so mass is conserved. The solver stops after a small fixed
iteration/work budget; it is granular-looking plastic relaxation, not fluid.

Track footprints may enqueue `compact` transactions only over loose flags.
Compaction changes density/shape under a fixed mass and rate cap. Stable initial
ground is not continuously flattened by track contacts.

Out-of-zone dump proposals are rejected before inventory debit and generate one
deduplicated diagnostic/presentation event.

## 8. Jolt and collision-lag behavior

Voxel Tools generated collision is the only Jolt surface inside the work zone;
the masked hard-ground collider is the only surface outside it.

- Soil edits overlapping current track support footprints are deferred until
  the footprint moves or the operation can be safely clipped.
- Track motion into blocks with a newer data revision than collision-ready
  revision is rate-limited/disarmed at the boundary; it is not allowed to drive
  blindly onto missing collision.
- A machine already supported by a ready block keeps normal Jolt operation.
- Bucket cut/support response reads authoritative SDF plus readiness metadata;
  it never treats a stale collider contact as current soil truth.
- Dirty work around bucket and tracks receives viewer/scheduler priority.

The foundation and integration stages must test real Godot Jolt behavior.
`is_area_meshed()` is necessary but not sufficient: support-ready publication
requires a bounded physics-query acknowledgement at known probes whose expected
solid/air result changed in the newest ticket. The foundation records the exact
v1.7/Godot-Jolt acknowledgement sequence as an acceptance artifact.

## 9. Presentation

Use one Voxel Tools-compatible triplanar soil shader visually matched to the
existing project soil family. Stable cuts show compact strata; loose deposits
show a slightly lighter/rougher classification derived from material flags or
texture weights selected in the foundation probe. No Terrain3D grass or plant
system is added to the voxel zone.

Dust, falling grains, and occasional clods are pooled events derived from
accepted transactions. They never affect SDF, mass, collision, or replay.

The perimeter uses retaining walls/curbs and clear markings, with a south entry
wide enough for both machines. Presentation dressing is moved around this
layout and has no collision/authority role unless explicitly declared.

## 10. Lifecycle and cutover

Startup creates deterministic initial SDF and empty bucket state. Reset:

1. stops/clears edit, settle, and visual queues;
2. increments authority generation;
3. detaches the old VoxelTerrain so late derivative work cannot re-enter;
4. recreates initial generator/data/viewers/collision;
5. publishes readiness only after the initial work surface is meshed/collidable.

There is no disk save/load in this task.

During development, a temporary selection seam may keep the current product
usable between child tasks. After final human acceptance, remove the old
heightfield cutting modes, active/loose material runtimes, parcel ownership,
and obsolete UI/status switches. Retain immutable hard-site generation,
Terrain3D presentation, machine/Jolt contracts, and bounded visual effects.

## 11. Diagnostics and budgets

Expose concise aggregates, never per-voxel logs:

- submitted/accepted/rejected/coalesced transactions and reasons;
- edit queue depth, oldest age, affected voxels/blocks, and commit time;
- data/mesh/collision revisions and dirty/ready block counts;
- Voxel Tools `remaining_main_thread_blocks`, dropped meshes/loads, and updated
  blocks where available;
- bucket mass/fill, terrain mass delta, conservation tolerance/error;
- settle/compact queue depth and capped work;
- track-motion/support gates caused by collision lag.

Starting budgets are hypotheses tested in Phase 1: 20 Hz edit windows, no more
than one bucket-sized dirty region per commit, and `mesh_block_size=16`. Product
acceptance targets 60 Hz fixed simulation and visually stable Forward+ play;
exact percentile limits are recorded from the foundation baseline before the
cutting task starts.

## 12. Risks and rollback

- Uniform `0.125` scale may make collision/mesh updates too expensive. The
  foundation task compares a coarser scale before committing the product.
- Voxel Tools does not expose a strict collider revision. The readiness proof is
  a mandatory spike gate with a changed-geometry Jolt query acknowledgement,
  not an assumption deferred to final integration.
- Arbitrary staged SDF CSG in GDScript may be slower than native bulk brushes.
  Benchmark both localized approaches and keep the authoritative interface
  independent of the chosen executor.
- Smooth SDF volume is approximate at the surface. Conservation uses mass plus
  a declared discretization tolerance and tests cumulative drift.
- Terrain3D/Voxel seam errors can create double collision. The ownership mask
  and seam test are completed before dynamic excavation is integrated.

If a foundation gate fails, no product cutover occurs. The task returns to
design to choose a coarser voxel scale or a project-owned chunk buffer executor;
it does not fall back to another heightfield excavation iteration.
