# Implementation plan

1. [x] Add generation-level mode selection and single-owner assertions.
2. [x] Run scripted legacy/shadow comparisons and resolve unexplained deltas.
3. [x] Wire active mode as the sole material owner at clean boundaries.
4. [x] Disable parcel material callbacks in active mode; use patch representatives
       as the bounded presentation layer.
5. [x] Execute SY205/SY135 cut/scoop/carry/spill/dump/settle and tool-role
       journeys across low/balanced/high.
6. [x] Run lifecycle, initialization/runtime fault, fallback, and 20-cycle soaks.
7. [x] Capture performance/error/conservation evidence; defer one human visual
       review to `08-24-product-experience-validation` per user direction.
8. [x] Switch the code default after automated gates; retain documented legacy mode.
9. [x] Update specs/runbook, run full verification, commit, and archive this child;
       parent completion remains separate.

## Risk and rollback

- Default-mode change is the final reversible commit, not the first integration
  step.
- Runtime failure cannot mix owners; fallback requires a clean new generation.
- Legacy deletion is forbidden in this task even after default cutover.
