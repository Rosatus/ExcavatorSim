# Validation evidence

## Passed

- Godot import/parser check with 4.7.1 console executable.
- `bucket_passthrough_mode_test.gd`: fixed-tick UI request, destructive clear,
  terrain digest/revision/generation immutability, debug/test seam rejection,
  query/soil/effects counter deltas, SY205 -> SY135 runtime rebuild, reset, and
  normal restoration.
- `jolt_articulated_equipment_test.gd`: both models, including stale queued/
  applied support wrench clearing, full-motion synthetic query, and synchronous
  Jolt applied/pending payload clearing with a monotonic identity at mode entry.
- Focused ordinary regressions: excavation gameplay, conservative soil
  authority, active soil patch benchmark, TerrainState, Terrain3D authority
  equivalence, visual pass, and release candidate.
- Isolated Terrain3D source + Windows export validation. Evidence:
  `artifacts/validation/bucket-pass-through-release-final/run-summary.json`; all
  bucket-ground entry/exit immutability and query/soil/effects parity gates pass.
- Backend Ruff and mypy.
- Backend full suite: 185 passed with an explicit repository-local pytest
  basetemp. Product-soak focused suite: 7 passed, including rejection of a
  pass-through-only run with no normal-mode paired baseline.
- A clean-context independent review of the atomic payload clear and soak
  paired-coverage gate reported no P0-P2 findings.
- Rebuilt the tracked `godot/dist/index.html` Gateway entry, then ran the full
  standalone matrix inside the Pixi dependency environment with the Godot dummy
  audio driver: all 36 scripts passed, including CAN Gateway E2E.
- Final backend gates: Ruff and mypy passed; 186 backend tests passed with a
  repository-local pytest basetemp; provenance, standalone paths, and backend
  production smoke passed. The default global pytest temp cleanup still reports
  the pre-existing Windows `pytest-current` permission error after all tests run.
- The rendered paired artifact is
  `artifacts/benchmark/bucket-pass-through-paired.json`. It records machine,
  source revision, dirty state, trace identity and the alternating order
  `N/P, P/N, N/P` for both models. Fixed-step p95 medians were:
  - SY205: normal `0.610 ms`, pass-through `0.430 ms` (29.5% lower).
  - SY135: normal `0.591 ms`, pass-through `0.400 ms` (32.3% lower).
  All six pass-through cells passed; every targeted query/soil/effects execution
  delta was zero and bypass deltas advanced by about 5,400 ticks.
- Known retained baseline exception: the artifact root remains `pass=false`
  because ordinary-mode rendered-frame p95 exceeded the existing 16.7 ms gate
  in SY205 (`31.38/16.74/18.47 ms`) and SY135 repetition 3 (`18.75 ms`). All
  fixed-step ceilings, pass-through rendered ceilings, lifecycle, telemetry,
  work counters and paired median comparisons passed. No release threshold was
  relaxed and the failed ordinary samples remain in the evidence.

## Environment / remaining release evidence

- The focused subjective visual/layout review remains a human milestone; the
  automated visual, UI, source/export, terrain-immutability and penetration
  contracts passed. The task is archived at the user's request with the normal
  rendered-frame baseline exception above explicitly retained.
