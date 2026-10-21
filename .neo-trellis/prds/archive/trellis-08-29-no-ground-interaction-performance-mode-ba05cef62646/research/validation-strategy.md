# Validation strategy research

## Deterministic behavior proof

- Add a standalone SceneTree test using the main-scene setup patterns in
  `godot/client/tests/excavation_gameplay_test.gd:158-190` and
  `godot/client/tests/release_candidate_test.gd:54-130`.
- Drive a fixed number of physics ticks with bucket commands that cross the
  authoritative surface. In bypass mode assert full accepted articulation,
  zero bucket query/support/cut/soil work counters, unchanged terrain identity
  and digest, unchanged ledger totals/payload, and no soil effects update.
- Re-enable ordinary mode and run the same command family to prove query/cut/
  payload/terrain counters advance and existing behavior returns.
- Cover SY205 and SY135, reset, model switch, Test Grid, Terrain3D fallback and
  recovery, and stale pending-work rejection.

## Performance evidence

- Add monotonic submitted/executed/skipped counters at subsystem boundaries.
  These prove work elimination without relying on noisy elapsed time.
- Extend the existing product soak harness rather than inventing a benchmark.
  It already warms up, disables VSync, captures fixed-step and render
  percentiles, memory, nodes, physics objects, and collision pairs
  (`backend/scripts/godot/jolt_product_soak.gd:35-46,96-145,287-337`;
  `backend/scripts/jolt_product_soak.py:58-108,160-303`).
- Run paired ordinary/bypass traces for both models at balanced quality. Keep
  the existing absolute release ceilings, and report relative fixed-step p50/
  p95 and CPU-work counter reductions. Avoid a brittle single-run mandatory
  percentage speedup; hardware scheduling and shader warm-up make that flaky.

## Regression and export gates

- Add the standalone mode test to
  `godot/client/tests/run_standalone_matrix.ps1`.
- Run the focused excavation/Jolt/authority/Terrain3D suites, then the full
  standalone matrix and repository verification.
- Extend the isolated Windows export smoke pattern from
  `godot/client/tests/run_terrain3d_release_validation.ps1:70-179` so source and
  exported builds report the same mode identity and behavior.
- Existing soak scenario gates require cut/dump/support and therefore need a
  mode-specific inverse scenario instead of reusing the ordinary PASS predicate
  unchanged (`backend/src/babylon_sim/product_soak.py:61-75`).

