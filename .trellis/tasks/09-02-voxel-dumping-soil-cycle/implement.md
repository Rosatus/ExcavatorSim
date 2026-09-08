# Implement - authoritative dump and soil cycle

## Current pass — 2026-09-08

User authorized direct implementation and requested that final testing and
visual/runtime acceptance be performed manually by the user. Earlier automated
gate checklists below are historical; they are not rerun requirements for this
pass and their checked boxes do not certify the new algorithm.

- [x] Save incoming work as checkpoint commit `3a6f1d6`.
- [x] Audit repeated same-location deposition and persistent outlet mounds.
- [x] Replace product deposit brushes with a bounded disposable surface plan
  and one staged SDF publication, preserving the existing ledger/readiness owner.
- [x] Suppress voxel decorative mounds; use short continuous release segments,
  world-space particles, volume-budgeted clods and ground-height retirement.
- [x] Require clear downward orientation, a free outlet, and no active cutting
  before releasing; preserve uncommitted inventory on gate exit.
- [x] Godot `--check-only` for the changed authority and presentation scripts.
- [ ] User manual acceptance: scoop/curl/carry; continuous dumping at one fixed
  spot; moving dump; re-excavate the resulting mound; judge responsiveness.
- [ ] Archive after user acceptance.

- [x] Add typed deposit/settle/compact operations to the existing authority and
  journal; do not create a second soil state.
- [x] Implement opening/in-zone/support validation, bounded release rate,
  loose-density shape placement, and atomic inventory debit.
- [x] Add sparse stable/loose/compacted classification subordinate to SDF/mass.
- [x] Add deterministic paired repose transfers and bounded dirty work queue.
- [x] Add loose-only track compaction and collision-readiness integration.
- [x] Derive pooled falling soil/dust/clod events from committed transactions;
  add deduplicated out-of-zone rejection feedback.
- [x] Run focused mass-cycle, partial/full/out-of-zone/duplicate/stale/reset,
  repose, compaction, re-excavation, readiness, and bounded-work tests.
- [x] Run one stable representative performance gate after all algorithms stop
  changing; do not add a long repeated soak.
- [x] Prevent stable-ground driving from staging empty compaction transactions;
  bound compaction coalescing and retire stale readiness polling work.
- [x] Add per-stage timing and allocation counters for proposal generation,
  native/SDF edit, material accounting, status digest, mesh-ready, and
  collision-ready latency; capture one short continuous-cut baseline.
- [x] Remove full SDF/material digests and broad status reconstruction from the
  runtime cut path; retain explicit diagnostic/test entry points.
- [x] Replace GDScript VoxelBuffer cut stamping/integration with bounded native
  `VoxelTool.do_path` block batches and sparse repeated-cut coverage accounting,
  using the approved approximate runtime mass model.
- [x] Replace sparse floor/inner clearance points with contract-derived filled
  cross-section ribbons. Gate the complete trailing occupancy envelope behind
  an accepted teeth/side-edge cutting front; outer surfaces alone cannot erase.
- [x] Add a bounded deep-insertion overburden-column cleanup pass and include
  its estimated removal in the same coverage/mass transaction without double
  credit.
- [x] Debounce readiness per dirty mesh block, retain last acknowledged Jolt
  collider until replacement, and expose bounded visual/collider lag.
- [x] Pause settle/compaction while cutting; drain them under an explicit idle
  budget and prevent their queue from delaying interactive cuts.
- [x] Run focused deterministic geometry/admission tests and one short profiled
  digging pass. Human Forward+ validates cut feel and any collider lag; do not
  add a long soak or repeated automated visual run.
- [x] Add SY135 deep insertion tests: no solid remains in the accepted bucket
  envelope, thin unsupported roofs are removed, and back-brush/
  withdrawal/curl-without-engagement cases preserve stable terrain.

## Dump-hitch remediation phases

### Phase D1 - Measure and freeze contracts

