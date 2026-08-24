# Implementation plan

1. [ ] Add generation-level mode selection and single-owner assertions.
2. [ ] Run scripted legacy/shadow comparisons and resolve unexplained deltas.
3. [ ] Wire active mode as the sole material owner at clean boundaries.
4. [ ] Convert/disable parcel transfer callbacks in active mode; retain hero clods.
5. [ ] Execute real SY205/SY135 cut/scoop/carry/spill/dump/settle and tool-role
       journeys across low/balanced/high.
6. [ ] Run lifecycle, initialization/runtime fault, fallback, and 20-cycle soaks.
7. [ ] Capture performance/error/visual/conservation evidence and human review.
8. [ ] Switch the default only after all gates pass; retain documented legacy mode.
9. [ ] Update specs/runbook, run full verification, commit, and archive children
       followed by the parent.

## Risk and rollback

- Default-mode change is the final reversible commit, not the first integration
  step.
- Runtime failure cannot mix owners; fallback requires a clean new generation.
- Legacy deletion is forbidden in this task even after default cutover.
