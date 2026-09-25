# Implement — 09-26 advanced assist modes

Commit: `af3cd91` feat(assist): relaxed attitude release + simple-digging
black-hole mode

## What landed

- `assist_rate_solver.gd`: `solve_dls_2x3` — damped least-squares for the
  two-row (height + along-axis) Jacobian used when the pitch row is dropped.
- `guided_profile_stage.gd`: `relaxed_attitude` var + shared `apply_params`
  knob; on `BLOCKED_KINEMATIC` the pitch row is dropped and the 2x3 solve is
  retried with saturated joint columns zeroed until feasible. Emits
  `<prefix>_relaxed`, re-latches `_attitude_ref` to the live angle.
- `slope_grade_assist.gd`: `apply_params` forwards shared knobs; the profile
  still gates enable and is consumed once.
- `jolt_chassis_track_runtime.gd`: `_assist_relaxed` persists the toggle
  across `configure()` rebuilds and re-arms both guided stages.
- `tracked_chassis_controller.gd` / `product_session.gd` / `operator_ui.gd` /
  `operator_menu_controls.tscn`: `relaxed_assist` + `simple_digging`
  CheckButtons in AdvancedPanel, config persistence, status snapshots.
- `voxel_excavation_authority.gd`: `set_dump_gate_enabled` master switch —
  gate can never open, staged dumps are cancelled on entry.
- `excavation_world.gd`: `set_simple_digging_enabled`, re-applied after every
  authority rebuild; `simple_digging_enabled` in status snapshots.

## Root causes found during debug

- `commands_out` was captured from the strict solve before the relaxed
  fallback overwrote `solved` — relaxed flags fired but output stayed zero.
- `KinematicArticulationState.propose_step` holds a stationary proposal until
  a zero-command tick arms `neutral_armed`; the standalone test drive must
  feed one zero tick after teleporting or nothing integrates.
- `credit_bucket_mass_for_test` refuses mass beyond remaining capacity — the
  test fills exactly to capacity instead of 2x.
- Dump-gate hold timer is suppressed while `_engaged`; a restore-dump test
  must submit enough open poses for the cut episode to clear and the
  confirmation hold to re-accumulate.

## Known-bad on clean baseline (not this change)

`slope_grade_assist_test.gd` fails on sy205 (no along-axis progress / tooth
off bench) — reproduced identically with the change stashed.
`operator_ui_test.gd` retains the known soil-timing failure.
