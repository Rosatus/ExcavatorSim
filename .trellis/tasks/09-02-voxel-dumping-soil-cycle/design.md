# Design - authoritative dump and soil cycle

The parent design plus accepted foundation/cutting contracts are authoritative.

Bucket mass releases at a bounded per-tick rate only when opening orientation,
position, generation, zone inset, and local support are valid. The authority
maps mass through loose bulk density to a small union of smooth ellipsoid/path
deposits. Accepted SDF material change and bucket debit form one transaction.

A sparse chunk-aligned fixed-point material field stores stable mass, mobile
mass, and mobile compaction state per touched cell, atomically beside SDF in the
same authority. It distinguishes initial stable material from loose and
compacted deposits without becoming a second writer. Deposition fills measured
free volume with mobile mass, never reclassifies overlapping stable mass, and
merges repeated mobile deposits by a deterministic weighted compaction rule.
Only dirty surface neighborhoods enter the repose queue. Each fixed iteration
makes paired subtract/add transfers from slopes above the configured repose
angle, in canonical coordinate order, under strict voxel/block/iteration
budgets. It stops with remaining work queued rather than expanding globally.

Track compaction consumes accepted contact footprints and load, operates only
on loose flags, and changes density/shape under conserved mass and bounded rate.
Its dirty blocks use the same mesh/collision tickets as cuts and deposits.

Out-of-zone proposals fail before debit. Particles/clods are pooled presentation
events keyed by committed transaction ID. Re-excavation has no special path: the
existing cutter removes deposited SDF and credits the same bucket ledger.

## Continuous-cut performance redesign

### Observed bottleneck

The current representative coalesced cut takes about 42 ms while commits occur
at up to 20 Hz. Each commit copies a haloed VoxelBuffer, converts it sample by
sample in GDScript, stamps many overlapping capsules, scans every cell with a
tetrahedral volume estimator, hashes the complete before/after arrays, writes
the complete buffer, and pastes it. Capacity clipping repeats most of the
window calculation fourteen times. Successful mutation then triggers a full
sparse-material digest and asynchronous mesh/collision rebuilding. This cannot
meet a 16.7 ms physics budget reliably through cadence tuning alone.

### Recommended product path: native real-time excavation

Accumulate the continuous bucket surface sweep in packed point/radius arrays,
split it on mesh-block boundaries, and execute bounded `VoxelTool.do_path`
removals through the native Voxel Tools implementation. Cut admission still
validates direction, speed, generation, protected shell, and editable bounds.
Runtime captured mass is estimated from swept volume multiplied by bounded SDF
occupancy probes and clamped by capacity. A sparse per-block/cell coverage cache
prevents repeated empty-space passes from repeatedly crediting the bucket.

The runtime transaction retains identity, estimated volume/mass, edited block
set, and readiness latency, but drops full before/after SDF digests and exact
tetrahedral integration from the physics hot path. Exact diff/conservation
remains available to focused diagnostic tests or an explicit offline validation
path. Visual meshing remains asynchronous. Collision publication is debounced
per dirty mesh block and may lag visual edits by a bounded 2-4 physics frames;
Jolt continues using the last acknowledged collider meanwhile.

### Deep-insertion geometry: authorized swept occupancy

The present cutter removes only capsule nets from `teeth_main_edge`,
`left_side_cutter`, and `right_side_cutter`. `floor_wear_plate` and
`inner_shell` contribute only sparse point trails, while outer regions do not
cut. That geometry cannot clear the volume occupied by a deeply inserted
bucket and therefore permits interior residuals and thin roofs.

Replace it with three related but separately gated layers:

1. **Leading-front authorization.** Teeth and side cutters retain the SDF
   contact, into-material velocity, continuity, generation, capacity, and zone
   checks. No leading authorization means no terrain mutation by any bucket
   wall.
2. **Trailing swept occupancy.** For each accepted interpolated bucket pose,
   derive dense cross-section ribbons from the contract floor, inner shell,
   side cutters/walls, and bounded relevant outer trailing surfaces. Clip every
   ribbon to the half-space behind the accepted cutting front and to the
   contract-derived cavity depth. Rasterize the ribbons as a small deterministic
   set of native `do_path` calls. The union is a filled occupancy/clearance
   envelope, not the whole visual-mesh hull and not sparse corner capsules.