- [x] Instrument the current deposit transaction with phase timings for support
  query, buffer/read staging, shape application, capacity fitting, material
  accounting, native/paste edit, digest/journal, and readiness issue. Capture
  one short partial/full-dump baseline; do not add a soak.
- [x] Freeze the batch/ledger contracts in focused tests before replacing the
  geometry path: no debit before commit, debit equals mobile-soil credit, and
  rejected/reset/stale batches are inert.

### Phase D2 - Coalesced native deposit

- [x] Introduce one typed pending-deposit batch per active landing neighborhood.
  Coalesce validated releases for at most 100 ms, flush on neighborhood change
  while the dump gate remains valid, and discard safely on dump-gate exit,
  rejection, reset, or generation change without debiting bucket inventory.
- [x] Pre-stage the complete accepted deposit transaction before mutation:
  cached support, bounds/generation, bounded free-space probes, sparse material
  mutations, affected blocks, ledger amounts, transaction identity, and journal
  data. Prevent all ordinary post-native-edit rejection paths.
- [x] Replace the runtime exact-fit deposit with one or a fixed small number of
  native `VoxelTool` add shapes whose parameters derive from loose bulk density
  and repose angle. Keep exact bucket debit equal to mobile-soil credit while
  recording the mound geometry as an explicit approximation.

### Phase D3 - Settle and readiness budget

- [x] Remove continuous settle work from the active-dump path. Default to the
  repose-shaped native mound; if required by focused review, allow only one
  bounded post-dump native correction under the idle budget.
- [x] Deduplicate mesh/collision readiness per dirty block and generation across
  deposit batches, preserving the last acknowledged Jolt collider until the
  new revision is ready.

### Phase D4 - Presentation allocation control

- [x] Make falling-soil presentation bridge the batch cadence without becoming
  authoritative. Quantize bucket-fill updates to five percentage points and at
  most 10 Hz, reuse mesh/material resources, make status consumption
  revision-driven, and replace repeated clod-pool scans with bounded free-list
  bookkeeping where measurements justify it.

### Phase D5 - Focused verification and human gate

- [x] Add fast deposit regressions for 100 ms/dump-end cancellation, landing-neighborhood
  split, partial/full capacity, exact ledger pairing, approximate geometry
  bounds, rejection/reset/generation safety, one-pending-batch bounds,
  no-active-dump settle work, readiness deduplication, and re-excavation.
- [x] Run one short profiled dump pass after the algorithm stabilizes. Require
  deposit/main-thread batch p95 <= 6 ms and p99 <= 10 ms, bounded readiness
  lag, no 20 Hz hitch pattern, and no unbounded visual allocations. Do not run
  paired soak, repeated automated visual playback, or a distribution build.
  - 2026-09-04 focused headless sample: native deposit commit `2.441 ms`
    (`1.389 ms` coverage, `0.578 ms` material, `0.052 ms` native edit), exact
    conservation; percentile/feel acceptance remains the Forward+ human gate.
- [ ] Ask the user for one Forward+ partial/full dump, mound growth, traversal,
  and re-excavation review. Record the accepted approximation, <=100 ms growth
  latency, stepped mound growth, and short collider lag as intentional.
- [x] Update the material-cycle spec.
- [ ] Commit and archive the child after the human milestone passes.

## Bucket-retention remediation phases

### Phase D6 - Runtime truth and dump admission

- [ ] Add concise, revision-driven diagnostics for live opening-down dot,
  contract/effective thresholds, dump-gate state, pending release mass, bucket
  mass, accepted deposit event ID, and frozen release pose. Use one short
  Forward+ reproduction to distinguish real ledger debit from visual-only
  leakage; do not add a soak.
  - Diagnostics are implemented and covered headlessly; the one short
    Forward+ reproduction remains part of the D9 human gate.
