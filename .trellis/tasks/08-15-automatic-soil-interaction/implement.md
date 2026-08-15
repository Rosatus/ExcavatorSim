# Automatic Soil Interaction Implementation Plan

## Phase A: Baseline And Contracts

- [x] Capture current terrain rebuild, particle, physics, and frame costs with Godot
      MCP/profiler; record balanced/high budgets and the target maximum commit
      latency before changing behavior.
- [x] Add validated SY205/SY135 capacity, cutting/top edge, tooth, cavity, opening,
      side/rear, support, density, and visual attachment contracts.
- [x] Add debug overlays and contract tests for both models; reject invalid contracts
      without reusing the other model's proxies.
- [x] Add rollout flags that distinguish production automatic soil, test/debug manual
      queues, clod presentation, and default-disabled backend feedback.

## Phase B: Fixed-Step Contact Foundation

- [x] Produce immutable generation-scoped `BucketPoseSnapshot` values after chassis
      and accepted articulation transforms are composed in the physics step.
- [x] Reset sweep history on teleport, stale/missing pose, reconnect, model/world
      generation change, rejection, and feature disablement.
- [x] Implement swept cut/push/intake/carry/spill/dump/rear-support classification
      using model proxies and terrain queries, with scripted tests for both models.
- [x] Keep the raw rear-support output independent of grains/clods so the following
      bucket-ground-lift child can consume it.

## Phase C: Transfer Ledger And Coarse Terrain

- [x] Implement bounded generation-scoped episode/transfer IDs and the one-owner
      lifecycle from coarse terrain through active, occupied/escaping, settled, and
      committed states.
- [x] Introduce `TerrainCommitScheduler` as the sole owner of `TerrainState` delta
      application, snapshotting, Terrain3D updates, and collision rebuild.
- [x] Coalesce scar/pile deltas by profiled cadence, threshold, and maximum latency;
      perform at most one mesh/collider rebuild per flush.
- [x] Add invariant, cap, stale-generation, force/discard cleanup, and no-direct-
      rebuild tests before connecting visual effects.

## Phase D: Bucket Material And Visual Flow

- [x] Implement compact bucket-local cellular occupancy with local gravity, intake,
      settling, heaping, side leakage, and dump behavior.
- [x] Derive volume, mass, center of mass, fill, and bounded resistance from occupied
      cells; use nominal/heaped capacity only for calibration and abnormal clamps.
- [x] Build a smoothed fill mesh and persistent GPU emitters for cut, intake, retained
      grains, spill, dump, impact, and dust from transfer/occupancy events.
- [x] Add optional pooled Jolt hero clods with isolated masks, hard caps, and sleep,
      timeout, distance, and generation reclamation. Clods never affect payload.
- [x] Route landed flow into settled pile deltas and smooth permitted compaction/LOD
      reconciliation without simultaneous transfer ownership.

## Visual Gate: Godot-Only Acceptance

- [x] Run scripted SY205/SY135 cut, carry, side-spill, dump, reset, reconnect, model
      switch, rejection, and feature-disable scenarios through Godot MCP.
- [x] Confirm all expected state transitions, single-state transfer ownership,
      configured caps, no orphan effect beyond 0.5 seconds, and no unbounded growth
      during a 30-second sustained run.
- [x] Capture balanced/high CPU, GPU, physics, object-count, terrain cadence, and
      commit-latency evidence; verify clods-off readability.
- [x] Do not begin feedback work until this gate passes. If intake/settling/spill is
      still visually unacceptable, stop and create a separate local-PBD planning
      review rather than silently expanding scope.

## Phase E: Optional Backend Feedback

- [x] Add backward-compatible HTTP capability preflight and conditional optional-
      capability hello/ack fields while leaving required capabilities unchanged.
- [x] Add `bucket_load_feedback` schema and bounded sender only when the feature is
      enabled, positively negotiated, and the WebSocket session is ready.
- [x] Add Python identity/range/sequence validation, latest-value mirror, monotonic
      timeout, health visibility, and lifecycle cleanup without replay authority.
- [x] Test new-client/old-backend and old-client/new-backend handshakes, absent/
      malformed preflight, unnegotiated sends, stale samples, and reset/reconnect.

## Phase F: Production Cutover And Quality Gate

- [x] Remove production Dig/Deposit UI nodes and F9/F10 bindings. Preserve direct
      queue APIs only for standalone tests or explicit debug builds.
- [x] Verify the rollback flag restores the prior aggregate diagnostic path without
      exposing manual controls in production or changing locomotion/articulation.
- [x] Run Ruff, mypy, full backend tests, provenance, `pixi run verify`, backend smoke,
      Godot standalone matrix, headless import, and `git diff --check`.
- [x] Repeat the final Godot MCP scenarios for both models and record profiler/live
      visual evidence in the task artifacts.

## Dependency Gate

Do not start `08-15-bucket-ground-lift-reaction` until the fixed-step pose snapshot,
raw rear-support classification, terrain scheduler, and generation cleanup contracts
are stable. The lift task must not depend on stochastic particles or Jolt clods.