3. **Bounded overburden cleanup.** When the accepted inner-shell sweep is more
   than a small threshold below the initial soil surface, generate a fixed
   width/depth grid of vertical native paths from the bucket roof to that
   surface. This deliberately makes the local excavation heightfield-like and
   removes unsupported voxel roofs without a connected-component search. The
   cleanup remains inside the bucket footprint, is absent for shallow passes,
   and cannot run without leading-front authorization.

The occupancy and roof-cleanup volumes feed the same approximate captured-mass
estimator and sparse coverage cache, so cleanup cannot credit the bucket twice.
Outer back and side surfaces can clear soil only as trailing members of an
already authorized cut; contact from those surfaces by themselves remains
support/obstruction rather than deletion.

Expected geometry tradeoffs:

- The contract regions are oriented boxes/segments, not a watertight bucket
  mesh, so the filled envelope is a model-specific approximation. It may cut a
  few centimeters beyond the visible sheet metal unless calibrated per model.
- Dense ribbons trade fewer residuals for a slightly rounder/wider cavity. Too
  sparse leaves holes; too dense increases native edit and remesh work, so the
  ribbon count must be fixed and budgeted.
- Overburden cleanup intentionally removes the soil column above a deeply
  inserted bucket even when the exact metal surface never touched every voxel.
  This prevents floating shelves and makes cuts readable, but forfeits tunnels
  and can enlarge deep cuts near steep banks; its path grid and footprint must
  remain fixed and bounded.
- Collision still follows the bounded debounce and can briefly represent the
  pre-cut roof after the visual soil has disappeared.

Dump, settle, and compaction become lower-priority work. They pause while a cut
is active and drain only from a fixed idle-time budget. Repose can use fewer,
larger native add/remove shapes rather than repeated fourteen-pass fits.

## Native batched-dump performance redesign

### Observed bottleneck

The interactive deposit path still uses the pre-native exact pipeline. A soil
proposal copies and scans a haloed voxel window, applies GDScript add shapes,
computes cell additions with tetrahedral fractions, and can repeat blending and
cell integration for fourteen capacity-search iterations. The settle path can
perform multiple equivalent fitted remove/add passes. Because the authority can
commit at 20 Hz, falling soil exposes this work as a regular hitch even though
the particles and pooled clods are comparatively cheap.

Bucket-fill presentation adds a secondary allocation source: status snapshots
copy arrays and dictionaries on physics frames, and small fill-ratio changes can
rebuild an `ArrayMesh` repeatedly throughout a dump.

### Deposit admission and coalescing

Keep release intent inside `VoxelExcavationAuthority`. Each valid pose performs
only bounded checks and accumulates requested loose mass into one pending batch
for the current landing neighborhood. A neighborhood change flushes the old
batch before opening a new one, so separate piles are not merged. The default
coalescing deadline is 100 ms; dump-end, reset, generation change, or capacity
boundary also forces an immediate decision.

Pending mass is reserved conceptually but is not debited from the bucket until
the batch commits. Before native mutation, the authority freezes transaction
identity, generation, editable bounds, one cached support result, requested
mass, bounded free-space probes, affected blocks, sparse material mutations,
and journal data. Any rejection happens here and releases the reservation. Once
the native edit begins, no ordinary validation branch may reject the staged
transaction because Voxel Tools does not expose rollback for the edit.

### Native mound and ledger contract

Convert accepted loose volume into one short native add path or a fixed small
set of overlapping spheres/paths. Radius and height derive from the configured
loose bulk density and repose angle, while sparse free-space probes cap mass
accepted near existing solids. Shape count is constant and independent of the
number of visual particles.

The soil ledger, not integrated SDF geometry, is authoritative at runtime:

```
validated release intent
    -> pending batch (<= 100 ms, one landing neighborhood)
    -> pre-staged admission/material/journal data
    -> fixed-count native VoxelTool add
    -> exact bucket debit == exact mobile-soil credit
    -> one transaction event + deduplicated readiness tickets
```

Native geometry may differ from credited volume at partial cells or where the
mound overlaps existing soil. Record requested/accepted mass, probe occupancy,
shape parameters, native-edit time, and the declared approximation error band;
do not recover exact volume by returning to full-window binary fitting.

### Repose, readiness, and interaction priority

