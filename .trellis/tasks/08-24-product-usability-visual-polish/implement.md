# Implementation plan

1. [x] `08-24-visual-baseline-evidence`: capture the full double-model,
       triple-quality core before matrix plus the balanced operator journey,
       error/performance evidence, rubric scores, defect backlog, and measurable
       targets. Mark this as legacy soil before/fallback evidence.
2. [x] `08-24-operator-onboarding-hud`: establish product information hierarchy,
       control discovery, warnings, recovery, and diagnostics toggle.
3. [x] `08-24-camera-workflow-presets`: implement four double-model camera
       workflows with collision-safe framing and discoverable input.
4. [x] Begin the soil-independent portion of
       `08-24-construction-site-visual-polish`: composition, scale cues, props,
       lighting, base materials, and fallback parity. Keep the child open.
5. [x] Complete the separate `08-24-gameplay-soil-interaction-rebuild` children:
       full-bucket tool contract and active-patch prototype may proceed in
       parallel, followed by conservative lifecycle, game-feel response, and
       generation-safe migration validation.
6. [x] Finish `08-24-construction-site-visual-polish` by integrating the stable
       persistent-field/active-patch dirty snapshots and close its seam/double-
       pile acceptance gates.
7. [x] `08-24-soil-effects-audio-feedback`: consume stabilized soil transfer,
       patch, ledger, and response snapshots; replace placeholder-looking
       feedback and add a quality-bounded runtime audio mix.
8. [ ] `08-24-product-experience-validation`: record after evidence, execute the
       two-model operator journeys, fix acceptance defects, and close the parent.

## Global validation

- Focused standalone tests for each touched presenter/controller.
- `godot/client/tests/run_standalone_matrix.ps1` with Godot 4.7.1 console.
- `pixi run verify` and `python ./.trellis/scripts/task.py validate <task>`.
- `git diff --check`, asset provenance verification, balanced 1080p performance
  trace, captured Godot error logs, and human side-by-side visual review for
  SY205 and SY135.

## Risk and rollback points

- `godot/client/scenes/main.tscn` and input routing are shared integration points;
  change them in small test-backed increments.
- Optional Terrain3D and fallback TerrainRenderer must remain visually coherent.
- External visual/audio assets are blocked until license/provenance is recorded.
- Camera and HUD transient state must never survive generation/model boundaries.
