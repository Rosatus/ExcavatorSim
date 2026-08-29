# Phase 4 exit evidence

## Outcome

- Product default is native `terrain3d`; explicit `soil_shader` rollback and
  automatic synchronized fallback remain supported.
- Approved project procedural soil is unchanged, Terrain3D demo dressing and
  native collision remain disabled, and TerrainState/soil/Jolt/TerrainCollider
  authority is unchanged.
- Advanced operator diagnostics show configured/active backend, material
  identity, and a bounded fallback reason from the existing read-only status
  snapshot.

## Editor, rendering, export, and rollback

- Real Windows Forward+/D3D12 probe:
  `output/terrain3d_phase4/forwardplus-final/run-summary.json` (`passed=true`,
  no fatal shader/material/GDExtension matches). Its evidence retains the
  approved brown/non-black native/fallback render and visible deformation.
- Source/export parity, deliberately executed with a space-containing output
  path:
  `output/terrain3d_phase4/release final spaced/run-summary.json`
  (`passed=true`, all parity fields true, no fatal log matches).
- Both source and exported Windows smoke cover native startup, cut revision 1,
  deposit revision 2, Test Grid, missing-material fail-open, recovery, explicit
  configured `soil_shader` rollback with unchanged authority digest, native
  restoration, SY135 switch, reset, and successful exit.
- The staged package contains `ExcavatorSim.exe`, the Terrain3D release DLL,
  root LICENSE/NOTICE, Terrain3D/Sky3D licenses, and Sky3D provenance. The DLL
  hash is compared with the vendored release binary, not merely inventoried.
- The isolated runner changes only a temporary project entry; the real product
  remains `res://scenes/main.tscn`.

## Automated gates

- Focused Godot gates passed: construction-site terrain, Terrain3D adapter,
  native/fallback authority equivalence for SY205/SY135, visual pass, and
  release-candidate contract.
- The full standalone matrix passed import, foundation, command mapping, HUD,
  ICT result, camera, feedback, Jolt capability/bucket/chassis/articulation,
  authority shadow, and telemetry before stopping at the pre-existing
  `can_gateway_e2e_test.gd` heartbeat failure. The same failure is recorded in
  Phase 2/3 and this phase changes no Gateway code.
- `run_standalone_matrix.ps1` now obtains terminal process status via explicit
  `WaitForExit()`/`Refresh()`, removing a false nonzero/null exit-code race seen
  after a passing feedback test.
- `pixi run verify`: Ruff and Mypy passed; all 182 backend tests passed. Pytest
  then raised the existing Windows Temp `pytest-current` symlink cleanup
  `PermissionError [WinError 5]`, after test completion.
- `pixi run verify-provenance`: passed (3 imported, 5 generated, 13 conceptual).
- `pixi run verify-standalone-paths`: passed.
- `pixi run backend-smoke`: blocked because the user-owned tracked
  `godot/dist/index.html` is currently deleted, so the production CLI reports
  `frontend build is missing; run 'pixi run build' first`. This unrelated dirty
  file was preserved and was not rebuilt or staged by this task.

## Human stop gate and prior phases

- The user explicitly accepted the Phase 1 visual effect on 2026-08-29. Phase
  4 changes only backend default selection and diagnostics; it does not alter
  the accepted material, composition, camera, lighting, or dressing.
- Phase 0–3 are archived under `.trellis/tasks/archive/2026-08/` with their
  rendered, material, lifecycle, and authority/collider evidence. Phase 3 proves
  native/fallback equality and native collision mode/layer `0` for both models.

## Review

- Two independent Phase 4 audits found no blocking product issue. Follow-up
  findings were fixed: space-safe process arguments, single-surface assertions
  at every transition, explicit rollback proof, and vendored/exported DLL hash
  equality.
