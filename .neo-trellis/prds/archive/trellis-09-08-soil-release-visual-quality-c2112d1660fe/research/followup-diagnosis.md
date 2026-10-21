# Follow-up bug analysis: dump completion and lifting roof

User requested both fixes after manual use on 2026-09-08.

## 1. Root Cause Category

- Cross-layer contract / coverage gap: the earlier release test checked birth TTL and ledger transfers, not prolonged empty-bucket admission. Surface deposition returns unrepresented tiny remainders to the bucket. Those were repeatedly re-admitted; every tiny event was amplified to at least 5% GPU flow.
- Implicit assumption / coverage gap: current teeth contact and inward motion were assumed to represent the entire active bucket sweep. On upward exit, they reject before the trailing shell finishes crossing shallow surface soil. Roof cleanup was deep-only; transform subdivision ignored rotational endpoint motion.

## 2. Reproduction and Why Earlier Checks Missed It

- `soil_dump_completion_test.gd` before the fix: after 20 simulated seconds, final two seconds still published 6 releases; bucket displayed empty, flight stock was 8440 mass quanta, last release 645 quanta. With 1,000,000 quanta/kg, this is milligram-scale residue, not useful visible flow. Logs: `output/dump-completion-before.*.log`.
- Final same test: 0 tail releases, 0 flight mass, retained bucket mass 8440 quanta, conservation error 0. New regression also checks visual teardown and stale snapshots.
- `_has_lift_exit_contact` initially passed analytic flat-SDF checks but missed the real zero-level surface because the runtime sampler rounds to voxel centers. The native fixture caught this; zero must count as occupied surface. Final actual SDF at a residual roof probe changed from 0 to 0.80874, and data revision advanced from entry cut to exit cut exactly once.
- Independent review caught the need for shallow exit cleanup even while the ordinary leading gate still accepts, and the exit depth strips were densified to cover the old inter-strip gaps. Numeric SDF output is evidence, not a brittle fixed-value assertion; regression requires actual occupied-to-air transition.

## 3. Prevention Mechanisms

| Priority | Mechanism | Action | Status |
| --- | --- | --- | --- |
| P0 | Lifecycle regression | Run continuous admission through inventory exhaustion; assert no tail releases or VFX | Done |
| P0 | Quantized terrain regression | Test actual VoxelTool surface before/after lift, not only analytic gate predicates | Done |
| P1 | Safe continuation | Require existing engagement, upward motion and bounded valid surface contact | Done |
| P1 | Geometry coverage | Test rotation-only subdivision and probes between exit depth strips | Done |
| P1 | Boundary contract | Forward final flight state; no voxel legacy flow fallback | Done |

## 4. Systematic Expansion

The same state-boundary issue applies to disable/re-enable, late subscribers and reset; targeted tests cover these without broadening runtime scope. Cutting tests retain unengaged withdrawal, inverted outer-shell contact, discontinuity and protected-zone rejection. Original-surface roof cleanup remains an intentional local approximation, not a connected-component solver for arbitrary terrain.

## 5. Knowledge Capture

Updated frontend client boundary and soil-release visual contract, task requirements, design and result. Human runtime inspection remains required for the exact reported pose and visual quality; headless assertions do not certify subjective appearance.
