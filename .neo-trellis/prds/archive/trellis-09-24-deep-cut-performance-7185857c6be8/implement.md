# Completed: deep voxel excavation performance

## Acceptance and scope
User accepted this round and explicitly requested batched commits and archival on 2026-09-24. This closes the task; no further approval is pending. This is user acceptance, not a claim that an additional manual visual test was performed. Retain voxels; no C++ migration this round.

## Delivered commits
- 1ad942e — canonical 2521-tick SY135 soak, exact single-pass physics-tick replay, trace SHA identity, appropriate replay gates and post-startup memory baseline.
- a1206d7 — actually enable threaded preparation in the scene (script must precede exported property), occupied-row coverage skipping and deterministic regression fixtures.
- 31c2e1f — native support-run classification/search/fill and publication of changed bounds only.
- 88c7184 — native deposit surface sign scan and precomputed route stencil, with frozen legacy solver parity.

## Evidence
Detailed report: diagnosis.md. Machine-readable before/intermediate/after metrics: comparison.json. Raw logs/captures remain local under output/new-soak-0924/{fixed-replay-baseline,threaded,final}; earlier depth/support checks under output/deep-cut-0924.

Same canonical input and corrected harness: max frame161.215→37.030ms, P99 28.698→17.563ms, >50ms77→0, P95 8.324→10.534ms. Do not hide the P95 distribution change. Final2521 inputs, no loop, PASS; queue sampled max2/age4ticks, worker max latency43.3ms, zero conservation error and no queue_full. No claim of locked60FPS.

PASS: voxel_cut_preparation_test (actual scene setting,421-frame execution equivalence, lifecycle/cancel/revision safety); soil_deposit_surface_test (30 exact old/new routing cases, scalar surface parity, domain expansion and pit unloading);8 backend soak tests; scoped Ruff/mypy; diff checks. Prior unchanged deep/support/full-SDF/refill/world tests remain valid. This commit/archive operation reused that evidence; it did not rerun heavy tests. Only an EOF whitespace cleanup followed validation.

## Remaining limits, not open requirements for this round
Five final frames exceeded33.3ms; signal publication peaked10.7ms. One readiness timeout occurred in both baseline and final; derived collision updates may still be pending with fallback preserved. Forty-two seconds cannot prove long-term leak freedom. Future strict16.7ms work should first attribute engine/harness/signal-callback wall time before selecting a C++ hotspot.

## Workspace boundaries
Pre-existing09-23-race-mode archival changes were excluded from these commits. Old soak bulk deletion had previously been rejected by policy: old local files remain retired, not deleted. No push was requested.
