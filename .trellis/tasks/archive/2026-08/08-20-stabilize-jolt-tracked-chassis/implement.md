# Implementation Plan

## Phase A: Baseline And Contract

- [x] Add quantitative settle/straight telemetry and regression thresholds for heave, tilt and hull/probe ownership switching.
- [x] Extend both physics-rig descriptors and validation for support/traction tuning.
- [x] Add hull/probe ownership telemetry and assertions proving the terrain mask does not oscillate after support takeover.

## Phase B: Coherent Support Solver

- [x] Add spring-damper support forces at active track probes.
- [x] Derive traction and braking caps from actual per-probe support load.
- [x] Adjust spawn height and safety hull clearance/mask.
- [x] Compute all track/support forces from one fixed-tick contact snapshot.
- [x] Correct suspension damping direction and track per-probe load history.
- [x] Move simplified traction to COM height while preserving differential yaw.
- [x] Add bounded descriptor-driven attitude stabilization and identity-valid heightfield support fallback.

## Phase C: Skid-Steer Tuning

- [x] Add pivot-intent blending and reduced lateral resistance.
- [x] Remove or reduce competing yaw torque assistance.
- [ ] Tune SY205 and SY135 to reach target-relative speed and stability gates.

## Phase D: Verification

- [ ] Run focused Jolt chassis tests for straight, arc, pivot, brake, partial support, reset, and model switch.
- [ ] Run the standalone matrix and `pixi run verify`.
- [ ] Run Godot MCP live travel/pivot smoke with Python stopped.
- [ ] Update task evidence, commit, push if requested, and archive this child before child 2 starts.

## Risky Files

- `godot/client/scripts/jolt_chassis_track_runtime.gd`
- `godot/client/scripts/tracked_chassis_controller.gd`
- `godot/client/resources/physics/sy205_physics_rig.json`
- `godot/client/resources/physics/sy135_physics_rig.json`
- `godot/client/tests/jolt_chassis_track_test.gd`

## Current Verification Evidence

- Godot 4.7.1 headless editor scan completes without a new parse error.
- `jolt_chassis_track_test.gd` passes for SY205 and SY135.
- Flat settle RMS: SY205 heave `0.0004 m/s`, tilt `0.0002 rad/s`; SY135 heave `0.0002 m/s`, tilt `0.0007 rad/s`.
- Straight travel settles at the configured belt targets with effectively zero heave/tilt RMS; braking reaches near-zero speed with four contacts per track.
- Slope/mound traversal retains four contacts per track, travels `8.276 m`, gains height, and switches hull ownership only once.
- Godot MCP 4.7.1 live smoke confirms straight and pivot command sequences return to near-zero heave/tilt rates with balanced support and no quality flags.
- User visually confirmed the repeating rearward rocking is no longer present.
