# Implementation Plan

## Phase A: Baseline And Instrumentation

- [ ] Read `trellis-before-dev` context for the Godot frontend layer.
- [ ] Add a focused posture/response test harness or extend the existing Jolt
      chassis test with reset, slope, acceleration, coast, brake, and reverse
      samples.
- [ ] Capture current SY135/SY205 baseline values for initial pitch, terrain
      normal error, speed curve, stop time/distance, and pitch peaks.

## Phase B: Initial Posture

- [ ] Verify rigid-body versus visual-root pitch using the new telemetry.
- [ ] Align reset basis to the `TerrainState` normal at the spawn boundary.
- [ ] Add model-specific bounded posture calibration only if baseline evidence
      shows a real physics bias after basis alignment.
- [ ] Assert clearance, no penetration, bilateral support, and neutral re-arm.

## Phase C: Longitudinal Dynamics

- [ ] Add sign-aware fixed-tick drive/brake effort shaping.
- [ ] Tune SY135 and SY205 acceleration, coast, brake force, and damping values
      independently while preserving support-load friction and pivot behavior.
- [ ] Add monotonic braking and bounded reverse zero-crossing assertions.
- [ ] Add peak pitch angle/rate and no-repeat-bounce regression checks.

## Phase D: Verification And Handoff

- [ ] Run Godot headless editor scan and focused Jolt tests.
- [ ] Run standalone/no-Python smoke for reset, travel, coast, brake, reverse,
      slope and model switch.
- [ ] Run `git diff --check` and `python ./.trellis/scripts/task.py validate`
      for this task.
- [ ] Update frontend spec/task evidence if new telemetry or calibration rules
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
