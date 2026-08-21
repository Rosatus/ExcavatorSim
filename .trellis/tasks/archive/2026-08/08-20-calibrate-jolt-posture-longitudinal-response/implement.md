# Implementation Plan

## Phase A: Baseline And Instrumentation

- [x] Read `trellis-before-dev` context for the Godot frontend layer.
- [x] Add a focused posture/response test harness or extend the existing Jolt
      chassis test with reset, slope, acceleration, coast, brake, and reverse
      samples.
- [x] Capture current SY135/SY205 baseline values for initial pitch, terrain
      normal error, speed curve, stop time/distance, and pitch peaks.

## Phase B: Initial Posture

- [x] Verify rigid-body versus visual-root pitch using the new telemetry.
- [x] Align reset basis to the `TerrainState` normal at the spawn boundary.
- [x] Add model-specific bounded posture calibration only if baseline evidence
      shows a real physics bias after basis alignment.
- [x] Assert clearance, no penetration, bilateral support, and neutral re-arm.

## Phase C: Longitudinal Dynamics

- [x] Add sign-aware fixed-tick drive/brake effort shaping.
- [x] Tune SY135 and SY205 acceleration, coast, brake force, and damping values
      independently while preserving support-load friction and pivot behavior.
- [x] Add monotonic braking and bounded reverse zero-crossing assertions.
- [x] Add peak pitch angle/rate and no-repeat-bounce regression checks.

## Phase D: Verification And Handoff

- [x] Run Godot headless editor scan and focused Jolt tests.
- [x] Run standalone/no-Python smoke for reset, travel, coast, brake, reverse,
      slope and model switch.
- [x] Run `git diff --check` and `python ./.trellis/scripts/task.py validate`
      for this task.
- [x] Update frontend spec/task evidence if new telemetry or calibration rules
      become reusable contracts.
- [ ] Commit, push, archive this child only after explicit implementation
      approval; leave the parent terrain/soil children untouched.

## Risky Files

- `godot/client/scripts/tracked_chassis_controller.gd`
- `godot/client/scripts/jolt_chassis_track_runtime.gd`
- `godot/client/scripts/physics_rig_descriptor.gd`
- `godot/client/resources/physics/sy135_physics_rig.json`
- `godot/client/resources/physics/sy205_physics_rig.json`
- `godot/client/tests/jolt_chassis_track_test.gd`
