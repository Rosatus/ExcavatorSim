# Implementation plan

1. [ ] Inspect and run the existing `visual_evidence_capture.gd` path unchanged.
2. [ ] Record the existing raw double-model balanced-quality core set and note
       the lifecycle, journey, error-log, and performance-evidence gaps.
3. [ ] Route lifecycle/model transitions through ProductSession; add the minimum
       deterministic journey checkpoints, checked file output, metadata, and
       focused completeness tests.
4. [ ] Generate the complete SY205/SY135 × low/balanced/high ×
       carry/dump/terrain/support matrix, the ten balanced-only journey captures,
       per-cell error/performance evidence, and interactive smoke observations.
5. [ ] Write the nine-dimension scorecard, evidence-linked backlog, acceptance
       targets, child ownership map, and nondeterminism decision.
6. [ ] Run focused capture tests, full standalone matrix, task validation,
       `pixi run verify`, provenance checks, and `git diff --check`.
7. [ ] Commit and archive this child, then start `operator-onboarding-hud`.

## Risky files and rollback

- `godot/client/tests/visual_evidence_capture.gd` may depend on render timing;
  retain deterministic settle waits and never loosen product assertions.
- Binary captures can inflate Git; decide tracked versus hashed external evidence
  only after measuring the raw matrix size.
- Main-scene product code is not modified in this child.
