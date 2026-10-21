# Soak main-thread performance

User requested committing the existing workspace, then running soak and attempting optimization (2026-09-28). Existing work committed as a3172ff, including validated relaxed exterior support and SY80U UID files.

Use the sole accepted SY135 2521-tick trace, normal/balanced Forward+, 5s settle. Preserve quality, sample geometry, transaction ordering and conservation. Measure fresh baseline, select evidenced main-thread work, implement correctness-preserving optimization, run focused parity/lifecycle tests and the same rendered soak. Report frame intervals separately from CPU/GPU, regressions and unresolved gates honestly. No push/export requested.

## Progress
Completed implementation and verification. See result.md and comparison.json. Existing workspace committed a3172ff; new optimization changes uncommitted. Valid baseline and final soak pass all current gates. CPU repeated work reduced, but P95/P99/max frame times did not improve; no claim of frame stability gain. Focused exact parity, model/attachment lifecycle, user-config isolation and backend evaluator tests passed. No further automatic checks needed unless new edits/findings arise.
