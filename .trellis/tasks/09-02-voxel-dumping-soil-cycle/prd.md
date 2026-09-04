# Voxel dumping and soil cycle

## Goal

Implement responsive in-zone authoritative dumping, repose-shaped loose soil,
track compaction, re-excavation, and conservation diagnostics without visible
cutting or falling-soil stalls.

## Requirements

- Depend on accepted foundation and cutting tasks; use their sole SDF/mass
  authority and collision-readiness contracts.
- Validate bucket opening/release state and debit inventory only for an accepted
  in-zone deposit transaction.
- Convert released mass to smooth loose-soil SDF deposits using a configured
  bulk density, support query, and bounded aggregate shapes.
- Mark deposits as loose and create the runtime mound with a repose-shaped
  native profile. Retain deterministic transfer settling for focused
  diagnostics or at most one bounded post-dump correction, not continuous
  active-dump work.
- Let track footprints compact loose material under bounded load/rate rules;
  untouched stable soil shall not be continuously flattened.
- Make settled/compacted deposits collidable, traversable, and re-excavatable
  through the same voxel authority.
- Reject deposits outside the work zone before bucket debit; provide one
  deduplicated diagnostic and transient visual effect.
- Preserve bounded queues and concise mass/conservation/readiness diagnostics.
- Eliminate perceptible periodic stalls while a bucket continuously cuts voxel
  soil. A representative cut must not consume a full 60 Hz physics-frame
  budget on the main thread.
- Treat real-time interaction latency as the product gate. Expensive digests,
  exact cell-volume integration, and background settling may not run
  synchronously on every accepted cut merely to preserve diagnostics.
- A deeply inserted bucket must not leave soil inside the swept bucket body or
  a thin unsupported roof above the newly opened cavity. Teeth and side cutters
  authorize cutting, while the floor, inner shell, side walls, and relevant
  trailing outer surfaces provide bounded occupancy/clearance geometry only
  behind that accepted leading front.
- Bucket-shell overlap alone may never authorize deletion. Clearance requires
  an active teeth/side-edge into-soil gate, compatible motion direction, a
  bounded contract-derived cavity depth, and the editable work-zone mask.
- Eliminate perceptible stalls while soil is released from the bucket. Runtime
  deposition may not execute repeated full-window SDF integration or iterative
  capacity fitting for every release tick.
- Coalesce validated releases for the same active landing neighborhood into one
  bounded pending deposit, with a default maximum accumulation window of
  100 ms and an immediate flush when dumping stops.
- Keep bucket debit and credited mobile-soil mass exactly paired at the
  committed-batch ledger boundary. The visible/native mound volume may use a
  bounded approximation based on sparse free-space probes and loose-soil bulk
  density; geometry is not the runtime mass authority.
- Apply an accepted batch through one or a fixed small number of native
  `VoxelTool` add shapes whose profile already approximates the configured
  angle of repose. Continuous per-tick SDF settling is not required during
  dumping; at most one bounded idle correction may run after the dump ends.
- Validate generation, zone, support, capacity, material mutations, and journal
  data before the irreversible native edit. A failed or rejected batch must not
  debit the bucket or credit deposited soil.
- Coalesce mesh/collision readiness by dirty block for each deposit batch rather
  than issuing work per visual clod or release sample. Preserve the last
  acknowledged Jolt collider until the replacement is ready.
- Keep falling particles and clods presentation-only and pooled. They may
  interpolate between committed batch events, but may not become soil-volume
  authority or force terrain mutation at their visual cadence.
- Bound bucket-fill presentation updates to at most 10 Hz and a 5 percentage
  point quantized fill change, reuse visual resources where practical, and
  avoid rebuilding status snapshots or meshes every physics frame.

## Acceptance Criteria

- [x] Partial and full dump sequences create smooth piles whose ledger credit
  equals bucket debit; exact legacy geometry remains within its declared
  discretization tolerance.
