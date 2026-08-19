# Final interaction acceptance implementation plan

## Phase A - Lineage and planning convergence

- [x] Confirm all three 08-15 children are archived and record their implementation
      commits.
- [x] Replace the stale Python-joint/direct-offset authority text with the archived
      08-17 hybrid Jolt boundary.
- [x] Define separate release-endurance, quality-matrix, and live-visual gates.
- [x] Refresh implementation/check context for the current architecture.

## Phase B - Quality-aware soak contract

- [x] Add an explicit validated quality-profile option to the Python soak runner.
- [x] Pass the selected profile into the Godot benchmark before scene startup and
      verify the observed controller profile matches it.
- [x] Add model/profile identity to Godot and aggregate reports with an explicit
      schema-version change.
- [x] Extend shared report evaluation and backend regression tests for valid,
      missing, unknown, and mismatched quality profiles.
- [x] Preserve existing quick/release command behavior with explicit balanced
      defaults and add `pixi run soak-jolt-quality-matrix`.

## Phase C - Automated acceptance matrix

- [x] Run focused soak evaluator and CLI tests.
- [x] Run the 90-second six-cell SY205/SY135 x low/balanced/high matrix.
- [x] Confirm every cell has track, articulation, cut/load/dump/support,
      reset/reconnect, one runtime, zero telemetry drops, bounded history, and
      published performance/memory budgets.
- [x] Record report hashes and summarized results in task research.

## Phase D - Release endurance

- [x] Run `pixi run soak-jolt-release` for 15 minutes per model at balanced
      quality without changing the published thresholds.
- [x] Preserve raw reports/logs under `artifacts/benchmark/` and record hashes and
      result tables in task research.
- [ ] If either model fails, stop closeout and isolate the failure before editing
      product code.

## Phase E - Live visual evidence

- [x] Use Godot AI MCP to review SY205 and SY135 at low/balanced/high quality.
- [x] Capture loaded carry, dump/deposit, terrain-change, and support states with
      matching runtime/model/profile identity.
- [x] Build and commit a compact contact sheet plus observation/inference table.
- [x] Restore editor/project settings and stop all benchmark/backend processes.

## Phase F - Final quality and parent closeout

- [x] Run `pixi run verify` and `pixi run backend-smoke`.
- [x] Run the Godot standalone matrix with the explicit Godot 4.7.1 executable.
- [x] Run provenance validation, `git diff --check`, and
      `python ./.trellis/scripts/task.py validate`.
- [x] Update release evidence/docs without changing the architecture boundary.
- [x] Run `trellis-check`, commit the implementation, then archive this parent and
      record the session.

## Validation Commands

```powershell
pixi run pytest backend/tests/backend/test_product_soak.py
pixi run soak-jolt-quality-matrix
pixi run soak-jolt-release
pixi run verify
pixi run backend-smoke
.\godot\client\tests\run_standalone_matrix.ps1 `
  -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
pixi run python backend/scripts/verify_provenance.py
python ./.trellis/scripts/task.py validate 08-15-realistic-excavator-interaction
git diff --check
```

## Risk And Rollback Points

- `backend/scripts/jolt_product_soak.py` and its Godot runner are the primary
  change boundary; do not mix acceptance instrumentation with authority changes.
- A report schema update must change producer, evaluator, tests, and evidence
  together.
- Raw soak artifacts are ignored; only curated compact evidence belongs in Git.
- Any substantial visual/physics tuning is a new task, not a hidden extension of
  this closeout.
