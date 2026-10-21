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

## Follow-up fixes (propagation + starvation)

- Relaxed assist never engaged in the real scene: the persisted option sets
  the chassis flag before the deferred Jolt runtime exists, and
  `_configure_jolt_runtime` never re-injected `relaxed_attitude` — every
  model build/switch silently dropped it. Runtime creation now re-pushes the
  params to both guided stages when the chassis flag is set.
- Hard-block-only triggering missed the real failure mode: near a joint
  limit the braking law shrinks the kinematic window toward zero so the
  strict solve crawls asymptotically without ever reporting
  `BLOCKED_KINEMATIC`. The solver now exposes `kin_lo`/`kin_hi` and the
  stage treats reach below `RELAXED_STARVATION_SCALE` as a release
  candidate, adopting the 2x3 solve only when it clears that band.
- `_rebuild_menu_theme` resynced race/test-graphics toggles but not the two
  new advanced toggles, so a theme switch left the relaxed/simple-digging
  buttons showing stale state (the visible-off / runtime-on desync reported
  as 'simple digging cannot be turned off'). Both sync helpers now run on
  rebuild.

## Simple digging scope selector (three-state)

The toggle became an OptionButton with OFF / ALWAYS / ASSIST_ONLY
(`ProductSession.SIMPLE_DIGGING_*`). The session owns
`simple_digging_mode` and recomputes the effective gate every
`_physics_process` tick because chassis-side assist toggles bypass the
session (`_assist_mode_active` = level assist enabled or slope mode
ACTIVE; preview does not count). `ExcavationWorld` still takes only the
effective bool, so gate/cutting semantics are unchanged. UI stores the int
under the same `simple_digging` config key; legacy bool values migrate
true->ALWAYS, false->OFF. Selector items are repopulated in
`_connect_controls` since the menu rebuild re-instantiates the panel.