The native mound is born with a repose-shaped profile, so an active dump does
not enqueue continuous SDF settle transfers. The previous deterministic solver
remains available to focused diagnostics. If visual review shows that a final
correction is necessary, schedule at most one bounded native correction after
dump-end and only under the existing idle budget; cutting and active dumping
always take priority.

Merge dirty blocks from the whole batch before issuing mesh/collision work.
Only one outstanding readiness ticket per block/generation is allowed, and
later batches extend the dirty revision rather than starting parallel polling.
Jolt continues to use the last acknowledged collider until the replacement is
ready, accepting the already-approved short visual/collision mismatch.

### Presentation path

Committed deposit events drive a continuous pooled falling-soil effect whose
lifetime bridges the 100 ms batch cadence. Bucket fill uses a quantized cached
level, updates no faster than 10 Hz and only after a five percentage-point
change or dump-end, and reuses mesh/material resources instead of allocating a
new mesh for every small ledger change. Status consumption becomes
revision/event-driven where possible. Active clods use a free list rather than
repeated full-pool scans; their fixed pool and particles remain visual only.

### Failure and rollback shape

- Before native edit: reject without bucket debit, mobile-soil credit, or
  readiness work; emit the existing deduplicated diagnostic.
- After native edit starts: finish the pre-staged ledger/journal transaction and
  report any unexpected publication failure as a terminal authority fault. Do
  not attempt a second compensating voxel edit in the same frame.
- A reset or generation change discards uncommitted pending batches without
  debit. Already committed batches follow the existing generation/reset rules.
- The old exact deposit/settle code remains reachable only from focused
  diagnostic tests during rollout, permitting a code-level rollback without
  making it the interactive default.

### Accepted tradeoffs

- Terrain growth can trail the visual release by up to 100 ms and may appear in
  small steps; dump-end flush bounds the final delay.
- Mound shape/volume is approximate and may merge slightly into prior soil.
- Repose is represented primarily by the generated shape rather than granular
  flow, so small avalanches and individual clod landings are not simulated.
- Collision can lag the visual mound by a few physics frames.
- These losses are accepted in exchange for eliminating repeated exact-fit and
  continuous-settle stalls while preserving exact ledger transfer.

## Shared native-edit risks

- Bucket mass is approximate, especially at partial-cell boundaries and when
  revisiting complex cavities. A coverage cache can bound drift but cannot prove
  exact SDF-volume conservation.
- Native edits have no project-visible dry-run/rollback result; admission must
  be correct before mutation, and failures after mutation cannot be atomically
  undone through the current API.
- Bounded collision debounce permits short-lived visual/collider disagreement;
  the bucket or track may overlap the newly cut surface for a few frames.
- Coarser block/tile batching can create a small delay between bucket movement
  and visible removal, though it avoids the present long stall.
- Transaction digests and affected-cell counts become diagnostic/offline data,
  not per-cut runtime truth.

## Alternatives considered

1. Optimize the existing exact GDScript pipeline with dirty-cell masks,
   one-pass capacity clipping, packed mutation arrays, cached status, and fewer
   hashes. This preserves conservation semantics but remains exposed to large
   GDScript windows, GC, and synchronous copy/paste; it is a useful preliminary
   cleanup, not a reliable final latency solution.
2. Increase voxel scale from 0.125 m to 0.20 m and lower commit cadence. This is
   cheap and can remove roughly three quarters of sample work, but produces
   visibly chunkier cuts, poorer tooth/sidewall fit, delayed feedback, and still
   retains worst-case fourteen-pass stalls.
3. Add a custom C++/GDExtension or maintain a Voxel Tools fork that performs the
   exact diff, capacity clipping, and mass reduction natively. This can preserve
   precision and achieve real-time speed, but adds native ABI/build/package
   maintenance, platform-specific debugging, and a materially larger delivery
   scope. It is the follow-up route if exact runtime conservation is mandatory.
4. Move the current algorithm to a worker thread. VoxelTool access and revision
   ordering cannot be assumed thread-safe, paste still returns to the main
   authority, and stale edits need cancellation/rollback. It adds latency and
   races without removing the core work, so it is not recommended.
5. Reduce only particle/clod counts. This may trim presentation overhead but
   leaves the synchronous exact deposit and settle fits intact, so it cannot
   address the primary hitch pattern.
6. Run exact deposits on a worker thread. Voxel access, stale generation order,
   and main-thread publication/rollback remain unresolved, while the expensive
   fitting work still exists; it is not the recommended first intervention.
