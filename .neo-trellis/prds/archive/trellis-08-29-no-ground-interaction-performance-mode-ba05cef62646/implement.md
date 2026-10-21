# Implementation plan — bucket pass-through performance mode

## Phase 1 — Shared policy and product control plane

- [x] Add one shared validated `normal|bucket_passthrough` policy owner.
- [x] Extend `ProductSession` with requested/active/pending state, fixed-tick
  transition application, status snapshot fields, transition sequence/error,
  and test seams.
- [x] Add a no-side-effect preflight before the destructive mode boundary;
  post-preflight setters must be deterministic/no-fail, with unexpected failure
  closing to ordinary mode and empty material rather than fake rollback.
- [x] Ensure startup is always `normal`; preserve active selection across
  lifecycle/reset/model/runtime rebuilds inside the current process.
- [ ] Add unit/standalone coverage for invalid mode, idempotent request,
  transition ordering, partial failure rollback, and non-persistence.

Review gate: no subsystem may define its own spelling or infer the mode from
quality profile, Terrain3D backend, `automatic_soil_enabled`, or soil owner.

## Phase 2 — Bucket physics/query bypass

- [x] Add the policy setter/state/counters to `TrackedChassisController` and
  propagate it during current and future Jolt runtime configuration.
- [x] In `JoltChassisTrackRuntime`, bypass bucket sweep and cut penetration,
  accept full FK motion, clear/suppress support wrench and stale contacts, and
  expose stable diagnostics/counters.
- [x] Gate compatibility-profile ground-lift submission while preserving the
  user-configured normal-mode setting.
- [x] Add focused tests proving bucket surface crossing, full accepted fraction,
  no support wrench/lift, no cut engagement, and unchanged track/chassis support
  for SY205 and SY135.

Review gate: do not disable `TerrainCollider`, terrain identity, track raycasts,
heightfield support fallback, hull support, traction, or chassis collision.

## Phase 3 — Soil, payload, terrain, and effects bypass

- [x] Add the distinct execution policy and monotonic counters to
  `ExcavationWorld`.
- [x] Make entry/exit a clean material-generation boundary: clear selected
  payload, active/released soil, patch/presenter, parcels, pending transfers and
  scheduler brushes, pose/batch/support state, and backend payload feedback;
  retain persistent terrain bytes, `TerrainState.world_generation`, and terrain
  revision while advancing the separate empty material/authority generation.
- [x] Early-return before automatic classification and all active/legacy soil,
  patch, parcel, commit, settle, and feedback work while bypassed.
- [x] Reject manual/test cut/deposit APIs consistently while bypassed.
- [x] Add an independent `SoilEffects` execution gate that clears once and skips
  update work without changing the current quality profile.
- [x] Ensure zero payload is delivered to the Jolt controller at the transition
  and no stale work replays on exit.
- [x] Add deterministic terrain/ledger/payload/counter regressions for entry,
  sustained bypass, exit, reset, reconnect, and model switch.
- [x] Explicitly cover `queue_cut_world`, `queue_deposit_world`, and
  `step_fixed_for_test` so test/debug seams cannot bypass the production gate.

Review gate: transition material loss is intentional and diagnostic-only; do
not fabricate a conservation transfer or revert committed terrain.

## Phase 4 — Game UI and operator diagnostics

- [x] Add a Tools-row toggle with clear pass-through/performance copy and a
  payload-clearing tooltip.
- [x] Bind it to `ProductSession` requested/active state, including pending,
  failure rollback, and test helpers; do not persist it.
- [x] Add compact Advanced diagnostics for active mode, last clear, and core
  executed/bypassed counters.
- [ ] Verify layout at supported window sizes and interaction with Advanced,
  Test Grid, CAN/ICT controls, panel collapse, keyboard/gamepad focus, and
  destructive reset/model dialogs.

## Phase 5 — Integrated, performance, and release validation

- [x] Add a dedicated standalone mode scene/script and register it in
  `godot/client/tests/run_standalone_matrix.ps1`.
- [x] Run focused policy, ProductSession, operator UI, bucket/Jolt, excavation,
  active-patch, TerrainState/collider, Terrain3D, visual, lifecycle, model-switch,
  and release-candidate tests.
- [x] Extend product soak collection and scenario evaluation with the explicit
  mode and work counters; keep ordinary gates unchanged and add inverse
  pass-through gates.
- [x] Run three alternating paired normal/pass-through balanced traces per model;
  preserve raw JSON/logs and write a comparison summary. Record commit/machine,
  trace, order, warm-up, sample duration, three raw p95s, medians, counter
  deltas, and any unchanged baseline ceiling failure without relaxing it.
- [x] Extend isolated source/export smoke to prove default, transition,
  pass-through immutability, lifecycle preservation, and normal restoration.
- [x] Run the full standalone matrix, repository verification, provenance/
  license checks if packaged files change, and inspect fatal logs.
- [ ] Perform a focused human visual pass: bucket visibly penetrates retained
  Terrain3D soil, tracks remain supported, and no soil effect remains active.

## Expected implementation surface

- `godot/client/scripts/product_session.gd`
- `godot/client/scripts/tracked_chassis_controller.gd`
- `godot/client/scripts/jolt_chassis_track_runtime.gd`
- `godot/client/scripts/excavation_world.gd`
- `godot/client/scripts/soil_effects.gd`
- one shared policy script/resource under `godot/client/scripts/`
- `godot/client/scripts/operator_ui.gd`
- `godot/client/scenes/main.tscn`
- focused and standalone tests under `godot/client/tests/`
- `backend/scripts/godot/jolt_product_soak.gd`
- `backend/scripts/jolt_product_soak.py` and/or
  `backend/src/babylon_sim/product_soak.py`
- release/performance documentation and task evidence

## Validation commands

Use the repository's existing Godot discovery/import logic from the runners.
At minimum:

```powershell
& godot/client/tests/run_standalone_matrix.ps1
& godot/client/tests/run_terrain3d_release_validation.ps1 -OutputDirectory "output/bucket pass-through release"
pixi run verify
```

Run focused headless SceneTree scripts during each phase before the full matrix.
Run the product soak through its documented `pixi`/Python entry point after the
mode dimension is implemented, for both `sy205` and `sy135` at `balanced`.

## Risk and rollback points

- The highest-risk boundary is applying one mode across ProductSession,
  controller/Jolt, excavation, and effects in the same fixed tick. Keep the
  transition transactional and add stale-request tests before UI work.
- Do not use collider disablement as an optimization; it breaks chassis support.
- Do not skip clean material reset; stale pose/brush/support work can replay on
  mode exit.
- Keep ordinary mode behavior and current soak predicates untouched so reverting
  the default/request path restores the existing product immediately.
