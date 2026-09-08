# Residual native cuts blocked by credit receipts — 2026-09-08

## User evidence and reset of assumptions

User reported that the thin sheets still remain after three geometry fixes and asked for an open-minded reassessment. The earlier fixtures proved local geometry improvements, not resolution of the operator's actual trajectory. Inspecting the renderer and background writers remains a separate hypothesis: voxel legacy settling is bypassed, native settling is mobile-only, and Terrain3D has an ownership mask. These source checks do not prove the screenshot's renderer source. MCP reported ExcavatorSim Godot 4.7.2, game stopped; no live screenshot-state SDF was available. No game input or lifecycle was changed.

## Reproduction independent of the cutter

`voxel_residual_recut_test.gd` uses real product-radius native paths at small sub-voxel offsets. The first brush credits 4 sparse stencil cells and leaves target SDF -0.0916. Eleven subsequent overlapping brushes reach the same residual but all reject with `no_accounted_material`; SDF remains unchanged. See `output/lift-exit-followup/recut-before2.out/.err`.

The sparse sampler admits nearby solid cells beyond a brush's actual removed shape. `stage_approximate_cut` permanently skips cells with an earlier credit receipt until deposit invalidation. The native executor previously rejected the entire operation when that produced no new mass. Thus accounting deduplication suppressed real geometry, regardless of how accurate the cutter paths were.

## Fix and bounds

- Keep receipt-based mass deduplication and the fixed coverage stencil/calibration.
- A failed material stage can authorize geometry-only execution only if every current coverage coordinate is credited and the ledger still balances.
- Require a current solid sample strictly inside the new brush, with a 0.02-voxel margin. Collect candidates in the existing bounded coverage walk. The first review caught an expensive segments-by-cells loop; it was removed before final validation.
- Execute native removal without changing material state. Set `native_geometry_only`, advance data revision/readiness, journal it, and return `changed=true` through the normal transaction predicate. The flag permits only native approximate cuts, not empty deposits.
- Once no solid sample is touched, reject as `no_sdf_change`. Deposit invalidates credit receipts as before.

## Agent automated

Final normal/full-capacity test: `recut-final-capacity.out/.err`. Every zero-credit cleanup measurably changes SDF; target becomes +0.0458. Bucket mass and full material digest remain identical to the first credited cut. Subsequent air operations do not commit. Normal and full capacity both pass. Zero mass alone and zero-mass deposit flags do not authorize a transaction.

Seven checks passed (`recut-final-*.out/.err`): residual recut, material field, authority lifecycle, cutting performance/diagnostics, world integration, release visual quality/lifecycle, and dump completion. World integration emitted only the existing Terrain3D deprecated interpolation warning. Performance representative commit: 13.126 ms versus the previous approximately 11.9 ms; sparse coordinate outputs remain equal to the frozen legacy oracle.

The broad authority test had stale expectations predating the current 120ms dump confirmation, surface-patch deposit, retained sub-visual residue, and full-bucket overflow policy. Updated fixtures preserve real gate confirmation and mass balance; a protected thin loose slab must either compact or reject `no_loose_material` with byte-identical SDF. All authority assertions now pass.

## What remains unproven

This proves a real execution blocker capable of preserving thin residuals. It does not prove that every visible sheet in the user's unrecorded trajectory has this cause. Human reproduction of the screenshot remains pending. If it persists, retain the running scene for direct SDF/renderer ownership and transaction inspection rather than inferring another geometry patch from the image alone.

## Why earlier fixes were insufficient

Root categories: cross-layer contract and test coverage gap. We checked path/volume coverage and isolated clean cells, while failing to test repeated partial-cell cuts through mass admission and actual native execution. Frontend specs now explicitly separate credit receipts from geometry completion and require sequential native recut evidence. No additional cutter geometry adjustment was made in this round.

## Follow-up: direct lifting versus curl/down

User's next observation: direct lift leaves sheets; curling and lowering can remove them. MCP again reports the game stopped, so live trajectory remains unavailable. Source and new failing tests establish two admission bugs: stationary returns engaged=false before contact evaluation, and lift continuation probes only original surface SDF rather than deeper remnants. Downward motion can re-enter the leading gate, whereas lifting relies on prior engagement.

Fix: retain previously engaged SY135 contact through stationary frames without creating cuts; release it in air. Probe the actual lower-envelope-to-surface column, voxel-spaced with at most 32 intervals, for below-surface residue. No additional cut-volume expansion or ledger change.

`hold-before.err` records both new tests failing before modification. `hold-final-voxel_bucket_cutter_test` passes pause/contact retention, stationary air termination, below-surface residual continuation, and existing negatives. `hold-final-voxel_lift_exit_test` inserts a stationary frame after leading admission and before commit/lift, then verifies real SDF cleanup. Residual recut and performance gates pass (`hold-*` logs); representative commit 12.765 ms. These are bounded deterministic cases; the actual user trajectory is still pending manual verification, not declared fixed from a screenshot.
