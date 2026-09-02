# Implementation plan - voxel excavation redesign

## Task map and ordering

The parent owns the final requirement set, architecture, integration review, and
cutover decision. Implementation proceeds through four child tasks in order;
each child is independently reviewable and archived only after its gate passes.

1. `09-02-voxel-work-zone-foundation`
2. `09-02-continuous-voxel-bucket-cutting`
3. `09-02-voxel-dumping-soil-cycle`
4. `09-02-voxel-excavation-product-cutover`

Do not begin child 2 until the real v1.7 collision-readiness and scale benchmark
from child 1 has selected a supported configuration. Do not delete legacy code
until child 4 has passed human product acceptance.

## Phase 1 - Voxel work-zone foundation

### Implementation

- [ ] Use Godot AI MCP to verify the connected custom editor/version, inspect
  ClassDB resources/properties, and author the isolated foundation scene where
  structural scene operations are supported.
- [ ] Add `VoxelWorkZoneConfig` with the approved `32 x 32 x 10 m` physical
  envelope, north-side transform, protected shell, entrance, centralized
  coordinate conversion, scale candidate, and budgets.
- [ ] Build a standalone Voxel Tools 1.7 API probe for generator, 16-bit SDF,
  Transvoxel, scaled bounds, viewer load, `VoxelTool` bulk operations,
  copy/paste, editability, statistics, `is_area_meshed`, reset/teardown, and
  generated Jolt collision.
- [ ] Benchmark `0.125 m` uniform scale and one coarser fallback using identical
  bucket-sized path/clearance edits. Record data-write, remesh, collider-ready,
  dirty-block, main-thread backlog, memory, and frame-time evidence.
- [ ] Select the smallest scale that passes the declared stable-once budget;
  persist the decision and tolerance in task evidence/spec.
- [ ] Add `VoxelWorkZone`, deterministic flat SDF initialization, zone/chassis
  viewers, Transvoxel material, readiness tickets, diagnostics, and reset.
- [ ] Extend Terrain3D/fallback hard-site generation toward +Z and apply one
  shared voxel-interior hole mask to visuals and hard-ground collision.
- [ ] Add retaining seam/entry presentation and relocate conflicting visual
  dressing; keep presentation-only nodes non-authoritative.

### Agent automated gate

- [ ] Custom-editor module/API probe passes from source and confirms SDF edits.
- [ ] Focused seam test proves exactly one visual/collision owner per sample at
  interior, protected boundary, entrance, apron, and exterior.
- [ ] Focused reset test rejects stale pre-reset readiness work.
- [ ] Focused Jolt test drives/ray-probes across the unedited entrance and proves
  the initial zone collider is ready before entry is armed.
- [ ] Run the chosen performance benchmark once after the candidate is stable;
  save concise metrics instead of streaming repeated soak logs.

### Human milestone

- [ ] Inspect one Forward+ foundation scene: material match, north-side layout,
  approach readability, no seam/hole, and smooth unedited traversal.

### Rollback point

- Product excavation remains on the current implementation. If scale or
  collider readiness fails, revise the voxel executor/config before child 2.

## Phase 2 - Continuous voxel bucket cutting

### Implementation

- [ ] Introduce `VoxelExcavationAuthority`, typed transaction records,
  generation/revision, bounded scheduler, SDF read facade, bucket inventory,
  dirty/readiness projection, and diagnostics.
- [ ] Introduce pure `VoxelBucketCutter` geometry from the shared model
  descriptors: cutting-edge/side sweeps, far-point subdivision, direction and
  engagement hysteresis, zone clipping, and constrained clearance volume.
- [ ] Implement localized transaction execution with native bulk primitives or
  staged buffer/paste as selected by Phase 1. Coalesce all overlapping surfaces
  into one ordered edit per dirty region.
- [ ] Implement represented-volume/mass measurement, capacity clipping, exact
  accepted ledger credit, idempotency, and discretization tolerance.
- [ ] Integrate accepted Jolt articulation snapshots without using stale
  collider contacts as removal evidence.
- [ ] Adapt bucket fill/payload/soil effects to the new ledger and remove old
  runtime work from the selected voxel path.

### Agent automated gate

- [ ] Pure geometry tests cover both model contracts, slow/fast translation,
  curl, rotation-only far-point motion, connected coverage, and no residual
  voxel inside the allowed clearance envelope.
- [ ] Negative tests cover stationary, above-ground, separating, teleport,
  stale generation, protected shell, outside zone, duplicate transaction, and
  full-bucket behavior.
- [ ] Fixed-input tests vary render frame cadence and assert identical ordered
  transaction/SDF/ledger hashes.
- [ ] Focused custom-editor runtime test performs repeated bucket-sized edits,
  asserts bounded queues/readiness, and records one stable performance run.

