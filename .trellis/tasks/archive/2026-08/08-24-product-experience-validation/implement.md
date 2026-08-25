# Implementation plan

1. [x] Add explicit before/after evidence phase metadata while preserving the
       frozen baseline workflow.
2. [x] Replace the hard-coded controls-visible baseline failure with a check of
       the real production onboarding/control copy.
3. [x] Close the current human-reported P0/P1 defects: runtime credit overlay,
       SY205 spawn heading, site-wide terrain support, collapsible operator HUD,
       and dual-model cab first-person view with reversible upper-shell
       transparency.
4. [x] Close the follow-up track-axis/input/test-graphics defects with explicit
       model-space and presentation-only contracts, then run their focused tests.
5. [x] Add XInput bindings with ISO dual-stick equipment control, independent
       trigger/shoulder track control, current-device prompts, per-model Joy axis
       direction calibration, and focused tests.
6. [ ] Run focused code tests for those five earlier changes, then run the exact 34-cell
       after matrix on the current implementation and fix only remaining P0/P1
       product integration defects revealed by it.
7. [ ] Run the existing full Godot and repository release gates once; reuse
       focused archived evidence instead of adding duplicate tests.
8. [ ] Record the before/after scorecard, automated journey ledger, performance
       evidence, P2 deferrals, and a compact human visual/audio/discoverability
       checklist.
9. [ ] Update the frontend boundary and release-candidate runbook, commit the
       automated closure, then request the single human review gate.
10. [ ] After human approval, archive this child and the product parent.

## Validation commands

```powershell
.\godot\client\tests\capture_visual_baseline.ps1 `
  -GodotExe 'E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe' `
  -EvidencePhase after -Model all -QualityProfile all
.\godot\client\tests\run_standalone_matrix.ps1 `
  -GodotExe 'E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
pixi run verify
pixi run soak-jolt-quality-matrix
git diff --check
python ./.trellis/scripts/task.py validate .trellis/tasks/08-24-product-experience-validation
```

The 15-minute release soak is run only if the shorter quality matrix or current
performance evidence exposes a release risk. Human review is not replaced by
assistant screenshot inspection or pixel thresholds.

The current after matrix remains pending until the human SY205 endpoint gate in
`human-review.md` accepts the corrected negative-side outward limit. The
superseded run made before that correction is diagnostic evidence only.

## Closure decision

On 2026-08-25 the user explicitly requested commit, push, and archival after the
focused code gates. Per the standing instruction to avoid additional assistant
visual inspection, steps 6-9 are closed as a documented release-gate waiver:
the superseded visual matrix is not promoted to passing evidence, no fresh
assistant visual review is claimed, and the remaining subjective checks stay
recorded in `human-review.md` for any later product pass.

## Rollback points

- Evidence-schema changes are isolated to capture tooling and can be reverted
  without touching runtime presentation or simulation.
- Raw captures are ignored artifacts; tracked evidence contains only manifests,
  summaries, hashes, and review decisions.
- A failed after journey remains evidence and blocks archival until its owning
  code is fixed or the PRD is explicitly changed.
