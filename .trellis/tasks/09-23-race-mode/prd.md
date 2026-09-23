# Race mode for wheeled and tracked locomotion

## Goal

Advanced-settings toggle "竞速模式 (Race Mode)" that greatly raises machine speed
limits and gives a Forza-Horizon-like driving feel, without changing normal-mode
behavior.

## Locked decisions (user, 2026-09-23)

- Speed target: moderate exaggeration — tracked ~14 m/s (≈50 km/h), wheeled ~28 m/s (≈100 km/h).
- Tracked feel: keep skid-steer, add yaw assist + stability (not car-like drift).
- Scope: only the default `jolt_authoritative` path (`JoltChassisTrackRuntime`); the legacy
  kinematic `TrackedLocomotionState` path stays untouched (its validator caps at 5 m/s).
- Work equipment (boom/arm/bucket) speeds unchanged.

## Design

- New `resources/physics/race_mode_profiles.json` (schema v1): `defaults.tracked` /
  `defaults.wheeled` overlays (`set` absolute values, `scale` multipliers, `assist`
  race-only params) plus optional `models.<id>` partial overrides. Separate file because
  `PhysicsRigDescriptor` validates with `_exact_fields` — extra keys in rig JSON would
  fail normal-mode validation.
- New `scripts/race_mode_profile.gd` (`RaceModeProfile`): loads + merges overlays for a
  model/kind, mirroring `WheeledMachineProfile` conventions.
- New `scripts/race_track_contact_solver.gd` (`RaceTrackContactSolver extends TrackContactSolver`):
  configure accepts overlaid tracks dict; `step` post-pass adds race assists
  (yaw-assist torque toward commanded yaw rate, attitude-stabilizing torque, optional
  downforce). Schema-declared-but-unused `yaw_assist_scale`/`attitude_*` give the semantics.
- New `scripts/race_wheeled_locomotion_state.gd` (`RaceWheeledLocomotionState extends
  WheeledLocomotionState`): configure merges overlay into valid wheel parameter keys;
  `step` post-pass adds speed² downforce + anti-roll.
- `JoltChassisTrackRuntime`: `race_mode` flag + `set_race_mode()`; keeps base
  `_tracks`/`_dynamics`/wheel params copies; swaps solver instance and body speed clamps
  on toggle; `stop_motion` + solver reset on switch; flag reapplied across `configure`
  (model switch).
- `TrackedChassisController.set_race_mode` forwards; `ProductSession.request_race_mode`
  mirrors `request_level_assist`; `OperatorUI` CheckButton `RaceMode` in AdvancedPanel
  persisted as `ui.race_mode` in `user://operator_ui.cfg`.

## Acceptance

- Toggle visible in 高级工具 page for all three UI themes; state persists across restart.
- Race on: tracked machine exceeds ~10 m/s, wheeled exceeds ~20 m/s (bounded), with
  faster throttle/brake response and stability assists; race off: byte-identical normal
  parameters and existing test suite unchanged.
- Neutral-arm safety, focus loss, model switch, reset paths unaffected.

## Checks

- New `tests/race_mode_test.gd` (headless SceneTree): solver swap, overlay math, clamp
  raise, neutral rearm preserved.
- Regression: `tracked_contact_regression_test`, `jolt_chassis_track_test`,
  `wheeled_locomotion_test`, `sy155w_wheeled_test`, `operator_ui_test`.
- Godot binary: `C:\apps\godot_voxel\godot.windows.editor.x86_64.exe --headless --path
  godot/client --fixed-fps 60 --script res://tests/<name>.gd`