- [x] Piles relax toward the configured repose range without fluid-like global
  spreading, unbounded work, or mass drift.
- [x] Loose deposits become collision-ready, can support/obstruct the machine,
  can be compacted by tracks, and can be excavated again.
- [x] Stable initial soil is unchanged by ordinary track passage except where
  explicitly configured as loose material.
- [x] Out-of-zone, duplicate, stale, and reset-crossing dumps leave SDF and
  bucket inventory unchanged.
- [x] Repeated cut/dump/settle/compact/re-cut cycles remain deterministic and
  conserve mass within cumulative tolerance.
- [ ] Human Forward+ review accepts pile appearance, behavior, traversal, and
  re-excavation without noticeable sustained stutter.
- [ ] Continuous cutting has no regular 20 Hz hitch pattern; captured telemetry
  reports main-thread edit p95 <= 6 ms and p99 <= 10 ms over a short focused
  digging pass on the development machine.
- [ ] Cut geometry remains continuous and clean at ordinary bucket speeds;
  repeated passes through already-empty space do not visibly refill the bucket.
- [ ] A representative deep vertical/diagonal insertion leaves no connected
  solid samples inside the accepted swept bucket occupancy envelope and no thin
  unsupported ceiling in the bounded cleanup halo.
- [ ] Curling or withdrawing an unengaged bucket, and brushing stable ground
  with its back/outer shell, does not delete terrain.
- [ ] Continuous partial and full dumping has no regular 20 Hz hitch pattern;
  short captured telemetry reports native deposit/main-thread batch p95 <= 6 ms
  and p99 <= 10 ms on the development machine.
- [ ] A continuing valid dump becomes visible in terrain no later than the
  100 ms coalescing bound, and ending a dump flushes its final accepted mass on
  the next authority commit without leaving a stranded pending batch.
- [ ] Every committed deposit pairs bucket debit and credited mobile-soil mass
  exactly in the ledger, while native mound geometry remains within the
  declared approximate-volume tolerance. Rejected, stale, duplicate,
  reset-crossing, unsupported, and out-of-zone batches change neither side.
- [ ] An active dump produces at most one pending batch per landing
  neighborhood and does not run the iterative exact-fit or continuous settle
  hot paths. A completed dump creates a readable repose-shaped mound without
  requiring per-frame soil relaxation.
- [ ] Deposit readiness requests are deduplicated per dirty block, and the
  visual/collider lag remains bounded without blocking the physics frame.
- [ ] Falling-soil visuals remain continuous enough to mask the 100 ms terrain
  batching, while bucket-fill mesh/status work stays bounded and pooled clods
  do not grow unbounded.

## Out of scope

- Per-grain rigid-body/DEM/MPM/SPH soil.
- Deposits on Terrain3D hard ground.
- Final removal of legacy excavation code.
- Persistence.
- Per-particle collision, granular landing, or particle-driven terrain edits.
- Restoring exact tetrahedral SDF-volume integration to the runtime dump path.
- Continuous fluid-like or per-frame repose simulation while a dump is active.

## Key product decision

- Runtime bucket mass may use a bounded sweep-volume estimate in exchange for a
  native VoxelTool cut path. Exact SDF-derived conservation is retained for
  focused diagnostics rather than required on every runtime cut.
- SY135 is the sole product acceptance model for this performance/geometry
  pass. Shared contracts must remain parseable for SY205, but SY205-specific
  geometry tuning and visual/runtime acceptance are deferred.
- The user accepts an approximately shaped mound, up to 100 ms terrain-growth
  latency, small stepped growth, and bounded visual/collider lag in exchange
  for responsive dumping. Ledger transfer remains exact even when native mound
  geometry is approximate.
- Runtime dumping uses coalesced native add shapes with a repose-shaped profile;
  the existing exact-fit and continuous-settle algorithms remain diagnostic or
  fallback material, not the interactive default path.