- [x] Enforce an initial effective full-dump threshold floor of `0.15`, validate
  each contract opening normal points out of its cavity, and remove the SY135
  negative-threshold path that admits horizontal/upward release. Preserve
  atomic pending-batch debit/credit; an upward curl cancels any release that has
  not crossed the commit boundary.
- [x] Add fast per-model contract-derived up/horizontal/down regressions. Up and
  horizontal poses held across multiple batching deadlines must not change mass,
  revision, pending deposit count, or accepted event ID; down remains the
  positive control.

### Phase D7 - Immutable release events

- [x] Carry an immutable typed release event through pending admission and
  commit: event/transaction ID, volume, release transform, opening normal,
  direction, and admission timestamp. Do not reconstruct it from the live pose
  after the coalescing delay.
- [x] Replace sticky voxel interaction/flow state with one-shot event
  consumption and a bounded TTL. Prove idle frames cannot replay or prolong an
  old dump.
- [x] Stop gravity flow and rigid-clod emission for `cut`; retain bounded dust
  or a short inward capture cue only. Reserve falling soil for committed
  deposit events.

### Phase D8 - Contained fill visual

- [x] Replace the open fill surface with a reusable closed shallow bucket-local
  volume bounded by the cavity proxy. Keep the scalar ledger authoritative,
  retain 10 Hz/five-percentage-point quantization, and add no colliders or
  per-grain bodies.
- [x] Add focused visual-contract tests for cavity-bounded vertices, stable
  bucket-relative transform, no cut-triggered falling flow/clods, immutable
  delayed-event pose, and event expiry.

### Phase D9 - Human acceptance and closure

- [x] Run the existing focused headless authority/presentation suites once after
  implementation stabilizes. Do not build distribution packages or run a long
  soak.
  - 2026-09-04: voxel authority, visual mound/release, voxel world,
    soil-interaction authority, arcade stamp, voxel material, schema, and Web
    lifecycle checks passed. Existing `bucket_soil_tool_test.gd` still reports
    its pre-existing floor/scrape classification failure; the broader arcade
    world smoke also still fails its clean-generation binding precondition.
- [ ] Human Forward+ gate for both models: scoop soil, curl opening upward,
  lift/slew and hold for five seconds with no mass loss or falling-soil VFX,
  then rotate clearly downward and observe one correctly placed dump event.
- [ ] Record the calibrated threshold and accepted approximation, update the
  material-cycle spec if the executable contract changed, then commit and
  archive only after the human milestone passes.

### Phase D10 - Retention correction and test capacity control

- [x] Move the unlimited collection-capacity override into an Advanced-menu
  test switch and default it off. Switching is non-destructive; restoring the
  contract capacity rejects while retained mass exceeds that capacity.
- [x] Decouple effective collection capacity from the contract-relative visual
  fill ratio so unlimited testing still produces a readable contained fill.
- [x] Require a continuously valid dump gate for 50 ms and cancel pending or
  queued-but-uncommitted releases when the opening leaves the gate. Preserve
  bucket mass, voxel revision, and accepted event identity on cancellation.
- [x] Correct the hash-bound opening-normal sign for supported contracts using
  the cavity-side invariant, and add focused capacity/cancellation regressions.
  - 2026-09-04: voxel authority (`deposit 1.693 ms` in the focused sample),
    material-field, release-presentation, and voxel-world integration tests
    passed. A Godot AI MCP main-scene run confirmed the Advanced switch defaults
    off, toggles live capacity `0.66 -> 1000 -> 0.66 m³`, and keeps visual
    capacity at `0.66 m³`.
- [ ] Human Forward+ check: confirm Advanced defaults off, toggle unlimited
  collection on, scoop/curl/lift without leakage, then point the opening clearly
  down long enough to produce a committed dump.

If native deposition cannot meet the budget, keep authoritative dump disabled
while optimizing; never fall back silently to visual-only piles or debit
inventory. Roll back to the prior code path only behind an explicit diagnostic
switch, not as the interactive default.