### Human milestone

- [ ] SY205 and SY135 Forward+ cuts are clean, continuous, aligned, responsive,
  and free of visible residual spikes for the representative slow/fast/curl
  strokes supplied in the test checklist.

### Rollback point

- Voxel zone remains available as foundation/demo; selected excavation may stay
  on the legacy path while cutter/readiness defects are corrected.

## Phase 3 - Authoritative dumping and soil cycle

### Implementation

- [ ] Add validated in-zone dump proposals, bounded mass release rate, SDF
  support query, loose-density deposit shapes, and accepted inventory debit.
- [ ] Add sparse material classification for stable/loose/compacted state that
  remains subordinate to the sole mass/SDF authority.
- [ ] Add bounded, paired remove/add repose relaxation over dirty surface
  neighborhoods with deterministic ordering and work budgets.
- [ ] Add track-footprint compaction over loose material only, conserving mass
  while changing density and represented shape.
- [ ] Reject out-of-zone dumps before inventory debit and emit one deduplicated
  diagnostic/visual event.
- [ ] Adapt pooled falling dirt/dust/clod effects to committed transactions.

### Agent automated gate

- [ ] Cut -> bucket -> dump -> settle -> re-cut sequences conserve mass within
  the declared tolerance across both model capacities and repeated cycles.
- [ ] Full bucket, partial dump, duplicate event, boundary clip, out-of-zone
  dump, generation reset, and derivative-lag cases change only allowed state.
- [ ] Repose and compaction queues remain bounded and deterministic; initial
  stable ground is not flattened merely by driving over it.
- [ ] Deposited pile becomes Jolt-collidable only through newest readiness and
  can be removed through the same cutter authority.

### Human milestone

- [ ] Dumped piles look soil-like rather than liquid, can be driven over and
  re-dug, and do not introduce noticeable sustained stutter.

### Rollback point

- Cutting/bucket inventory remains usable while deposition is kept disabled;
  never silently substitute a visual-only pile for accepted authoritative dump.

## Phase 4 - Product integration, acceptance, and cutover

### Implementation

- [ ] Move the product scene and operator diagnostics to the voxel authority;
  retain Bucket Pass behavior against the new path without restoring paired
  soak requirements.
- [ ] Finalize collision-lag motion/support gating for entry, travel, parking,
  excavation under/near tracks, deposits, reset, model switch, pause, and
  teardown.
- [ ] Complete status/HUD fields for readiness, backlog, bucket mass/fill,
  conservation, and bounded rejection reasons.
- [ ] Run final focused cross-layer audit: Gateway/Python contracts and non-soil
  input/motion/CAN paths must be unchanged.
- [ ] After manual acceptance, make voxel excavation the only product path and
  delete heightfield excavation solvers, active/loose soil runtimes, parcel
  ownership, duplicate collider/terrain mutation paths, obsolete toggles, and
  their now-invalid tests/docs.
- [ ] Retain hard-site generation/Terrain3D presentation, shared model/physics
  descriptors, Jolt machine authority, and reusable bounded effects.
- [ ] Update `NOTICE.md`, architecture, Godot integration, terrain/soil specs,
  test instructions, and package provenance to describe actual voxel ownership.

### Agent automated gate

- [ ] Parser/import plus focused authority, lifecycle, seam, Jolt traversal,
  both-model, reset, conservation, and stale-readiness regressions pass.
- [ ] Because shared authority/lifecycle code and native packaging change, run
  the full Godot standalone matrix once after the final source candidate is
  stable.
- [ ] Run source/export parity and packaged startup/module/collision smoke once
  only if the user authorizes release artifacts in the finishing turn.
- [ ] Run one final representative performance gate after all integration edits;
  do not repeat retired paired Bucket Pass soak.

### Human final acceptance

- [ ] Start on hard apron, enter the zone, traverse pristine/dug/deposited soil,
  park, cut with both models, fill, dump, compact, re-dig, reset, and repeat.
- [ ] Confirm cleanliness/alignment, material and seam appearance, responsive
  control feel, no noticeable sustained stutter, and no fall-through/snags.

### Cutover/rollback

- Legacy deletion occurs only after the preceding human result is explicitly
  accepted. Before deletion, the last pre-cutover commit is the rollback point.
  After deletion, rollback is Git-level, not a runtime product mode.

## Parent completion checklist

- [ ] All four child tasks are archived with their gate evidence.
- [ ] Parent PRD AC1-AC11 are mapped to passing child evidence or explicit human
  acceptance.
- [ ] Final code contains one mutable soil authority and no Terrain3D/voxel
  collider overlap.
- [ ] Specs describe actual ownership; obsolete heightfield claims are removed.
- [ ] Commit/push/archive occurs only after the user approves the final result.

